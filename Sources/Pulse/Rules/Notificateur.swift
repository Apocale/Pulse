import Foundation
import UserNotifications

/// Qui envoie les notifications. Le moteur et le surveillant ne connaissent
/// que ce protocole : les tests leur donnent un carnet, l'app le centre de
/// notifications de macOS.
@MainActor
protocol Notificateur: AnyObject {
    /// Envoie, ou dit pourquoi pas : `fin(nil)` si macOS l'a prise, sinon
    /// la raison. Ne demande JAMAIS l'autorisation.
    func envoyer(_ notification: NotificationRegle, fin: @escaping @Sendable @MainActor (String?) -> Void)
}

/// Les notifications de macOS.
///
/// Ne pas déranger et les modes de concentration : chaque notification est
/// ORDINAIRE (`interruptionLevel = .active`), jamais « urgente » au sens du
/// système. macOS la range alors sans bannière ni son dans le Centre de
/// notifications tant qu'une concentration est active — c'est lui qui
/// tranche, et il sait ce que Pulse ne peut pas lire sans une autorisation
/// de plus (`INFocusStatusCenter`).
///
/// Jamais créé hors du bundle (`swift test`, `.build/release/Pulse`) :
/// `UNUserNotificationCenter.current()` y lève une exception. Jamais sous
/// `--probe`, `--snapshot`, `--banc` (`Persistence`).
@MainActor
final class NotificateurSysteme: NSObject, ObservableObject, Notificateur, UNUserNotificationCenterDelegate {
    static let shared = NotificateurSysteme()

    enum Statut: String {
        case inconnu, jamaisDemande, autorise, refuse, horsApp

        var texte: String {
            switch self {
            case .inconnu:       return "pas encore lu"
            case .jamaisDemande: return "jamais demandées : macOS les demandera quand vous allumerez une règle qui notifie"
            case .autorise:      return "autorisées"
            case .refuse:        return "refusées : Réglages Système › Notifications › Pulse"
            case .horsApp:       return "indisponibles hors de Pulse.app"
            }
        }
    }

    @Published private(set) var statut: Statut = .inconnu

    nonisolated static var disponible: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil && Persistence.enabled
    }

    private var centre: UNUserNotificationCenter? {
        guard Self.disponible else { return nil }
        let centre = UNUserNotificationCenter.current()
        if centre.delegate == nil { centre.delegate = self }
        return centre
    }

    /// Lit l'état de l'autorisation, sans rien demander.
    func lireStatut() {
        guard let centre else { statut = .horsApp; return }
        centre.getNotificationSettings { reglages in
            let lu = Self.statut(reglages.authorizationStatus)
            Task { @MainActor in NotificateurSysteme.shared.statut = lu }
        }
    }

    /// La demande de macOS, à l'écran. Appelée SEULEMENT quand Isma allume
    /// lui-même une règle qui notifie, et seulement si elle n'a jamais été
    /// faite : jamais au lancement, jamais par un essai.
    ///
    /// `fin(accordée, erreur)` : l'erreur de macOS telle quelle, s'il en
    /// rend une — un refus de l'app elle-même (signature ad hoc ?) ne doit
    /// pas se lire comme un refus d'Isma.
    func demanderAutorisation(fin: @escaping @Sendable @MainActor (Bool, String?) -> Void) {
        guard let centre else { fin(false, "hors de Pulse.app"); return }
        centre.requestAuthorization(options: [.alert, .sound]) { accorde, erreur in
            let raison = erreur.map { "\($0.localizedDescription) [\(($0 as NSError).domain) \(($0 as NSError).code)]" }
            Task { @MainActor in
                NotificateurSysteme.shared.statut = accorde ? .autorise : .refuse
                fin(accorde, raison)
            }
        }
    }

    /// Demande l'autorisation si — et seulement si — macOS n'a jamais posé
    /// la question. `fin(nil)` : rien n'a été demandé.
    func demanderSiJamaisDemande(fin: @escaping @Sendable @MainActor (Bool?, String?) -> Void) {
        guard let centre else { fin(nil, nil); return }
        centre.getNotificationSettings { reglages in
            let lu = reglages.authorizationStatus
            Task { @MainActor in
                NotificateurSysteme.shared.statut = Self.statut(lu)
                guard lu == .notDetermined else { fin(nil, nil); return }
                NotificateurSysteme.shared.demanderAutorisation { fin($0, $1) }
            }
        }
    }

    func envoyer(_ notification: NotificationRegle, fin: @escaping @Sendable @MainActor (String?) -> Void) {
        guard let centre else { fin("hors de Pulse.app : rien n'est envoyé"); return }
        let titre = notification.titre, corps = notification.corps, son = notification.son
        centre.getNotificationSettings { reglages in
            let statut = reglages.authorizationStatus
            Task { @MainActor in
                NotificateurSysteme.shared.statut = Self.statut(statut)
                guard statut == .authorized || statut == .provisional else {
                    fin(statut == .denied ? "notifications refusées dans Réglages Système"
                                          : "autorisation jamais demandée")
                    return
                }
                let contenu = UNMutableNotificationContent()
                contenu.title = titre
                contenu.body = corps
                contenu.sound = son ? .default : nil
                contenu.threadIdentifier = "pulse.regles"
                contenu.interruptionLevel = .active
                let requete = UNNotificationRequest(identifier: "pulse.regles.\(UUID().uuidString)",
                                                    content: contenu, trigger: nil)
                do {
                    try await UNUserNotificationCenter.current().add(requete)
                    fin(nil)
                } catch {
                    fin(error.localizedDescription)
                }
            }
        }
    }

    nonisolated static func statut(_ s: UNAuthorizationStatus) -> Statut {
        switch s {
        case .authorized, .provisional, .ephemeral: return .autorise
        case .denied:                               return .refuse
        case .notDetermined:                        return .jamaisDemande
        @unknown default:                           return .inconnu
        }
    }

    /// Pulse au premier plan (la fenêtre Réglages ouverte) : la bannière
    /// s'affiche quand même. Rien ne s'ouvre au clic.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

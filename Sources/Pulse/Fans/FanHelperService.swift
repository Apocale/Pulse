import Foundation
import AppKit
import CryptoKit
import PulseFanKit

/// L'installation du helper des ventilateurs — et RIEN d'autre n'installe
/// quoi que ce soit : `install()` n'est appelé que par le bouton « Installer
/// le helper… » de la page Ventilateurs, après l'accord d'Isma dans une
/// alerte qui dit en deux phrases ce qui sera installé et comment l'enlever.
///
/// Un démon launchd classique, installé une fois : `PulseHelper --installe`
/// lancé en root par la demande de mot de passe de macOS (c'est Isma qui le
/// tape) copie le binaire dans `/Library/PrivilegedHelperTools` et son plist
/// dans `/Library/LaunchDaemons` — deux dossiers que seul root peut écrire.
/// Les recompilations de Pulse.app (une par fusion) ne le touchent pas.
/// `SMAppService.daemon` a été écarté : avec une signature ad hoc, launchd
/// fige au premier enregistrement l'empreinte du helper, et chaque
/// recompilation donne « Launch Constraint Violation » (sources dans
/// docs/chantiers/14-ventilateurs.md).
///
/// Désinstallation en un clic : le helper, qui est root, s'efface lui-même
/// sur demande (commande `uninstall`) ; s'il ne répond pas, la même demande
/// de mot de passe lance `PulseHelper --desinstalle`.
@MainActor
enum FanHelperService {
    enum State: Equatable {
        /// Rien d'installé : Pulse ne touche pas aux ventilateurs.
        case absent
        /// Installé dans /Library ; launchd le lance à la demande.
        case installed
        /// Rien à faire d'ici (bundle sans helper).
        case unavailable(String)

        var probeText: String {
            switch self {
            case .absent:               return "absent — rien d'installé, rien d'enregistré"
            case .installed:            return "installé (\(FanProtocol.installedHelper))"
            case .unavailable(let why): return why
            }
        }
    }

    /// Le helper embarqué dans ce Pulse.app, celui qu'une installation copie.
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PulseHelper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var state: State {
        let fm = FileManager.default
        if fm.fileExists(atPath: FanProtocol.installedPlist) || fm.fileExists(atPath: FanProtocol.installedHelper) {
            return .installed
        }
        guard bundledHelper == nil else { return .absent }
        // Un Pulse.app sans helper est la version à partager
        // (outils/distribue.sh) : le pilotage n'a jamais été essayé sur un
        // vrai Mac, il ne part pas sur celui d'un autre.
        return .unavailable(Bundle.main.bundleURL.pathExtension == "app"
            ? "Pas dans cette version de Pulse : le réglage des ventilateurs n'a pas encore été essayé sur un vrai Mac. Pulse les lit, macOS les pilote."
            : "absent — et ce Pulse ne l'embarque pas (lancé hors de Pulse.app)")
    }

    static var isInstalled: Bool { state == .installed }

    /// Le helper installé est-il celui de ce Pulse ? Comparés octet pour
    /// octet (SHA-256) ; nil si l'un des deux manque.
    static var upToDate: Bool? {
        guard let bundled = bundledHelper,
              let a = try? Data(contentsOf: bundled),
              let b = try? Data(contentsOf: URL(fileURLWithPath: FanProtocol.installedHelper)) else { return nil }
        return SHA256.hash(data: a) == SHA256.hash(data: b)
    }

    static var bundledDescription: String {
        guard let bundled = bundledHelper else {
            return "à lire depuis Pulse.app (Contents/MacOS/PulseHelper)"
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: bundled.path)[.size] as? Int) ?? 0
        return "\(bundled.path) (\(size / 1000) ko, signé ad hoc), inerte tant que rien n'a été accepté"
    }

    /// Les deux phrases de l'alerte d'installation.
    static let consent = """
        Pulse va installer un petit programme, le « helper », qui tourne en administrateur et ne sait faire qu'une chose : régler la vitesse des deux ventilateurs, toujours entre le minimum et le maximum d'Apple, en rendant la main à macOS dès que Pulse quitte, que le Mac s'endort ou que quelque chose cloche. macOS va vous demander votre mot de passe ; pour l'enlever, un clic sur « Désinstaller » dans cette page.
        """

    static let explanation = "Sans helper, Pulse lit les ventilateurs mais ne peut pas les régler : écrire dans le SMC exige l'administrateur. Rien n'est installé tant que vous ne l'avez pas accepté, et le mode reste Automatique tant que vous n'en choisissez pas un autre."

    /// Lance `PulseHelper --installe` en root, par la demande de mot de
    /// passe administrateur de macOS. Rend la phrase à afficher.
    static func install() -> String {
        guard let helper = bundledHelper else { return "Ce Pulse n'embarque pas le helper." }
        switch runAsAdministrator(helper.path, "--installe") {
        case .success:
            return "Helper installé. macOS peut signaler un « élément d'arrière-plan ajouté » : c'est lui."
        case .cancelled:
            return "Installation annulée : rien n'a changé."
        case .failed(let why):
            return "Installation impossible : \(why)"
        }
    }

    /// Le helper s'efface lui-même ; s'il ne répond pas, la demande de mot
    /// de passe lance `--desinstalle`.
    static func uninstall() -> String {
        let client = FanXPCClient()
        defer { client.close() }
        if let status = client.sendAndWait(FanRequest(command: .uninstall), timeout: 2), status.accepted {
            // Il efface ses fichiers 0,3 s après sa réponse.
            for _ in 0..<20 where isInstalled { Thread.sleep(forTimeInterval: 0.1) }
            if !isInstalled { return "Helper désinstallé : macOS a la main." }
        }
        guard let helper = bundledHelper else {
            return "Le helper ne répond pas. Dans le Terminal : sudo \(FanProtocol.installedHelper) --desinstalle"
        }
        switch runAsAdministrator(helper.path, "--desinstalle") {
        case .success:   return "Helper désinstallé : macOS a la main."
        case .cancelled: return "Désinstallation annulée : le helper reste installé, en automatique."
        case .failed(let why): return "Désinstallation impossible : \(why)"
        }
    }

    enum Outcome { case success, cancelled, failed(String) }

    /// La demande de mot de passe administrateur de macOS, pour UNE
    /// commande fixe : le helper embarqué et un seul argument connu.
    private static func runAsAdministrator(_ path: String, _ argument: String) -> Outcome {
        guard argument == "--installe" || argument == "--desinstalle" else { return .failed("argument inconnu") }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script (quoted form of \"\(escaped)\") & \" \(argument)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed("script illisible") }
        script.executeAndReturnError(&error)
        guard let error else { return .success }
        // -128 : « Annuler » dans la demande de mot de passe.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "erreur inconnue")
    }
}

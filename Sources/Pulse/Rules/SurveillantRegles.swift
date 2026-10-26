import Foundation
import AppKit
import Combine

/// Le surveillant : nourrit le moteur des relevés du `Sampler`, écrit le
/// journal, passe les notifications au notificateur, publie ce qui est en
/// cours (barre de menus, page Règles).
///
/// COÛT NUL quand aucune règle n'est active : ni abonnement au relevé, ni
/// minuterie — il n'écoute que `regles.json`. Une règle allumée l'abonne à
/// la publication de la mémoire, UNE fois par relevé (5 s panneau fermé) :
/// il lit des valeurs déjà publiées, sans relevé de plus ; seul le forfait,
/// qui additionne le cumul du cycle, se relit une fois par minute au plus.
/// Les plages horaires et le regroupement se règlent au relevé suivant :
/// pas de minuterie à eux.
@MainActor
final class SurveillantRegles: ObservableObject {
    static let shared = SurveillantRegles()

    /// Un épisode en cours, tel que la barre et la page Règles le montrent.
    struct Signal: Equatable, Identifiable {
        var id: String
        var regle: String
        var nom: String
        var texte: String
        var debut: Date
        /// La règle demande le symbole dans la barre.
        var barre: Bool
    }

    @Published private(set) var enCours: [Signal] = []

    let store: ReglesStore
    var notificateur: Notificateur
    private(set) var moteur = MoteurRegles()
    private var detecteur = DetecteurEvenements()
    private weak var sampler: Sampler?
    private var abonnement: AnyCancellable?
    private var abonnementRegles: AnyCancellable?
    private var forfait: (lu: Date, valeur: Double?)?
    private var repris = false
    private let journalise: Bool
    private let urlJournal: URL
    /// Lu à chaque évaluation ; remplaçable par les tests.
    var appAuPremierPlan: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    /// Le forfait additionne trente jours de cumul : une fois par minute.
    static let rythmeForfait: TimeInterval = 60

    /// Sans argument : les règles d'Isma et les notifications de macOS.
    init(store: ReglesStore? = nil, notificateur: Notificateur? = nil,
         journal: URL = JournalRegles.url, journalise: Bool = Persistence.enabled) {
        self.store = store ?? .shared
        self.notificateur = notificateur ?? NotificateurSysteme.shared
        self.urlJournal = journal
        self.journalise = journalise
    }

    /// Abonné au relevé ? Faux tant qu'aucune règle n'est active.
    var ecoute: Bool { abonnement != nil }

    /// Au lancement de l'app : écoute les règles, et le relevé seulement
    /// si l'une d'elles est active.
    func demarrer(_ sampler: Sampler) {
        self.sampler = sampler
        // `@Published` publie AVANT d'écrire : les règles arrivent par le
        // flux, `store.regles` serait encore l'ancienne liste.
        abonnementRegles = store.$fichier
            .map(\.regles)
            .removeDuplicates { $0.filter(\.active) == $1.filter(\.active) }
            .sink { [weak self] regles in
                MainActor.assumeIsolated { self?.actualiser(regles) }
            }
    }

    func actualiser(_ regles: [Regle]) {
        // Les fins de copie ne quittent la file du relevé que pour une règle
        // allumée qui les attend (19-suivis).
        DiskActivity.ecouteCopies = regles.contains { $0.active && $0.mesure == "disques.copieTerminee" }
        guard regles.contains(where: \.active) else {
            exportsEnAttente = []
            guard abonnement != nil || !enCours.isEmpty else { return }
            abonnement = nil
            journal(moteur.eteindre(date: Date(), regles: regles))
            enCours = []
            return
        }
        if !repris {
            repris = true
            if journalise { JournalRegles.elaguer(url: urlJournal) }
            moteur.reprendre(JournalRegles.lire(depuis: urlJournal, apres: Date().addingTimeInterval(-JournalRegles.retention)),
                             regles: regles)
        }
        guard abonnement == nil, let sampler else { return }
        // Une référence neuve : allumer « Premiere a planté » à 15 h ne
        // notifie pas le plantage de 11 h.
        detecteur = DetecteurEvenements()
        abonnement = sampler.$memory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.evaluer() } }
    }

    /// Un relevé : lit les mesures des règles actives, fait tourner le
    /// moteur, écrit, envoie, publie.
    func evaluer(date: Date = Date()) {
        guard let sampler else { return }
        let regles = store.regles
        let actives = regles.filter(\.active)
        let mesures = Set(actives.map(\.mesure))
        let releve = lire(sampler, mesures: mesures, date: date)
        let (lignes, notifications) = moteur.evaluer(regles, releve, alertes: store.fichier.alertes)
        journal(lignes)
        for notification in notifications {
            notificateur.envoyer(notification) { [weak self] raison in
                guard let self, let raison else { return }
                journal(notification.alertes.map {
                    EntreeJournal(date: Date(), genre: .nonEnvoyee, regle: $0.regle, nom: $0.nom,
                                  sujet: $0.sujet, sujetNom: $0.sujetNom, texte: raison)
                })
            }
        }
        publier(regles)
    }

    /// Le relevé du moteur, tiré de ce que le `Sampler` a déjà publié.
    func lire(_ sampler: Sampler, mesures: Set<String>, date: Date) -> ReleveRegles {
        var entrees = EntreesRegles(memoire: sampler.memory, cpu: sampler.cpu, volumes: sampler.volumes,
                                    previsions: sampler.forecasts, series: sampler.series,
                                    reseau: sampler.networkTrail.isEmpty ? nil : sampler.network)
        if mesures.contains("reseau.forfait") {
            if let forfait, date.timeIntervalSince(forfait.lu) < Self.rythmeForfait {
                entrees.forfait = forfait.valeur
            } else {
                let valeur = sampler.forfait.fraction
                forfait = (date, valeur)
                entrees.forfait = valeur
            }
        }
        var releve = ReleveRegles(date: date,
                                  valeurs: LectureRegles.valeurs(entrees, mesures: mesures, date: date),
                                  enMontage: LectureRegles.enMontage(appAuPremierPlan()))
        let evenementiel = mesures.contains { CatalogueMesures.mesure($0)?.unite == .evenement }
        if evenementiel {
            var evenements = detecteur.observer(export: sampler.export, incidents: sampler.incidents,
                                                copies: sampler.disks.copiesTerminees, date: date)
            // Un export fini attend le journal d'AME, relu sur la file du
            // relevé : dit un relevé plus tard, avec son fichier et son issue.
            // Règle éteinte entre-temps : rien ne reste en attente, qu'une
            // fin d'export ancienne ne se dise pas à son retour.
            if !mesures.contains("montage.exportTermine") { exportsEnAttente = [] }
            if let finis = evenements.removeValue(forKey: "montage.exportTermine"),
               mesures.contains("montage.exportTermine") {
                exportsEnAttente += finis
                journalAME = nil
                let depuis = finis.compactMap(\.debut).min() ?? date.addingTimeInterval(-3600)
                sampler.exportsTermines(depuis: depuis.addingTimeInterval(-120)) { [weak self] records in
                    self?.journalAME = records
                }
            }
            if let prets = exportsPrets(date: date) { evenements["montage.exportTermine"] = prets }
            releve.evenements = evenements
        }
        return releve
    }

    // MARK: - Export terminé : le fichier et son issue (19-suivis)

    /// Les fins d'export qui attendent la relecture du journal d'AME.
    private var exportsEnAttente: [Evenement] = []
    /// La réponse de cette relecture : les exports terminés qu'il décrit.
    private var journalAME: [ExportRecord]?
    /// Au-delà, l'export se dit sans son fichier : l'app et la durée.
    static let attenteJournal: TimeInterval = 20

    /// Les fins d'export à dire maintenant : le journal a répondu, ou elles
    /// ont assez attendu. `nil` s'il n'y a rien à dire.
    func exportsPrets(date: Date) -> [Evenement]? {
        guard !exportsEnAttente.isEmpty else { return nil }
        let echu = exportsEnAttente.contains { date.timeIntervalSince($0.date) >= Self.attenteJournal }
        guard journalAME != nil || echu else { return nil }
        let prets = exportsEnAttente.map { fin -> Evenement in
            guard let journal = journalAME, let debut = fin.debut else { return fin }
            var dit = fin
            dit.texte = LectureRegles.texteExport(LectureRegles.fichiersExport(journal, debut: debut, fin: fin.date),
                                                  repli: fin.texte)
            return dit
        }
        exportsEnAttente = []
        return prets
    }

    /// Pour les tests : une fin d'export en attente, et la réponse du journal.
    func attendreExport(_ fin: Evenement) { exportsEnAttente.append(fin) }
    func journalRelu(_ records: [ExportRecord]) { journalAME = records }

    private func publier(_ regles: [Regle]) {
        let signaux = moteur.enCours(regles).map { regle, sujet, episode in
            Signal(id: MoteurRegles.cle(regle.id, sujet), regle: regle.id, nom: regle.nom,
                   texte: episode.texte, debut: episode.debut, barre: regle.barre)
        }
        if signaux != enCours { enCours = signaux }
    }

    private func journal(_ lignes: [EntreeJournal]) {
        guard journalise else { return }
        JournalRegles.ecrire(lignes, vers: urlJournal)
    }

    // MARK: - La barre de menus

    /// Pour l'icône de barre : `nil` si aucune règle allumée ne demande la
    /// cloche (rien de réservé, l'icône garde sa largeur d'avant), sinon
    /// s'il faut l'allumer. `--snapshot x.png --barre --alerte` la montre
    /// allumée, sans rien écrire.
    static var alerteBarre: Bool? {
        if !Persistence.enabled, CommandLine.arguments.contains("--alerte") { return true }
        return alerte(regles: shared.store.regles, enCours: shared.enCours)
    }

    static func alerte(regles: [Regle], enCours: [Signal]) -> Bool? {
        guard regles.contains(where: { $0.active && $0.barre }) else { return nil }
        return enCours.contains(where: \.barre)
    }

    /// Ce que l'infobulle et VoiceOver disent de la cloche.
    var texteBarre: String? {
        let signaux = enCours.filter(\.barre)
        guard let premier = signaux.first else { return nil }
        let autres = signaux.count - 1
        return "alerte : \(premier.nom)" + (autres > 0 ? " et \(autres) autre\(autres > 1 ? "s" : "")" : "")
    }

    /// Le segment de barre pour le chantier 09 (un élément par module) :
    /// les valeurs seulement, le dessin est à lui.
    var segmentBarre: MenuBarSegment? {
        let signaux = enCours.filter(\.barre)
        guard !signaux.isEmpty, let dit = texteBarre else { return nil }
        return MenuBarSegment(label: "ALERTE", value: "\(signaux.count)", spoken: dit)
    }

    /// Le bouton « Envoyer une notification d'essai » : Isma voit à quoi
    /// ressemble une alerte, sans attendre un vrai problème. macOS demande
    /// l'autorisation à ce moment-là s'il ne l'a jamais fait — c'est un
    /// clic d'Isma, jamais un essai automatique.
    func essayer(_ fin: @escaping @Sendable @MainActor (String) -> Void) {
        guard NotificateurSysteme.disponible else { fin("indisponible hors de Pulse.app"); return }
        let systeme = NotificateurSysteme.shared
        systeme.demanderSiJamaisDemande { [weak self] accorde, erreur in
            if let accorde {
                self?.journal([EntreeJournal(date: Date(), genre: .autorisation, regle: "essai",
                                             nom: "Notification d'essai",
                                             texte: (accorde ? "accordée" : "refusée") + (erreur.map { " — \($0)" } ?? ""))])
            }
            let essai = NotificationRegle(titre: "Pulse · essai",
                                          corps: "Une règle vous préviendra ainsi, une fois par épisode.",
                                          son: false, alertes: [])
            systeme.envoyer(essai) { [weak self] raison in
                self?.journal([EntreeJournal(date: Date(), genre: raison == nil ? .notifiee : .nonEnvoyee,
                                             regle: "essai", nom: "Notification d'essai", texte: raison ?? "")])
                fin(raison.map { "Pas envoyée : \($0)." } ?? "Envoyée : elle s'affiche en haut à droite de l'écran.")
            }
        }
    }

    /// Isma allume une règle qui notifie : la seule occasion de demander
    /// l'autorisation à macOS, et une fois seulement (le statut le dit).
    func regleAllumee(_ regle: Regle) {
        guard regle.notification, NotificateurSysteme.disponible else { return }
        NotificateurSysteme.shared.demanderSiJamaisDemande { [weak self] accorde, erreur in
            guard let accorde else { return }
            self?.journal([EntreeJournal(date: Date(), genre: .autorisation, regle: regle.id, nom: regle.nom,
                                         texte: (accorde ? "accordée" : "refusée") + (erreur.map { " — \($0)" } ?? ""))])
        }
    }
}

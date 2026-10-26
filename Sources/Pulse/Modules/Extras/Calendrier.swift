import SwiftUI
import EventKit

/// Un événement, tel que la carte l'affiche.
struct EvenementAgenda: Equatable, Identifiable {
    var id: String
    var titre: String
    var debut: Date
    var fin: Date
    var journee: Bool
    var calendrier: String

    /// En cours à cet instant (une journée entière ne l'est jamais : elle
    /// n'a pas d'heure, la carte l'écrit « journée »).
    func enCours(_ maintenant: Date) -> Bool { !journee && debut <= maintenant && maintenant < fin }
}

/// L'accès au calendrier, dans les mots de la carte.
enum AccesCalendrier: String, Equatable {
    case jamaisDemande = "jamais demandé"
    case accorde = "accordé"
    case refuse = "refusé"
    case restreint = "restreint par un profil"
    case ecritureSeule = "écriture seule"
}

/// D'où viennent les événements : EventKit dans l'app installée, un magasin
/// simulé dans les tests et sous `--exemple`. Rien d'autre ne touche
/// EventKit.
@MainActor
protocol SourceEvenements: AnyObject {
    var acces: AccesCalendrier { get }
    /// Demande l'accès. L'app installée seulement, carte activée par Isma.
    func demanderAcces(_ fini: @escaping @Sendable @MainActor (AccesCalendrier) -> Void)
    func evenements(de debut: Date, a fin: Date) -> [EvenementAgenda]
}

/// EventKit. Créé seulement dans l'app installée, carte activée : jamais par
/// `--snapshot`, `--probe`, `--banc`, `--rendus` ni `swift test`.
@MainActor
final class SourceEventKit: SourceEvenements {
    private lazy var magasin = EKEventStore()

    /// Lit l'état sans rien demander : `authorizationStatus` ne montre
    /// jamais de fenêtre.
    static var statut: AccesCalendrier {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .jamaisDemande
        case .restricted: return .restreint
        case .denied: return .refuse
        case .writeOnly: return .ecritureSeule
        case .fullAccess: return .accorde
        @unknown default: return .refuse
        }
    }

    var acces: AccesCalendrier { Self.statut }

    func demanderAcces(_ fini: @escaping @Sendable @MainActor (AccesCalendrier) -> Void) {
        magasin.requestFullAccessToEvents { _, _ in
            Task { @MainActor in fini(SourceEventKit.statut) }
        }
    }

    func evenements(de debut: Date, a fin: Date) -> [EvenementAgenda] {
        guard acces == .accorde else { return [] }
        let predicat = magasin.predicateForEvents(withStart: debut, end: fin, calendars: nil)
        return magasin.events(matching: predicat).map { e in
            EvenementAgenda(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
                      titre: e.title?.isEmpty == false ? e.title! : "Sans titre",
                      debut: e.startDate, fin: e.endDate, journee: e.isAllDay,
                      calendrier: e.calendar?.title ?? "")
        }
    }
}

/// Un magasin d'événements simulé : les tests, et la carte sous `--exemple`.
@MainActor
final class SourceSimulee: SourceEvenements {
    var acces: AccesCalendrier
    var tous: [EvenementAgenda]
    /// Réponse à la prochaine demande d'accès.
    var reponse: AccesCalendrier
    private(set) var demandes = 0
    private(set) var lectures = 0

    init(acces: AccesCalendrier = .accorde, reponse: AccesCalendrier = .accorde, evenements: [EvenementAgenda] = []) {
        self.acces = acces
        self.reponse = reponse
        self.tous = evenements
    }

    func demanderAcces(_ fini: @escaping @Sendable @MainActor (AccesCalendrier) -> Void) {
        demandes += 1
        acces = reponse
        fini(acces)
    }

    func evenements(de debut: Date, a fin: Date) -> [EvenementAgenda] {
        lectures += 1
        guard acces == .accorde else { return [] }
        return tous.filter { $0.fin > debut && $0.debut < fin }
    }

    /// Une journée de montage : un appel dans 25 min, une livraison, demain
    /// une version 2 et un anniversaire, une réunion dans trois jours.
    static func exemple(_ maintenant: Date = Date()) -> SourceSimulee {
        let cal = Calendar.current
        let demain = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: maintenant))!
        func a(_ jour: Date, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: jour)! }
        let appel = maintenant.addingTimeInterval(25 * 60)
        return SourceSimulee(evenements: [
            EvenementAgenda(id: "1", titre: "Appel client : retours V1", debut: appel, fin: appel.addingTimeInterval(1800),
                      journee: false, calendrier: "Travail"),
            EvenementAgenda(id: "2", titre: "Livraison du teaser", debut: maintenant.addingTimeInterval(3 * 3600),
                      fin: maintenant.addingTimeInterval(4 * 3600), journee: false, calendrier: "Travail"),
            EvenementAgenda(id: "3", titre: "Anniversaire de Sara", debut: demain, fin: cal.date(byAdding: .day, value: 1, to: demain)!,
                      journee: true, calendrier: "Famille"),
            EvenementAgenda(id: "4", titre: "Montage : version 2", debut: a(demain, 10), fin: a(demain, 13),
                      journee: false, calendrier: "Travail"),
            EvenementAgenda(id: "5", titre: "Réunion d'équipe", debut: a(cal.date(byAdding: .day, value: 3, to: demain)!, 9, 30),
                      fin: a(cal.date(byAdding: .day, value: 3, to: demain)!, 10, 30), journee: false, calendrier: "Travail"),
        ])
    }
}

/// Les réglages de la carte Calendrier (`modules.calendrier.options`).
struct ReglagesCalendrier: Equatable {
    static let module = "calendrier"

    enum Horizon: String, CaseIterable {
        case aujourdhui, demain, semaine
        var libelle: String {
            switch self {
            case .aujourdhui: return "Aujourd'hui"
            case .demain: return "Aujourd'hui et demain"
            case .semaine: return "Les 7 prochains jours"
            }
        }
        var jours: Int { switch self { case .aujourdhui: return 1; case .demain: return 2; case .semaine: return 7 } }
    }

    var nombre = 5
    var horizon = Horizon.demain
    var journees = true

    init() {}

    init(options: [String: OptionValue]) {
        if let n = options["nombre"]?.int { nombre = min(10, max(1, n)) }
        horizon = options["horizon"]?.text.flatMap(Horizon.init(rawValue:)) ?? .demain
        journees = options["journees"]?.bool ?? true
    }

    /// La fenêtre lue : de maintenant à la fin du dernier jour de l'horizon.
    func fenetre(_ maintenant: Date, calendrier: Calendar = .current) -> (Date, Date) {
        let debutJour = calendrier.startOfDay(for: maintenant)
        return (maintenant, calendrier.date(byAdding: .day, value: horizon.jours, to: debutJour)!)
    }
}

/// Les événements à venir, lus par la source. Partagé par la carte, le
/// segment de barre et `--probe`.
@MainActor
final class Agenda: ObservableObject {
    static let shared = Agenda()

    @Published private(set) var evenements: [EvenementAgenda] = []
    @Published private(set) var acces: AccesCalendrier?
    @Published private(set) var lu: Date?
    /// Pourquoi rien n'est lu (hors de l'app, sans `--exemple`).
    @Published private(set) var horsApp = false

    private(set) var source: SourceEvenements?
    private let fabrique: @MainActor () -> SourceEvenements?
    private var minuterie: Timer?
    private var observateur: NSObjectProtocol?
    private var actif = false
    @Published private(set) var demandeFaite = false
    var reglages = ReglagesCalendrier()

    /// La source selon le contexte : simulée sous `--exemple`, EventKit
    /// dans l'app installée, aucune ailleurs.
    static func sourceParDefaut() -> SourceEvenements? {
        if Extras.exemple { return SourceSimulee.exemple() }
        if Extras.appReelle { return SourceEventKit() }
        return nil
    }

    /// L'heure de chaque lecture. Injectée par les tests : lue sur la vraie
    /// horloge, la fenêtre « de maintenant à demain soir » laissait derrière
    /// elle les événements d'essai, posés à une heure fixe — le test passait
    /// le matin et cassait `main` une heure plus tard (11/10, 07:15).
    private let horloge: @MainActor () -> Date

    init(source fabrique: @escaping @MainActor () -> SourceEvenements? = Agenda.sourceParDefaut,
         horloge: @escaping @MainActor () -> Date = { Date() }) {
        self.fabrique = fabrique
        self.horloge = horloge
    }

    /// L'état de la carte au réglage précédent ; nil avant le premier.
    private var etaitAffichee: Bool?

    /// Carte affichée : lire, et relire toutes les 5 min et à chaque
    /// changement du calendrier (pour le segment de barre, panneau fermé).
    /// Masquée : tout s'arrête, la source est lâchée.
    ///
    /// La demande d'accès part ici dans un seul cas : Isma vient d'activer
    /// la carte, l'app tournant — le passage de masquée à affichée —, et
    /// macOS n'a encore jamais posé la question. Jamais au lancement : Pulse
    /// est signé ad hoc, et macOS peut oublier l'accès à chaque
    /// reconstruction (l'identité de signature change) ; la demande
    /// surgirait alors après chaque fusion, en plein montage. Dans ce cas la
    /// carte propose un bouton, et c'est Isma qui demande (`demanderAcces`).
    func regler(affiche: Bool, reglages: ReglagesCalendrier) {
        self.reglages = reglages
        let activation = etaitAffichee == false && affiche
        etaitAffichee = affiche
        guard affiche else { arreter(); return }
        if source == nil { source = fabrique() }
        guard let source else {
            horsApp = true
            return
        }
        horsApp = false
        acces = source.acces
        if activation { demanderAcces() }
        if !actif {
            actif = true
            let m = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.relire() }
            }
            m.tolerance = 30
            RunLoop.main.add(m, forMode: .common)
            minuterie = m
            if source is SourceEventKit {
                observateur = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil,
                                                                     queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.relire() }
                }
            }
        }
        relire()
    }

    /// Demande l'accès, une fois par lancement : à l'activation de la carte,
    /// ou au bouton de la carte quand macOS ne l'a jamais accordé.
    func demanderAcces() {
        guard let source, source.acces == .jamaisDemande, !demandeFaite else { return }
        demandeFaite = true
        source.demanderAcces { [weak self] reponse in
            self?.acces = reponse
            self?.relire()
        }
    }

    func arreter() {
        actif = false
        minuterie?.invalidate()
        minuterie = nil
        if let observateur { NotificationCenter.default.removeObserver(observateur) }
        observateur = nil
        source = nil
        evenements = []
        lu = nil
    }

    func relire(_ instant: Date? = nil) {
        guard let source else { return }
        let maintenant = instant ?? horloge()
        acces = source.acces
        let (debut, fin) = reglages.fenetre(maintenant)
        evenements = Self.trier(source.evenements(de: debut, a: fin), reglages: reglages)
        lu = maintenant
    }

    /// Les journées entières d'abord dans leur jour, puis par heure ; sans
    /// les journées si Isma les a masquées.
    static func trier(_ tous: [EvenementAgenda], reglages: ReglagesCalendrier) -> [EvenementAgenda] {
        tous.filter { reglages.journees || !$0.journee }
            .sorted { a, b in
                let ja = Calendar.current.startOfDay(for: a.debut), jb = Calendar.current.startOfDay(for: b.debut)
                if ja != jb { return ja < jb }
                if a.journee != b.journee { return a.journee }
                return a.debut < b.debut
            }
    }

    /// Le prochain événement à heure, en cours ou à venir.
    func prochain(_ maintenant: Date = Date()) -> EvenementAgenda? {
        evenements.first { !$0.journee && $0.fin > maintenant }
    }
}

/// « dans 25 min », « en cours », « à 14:00 », « demain 10:00 ».
enum QuandEvenement {
    static func texte(_ e: EvenementAgenda, _ maintenant: Date, calendrier: Calendar = .current) -> String {
        if e.journee { return calendrier.isDate(e.debut, inSameDayAs: maintenant) ? "aujourd'hui" : jour(e.debut, maintenant, calendrier) }
        if e.enCours(maintenant) { return "en cours" }
        let ecart = e.debut.timeIntervalSince(maintenant)
        if ecart >= 0, ecart < 3600 { return "dans \(max(1, Int((ecart / 60).rounded(.up)))) min" }
        if calendrier.isDate(e.debut, inSameDayAs: maintenant) { return "à \(Extras.heure(e.debut))" }
        return "\(jour(e.debut, maintenant, calendrier)) \(Extras.heure(e.debut))"
    }

    /// « demain », « mardi ».
    static func jour(_ date: Date, _ maintenant: Date, _ calendrier: Calendar) -> String {
        if let demain = calendrier.date(byAdding: .day, value: 1, to: maintenant), calendrier.isDate(date, inSameDayAs: demain) {
            return "demain"
        }
        return Extras.formateur("EEEE", calendrier.timeZone).string(from: date)
    }
}

/// Le calendrier, chantier 18 : les prochains événements, lus sur le Mac par
/// EventKit. L'autorisation n'est demandée qu'au moment où Isma active la
/// carte, dans l'app installée.
struct CalendrierModule: PulseModule {
    let id = ReglagesCalendrier.module
    let name = "Calendrier"
    let symbol = "calendar"
    var summary: String {
        "Les prochains événements de vos calendriers. macOS demande l'accès à l'activation de la carte ; rien ne sort du Mac."
    }
    var enabledByDefault: Bool { false }
    var defaultColumn: Int { 1 }

    var cost: ModuleCost {
        ModuleCost(closed: 0.0001, open: 0.0001,
                   note: "calendrier : carte masquée, rien ; affichée, une lecture d'EventKit toutes les 5 min et à chaque changement du calendrier")
    }

    var options: [ModuleOption] {
        [ModuleOption(id: "horizon", label: "Jusqu'à",
                      kind: .choice(ReglagesCalendrier.Horizon.allCases.map { (value: $0.rawValue, label: $0.libelle) },
                                    default: ReglagesCalendrier.Horizon.demain.rawValue)),
         ModuleOption(id: "nombre", label: "Événements listés", kind: .number(range: 1...10, default: 5, unit: "")),
         ModuleOption(id: "journees", label: "Événements d'une journée entière",
                      help: "Anniversaires, jours fériés, congés.", kind: .toggle(default: true))]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(CarteCalendrier(agenda: Agenda.shared, reglages: ReglagesCalendrier(options: context.settings.options),
                                compact: context.compact))
    }

    func stateDidChange(_ state: ModuleState) {
        let reglages = ReglagesCalendrier(options: SettingsStore.shared.settings.module(id).options)
        // Affichée (réglage d'Isma) : on lit, panneau ouvert ou fermé — le
        // segment de barre en a besoin. Sous `--exemple`, la carte se rend
        // même masquée.
        Agenda.shared.regler(affiche: state.enabled || Extras.exemple, reglages: reglages)
    }

    /// « AGENDA » sur « 25 min » ou « 14:00 ». Rien à venir : rien.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        let maintenant = Date()
        guard let e = Agenda.shared.prochain(maintenant), Calendar.current.isDate(e.debut, inSameDayAs: maintenant) else { return nil }
        let quand = QuandEvenement.texte(e, maintenant)
        let valeur = quand.hasPrefix("dans ") ? String(quand.dropFirst(5)) : (e.enCours(maintenant) ? "en cours" : Extras.heure(e.debut))
        return MenuBarSegment(label: "AGENDA", value: valeur, spoken: "Prochain événement : \(e.titre), \(quand)")
    }

    /// `--probe` ne passe pas par l'ouverture du panneau : la section règle
    /// l'agenda comme l'app au lancement — sans rien demander, `--probe`
    /// n'étant jamais l'app installée.
    func probeSection() -> ProbeSection? {
        let affichee = Layout.isEnabled(self, in: SettingsStore.shared.settings)
        stateDidChange(ModuleState(enabled: affichee, panelOpen: false))
        return Self.section(Agenda.shared, affichee: affichee)
    }

    static func section(_ agenda: Agenda, affichee: Bool, maintenant: Date = Date()) -> ProbeSection {
        var lignes: [String] = []
        if !affichee && !Extras.exemple {
            lignes.append("carte masquée (désactivée par défaut) : EventKit jamais appelé, aucune demande d'accès")
            return ProbeSection(title: "CALENDRIER", lines: lignes)
        }
        if Extras.exemple { lignes.append("magasin simulé (--exemple) : aucun appel à EventKit") }
        if agenda.horsApp {
            // Le statut se lit sans rien demander ; les événements, non : un
            // binaire lancé hors de l'app n'a pas l'accès de Pulse.app.
            lignes.append("hors de l'app installée : rien n'est lu ni demandé ; accès de ce processus : \(SourceEventKit.statut.rawValue)")
            return ProbeSection(title: "CALENDRIER", lines: lignes)
        }
        lignes.append("accès \(agenda.acces?.rawValue ?? "inconnu") · horizon \(agenda.reglages.horizon.libelle.lowercased()) · \(agenda.evenements.count) événement\(agenda.evenements.count > 1 ? "s" : "")"
                      + (agenda.lu.map { " · lu à \(Extras.heure($0))" } ?? ""))
        for e in agenda.evenements.prefix(agenda.reglages.nombre) {
            let heure = e.journee ? "journée" : "\(Extras.heure(e.debut))–\(Extras.heure(e.fin))"
            lignes.append("\(QuandEvenement.texte(e, maintenant).padding(toLength: 16, withPad: " ", startingAt: 0)) \(heure.padding(toLength: 12, withPad: " ", startingAt: 0)) \(e.titre) (\(e.calendrier))")
        }
        return ProbeSection(title: "CALENDRIER", lines: lignes)
    }
}

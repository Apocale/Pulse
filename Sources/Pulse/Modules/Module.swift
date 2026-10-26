import SwiftUI

/// Un module de Pulse : un thème mesuré — processeur, mémoire, capteurs… —,
/// sa carte dans le panneau, son segment de barre de menus s'il en a un, ses
/// réglages propres et ce qu'il coûte.
///
/// Un module s'inscrit en UNE ligne dans `ModuleRegistry.all` ; c'est tout ce
/// qu'il faut pour que sa carte entre dans le panneau, dans la mise en page
/// réglable et dans la fenêtre Réglages.
///
/// Seuls `id`, `name`, `symbol` et `card(_:)` sont obligatoires : tout le
/// reste a une valeur par défaut (extension plus bas).
///
/// Exemple, pour un chantier qui ajoute sa carte :
///
/// ```swift
/// struct SensorsModule: PulseModule {
///     let id = "capteurs"            // stable : clé des réglages persistés
///     let name = "Capteurs"
///     let symbol = "thermometer.medium"
///     func card(_ context: CardContext) -> AnyView {
///         AnyView(SensorsCard(compact: context.compact))
///     }
/// }
/// ```
@MainActor
protocol PulseModule {
    /// Identifiant stable, en français, sans accent ni espace (« memoire »).
    /// Clé des réglages persistés : le renommer ferait perdre à Isma la
    /// place et les choix de la carte.
    var id: String { get }

    /// Le nom affiché : titre de la carte et de la page de réglages.
    var name: String { get }

    /// Symbole SF de la carte et de la barre latérale des Réglages.
    var symbol: String { get }

    /// Une phrase pour la fenêtre Réglages : ce que la carte montre.
    var summary: String { get }

    /// Ce que le module coûte, mesuré. Voir `ModuleCost`.
    var cost: ModuleCost { get }

    /// Affiché au premier lancement ? Un module qui sort sur Internet ou
    /// demande une autorisation (calendrier, météo) répond non.
    var enabledByDefault: Bool { get }

    /// Colonne au premier lancement, dans la mise en page à deux colonnes :
    /// 0 à gauche (activité), 1 à droite (capacité et travail).
    var defaultColumn: Int { get }

    /// Réglages propres au module, déclarés : la fenêtre Réglages les dessine
    /// seule, et ils sont persistés avec les autres. Lus dans la carte par
    /// `context.option(id)`.
    var options: [ModuleOption] { get }

    /// Les séries que la carte colore. Leur teinte se règle dans la fenêtre
    /// Réglages, contraste mesuré ; la carte la lit par `context.tint(id)`.
    var series: [ModuleSeries] { get }

    /// La carte liste des applications : la fenêtre Réglages propose alors
    /// d'en choisir le nombre, lu par `context.appCount`.
    var listsApps: Bool { get }

    /// La carte du panneau.
    func card(_ context: CardContext) -> AnyView

    /// La carte a-t-elle quelque chose à dire ? Non : elle se retire du
    /// panneau sans laisser de trou (la carte Montage hors session).
    func hasContent(_ sampler: Sampler) -> Bool

    /// Le segment de barre de menus, s'il y en a un. Le dessin des segments
    /// appartient au chantier 09 ; le module ne fournit que les valeurs.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment?

    /// Le panneau s'ouvre ou se ferme, la carte est affichée ou masquée. Un
    /// module qui mesure lui-même accélère, ralentit ou s'arrête ici : le
    /// budget de moins de 1 % d'un cœur panneau fermé en dépend. Appelé une
    /// fois au lancement, puis à chaque changement.
    func stateDidChange(_ state: ModuleState)

    /// Sa section dans `--probe`, si le module mesure quelque chose que les
    /// sections existantes ne disent pas. Règle du dépôt : chaque chiffre de
    /// la carte se retrouve dans `--probe`.
    func probeSection() -> ProbeSection?

    /// Ce qu'une liste d'options ne sait pas dire — les personnes des
    /// horloges, un nom et une ville chacune : une section de plus dans la
    /// page du module de la fenêtre Réglages, sous « Réglages de la carte ».
    func settingsSection(_ store: SettingsStore) -> (title: String, content: AnyView)?
}

extension PulseModule {
    var summary: String { "" }
    var cost: ModuleCost { .socle }
    var enabledByDefault: Bool { true }
    var defaultColumn: Int { 0 }
    var options: [ModuleOption] { [] }
    var series: [ModuleSeries] { [] }
    var listsApps: Bool { false }
    func hasContent(_ sampler: Sampler) -> Bool { true }
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? { nil }
    func stateDidChange(_ state: ModuleState) {}
    func probeSection() -> ProbeSection? { nil }
    func settingsSection(_ store: SettingsStore) -> (title: String, content: AnyView)? { nil }
}

/// Ce qu'un module doit savoir pour régler sa cadence.
struct ModuleState: Equatable {
    /// La carte est affichée (réglage d'Isma).
    var enabled: Bool
    /// Le panneau est sous les yeux d'Isma.
    var panelOpen: Bool
    /// Son segment est affiché dans la barre de menus (chantier 09) : un
    /// module qui mesure lui-même continue, carte masquée, à sa cadence
    /// panneau fermé.
    var menuBar = false
}

/// Ce qu'un module coûte en processeur, MESURÉ et non estimé : temps CPU
/// cumulé du processus sur plusieurs minutes (`ps -o time=`, ou `--banc`),
/// jamais un `top` instantané — voir le README, « Un popover refermé continue
/// de se dessiner ».
struct ModuleCost: Equatable {
    /// Part d'un cœur, en pour cent, panneau fermé. Nil : pas mesuré seul.
    var closed: Double?
    /// Part d'un cœur, en pour cent, panneau ouvert. Nil : pas mesuré seul.
    var open: Double?
    /// D'où sort la mesure, ou pourquoi il n'y en a pas de propre.
    var note: String

    /// Les modules du socle lisent tous le même `Sampler` : leur coût est
    /// celui du relevé commun, qu'on ne sait pas découper par carte.
    static let socle = ModuleCost(
        closed: nil, open: nil,
        note: "relevé commun du socle : 0,72 % d'un cœur panneau fermé, tous modules du socle confondus (11/10)")
}

/// Un réglage propre à un module, déclaré plutôt que dessiné : la fenêtre
/// Réglages en fait un interrupteur, un menu ou un champ numérique.
struct ModuleOption: Identifiable {
    enum Kind {
        case toggle(default: Bool)
        /// Valeurs stables (persistées) et libellés affichés.
        case choice([(value: String, label: String)], default: String)
        case number(range: ClosedRange<Int>, default: Int, unit: String)
    }

    /// Clé persistée, stable comme l'identifiant du module.
    var id: String
    var label: String
    /// Une phrase sous le contrôle, facultative.
    var help: String = ""
    var kind: Kind

    var defaultValue: OptionValue {
        switch kind {
        case .toggle(let value):        return .bool(value)
        case .choice(_, let value):     return .text(value)
        case .number(_, let value, _):  return .int(value)
        }
    }
}

/// Une série colorée d'une carte (« utilisateur », « système »…), dont la
/// teinte se règle. La teinte par défaut est un rôle de `Palette`, mesuré.
struct ModuleSeries: Identifiable, Equatable {
    var id: String
    var label: String
    var defaultTint: PaletteRole
}

/// Les teintes mesurées de `Palette`, par leur rôle. Une série choisit
/// parmi elles par défaut ; la fenêtre Réglages en propose d'autres, chacune
/// refusée sous 3:1 sur le fond des cartes (règle dure n°4).
enum PaletteRole: String, Codable, CaseIterable {
    case data, muted, warning, alert, tertiary

    var color: Color {
        switch self {
        case .data:     return Palette.data
        case .muted:    return Palette.muted
        case .warning:  return Palette.warning
        case .alert:    return Palette.alert
        case .tertiary: return Palette.tertiary
        }
    }
}

/// Un segment de barre de menus, façon iStat : une petite étiquette
/// au-dessus d'une valeur (« MÉM » sur « 72 % »). Les valeurs seulement : le
/// style — texte, mini-graphe, jauge, anneau — est l'affaire du chantier 09.
struct MenuBarSegment: Equatable {
    /// Étiquette en capitales, six signes au plus (« MÉM », « SSD 2 »).
    var label: String
    /// La valeur, déjà formatée (« 72 % »).
    var value: String
    /// Ce que VoiceOver et l'infobulle disent (« mémoire 72 % »).
    var spoken: String
    /// Part d'un total réel, de 0 à 1, pour une jauge ou un anneau. Nil
    /// quand il n'y a pas de dénominateur réel (règle dure n°7).
    var fraction: Double? = nil
}

/// Une section de `--probe` fournie par un module.
struct ProbeSection {
    /// En capitales, comme les autres sections (« CAPTEURS »).
    var title: String
    var lines: [String]
}

import SwiftUI

/// Ce qu'une carte reçoit pour se dessiner : le relevé commun, l'historique
/// ouvert, et les réglages de son module.
///
/// Une carte qui a son propre modèle (un lecteur de capteurs, par exemple) le
/// garde dans sa vue ; elle n'est pas obligée de lire `sampler`.
@MainActor
struct CardContext {
    /// Le relevé commun du socle : mémoire, processeur, volumes, réseau…
    let sampler: Sampler

    /// L'historique déplié, un seul à la fois dans tout le panneau. Une clé
    /// par historique (« volumes », « reseau »…) ; nil quand tout est replié.
    let open: Binding<String?>

    /// Les réglages de ce module, tels qu'Isma les a laissés.
    let settings: ModuleSettings

    /// Les réglages globaux qui touchent l'affichage (unités).
    let display: DisplaySettings

    private let seriesDefaults: [String: PaletteRole]
    private let optionDefaults: [String: OptionValue]

    init(module: any PulseModule, sampler: Sampler, open: Binding<String?>,
         settings: ModuleSettings = ModuleSettings(), display: DisplaySettings = DisplaySettings()) {
        self.sampler = sampler
        self.open = open
        self.settings = settings
        self.display = display
        seriesDefaults = Dictionary(module.series.map { ($0.id, $0.defaultTint) }, uniquingKeysWith: { a, _ in a })
        optionDefaults = Dictionary(module.options.map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
    }

    /// Carte compacte : le titre et le dessin principal, sans les listes.
    var compact: Bool { settings.compact }

    /// Combien d'applications la carte liste.
    var appCount: Int { settings.appCount ?? ModuleSettings.defaultAppCount }

    /// La teinte d'une série : celle qu'Isma a choisie si elle passe encore
    /// le contraste, sinon celle du module.
    func tint(_ series: String) -> Color {
        if let chosen = settings.tints[series], let color = TintChoice(raw: chosen).color { return color }
        return (seriesDefaults[series] ?? .data).color
    }

    /// La valeur d'un réglage propre au module, ou sa valeur par défaut.
    func option(_ id: String) -> OptionValue {
        settings.options[id] ?? optionDefaults[id] ?? .text("")
    }
}

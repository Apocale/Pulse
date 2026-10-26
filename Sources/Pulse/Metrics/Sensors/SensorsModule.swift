import SwiftUI

/// Le module Capteurs : températures, ventilateurs, puissance, fréquences.
/// Inscrit en une ligne dans `ModuleRegistry.all`.
struct SensorsModule: PulseModule {
    let id = "capteurs"
    let name = "Capteurs"
    let symbol = "thermometer.medium"
    var summary: String { "Températures, ventilateurs, puissance et fréquences de la puce, lus sans mot de passe." }
    /// À droite, sous Mémoire, Disques et Montage : la colonne de gauche
    /// porte déjà Processeur, Réseau et Énergie. Relevé au rendu du panneau
    /// entier le 11/10 : à gauche, 1 510 pt de haut, plus que l'écran
    /// (1 290 utiles) ; à droite, sous le plafond.
    var defaultColumn: Int { 1 }

    /// Mesuré par `--probe` (section CAPTEURS), temps CPU du thread, médiane
    /// de 5, sous forte charge le 11/10 : panneau fermé, SMC seul, 0,8 ms
    /// toutes les 30 s ; ouvert, SMC + IOReport, 4,4 ms toutes les 1,5 s.
    var cost: ModuleCost {
        ModuleCost(closed: 0.003, open: 0.29,
                   note: "capteurs : fermé, SMC seul toutes les 30 s (0,8 ms) ; ouvert, + IOReport toutes les 1,5 s (4,4 ms) ; rien si la carte et le segment sont masqués (--probe, CAPTEURS)")
    }

    static let barOption = "barre"

    var options: [ModuleOption] {
        [ModuleOption(id: Self.barOption, label: "Température du processeur dans la barre de menus",
                      help: "« CPU 62° » : la moyenne des cœurs, relue toutes les 30 s panneau fermé.",
                      kind: .toggle(default: false))]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(SensorsCard(store: SensorStore.shared, compact: context.compact, open: context.open))
    }

    /// Le segment, seulement s'il est allumé dans les Réglages. Pas de
    /// `fraction` : une température n'a pas de dénominateur réel.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        guard Self.barEnabled, let celsius = SensorStore.shared.sample?.cpuTemperature else { return nil }
        let value = "\(Int(celsius.rounded()))°"
        return MenuBarSegment(label: "CPU", value: value,
                              spoken: "processeur \(Int(celsius.rounded())) degrés")
    }

    func stateDidChange(_ state: ModuleState) {
        SensorStore.shared.setCadence(Self.cadence(enabled: state.enabled, panelOpen: state.panelOpen,
                                                   bar: Self.barEnabled))
    }

    /// Lit vite quand la carte est sous les yeux, lentement quand seul le
    /// segment ou la reprise de l'ouverture en a besoin, pas du tout sinon :
    /// une carte masquée sans segment ne coûte rien.
    static func cadence(enabled: Bool, panelOpen: Bool, bar: Bool) -> SensorStore.Cadence {
        if enabled && panelOpen { return .open }
        if enabled || bar { return .closed }
        return .stopped
    }

    func probeSection() -> ProbeSection? {
        ProbeSection(title: "CAPTEURS · lecture seule, sans sudo", lines: SensorProbe.lines())
    }

    private static var barEnabled: Bool {
        SettingsStore.shared.settings.module("capteurs").options[barOption]?.bool ?? false
    }
}

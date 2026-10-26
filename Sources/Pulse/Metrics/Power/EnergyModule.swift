import SwiftUI

/// Le module Énergie (chantier 06) : batterie, chargeur, mode d'énergie,
/// AirPods et accessoires. Inscrit en une ligne dans `ModuleRegistry.all`.
///
/// Il mesure lui-même, avec `PowerSampler` : le relevé commun du socle ne
/// lit pas la batterie. Une seule instance, partagée par la carte, la barre
/// de menus et le cycle de vie du panneau.
struct EnergyModule: PulseModule {
    let id = "energie"
    let name = "Énergie"
    let symbol = "battery.75percent"
    var summary: String {
        "Charge et santé de la batterie, consommation, chargeur, mode d'énergie, AirPods et accessoires."
    }
    /// Colonne de gauche : la plus courte des deux sur le rendu du 11/10
    /// (processeur et réseau, 640 pt contre 715 à droite).
    var defaultColumn: Int { 0 }

    /// Mesuré sur le code réel (test `unReleveResteBonMarche`, temps
    /// processeur du fil, 11/10) puis rapporté à la cadence. Le banc de 60 s
    /// ne peut pas le voir : sa phase fermée dure 20 s, la cadence fermée
    /// 5 min.
    var cost: ModuleCost {
        ModuleCost(closed: 0.0004, open: 0.025,
                   note: "énergie : 1,24 ms de processeur par relevé (batterie, alimentation, SMC), 0,07 ms pour les accessoires ; "
                       + "fermé un relevé / 5 min (0,0004 %), ouvert 5 s et 30 s (0,025 %) ; carte masquée : rien ; "
                       + "system_profiler 0,09 s au lancement puis toutes les 6 h au plus, panneau ouvert")
    }

    var options: [ModuleOption] {
        [ModuleOption(id: "appareils", label: "AirPods et accessoires",
                      help: "Leur charge, telle que macOS la publie pour le widget Batteries.",
                      kind: .toggle(default: true)),
         ModuleOption(id: "journee", label: "Historique",
                      help: "Depuis le titre de la carte : la consommation sur secteur, la charge sur batterie, de 1 heure à 90 jours.",
                      kind: .toggle(default: true))]
    }

    var series: [ModuleSeries] {
        [ModuleSeries(id: "charge", label: "Charge", defaultTint: .data),
         ModuleSeries(id: "sante", label: "Santé", defaultTint: .data)]
    }

    /// L'échantillonneur, créé au premier besoin : au lancement par
    /// `stateDidChange` si la carte est affichée, ou par la carte elle-même.
    /// Carte masquée dès le lancement, il n'existe jamais : ni lecture, ni
    /// minuterie, ni `system_profiler`.
    @MainActor private static var shared: PowerSampler?
    @MainActor static var power: PowerSampler {
        if let existing = shared { return existing }
        let created = PowerSampler()
        shared = created
        return created
    }

    /// Banc d'essai (chantier 03) : la carte nourrie d'un relevé figé
    /// (`PowerSampler(figé:)`), pour les images de référence de `--rendus`.
    @MainActor static func installer(_ fige: PowerSampler) { shared = fige }

    /// Faut-il un échantillonneur ? Pas pour une carte masquée qui n'en a
    /// encore jamais eu ; s'il existe, il s'arrête lui-même (`update`).
    nonisolated static func needsSampler(enabled: Bool, exists: Bool) -> Bool { enabled || exists }

    func card(_ context: CardContext) -> AnyView {
        AnyView(EnergyCard(power: Self.power,
                           compact: context.compact,
                           showsDevices: context.option("appareils").bool ?? true,
                           showsDay: context.option("journee").bool ?? true,
                           levelColor: context.tint("charge"),
                           healthColor: context.tint("sante"),
                           open: context.open))
    }

    /// Un Mac de bureau sans AirPods à portée n'a rien à dire ici.
    func hasContent(_ sampler: Sampler) -> Bool {
        Self.power.sample.hasBattery || !Self.power.accessories.isEmpty
    }

    /// « BAT » sur « 74 % » ; la charge est la part d'un total réel.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        let s = Self.power.sample
        guard s.hasBattery, let level = s.level else { return nil }
        return MenuBarSegment(label: "BAT", value: Fmt.percent(level),
                              spoken: "batterie \(Fmt.percent(level)), \(s.state.label)", fraction: level)
    }

    func stateDidChange(_ state: ModuleState) {
        // « BAT » dans la barre de menus : relue à la cadence fermée même
        // carte masquée (chantier 09).
        let wanted = state.enabled || state.menuBar
        guard Self.needsSampler(enabled: wanted, exists: Self.shared != nil) else { return }
        Self.power.update(enabled: wanted, panelOpen: state.panelOpen)
    }

    /// Le registre ajoute lui-même l'indentation de deux espaces.
    func probeSection() -> ProbeSection? {
        ProbeSection(title: "ÉNERGIE · batterie, alimentation, appareils",
                     lines: PowerProbe.lines().map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 })
    }
}

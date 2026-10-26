import SwiftUI

/// Le module Médias dans le registre (chantier 01) : la carte, ses séries,
/// son coût mesuré, sa section de `--probe`.
struct MediaModule: PulseModule {
    let id = "medias"
    let name = "Médias"
    let symbol = "film.stack"
    var summary: String {
        "Les exports de la semaine, la carte graphique et ses applications, l'encodeur vidéo, le cache média d'Adobe."
    }
    /// À droite, sous le montage dont elle prolonge le propos. Mesuré le
    /// 11/10 avec la carte Énergie (06) à gauche : à gauche aussi, le panneau
    /// montait à 1 378 pt, au-delà des 1 290 utiles de l'écran d'Isma.
    var defaultColumn: Int { 0 }

    /// Masquée au premier lancement, À REGRET : le panneau à deux colonnes
    /// est plein. Mesuré le 11/10 après les cartes Réseau (07), Énergie (06)
    /// et Capteurs (04) : 1 232 pt sans elle, 1 449 avec, pour 1 290 utiles
    /// sur l'écran d'Isma — aucune colonne ne la loge. Elle s'active dans la
    /// fenêtre Réglages ; à rendre visible d'office dès que le panneau passe
    /// à trois colonnes (décision du socle, chantier 01).
    var enabledByDefault: Bool { false }

    var series: [ModuleSeries] {
        [ModuleSeries(id: "exports", label: "Exports par jour", defaultTint: .data),
         ModuleSeries(id: "gpu", label: "Occupation du GPU", defaultTint: .data)]
    }

    /// Mesuré le 11/10 (`--probe`, section MÉDIAS) : fermé, un `stat` du
    /// journal d'AME par relevé ; ouvert, IOReport et les clients du GPU.
    var cost: ModuleCost {
        ModuleCost(closed: 0, open: 0.3,
                   note: "médias : panneau fermé, rien ; ouvert, un stat de 69 µs, et 4,7 ms par relevé + 6,6 ms toutes les 30 s si la carte ou le dépliant des exports est affiché (11/10)")
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(MediaCard(sampler: context.sampler, context: context))
    }

    /// Carte masquée : rien à mesurer, même panneau ouvert. Le journal
    /// d'AME, lui, reste suivi — c'est un `stat`, et l'historique ne doit
    /// pas avoir de trou le jour où la carte revient.
    func stateDidChange(_ state: ModuleState) {
        MediaTracker.setShown(state.enabled)
    }

    func probeSection() -> ProbeSection? {
        // Les lignes de `MediaProbe` portent déjà leur retrait de section.
        ProbeSection(title: "MÉDIAS · carte graphique, moteurs, exports, cache",
                     lines: MediaProbe.lines().map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 })
    }
}

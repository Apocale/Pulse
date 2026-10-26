import SwiftUI

/// Le registre unique des modules. Un module s'y inscrit en UNE ligne ; sa
/// carte entre alors dans le panneau, dans la mise en page réglable, dans la
/// fenêtre Réglages et, s'il en fournit une, dans `--probe`.
@MainActor
enum ModuleRegistry {
    /// Tous les modules, dans l'ordre par défaut des cartes, de haut en bas
    /// dans chaque colonne.
    ///
    /// **Chantiers : remplacez la ligne commentée qui porte votre numéro par
    /// votre module, sans toucher aux voisines.** Les lignes vides qui les
    /// séparent sont là pour que git fusionne chaque chantier sans conflit :
    /// ne les retirez pas.
    static let all: [any PulseModule] = [
        ProcessorModule(),
        ReseauModule(),         // 07-reseau : remplace NetworkModule, même identifiant
        MemoryModule(),
        DisksModule(),
        WorkModule(),

        SensorsModule(),         // 04-capteurs

        // 05-disques

        EnergyModule(),

        // 07-reseau

        MediaModule(),

        // 18-extras
        HorlogesModule(),
        CalendrierModule(),
        MeteoModule(),
    ]

    /// Le module d'identifiant `id`, s'il est inscrit.
    static func module(_ id: String) -> (any PulseModule)? {
        all.first { $0.id == id }
    }

    /// Les identifiants, dans l'ordre du registre.
    static var ids: [String] { all.map(\.id) }

    /// Le panneau s'ouvre ou se ferme : chaque module accélère, ralentit ou
    /// s'arrête, selon que sa carte est affichée ou non.
    static func panelDidChange(open: Bool, settings: PulseSettings) {
        let inBar = Set(MenuBarCatalog.items(settings).filter(\.shown).map(\.id))
        for module in all {
            module.stateDidChange(ModuleState(enabled: Layout.isEnabled(module, in: settings), panelOpen: open,
                                              menuBar: inBar.contains(module.id)))
        }
    }
}

import Foundation

/// La disposition des cartes, calculée sans vue : quelles cartes, dans quel
/// ordre, dans quelle colonne. Pure, donc testée (`LayoutTests`).
///
/// Chaque carte a une colonne : celle qu'Isma a choisie, sinon celle que
/// son module propose pour deux colonnes. Une colonne au-delà du nombre
/// affiché tombe dans la dernière. Dans chaque colonne, les cartes suivent
/// l'ordre global des réglages.
@MainActor
enum Layout {
    /// L'ordre complet des modules : celui des réglages, sans doublon ni
    /// inconnu, puis chaque module qui n'y figure pas encore — ajouté depuis
    /// par un chantier —, glissé juste après son prédécesseur dans le
    /// registre.
    static func order(_ settings: PulseSettings, modules given: [any PulseModule]? = nil) -> [String] {
        let modules = given ?? ModuleRegistry.all
        let known = modules.map(\.id)
        var order: [String] = []
        for id in settings.layout.order where known.contains(id) && !order.contains(id) {
            order.append(id)
        }
        for (index, id) in known.enumerated() where !order.contains(id) {
            let before = known[..<index].last { order.contains($0) }
            let at = before.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            order.insert(id, at: at)
        }
        return order
    }

    /// Nombre de colonnes affichées, borné à 1…3.
    static func columnCount(_ settings: PulseSettings) -> Int {
        min(max(settings.layout.columns, LayoutSettings.columnRange.lowerBound), LayoutSettings.columnRange.upperBound)
    }

    static func isEnabled(_ module: any PulseModule, in settings: PulseSettings) -> Bool {
        settings.module(module.id).enabled ?? module.enabledByDefault
    }

    /// La colonne d'un module, bornée au nombre de colonnes affichées.
    static func column(of module: any PulseModule, in settings: PulseSettings) -> Int {
        let wanted = settings.module(module.id).column ?? module.defaultColumn
        return min(max(wanted, 0), columnCount(settings) - 1)
    }

    /// Les colonnes, de gauche à droite, chacune de haut en bas : les
    /// identifiants des cartes affichées. Une colonne peut être vide.
    static func columns(_ settings: PulseSettings, modules given: [any PulseModule]? = nil) -> [[String]] {
        let modules = given ?? ModuleRegistry.all
        var columns = Array(repeating: [String](), count: columnCount(settings))
        for id in order(settings, modules: modules) {
            guard let module = modules.first(where: { $0.id == id }), isEnabled(module, in: settings) else { continue }
            columns[column(of: module, in: settings)].append(id)
        }
        return columns
    }

    /// Change le nombre de colonnes et répartit les cartes affichées dans
    /// l'ordre de lecture — première colonne de haut en bas, puis la
    /// suivante —, en parts égales à une carte près. À deux colonnes, chaque
    /// carte retrouve plutôt la place que son module propose : c'est la
    /// disposition d'origine, équilibrée à la mesure.
    static func setColumns(_ count: Int, in settings: inout PulseSettings,
                           modules given: [any PulseModule]? = nil) {
        let modules = given ?? ModuleRegistry.all
        let reading = columns(settings, modules: modules).flatMap { $0 }
        let count = min(max(count, LayoutSettings.columnRange.lowerBound), LayoutSettings.columnRange.upperBound)
        settings.layout.columns = count
        settings.layout.order = order(settings, modules: modules)
        if count == 2 {
            for module in modules { settings.modules[module.id, default: ModuleSettings()].column = nil }
            return
        }
        // Les cartes masquées gardent leur place relative : elles suivent
        // la carte affichée qui les précède dans l'ordre global.
        let perColumn = Int((Double(reading.count) / Double(count)).rounded(.up))
        for (index, id) in reading.enumerated() {
            settings.modules[id, default: ModuleSettings()].column = perColumn == 0 ? 0 : min(index / perColumn, count - 1)
        }
        // L'ordre global devient l'ordre de lecture, cartes masquées à la
        // suite de leur voisine d'avant.
        var reordered = reading
        for id in settings.layout.order where !reordered.contains(id) {
            let all = settings.layout.order
            let before = all[..<(all.firstIndex(of: id) ?? 0)].last { reordered.contains($0) }
            let at = before.flatMap { reordered.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            reordered.insert(id, at: at)
        }
        settings.layout.order = reordered
    }

    /// Place la carte `id` dans la colonne `column`, juste avant la carte
    /// `before` (nil : en bas de la colonne). Le geste du glisser-déposer.
    static func move(_ id: String, toColumn column: Int, before: String?, in settings: inout PulseSettings,
                     modules given: [any PulseModule]? = nil) {
        let modules = given ?? ModuleRegistry.all
        var order = order(settings, modules: modules)
        guard order.contains(id), id != before else { return }
        order.removeAll { $0 == id }
        let target = min(max(column, 0), columnCount(settings) - 1)
        settings.modules[id, default: ModuleSettings()].column = target
        if let before, let index = order.firstIndex(of: before) {
            order.insert(id, at: index)
        } else {
            // En bas de la colonne : après la dernière carte de cette colonne
            // dans l'ordre global, sinon tout à la fin.
            settings.layout.order = order
            let last = columns(settings, modules: modules)[target].last { $0 != id }
            if let last, let index = order.firstIndex(of: last) {
                order.insert(id, at: index + 1)
            } else {
                order.append(id)
            }
        }
        settings.layout.order = order
    }
}

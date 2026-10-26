import SwiftUI
import AppKit

// Le panneau ne dépasse jamais l'écran où se trouve l'icône.
//
// Quand les cartes ne tiennent pas en hauteur, les dernières cartes des
// colonnes trop hautes passent dans une colonne de plus, à droite — autant de
// colonnes qu'il en faut et que la largeur de l'écran permet. Plutôt que des
// cartes compactes : une colonne de plus ne retire rien à lire, alors qu'une
// carte compacte cache ses listes (apps, journées, températures) sans le dire.
// L'écran d'Isma est large (2 056 pt) et bas (1 290 pt utiles) : la place est
// sur le côté. Les autres cartes restent où Isma les a mises, dans son ordre.
//
// Les réglages d'Isma ne sont jamais réécrits : c'est l'affichage qui
// s'adapte, à chaque mise en page, donc aussi quand une carte grandit panneau
// ouvert ou quand Isma en active une de plus.

/// La place que l'écran offre au contenu du panneau.
struct PanelLimits: Equatable {
    /// Hauteur disponible pour le contenu du panneau, marges comprises.
    var height: CGFloat
    /// Largeur disponible pour le contenu du panneau, marges comprises.
    var width: CGFloat

    /// La flèche du popover (13 pt) et une marge de 3 pt sous la barre de
    /// menus : le contenu commence plus bas que la zone visible de l'écran.
    static let popoverChrome: CGFloat = 16

    /// L'écran de l'icône, tel que macOS le laisse aux fenêtres : sans la
    /// barre de menus ni le Dock (`visibleFrame`). Sur le 16 pouces d'Isma,
    /// Dock masqué : 2 056 × 1 290 pt, soit 1 274 pt pour le contenu.
    static func of(_ screen: NSScreen?) -> PanelLimits? {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        return screenSized(width: frame.width, height: frame.height)
    }

    /// Pour une zone visible de `width` × `height` pt.
    static func screenSized(width: CGFloat, height: CGFloat) -> PanelLimits {
        PanelLimits(height: height - popoverChrome, width: width - popoverChrome)
    }

    /// La barre de titre du panneau détaché (chantier 13, `FloatingContent`) :
    /// 26 pt et 2 de marge, au-dessus du panneau. Pas de flèche.
    static let floatingTitle: CGFloat = 28

    /// Le panneau détaché, dans une zone visible de `width` × `height` pt :
    /// la fenêtre entière, barre de titre comprise, tient dans l'écran.
    static func windowSized(width: CGFloat, height: CGFloat) -> PanelLimits {
        PanelLimits(height: height - floatingTitle, width: width)
    }

    /// La zone visible à respecter : `--ecran 2056x1290` sous `--snapshot` et
    /// `--ajuste` (pour rendre le cas d'un autre écran), sinon l'écran
    /// principal.
    static func visibleArea() -> CGSize? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--ecran"), index + 1 < args.count {
            let parts = args[index + 1].lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        }
        return NSScreen.main?.visibleFrame.size
    }
}

enum PanelFit {
    /// Répartit les cartes en colonnes qui tiennent dans `budget`.
    ///
    /// - `heights` : la hauteur de chaque carte, dans l'ordre du panneau ;
    /// - `columns` : la colonne réglée de chacune (bornée à `count`) ;
    /// - `budget` : la hauteur offerte aux colonnes, nil sans limite ;
    /// - `maxColumns` : ce que la largeur de l'écran permet.
    ///
    /// Rend les colonnes, de gauche à droite, chacune avec les indices de ses
    /// cartes de haut en bas. Tant qu'une colonne dépasse, ses dernières
    /// cartes passent dans une colonne ajoutée à droite, dans leur ordre ;
    /// une carte seule plus haute que le budget reste où elle est.
    static func arrange(heights: [CGFloat], columns: [Int], count: Int, spacing: CGFloat,
                        budget: CGFloat?, maxColumns: Int) -> [[Int]] {
        var result = Array(repeating: [Int](), count: max(1, count))
        for (index, column) in columns.enumerated() {
            result[min(max(column, 0), result.count - 1)].append(index)
        }
        guard let budget else { return result }
        func height(_ column: [Int]) -> CGFloat {
            column.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(max(0, column.count - 1))
        }
        while result.contains(where: { height($0) > budget }) {
            // Une colonne réglée restée vide, à droite des cartes, reçoit le
            // débordement avant qu'on en ajoute une.
            let lastFilled = result.lastIndex(where: { !$0.isEmpty }) ?? -1
            var appended = false
            let target: Int
            if lastFilled + 1 < result.count {
                target = lastFilled + 1
            } else if result.count < maxColumns {
                result.append([])
                appended = true
                target = result.count - 1
            } else {
                break
            }
            var spilled: [Int] = []
            for index in 0..<target {
                var moved: [Int] = []
                while height(result[index]) > budget, result[index].count > 1 {
                    moved.insert(result[index].removeLast(), at: 0)
                }
                spilled += moved
            }
            // Rien ne peut bouger (une carte seule plus haute que l'écran) :
            // on s'arrête là.
            guard !spilled.isEmpty else {
                if appended { result.removeLast() }
                break
            }
            result[target] = spilled
        }
        return result
    }

    /// `arrange`, et quand même toutes les colonnes permises ne suffisent
    /// pas, les cartes versées dans l'ordre de lecture, en colonnes aussi
    /// basses que possible. Le débordement s'empilait sinon dans la dernière
    /// colonne : relevé le 26/10 sur un 14 pouces réglé en « texte plus
    /// grand » (1 352 × 771 pt), quatre colonnes, la dernière à 850 pt pour
    /// 755 — le bas du panneau, et Quitter, sortaient de l'écran. Quand
    /// `arrange` tient — l'écran d'Isma —, rien ne change.
    ///
    /// Si l'ordre de lecture ne tient pas non plus, les cartes se rangent au
    /// plus serré (`pack`) : sur ce même écran, 7 cartes tiennent en 4
    /// colonnes de 644 pt au plus, quand l'ordre de lecture en demandait 789.
    /// Rien ne tient : le partage le plus bas des trois.
    static func arrangeToFit(heights: [CGFloat], columns: [Int], count: Int, spacing: CGFloat,
                             budget: CGFloat?, maxColumns: Int) -> [[Int]] {
        let base = arrange(heights: heights, columns: columns, count: count, spacing: spacing,
                           budget: budget, maxColumns: maxColumns)
        guard let budget, tallest(base, heights: heights, spacing: spacing) > budget else { return base }
        let order = columns.indices.sorted { (columns[$0], $0) < (columns[$1], $1) }
        let available = max(base.count, max(1, count))
        let candidates = [base,
                          flowBalanced(order: order, heights: heights, spacing: spacing, maxColumns: available),
                          pack(order: order, heights: heights, spacing: spacing, budget: budget, maxColumns: available)]
        if let fitting = candidates.first(where: { tallest($0, heights: heights, spacing: spacing) <= budget }) {
            return fitting
        }
        return candidates.min { tallest($0, heights: heights, spacing: spacing) < tallest($1, heights: heights, spacing: spacing) } ?? base
    }

    /// Au plus serré : de la plus haute à la plus basse, chaque carte dans la
    /// première colonne où elle tient (sinon la moins haute). Dans chaque
    /// colonne, l'ordre de lecture revient, et les colonnes se rangent selon
    /// leur première carte.
    static func pack(order: [Int], heights: [CGFloat], spacing: CGFloat, budget: CGFloat, maxColumns: Int) -> [[Int]] {
        var bins = Array(repeating: [Int](), count: max(1, maxColumns))
        var used = Array(repeating: CGFloat(0), count: bins.count)
        let tallestFirst = order.sorted { heights[$0] != heights[$1] ? heights[$0] > heights[$1] : $0 < $1 }
        for index in tallestFirst {
            func after(_ bin: Int) -> CGFloat { bins[bin].isEmpty ? heights[index] : used[bin] + spacing + heights[index] }
            let bin = bins.indices.first { after($0) <= budget }
                ?? bins.indices.min { used[$0] < used[$1] } ?? 0
            used[bin] = after(bin)
            bins[bin].append(index)
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return bins.filter { !$0.isEmpty }
            .map { $0.sorted { position[$0, default: 0] < position[$1, default: 0] } }
            .sorted { position[$0[0], default: 0] < position[$1[0], default: 0] }
    }

    /// La hauteur de la plus haute colonne.
    static func tallest(_ arranged: [[Int]], heights: [CGFloat], spacing: CGFloat) -> CGFloat {
        arranged.map { column in
            column.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(max(0, column.count - 1))
        }.max() ?? 0
    }

    /// Les cartes de `order` versées colonne après colonne, comme dans un
    /// journal : chacune se remplit jusqu'à `limit`, la suivante prend la
    /// suite. Une carte seule plus haute que `limit` a sa colonne à elle.
    static func flow(order: [Int], heights: [CGFloat], spacing: CGFloat, limit: CGFloat) -> [[Int]] {
        var result: [[Int]] = [[]]
        var height: CGFloat = 0
        for index in order {
            if result[result.count - 1].isEmpty {
                result[result.count - 1].append(index)
                height = heights[index]
            } else if height + spacing + heights[index] > limit {
                result.append([index])
                height = heights[index]
            } else {
                result[result.count - 1].append(index)
                height += spacing + heights[index]
            }
        }
        return result
    }

    /// Le plus bas des partages en `maxColumns` colonnes au plus, dans
    /// l'ordre de lecture : dichotomie sur la hauteur, comme
    /// `arrangeBalanced`.
    static func flowBalanced(order: [Int], heights: [CGFloat], spacing: CGFloat, maxColumns: Int) -> [[Int]] {
        var low = order.map { heights[$0] }.max() ?? 0
        var high = order.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(max(0, order.count - 1))
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if flow(order: order, heights: heights, spacing: spacing, limit: middle).count <= maxColumns {
                high = middle
            } else {
                low = middle
            }
        }
        return flow(order: order, heights: heights, spacing: spacing, limit: high)
    }

    /// VARIANTE À TRANCHER PAR ISMA (chantier 16), rendue seulement avec
    /// `--equilibre` (`--snapshot`, `--ajuste`) : le même nombre de colonnes
    /// que `arrange`, mais des colonnes équilibrées — la plus petite hauteur
    /// qui tient dans ce nombre, trouvée par dichotomie sur le budget. Plus
    /// court (relevé figé + Médias : 1 240 → ~1 020 pt), au prix d'une carte
    /// de plus déplacée (Capteurs). Inactive dans l'app.
    static let equilibre = CommandLine.arguments.contains("--equilibre")

    static func arrangeBalanced(heights: [CGFloat], columns: [Int], count: Int, spacing: CGFloat,
                                budget: CGFloat?, maxColumns: Int) -> [[Int]] {
        let base = arrange(heights: heights, columns: columns, count: count, spacing: spacing,
                           budget: budget, maxColumns: maxColumns)
        guard let budget, base.count > max(1, count) else { return base }
        func tallest(_ arranged: [[Int]]) -> CGFloat {
            arranged.map { column in
                column.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(max(0, column.count - 1))
            }.max() ?? 0
        }
        var low = heights.max() ?? 0, high = budget
        for _ in 0..<24 {
            let middle = (low + high) / 2
            let tried = arrange(heights: heights, columns: columns, count: count, spacing: spacing,
                                budget: middle, maxColumns: base.count)
            if tried.count <= base.count, tallest(tried) <= middle { high = middle } else { low = middle }
        }
        return arrange(heights: heights, columns: columns, count: count, spacing: spacing,
                       budget: high, maxColumns: base.count)
    }

    /// Les hauteurs retenues quand un historique est ouvert : dans chaque
    /// colonne trop haute pour `budget`, les cartes compactables
    /// (`compactHeights` non nil) passent en compactes de BAS EN HAUT, une à
    /// une, tant que la colonne dépasse — pas une de plus.
    ///
    /// Avant (chantier 10), toutes les autres cartes de la colonne passaient
    /// en compactes, qu'il le faille ou non : historique des volumes ouvert,
    /// la carte Mémoire perdait sa légende et ses apps alors que compacter
    /// Capteurs seule suffisait (chantier 16, mesuré sur `--ouvert`). Une
    /// colonne qui tient ne change pas ; sans budget (rendus de référence),
    /// rien ne change.
    static func shrink(heights: [CGFloat], compactHeights: [CGFloat?], columns: [Int], count: Int,
                       spacing: CGFloat, budget: CGFloat?) -> [CGFloat] {
        var kept = heights
        guard let budget else { return kept }
        let count = max(1, count)
        for column in 0..<count {
            let members = columns.indices.filter { min(max(columns[$0], 0), count - 1) == column }
            func height() -> CGFloat {
                members.reduce(0) { $0 + kept[$1] } + spacing * CGFloat(max(0, members.count - 1))
            }
            for index in members.reversed() where height() > budget {
                if let compact = compactHeights[index], compact < kept[index] { kept[index] = compact }
            }
        }
        return kept
    }

    /// Comme `shrink`, sur des colonnes déjà rangées : le dernier recours d'un
    /// écran trop petit pour toutes les cartes pleines, même au plus serré
    /// (un 14 pouces au plus gros texte, 1 147 × 708 pt : 809 pt pour 692,
    /// 26/10). Dans chaque colonne qui dépasse, les cartes compactables
    /// passent en compactes de bas en haut, tant qu'il le faut.
    static func shrink(arranged: [[Int]], heights: [CGFloat], compactHeights: [CGFloat?],
                       spacing: CGFloat, budget: CGFloat) -> [CGFloat] {
        var kept = heights
        for members in arranged {
            func height() -> CGFloat {
                members.reduce(0) { $0 + kept[$1] } + spacing * CGFloat(max(0, members.count - 1))
            }
            for index in members.reversed() where height() > budget {
                if let compact = compactHeights[index], compact < kept[index] { kept[index] = compact }
            }
        }
        return kept
    }

    /// Combien de colonnes de `columnWidth` tiennent dans `width`, marges du
    /// panneau (2 × 12 pt) comprises. Au moins une.
    static func maxColumns(width: CGFloat, columnWidth: CGFloat, spacing: CGFloat, padding: CGFloat = 12) -> Int {
        max(1, Int(((width - 2 * padding + spacing) / (columnWidth + spacing)).rounded(.down)))
    }
}

/// La place d'une vue dans le panneau.
enum PanelSlot: Equatable {
    case header
    case card(column: Int)
    case footer
}

struct PanelSlotKey: SwiftUI.LayoutValueKey {
    static let defaultValue = PanelSlot.header
}

/// Une carte qui peut passer en compacte pour laisser la place à
/// l'historique ouvert dans sa colonne : elle porte ses deux formes dans un
/// `ViewThatFits`, et la mise en page choisit (`PanelFit.shrink`).
struct PanelShrinkKey: SwiftUI.LayoutValueKey {
    static let defaultValue = false
}

/// Une carte qui porte aussi sa forme compacte, pour le dernier recours d'un
/// écran bas (`PanelFit.shrink(arranged:)`) : compactée seulement si, rangées
/// au plus serré, les cartes pleines ne tiennent pas. Jamais avant d'avoir
/// essayé plus de colonnes.
struct PanelCompactKey: SwiftUI.LayoutValueKey {
    static let defaultValue = false
}

/// Le panneau : le verdict en tête, les cartes en colonnes, le pied.
///
/// Mêmes mesures que la pile d'origine — `VStack(alignment: .leading,
/// spacing: 10)` de trois rangées, colonnes de 296 pt séparées de 10 pt, en
/// haut —, à une règle près : les colonnes trop hautes pour `maxHeight`
/// débordent dans une colonne de plus (`PanelFit.arrange`). Quand tout tient,
/// le rendu est celui de la pile, au pixel près (vérifié).
struct PanelLayout: SwiftUI.Layout {
    var columnCount: Int
    /// Hauteur offerte au contenu, sans les marges extérieures. Nil : sans limite.
    var maxHeight: CGFloat?
    var maxColumns: Int
    var columnWidth: CGFloat = PopoverView.columnWidth
    var spacing: CGFloat = 10

    struct Plan {
        var width: CGFloat
        var height: CGFloat
        var headerHeight: CGFloat
        /// Ordonnée de chaque rangée d'en-tête (indice de sous-vue) ; une
        /// rangée vide — l'avis de la barre de menus quand tout se voit — n'a
        /// ni place ni espacement, comme dans une pile.
        var headers: [Int: (y: CGFloat, height: CGFloat)]
        var columnsHeight: CGFloat
        /// Pour chaque carte (indice de sous-vue) : sa colonne et son ordonnée.
        var cards: [Int: (column: Int, y: CGFloat, height: CGFloat)]
        var columns: Int
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let plan = plan(proposal, subviews)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(proposal, subviews)
        for (index, subview) in subviews.enumerated() {
            switch subview[PanelSlotKey.self] {
            case .header:
                let row = plan.headers[index] ?? (y: 0, height: 0)
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + row.y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: row.height))
            case .footer:
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + plan.headerHeight + spacing + plan.columnsHeight + spacing),
                              anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            case .card:
                guard let card = plan.cards[index] else { continue }
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(card.column) * (columnWidth + spacing),
                                          y: bounds.minY + plan.headerHeight + spacing + card.y),
                              anchor: .topLeading,
                              proposal: ProposedViewSize(width: columnWidth, height: card.height))
            }
        }
    }

    func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
        var header = CGSize.zero, footer = CGSize.zero
        var headers: [Int: (y: CGFloat, height: CGFloat)] = [:]
        var cardIndices: [Int] = [], heights: [CGFloat] = [], columns: [Int] = []
        var compactHeights: [CGFloat?] = [], lastResortHeights: [CGFloat?] = []
        let measure = ProposedViewSize(width: proposal.width, height: nil)
        for (index, subview) in subviews.enumerated() {
            switch subview[PanelSlotKey.self] {
            case .header:
                let size = subview.sizeThatFits(measure)
                guard size.height > 0 else { continue }
                if !headers.isEmpty { header.height += spacing }
                headers[index] = (header.height, size.height)
                header.height += size.height
                header.width = max(header.width, size.width)
            case .footer: footer = subview.sizeThatFits(measure)
            case .card(let column):
                cardIndices.append(index)
                let full = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
                heights.append(full)
                // Sa forme compacte : ce que le `ViewThatFits` rend quand la
                // pleine ne tient pas (un point de moins suffit).
                let shrinkable = subview[PanelShrinkKey.self]
                let compact = shrinkable || subview[PanelCompactKey.self]
                    ? subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: max(0, full - 1))).height
                    : nil
                compactHeights.append(shrinkable ? compact : nil)
                lastResortHeights.append(compact)
                columns.append(column)
            }
        }
        let budget = maxHeight.map { $0 - header.height - footer.height - 2 * spacing }
        // D'abord compacter, de bas en haut, ce que l'historique ouvert
        // pousse hors de l'écran ; ensuite seulement, une colonne de plus.
        heights = PanelFit.shrink(heights: heights, compactHeights: compactHeights, columns: columns,
                                  count: columnCount, spacing: spacing, budget: budget)
        let arranged = PanelFit.equilibre
            ? PanelFit.arrangeBalanced(heights: heights, columns: columns, count: columnCount, spacing: spacing,
                                       budget: budget, maxColumns: max(columnCount, maxColumns))
            : PanelFit.arrangeToFit(heights: heights, columns: columns, count: columnCount, spacing: spacing,
                                    budget: budget, maxColumns: max(columnCount, maxColumns))
        if let budget, PanelFit.tallest(arranged, heights: heights, spacing: spacing) > budget {
            heights = PanelFit.shrink(arranged: arranged, heights: heights, compactHeights: lastResortHeights,
                                      spacing: spacing, budget: budget)
        }
        var cards: [Int: (column: Int, y: CGFloat, height: CGFloat)] = [:]
        var columnsHeight: CGFloat = 0
        for (column, members) in arranged.enumerated() {
            var y: CGFloat = 0
            for (position, member) in members.enumerated() {
                if position > 0 { y += spacing }
                cards[cardIndices[member]] = (column, y, heights[member])
                y += heights[member]
            }
            columnsHeight = max(columnsHeight, y)
        }
        let columnsWidth = CGFloat(arranged.count) * columnWidth + CGFloat(max(0, arranged.count - 1)) * spacing
        let width = max(header.width, columnsWidth, footer.width)
        return Plan(width: width, height: header.height + spacing + columnsHeight + spacing + footer.height,
                    headerHeight: header.height, headers: headers, columnsHeight: columnsHeight, cards: cards,
                    columns: arranged.count)
    }
}

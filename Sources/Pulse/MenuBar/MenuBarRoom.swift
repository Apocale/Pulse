import AppKit
import CoreGraphics

/// La place dans la barre de menus, et ce qui s'y voit vraiment.
///
/// Relevé le 11/10 (`CGWindowListCopyWindowInfo`) : sur macOS 26, TOUTES les
/// icônes de la barre sont des fenêtres de Control Center, au niveau 25 —
/// celles de Pulse comprises. Le cadre qu'annoncent l'app et l'API
/// d'accessibilité ne prouve rien : quand la barre déborde, macOS cache
/// les icônes les plus à gauche sans changer ce cadre (README, 07/10, Pulse
/// « toujours annoncé à x = 1170 » sous une pastille de caméra). Ce qui
/// tranche, c'est une fenêtre de Control Center À L'ÉCRAN qui contient ce
/// cadre : relevé, Pulse à x = 1347 sur 125 pt, dans la fenêtre x = 1340 sur
/// 139 pt (7 pt de marge de chaque côté).
///
/// Bornes et positions seulement : aucune autorisation n'est demandée, le nom
/// des fenêtres des autres apps n'est pas lu.
enum MenuBarRoom {
    /// Une fenêtre de la barre de menus, en coordonnées d'écran Quartz
    /// (origine en haut à gauche de l'écran principal).
    struct Window: Equatable {
        var frame: CGRect
        var owner: String
    }

    /// Où est un élément.
    enum Place: Equatable {
        /// Dans une fenêtre affichée, à droite de l'encoche.
        case visible
        /// Affiché, mais derrière l'encoche : invisible sur l'écran du Mac.
        case behindNotch
        /// Aucune fenêtre affichée ne le contient : macOS ne le dessine pas,
        /// faute de place — ou parce qu'il est décoché dans Réglages
        /// Système › Barre de menus.
        case notDrawn
        /// L'élément n'a pas de cadre : il n'est pas dans la barre.
        case absent

        var isVisible: Bool { self == .visible }

        var label: String {
            switch self {
            case .visible:     return "visible"
            case .behindNotch: return "CACHÉ derrière l'encoche"
            case .notDrawn:    return "CACHÉ : macOS ne le dessine pas (barre pleine, ou décoché dans Réglages Système › Barre de menus)"
            case .absent:      return "absent de la barre"
            }
        }
    }

    /// Le niveau des fenêtres de la barre de menus (`kCGStatusWindowLevel`).
    static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

    /// Les fenêtres de la barre de menus affichées en ce moment, de gauche à
    /// droite.
    static func shownWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info -> Window? in
            guard (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double] else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            return Window(frame: frame, owner: info[kCGWindowOwnerName as String] as? String ?? "")
        }
        .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// La zone à droite de l'encoche sur l'écran intégré, en coordonnées
    /// Quartz. Nil sans encoche : tout l'écran est alors disponible.
    @MainActor
    static func rightOfNotch() -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil }),
              let area = screen.auxiliaryTopRightArea else { return nil }
        return quartz(area)
    }

    /// L'écran intégré, celui de l'encoche, en coordonnées Quartz.
    @MainActor
    static func notchScreen() -> CGRect? {
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopRightArea != nil }) else { return nil }
        return quartz(screen.frame)
    }

    /// Un cadre AppKit (origine en bas à gauche de l'écran principal) en
    /// coordonnées Quartz.
    @MainActor
    static func quartz(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Où est l'élément de cadre `item` (Quartz), parmi les fenêtres
    /// affichées. Une fenêtre le contient si elle l'englobe à 1 pt près et ne
    /// le dépasse pas de plus de 30 pt — ses marges, pas une autre icône.
    ///
    /// `screen` : l'écran de l'encoche. Une icône d'un second écran posé à
    /// GAUCHE du Mac, sur la même rangée, a un X plus petit que l'encoche
    /// sans être dessous : elle était dite cachée (26/10).
    static func place(of item: CGRect?, in windows: [Window], rightOfNotch area: CGRect?,
                      screen: CGRect? = nil) -> Place {
        guard let item, item.width > 0 else { return .absent }
        let holder = windows.first { w in
            w.frame.minX - 1 <= item.minX && item.maxX <= w.frame.maxX + 1
                && w.frame.width - item.width <= 30
                && w.frame.minY - 1 <= item.midY && item.midY <= w.frame.maxY + 1
        }
        guard let holder else { return .notDrawn }
        if let area, sameRow(holder.frame, area), item.minX < area.minX - 1,
           screen.map({ item.minX >= $0.minX - 1 }) ?? true {
            return .behindNotch
        }
        return .visible
    }

    /// Sur la rangée de l'encoche. Un second écran a sa propre barre de
    /// menus : posé au-dessus, ses fenêtres ont des Y négatifs, et elles
    /// passaient le seul test `minY < area.maxY`. Relevé le 26/10 avec un
    /// écran de 3 440 × 1 440 au-dessus du Mac : « 918 points, dont 1 715
    /// pris par 29 icônes », dont 16 de l'autre écran.
    static func sameRow(_ frame: CGRect, _ area: CGRect) -> Bool {
        frame.maxY > area.minY && frame.minY < area.maxY
    }

    /// La place libre à droite de l'encoche : entre le bord de l'encoche et
    /// la première icône affichée. Avec la largeur de la zone et celle que
    /// prennent les icônes.
    static func room(_ windows: [Window], rightOfNotch area: CGRect) -> (area: CGFloat, used: CGFloat, free: CGFloat, count: Int) {
        let inside = windows.filter {
            $0.frame.minX >= area.minX - 1 && $0.frame.maxX <= area.maxX + 1 && sameRow($0.frame, area)
        }
        let used = inside.reduce(0) { $0 + $1.frame.width }
        let free = max(0, (inside.first?.frame.minX ?? area.maxX) - area.minX)
        return (area.width, used, free, inside.count)
    }
}

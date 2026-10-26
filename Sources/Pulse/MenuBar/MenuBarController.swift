import AppKit
import Combine

/// Les éléments de Pulse dans la barre de menus : un seul en mode combiné,
/// un par segment sinon.
///
/// Trois règles, chacune payée par un bug réel (README) :
/// - un `NSStatusItem` sans titre ne dessine rien sur macOS 26 : une espace
///   fine tient lieu de titre, tout le reste est dans l'image ;
/// - la largeur est FIGÉE : l'image a toujours la taille du pire cas de sa
///   composition, et la longueur de l'élément est mesurée une fois sur elle.
///   Elle ne se remesure que si la composition change (réglages, un disque
///   au nom plus large) : le débit qui change toutes les 2 s ne fait pas
///   danser les icônes voisines ;
/// - rien n'est redessiné tant que ce qui s'affiche ne change pas.
@MainActor
final class MenuBarController {
    private let sampler: Sampler
    private weak var target: AnyObject?
    private let action: Selector
    private(set) var items: [NSStatusItem] = []
    /// Ce que chaque élément affiche, dans l'ordre de la barre.
    private var shown: [MenuBarContent] = []
    /// La composition sur laquelle les longueurs ont été mesurées.
    private var shape: [String] = []
    private var mode: MenuBarSettings.Mode?
    /// Les segments qui ont chacun leur élément (mode séparé).
    private var itemIds: [String] = []
    private let history = MenuBarHistory()
    private let rates = MenuBarRateFilter()
    private var lastRender: Date = .distantPast
    /// Le dernier élément cliqué : le panneau s'y accroche.
    private weak var clicked: NSStatusBarButton?
    /// Combien de fois une image a été refaite : `--probe` et le banc le
    /// disent.
    private(set) var renders = 0
    /// La barre montrait-elle une alerte au relevé précédent ? nil avant le
    /// premier : une alerte déjà là au lancement n'est pas « arrivée ».
    private var alerting: Bool?

    /// Le nom sous lequel macOS se souvient de la place de l'élément combiné
    /// — celui d'avant ce chantier : la place qu'Isma lui a donnée au
    /// ⌘-glisser est gardée.
    static let combinedAutosave = "com.isma.pulse.statusitem"
    static func autosave(_ id: String) -> String { "com.isma.pulse.barre.\(id)" }

    init(sampler: Sampler, target: AnyObject, action: Selector) {
        self.sampler = sampler
        self.target = target
        self.action = action
        history.seed(from: sampler)
    }

    // MARK: Rafraîchissement

    /// Au plus une fois toutes les `minInterval` secondes. L'icône est le
    /// premier poste du budget (0,45 point sur 0,75, chantier 03, 11/10) :
    /// chaque affichage compte. Les réglages, eux, s'appliquent tout de suite
    /// (`refresh`).
    static let minInterval: TimeInterval = 5

    func refreshIfDue() {
        guard Date().timeIntervalSince(lastRender) >= Self.minInterval else { return }
        refresh()
    }

    /// `force` : la densité de l'écran a changé, chaque image est refaite.
    func refresh(force: Bool = false) {
        lastRender = Date()
        let settings = SettingsStore.shared.settings
        let contents = MenuBarComposer.contents(sampler, settings: settings, history: history, rates: rates)
        let alert = contents.first { $0.alert != nil }?.alert
        if let text = Self.announcement(wasAlerting: alerting, alert: alert) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        alerting = alert?.symbol == MenuBarAlert.alertSymbol
        let newShape = contents.map(Self.shapeKey)
        let ids = contents.map { $0.pieces.first?.id ?? "pulse" }
        if mode != settings.menuBar.mode || (settings.menuBar.mode == .separate && ids != itemIds) {
            rebuild(count: contents.count, ids: ids, mode: settings.menuBar.mode)
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let reshaped = newShape != shape
        for (index, content) in contents.enumerated() where index < items.count {
            guard force || reshaped || index >= shown.count || shown[index] != content else { continue }
            let button = items[index].button
            button?.image = MenuBarDrawing.image(content, scale: scale)
            renders += 1
            if button?.title != "\u{2009}" { button?.title = "\u{2009}" }
            // Une image template n'expose rien à VoiceOver : sans ce libellé,
            // l'élément serait muet. Reposé seulement s'il change.
            let spoken = content.spoken
            if button?.toolTip != spoken {
                button?.setAccessibilityLabel(spoken)
                button?.toolTip = spoken
            }
        }
        if reshaped { fixLengths() }
        shape = newShape
        shown = contents
    }

    /// Ce que VoiceOver annonce quand une alerte ARRIVE dans la barre :
    /// panneau fermé, rien d'autre ne la dirait (16 : « Inform VoiceOver when
    /// visible content or layout changes occur »). Une fois par alerte, pas
    /// à chaque relevé ; ni les avertissements, ni la cloche d'une règle —
    /// Isma est en alerte un tiers du temps, la voix doit rester rare. Pas au
    /// premier relevé : chaque relance de Pulse la redirait.
    nonisolated static func announcement(wasAlerting: Bool?, alert: MenuBarAlert?) -> String? {
        guard wasAlerting == false, let alert, alert.symbol == MenuBarAlert.alertSymbol else { return nil }
        return "Pulse — " + alert.spoken
    }

    /// Ce qui fixe la taille de l'image : ni les valeurs, ni l'alerte.
    private static func shapeKey(_ content: MenuBarContent) -> String {
        let size = MenuBarDrawing.size(content)
        return "\(content.reservesAlert)|\(size.width)|" + content.pieces.map { "\($0.id):\($0.style.rawValue)" }.joined(separator: ",")
    }

    // MARK: Éléments

    /// Recrée les éléments. Un nouvel élément se pose à GAUCHE des autres :
    /// ils sont donc créés de droite à gauche, pour que le premier segment
    /// réglé soit le plus à gauche. Ensuite, ⌘-glisser les range, et macOS
    /// s'en souvient par leur nom.
    private func rebuild(count: Int, ids: [String], mode: MenuBarSettings.Mode) {
        for item in items { NSStatusBar.system.removeStatusItem(item) }
        items = []
        shown = []
        shape = []
        self.mode = mode
        // En mode combiné, un seul élément quel que soit son contenu : il
        // n'est recréé que si le mode change.
        itemIds = mode == .combined ? [] : ids
        var created: [NSStatusItem] = []
        for index in (0..<max(1, count)).reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = mode == .combined ? Self.combinedAutosave : Self.autosave(ids[safe: index] ?? "pulse")
            // Le pourcentage d'abord, l'image ensuite : l'espace fine du titre
            // à gauche, l'image à droite.
            item.button?.imagePosition = .imageTrailing
            item.button?.target = target
            item.button?.action = action
            // Clic droit : le menu de l'app (Réglages, Quitter).
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            created.append(item)
        }
        items = created.reversed()
    }

    /// Largeur FIXE de chaque élément, lue sur le bouton avec son image — qui
    /// a déjà la taille du pire cas. Remesurée seulement quand la
    /// composition change.
    private func fixLengths() {
        for item in items {
            guard let button = item.button else { continue }
            item.length = ceil(button.fittingSize.width)
        }
    }

    // MARK: Clic et ancrage

    /// L'élément cliqué : le panneau s'y accroche, le menu de l'app aussi.
    func didClick(_ sender: Any?) {
        clicked = sender as? NSStatusBarButton
    }

    /// L'élément à qui poser le menu de l'app : le cliqué, sinon le premier.
    var clickedItem: NSStatusItem? {
        items.first { $0.button === clicked } ?? items.first
    }

    /// Le bouton où accrocher le panneau : le cliqué — il se voit, puisqu'on
    /// vient de cliquer dessus —, sinon (raccourci ⌃⌥M) le premier élément
    /// visible. Nil : aucun ne se voit, l'app prend son ancrage de secours.
    func anchorButton(fromClick: Bool) -> NSStatusBarButton? {
        if fromClick, let clicked, items.contains(where: { $0.button === clicked }) { return clicked }
        let report = visibility()
        return zip(items, report).first { $0.1.place.isVisible }?.0.button
    }

    // MARK: Ce qui se voit

    struct Report {
        var name: String
        var frame: CGRect?
        var place: MenuBarRoom.Place
    }

    /// Où est chaque élément, vérifié sur les fenêtres de Control Center à
    /// l'écran (`MenuBarRoom`). Quelques millisecondes : à l'ouverture du
    /// panneau, jamais à la cadence du relevé.
    func visibility() -> [Report] {
        let windows = MenuBarRoom.shownWindows()
        let area = MenuBarRoom.rightOfNotch()
        let screen = MenuBarRoom.notchScreen()
        return items.enumerated().map { index, item in
            let frame = item.button?.window.map { MenuBarRoom.quartz($0.frame) }
            // Combiné : « Pulse » ; séparé : le nom du segment (« Mémoire »).
            let name = mode == .separate
                ? (shown[safe: index]?.pieces.first.flatMap { MenuBarCatalog.entry($0.id)?.name } ?? "Pulse")
                : "Pulse"
            return Report(name: name, frame: frame,
                          place: MenuBarRoom.place(of: frame, in: windows, rightOfNotch: area, screen: screen))
        }
    }

    /// Vérifie et publie pour le panneau (`MenuBarNotice`).
    func publishVisibility() {
        let report = visibility()
        MenuBarStatus.shared.update(report.filter { !$0.place.isVisible }.map(\.name), total: report.count)
    }
}

/// Ce que le panneau dit de la barre : les éléments cachés, vérifiés à son
/// ouverture.
@MainActor
final class MenuBarStatus: ObservableObject {
    static let shared = MenuBarStatus()
    @Published private(set) var hidden: [String] = []
    @Published private(set) var total = 0

    func update(_ hidden: [String], total: Int) {
        if hidden != self.hidden { self.hidden = hidden }
        if total != self.total { self.total = total }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

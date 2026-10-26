import SwiftUI
import AppKit

/// Le tableau de bord : une grande fenêtre pour un second écran. Le verdict,
/// les grands graphes d'historique, puis toutes les cartes du panneau, dans
/// l'ordre des réglages, en autant de colonnes que la largeur en loge.
///
/// Une fenêtre ordinaire, redimensionnable, qui passe en plein écran sur son
/// écran. Comme le panneau : contenu créé à l'ouverture, vidé à la
/// fermeture ou quand elle ne se voit plus (réduite, recouverte, autre
/// espace) — et la cadence du relevé suit.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    static let shared = DashboardWindow()

    static let defaultSize = NSSize(width: 1440, height: 900)
    static let minimumSize = NSSize(width: 700, height: 480)
    private static let autosaveName = "PulseTableauDeBord"

    private var window: NSWindow?
    private var host: SurfaceHost?
    private var occlusion: NSObjectProtocol?

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        guard let sampler = Surfaces.sampler else { return }
        let window = self.window ?? makeWindow(sampler: sampler, persist: Persistence.enabled)
        host?.live()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Surfaces.set("tableau", visible: true)
    }

    /// La fenêtre, construite comme dans l'app ; `--snapshot --tableau` s'en
    /// sert aussi, sans la poser à l'écran ni rien écrire.
    func makeWindow(sampler: Sampler, persist: Bool, size: NSSize? = nil) -> NSWindow {
        // Pas d'options de taille : c'est la fenêtre qui décide, le contenu
        // la remplit et défile.
        let host = SurfaceHost(sizing: []) {
            AnyView(DashboardView(sampler: sampler))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Pulse — tableau de bord"
        window.titlebarAppearsTransparent = true
        window.contentMinSize = Self.minimumSize
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = host.controller
        window.setContentSize(size ?? Self.defaultSize)
        window.delegate = self
        host.live()
        if persist {
            // Là où Isma l'a laissée ; la première fois, sur le second écran
            // s'il y en a un — c'est pour lui qu'elle existe.
            if !window.setFrameUsingName(Self.autosaveName) { Self.placeOnSecondScreen(window) }
            window.setFrameAutosaveName(Self.autosaveName)
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.occlusionChanged() }
                }
        }
        self.host = host
        self.window = window
        return window
    }

    /// Le plus grand écran qui n'est pas celui de la barre de menus ; sinon
    /// l'écran principal.
    private static func placeOnSecondScreen(_ window: NSWindow) {
        let screens = NSScreen.screens
        let others = screens.dropFirst()
        let screen = others.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? NSScreen.main ?? screens.first
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let width = min(defaultSize.width, visible.width - 40)
        let height = min(defaultSize.height, visible.height - 40)
        window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
                        display: false)
    }

    /// Réduite dans le Dock, une fenêtre n'est plus `isVisible` : s'arrêter
    /// là gardait la cadence ouverte (signalé par le 17, corrigé par le 19).
    private func occlusionChanged() {
        guard let window, host != nil else { return }
        let seen = Surfaces.isSeen(window)
        if seen { host?.live() } else { host?.freeze(size: window.contentView?.frame.size ?? .zero) }
        Surfaces.set("tableau", visible: seen)
    }

    func windowDidMiniaturize(_ notification: Notification) { occlusionChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { occlusionChanged() }

    func windowWillClose(_ notification: Notification) {
        Surfaces.set("tableau", visible: false)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            self.host?.controller.rootView = AnyView(EmptyView())
            self.window?.contentViewController = nil
            self.window = nil
            self.host = nil
        }
    }
}

// MARK: - Le contenu

struct DashboardView: View {
    @ObservedObject var sampler: Sampler
    @ObservedObject var store: SettingsStore

    /// Un historique déplié à la fois, comme dans le panneau, mais le sien.
    @State private var open: String?

    /// Hauteur des grands graphes : trois fois celle des cartes.
    static let plotHeight: CGFloat = 150
    static let spacing: CGFloat = 12

    init(sampler: Sampler, store: SettingsStore? = nil) {
        self.sampler = sampler
        self.store = store ?? .shared
    }

    var body: some View {
        let settings = store.settings
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                VerdictHeadline(verdict: sampler.verdict)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: Self.spacing, alignment: .top)],
                          alignment: .leading, spacing: Self.spacing) {
                    ForEach(charts) { chart in
                        Card {
                            HistoryChart(keys: chart.keys, title: chart.title, range: chart.range,
                                         plotHeight: Self.plotHeight)
                        }
                    }
                }
                Masonry(columnWidth: PopoverView.columnWidth, spacing: Self.spacing) {
                    ForEach(cards(settings), id: \.self) { id in
                        card(id, settings)
                    }
                }
            }
            .padding(20)
        }
        .background(PopoverBackground().ignoresSafeArea())
        .environment(\.pulseSurface, .dashboard)
    }

    /// Les grands graphes : ce qu'on regarde pendant un export.
    struct Chart: Identifiable {
        var id: String { keys.joined(separator: "+") }
        var title: String
        var keys: [String]
        var range: HistoryRange
    }

    private var charts: [Chart] {
        var list = [
            Chart(title: "Processeur", keys: ["cpu.total"], range: .hour),
            Chart(title: "Mémoire utilisée", keys: ["memoire.utilisee"], range: .day),
            Chart(title: "Swap", keys: ["memoire.swap"], range: .day),
            Chart(title: "Carte graphique", keys: ["gpu"], range: .hour),
            Chart(title: "Débit internet", keys: ["reseau.envoi", "reseau.reception"], range: .hour),
            Chart(title: "Débit des disques", keys: [DiskActivity.historyKeys.read, DiskActivity.historyKeys.write],
                  range: .hour),
        ]
        if let disk = EtatBuilder.rushes(sampler.volumes) ?? sampler.volumes.first(where: { $0.isInternal }) {
            list.append(Chart(title: "Libre · \(disk.name)", keys: [SeriesCatalog.volumeKey(disk.historyKey)],
                              range: .month))
        }
        return list
    }

    /// Les cartes affichées, dans l'ordre des réglages, sans celles qui
    /// n'ont rien à dire (la carte Montage hors session).
    private func cards(_ settings: PulseSettings) -> [String] {
        Layout.order(settings).filter { id in
            guard let module = ModuleRegistry.module(id) else { return false }
            return Layout.isEnabled(module, in: settings) && module.hasContent(sampler)
        }
    }

    @ViewBuilder
    private func card(_ id: String, _ settings: PulseSettings) -> some View {
        if let module = ModuleRegistry.module(id) {
            module.card(CardContext(module: module, sampler: sampler, open: $open,
                                    settings: settings.module(id), display: settings.display))
                .frame(width: PopoverView.columnWidth)
        }
    }
}

/// Le verdict en tête du tableau de bord : la phrase, puis la preuve. Même
/// grammaire que le bandeau du panneau — le symbole teinté dit la nature,
/// le texte reste `.primary` et `.secondary` (règle dure n°6).
struct VerdictHeadline: View {
    var verdict: Verdict

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: verdict.symbol)
                .font(.title)
                .foregroundStyle(tint)
                // Le niveau dit en mots, comme dans le panneau (chantier 16).
                .accessibilityLabel(PopoverView.spokenLevel(verdict.level))
                .accessibilityHidden(PopoverView.spokenLevel(verdict.level).isEmpty)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.phrase)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(verdict.also.isEmpty ? verdict.evidence
                     : verdict.evidence + "  ·  et aussi : " + verdict.also.joined(separator: ", "))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch verdict.level {
        case .alert:   return Palette.alert
        case .warning: return Palette.warning
        case .data:    return Palette.data
        case .muted:   return Palette.muted
        }
    }
}

/// Des colonnes de largeur fixe, autant que la largeur en loge, chaque carte
/// posée dans la colonne la moins haute — dans l'ordre de lecture. Le bloc
/// est centré : les cartes gardent la largeur pour laquelle elles sont
/// dessinées (296 pt), on ne les étire pas.
struct Masonry: SwiftUI.Layout {
    var columnWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (columnWidth * 3 + spacing * 2)
        let placed = place(subviews, width: width)
        return CGSize(width: proposal.width ?? placed.used, height: placed.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let placed = place(subviews, width: bounds.width)
        let inset = max(0, (bounds.width - placed.used) / 2)
        for (index, point) in placed.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + inset + point.x, y: bounds.minY + point.y),
                                  proposal: ProposedViewSize(width: columnWidth, height: nil))
        }
    }

    static func columnCount(width: CGFloat, columnWidth: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (columnWidth + spacing)))
    }

    private func place(_ subviews: LayoutSubviews, width: CGFloat) -> (origins: [CGPoint], used: CGFloat, height: CGFloat) {
        let count = min(Self.columnCount(width: width, columnWidth: columnWidth, spacing: spacing),
                        max(1, subviews.count))
        var heights = Array(repeating: CGFloat(0), count: count)
        var origins: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: y))
            heights[column] = y + size.height
        }
        let used = CGFloat(count) * columnWidth + CGFloat(count - 1) * spacing
        return (origins, used, heights.max() ?? 0)
    }
}

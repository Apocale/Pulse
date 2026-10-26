import SwiftUI
import AppKit

/// Le panneau détaché : le même contenu que le popover, dans une fenêtre qui
/// reste là — au-dessus de Premiere en plein écran si Isma le veut.
///
/// Un `NSPanel` NON ACTIVANT : un clic dedans (déplier un historique,
/// l'épingle) ne fait pas passer Pulse au premier plan, Premiere garde le
/// clavier. `hidesOnDeactivate` à faux : une app accessoire n'est presque
/// jamais active, et un panneau ordinaire disparaîtrait aussitôt.
///
/// Budget : le contenu n'existe que pendant que la fenêtre se voit
/// (`SurfaceHost`). Fermée, rien ne reste ; cachée — réduite, recouverte,
/// sur un autre espace —, le contenu est vidé et le relevé repasse à la
/// cadence fermée.
@MainActor
final class FloatingWindow: NSObject, NSWindowDelegate {
    static let shared = FloatingWindow()

    private var panel: NSPanel?
    private var host: SurfaceHost?
    private var occlusion: NSObjectProtocol?

    // MARK: - Réglages de la fenêtre

    private static let onTopKey = "fenetre.dessus"
    private static let originKey = "fenetre.origine"
    /// Sous `--snapshot` : rien n'est écrit, la valeur vit en mémoire.
    private static var onTopInMemory: Bool?

    /// Au-dessus de toutes les fenêtres, plein écran compris. Activé par
    /// défaut : c'est la raison d'être d'un panneau détaché.
    static var onTop: Bool {
        get { onTopInMemory ?? (UserDefaults.standard.object(forKey: onTopKey) as? Bool) ?? true }
        set {
            onTopInMemory = newValue
            if Persistence.enabled { UserDefaults.standard.set(newValue, forKey: onTopKey) }
        }
    }

    var isOpen: Bool { panel?.isVisible == true }

    // MARK: - Ouverture

    /// Ouvre la fenêtre. `popoverFrame` : le cadre du panneau qu'elle
    /// remplace — elle s'ouvre à sa place, coin haut gauche sur coin haut
    /// gauche. Sinon, là où Isma l'a laissée la dernière fois.
    func show(replacing popoverFrame: NSRect?) {
        guard let sampler = Surfaces.sampler else { return }
        let panel = self.panel ?? makePanel(sampler: sampler, persist: Persistence.enabled)
        // Premiere garde le clavier… sauf pour qui navigue au clavier seul :
        // avec l'Accès complet au clavier, le panneau peut devenir actif et
        // Tab y entre (HIG Keyboards, « Support Full Keyboard Access » ;
        // chantier 16). Relu à chaque ouverture : le réglage peut changer.
        panel.becomesKeyOnlyIfNeeded = !NSApp.isFullKeyboardAccessEnabled
        host?.live()
        panel.contentView?.layoutSubtreeIfNeeded()
        if let host { Self.fit(panel, to: Self.idealSize(host)) }
        if let popoverFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: popoverFrame.minX, y: popoverFrame.maxY))
        } else if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            panel.setFrameTopLeftPoint(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - 8))
        }
        Self.keepOnScreen(panel)
        panel.orderFrontRegardless()
        Surfaces.set("fenetre", visible: true)
    }

    /// La fenêtre, construite comme dans l'app ; `--snapshot --fenetre` s'en
    /// sert aussi, sans jamais la poser à l'écran ni rien écrire.
    func makePanel(sampler: Sampler, persist: Bool) -> NSPanel {
        // Aucune contrainte de taille entre le contenu et la fenêtre : le
        // contenu mesure sa taille idéale et la fenêtre la suit quand elle
        // change (un historique déplié), et seulement alors. Deux essais
        // écartés, mesurés le 11/10 : des contraintes min/max refaisaient la
        // mise en page de la fenêtre à chaque relevé (11,3 % d'un cœur
        // fenêtre ouverte, 8,0 % pour le popover au même moment) ; la taille
        // préférée suivie à la volée bouclait avec la marge de la barre de
        // titre (exception AppKit « Update Constraints in Window »).
        let host = SurfaceHost(sizing: []) {
            // Le panneau tient dans l'écran, barre de titre comprise : trop
            // haut, il prend une colonne de plus (`PanelFit`, chantier 01).
            AnyView(FloatingContent(sampler: sampler, limits: FloatingWindow.panelLimits(),
                                    onTop: FloatingWindow.onTop,
                                    setOnTop: { FloatingWindow.shared.setOnTop($0) },
                                    sizeDidChange: { size in
                                        DispatchQueue.main.async {
                                            MainActor.assumeIsolated { FloatingWindow.shared.fitPanel(to: size) }
                                        }
                                    }))
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Pulse — panneau détaché"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true   // relu à chaque ouverture (`show`)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // Un panneau se ferme, il ne se réduit ni ne s'agrandit : seul le
        // bouton de fermeture reste.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = host.controller
        panel.delegate = self
        Self.apply(onTop: Self.onTop, to: panel)
        host.live()
        self.host = host
        Self.fit(panel, to: Self.idealSize(host))
        self.panel = panel
        if persist {
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.occlusionChanged() }
                }
        }
        return panel
    }

    func fitPanel(to size: CGSize) { Self.fit(panel, to: size) }

    /// La place du panneau dans la fenêtre : l'écran principal sous la barre
    /// de menus, moins la barre de titre (`PanelLimits.windowSized`).
    static func panelLimits() -> PanelLimits? {
        PanelLimits.visibleArea().map { .windowSized(width: $0.width, height: $0.height) }
    }

    /// La taille idéale du contenu, mesurée sans fenêtre : le contenu est à
    /// taille fixe, la proposition n'y change rien.
    static func idealSize(_ host: SurfaceHost) -> CGSize {
        host.controller.sizeThatFits(in: NSSize(width: 4000, height: 4000))
    }

    /// La fenêtre prend la taille du contenu, coin haut gauche immobile.
    static func fit(_ panel: NSPanel?, to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let content = panel.contentRect(forFrameRect: panel.frame).size
        guard abs(content.width - size.width) > 0.5 || abs(content.height - size.height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }

    /// L'épingle : au-dessus de tout, sur tous les espaces, plein écran
    /// compris ; décochée, une fenêtre ordinaire qu'une autre recouvre.
    func setOnTop(_ on: Bool) {
        Self.onTop = on
        if let panel { Self.apply(onTop: on, to: panel) }
    }

    static func apply(onTop: Bool, to panel: NSPanel) {
        panel.isFloatingPanel = onTop
        panel.level = onTop ? .floating : .normal
        panel.collectionBehavior = onTop
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .fullScreenAuxiliary]
    }

    /// Une fenêtre rouverte sur un écran débranché depuis tomberait dans le
    /// vide : ramenée dans l'écran le plus proche.
    private static func keepOnScreen(_ panel: NSPanel) {
        let frame = panel.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        if origin != frame.origin { panel.setFrameOrigin(origin) }
    }

    // MARK: - Visible, caché, fermé

    /// Réduite, recouverte ou sur un autre espace : plus rien ne se dessine,
    /// le relevé ralentit. De retour sous les yeux : le contenu revient.
    private func occlusionChanged() {
        guard let panel, host != nil else { return }
        let seen = Surfaces.isSeen(panel)
        if seen { host?.live() } else { host?.freeze(size: panel.contentView?.frame.size ?? .zero) }
        Surfaces.set("fenetre", visible: seen)
    }

    func windowDidMove(_ notification: Notification) {
        guard Persistence.enabled, let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)),
                                  forKey: Self.originKey)
    }

    func windowWillClose(_ notification: Notification) {
        Surfaces.set("fenetre", visible: false)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        // Au tour de boucle suivant, pas au milieu de la fermeture : la
        // vue est vidée avant d'être lâchée, comme celle du popover.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible != true else { return }
            self.host?.controller.rootView = AnyView(EmptyView())
            self.panel?.contentViewController = nil
            self.panel = nil
            self.host = nil
        }
    }
}

/// Le contenu de la fenêtre détachée : une barre de titre discrète — la
/// place du bouton de fermeture, l'épingle —, puis le panneau tel quel.
struct FloatingContent: View {
    @ObservedObject var sampler: Sampler
    /// La place que l'écran laisse au panneau ; nil : sans limite.
    var limits: PanelLimits? = nil
    /// Les réglages : ceux d'Isma, ou ceux d'un rendu figé (`--ajuste`).
    var store: SettingsStore? = nil
    @State var onTop: Bool
    var setOnTop: (Bool) -> Void
    /// La taille idéale du contenu a changé : la fenêtre la suit.
    var sizeDidChange: (CGSize) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // La place des boutons de la fenêtre, à gauche.
                Spacer().frame(width: 52)
                Spacer()
                Text("Pulse")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                pin
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            PopoverView(sampler: sampler, store: store, limits: limits)
        }
        .fixedSize()
        .background(PopoverBackground())
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FloatingSizeKey.self, value: geometry.size)
        })
        .onPreferenceChange(FloatingSizeKey.self) { sizeDidChange($0) }
        // Sous la barre de titre transparente : sa marge ne joue pas, la
        // fenêtre fait la taille du contenu au point près.
        .ignoresSafeArea()
        .environment(\.pulseSurface, .floating)
    }

    /// Plein ou vide, le symbole dit l'état : la couleur ne le porte pas
    /// seule. `.primary` quand l'épingle tient, `.secondary` sinon.
    private var pin: some View {
        Button {
            onTop.toggle()
            setOnTop(onTop)
        } label: {
            Image(systemName: onTop ? "pin.fill" : "pin")
                .font(.callout)
                .foregroundStyle(onTop ? .primary : .secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(onTop ? "Au-dessus de toutes les fenêtres, plein écran compris — cliquer pour la libérer"
                    : "Garder au-dessus de toutes les fenêtres, plein écran compris")
        .accessibilityLabel("Garder au-dessus de toutes les fenêtres")
        .accessibilityValue(onTop ? "activé" : "désactivé")
    }
}

private struct FloatingSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

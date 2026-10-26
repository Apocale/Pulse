import SwiftUI
import AppKit

/// La fenêtre Réglages : ouverte depuis le menu de l'icône (clic droit) ou
/// le bouton ⚙ du panneau, ⌘, au clavier.
///
/// Son contenu n'existe que pendant qu'elle est ouverte ET sous les yeux
/// d'Isma, comme celui du panneau : une vue SwiftUI gardée en vie resterait
/// abonnée au sampler et se recalculerait à chaque relevé (README, « Un
/// popover refermé continue de se dessiner »). Réduite, masquée, sur un autre
/// espace ou entièrement recouverte (Premiere en plein écran) : contenu vidé,
/// relevé à la cadence fermée ; de retour, elle revient sur sa page.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    /// Le relevé de l'app, pour l'aperçu en direct des cartes. Posé par
    /// `AppDelegate` au lancement.
    var sampler: Sampler?

    /// Sous les yeux d'Isma (`true`) ou non — fermée, réduite, masquée,
    /// recouverte : l'app règle la cadence du relevé, pour que l'aperçu des
    /// cartes vive au rythme du panneau ouvert, et seulement quand il se voit.
    var visibilityDidChange: ((Bool) -> Void)?

    private var window: NSWindow?
    private var host: SurfaceHost?
    private var occlusion: NSObjectProtocol?
    /// La page affichée, gardée quand le contenu est vidé.
    private(set) var page: SettingsPage = .general
    /// Ce qui a été annoncé à l'app en dernier.
    private(set) var isSeen = false

    static let size = NSSize(width: 980, height: 660)

    func show(_ page: SettingsPage = .general) {
        guard let sampler else { return }
        let window = self.window ?? makeWindow(sampler: sampler, page: page)
        if window.isMiniaturized { window.deminiaturize(nil) }
        host?.live()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        announce(true)
    }

    /// La fenêtre et son contenu, sans la poser à l'écran : `show` l'y met,
    /// `--banc --reglages` la garde hors écran pour mesurer ce qu'elle coûte.
    @discardableResult
    func makeWindow(sampler: Sampler, page: SettingsPage = .general) -> NSWindow {
        self.page = page
        // Les options de taille par défaut de `NSHostingController`
        // (minimum, intrinsèque, maximum) : la fenêtre ne descend pas sous
        // les 900 × 600 de la vue.
        let host = SurfaceHost(sizing: .standardBounds) { [weak self] in
            AnyView(SettingsView(store: .shared, sampler: sampler, page: self?.page ?? .general,
                                 pageDidChange: { self?.page = $0 }))
        }
        host.live()
        let window = NSWindow(contentViewController: host.controller)
        window.title = "Réglages de Pulse"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Premiere en plein écran : la fenêtre vient sur l'espace où
        // Isma se trouve, au lieu de le renvoyer au bureau.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
        self.host = host
        self.window = window
        return window
    }

    /// Relit si la fenêtre se voit : à chaque changement d'occlusion, et
    /// quand elle est réduite ou rouverte du Dock.
    func visibilityChanged() {
        guard let window else { return }
        let seen = Surfaces.isSeen(window)
        if seen { host?.live() } else { host?.freeze(size: window.contentView?.frame.size ?? .zero) }
        announce(seen)
    }

    /// Le contenu existe-t-il ? (`--banc --reglages`, tests.)
    var isLive: Bool { host?.isLive == true }

    /// Dit à l'app si la fenêtre est sous les yeux d'Isma, une fois par
    /// bascule. Interne pour les tests, qui ne l'affichent jamais.
    func announce(_ seen: Bool) {
        guard seen != isSeen else { return }
        isSeen = seen
        visibilityDidChange?(seen)
    }

    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }

    func windowWillClose(_ notification: Notification) {
        SettingsStore.shared.flush()
        close()
    }

    /// Fermée : cadence fermée, contenu vidé puis lâché au tour de boucle
    /// suivant, pas au milieu de la fermeture. Rouverte entre-temps, elle
    /// repart d'une fenêtre neuve.
    func close() {
        announce(false)
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        let (window, host) = (self.window, self.host)
        self.window = nil
        self.host = nil
        DispatchQueue.main.async {
            host?.controller.rootView = AnyView(EmptyView())
            window?.contentViewController = nil
        }
    }
}

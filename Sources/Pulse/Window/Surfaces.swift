import SwiftUI
import AppKit

/// Les surfaces du chantier 13 hors du panneau : la fenêtre détachée et le
/// tableau de bord. Ce fichier tient ce qu'elles partagent avec l'app.
///
/// Une seule question compte pour le budget : une surface est-elle SOUS LES
/// YEUX d'Isma ? Oui : le relevé passe à la cadence du panneau ouvert. Non —
/// fermée, réduite, sur un autre espace, recouverte — : son contenu est vidé
/// et la cadence retombe, exactement comme quand le panneau se referme
/// (README, « Un popover refermé continue de se dessiner »).
@MainActor
enum Surfaces {
    /// Le relevé de l'app, posé au lancement par `attach`.
    private(set) static var sampler: Sampler?

    /// Appelé quand une surface apparaît ou disparaît : l'app recalcule la
    /// cadence du relevé (`AppDelegate.measuringOpen`).
    private static var visibilityDidChange: (() -> Void)?

    private static var visible: Set<String> = []

    /// Au moins une surface est sous les yeux d'Isma.
    static var anyVisible: Bool { !visible.isEmpty }

    /// Une fenêtre se voit-elle ? À l'écran (`isVisible` : ni fermée, ni
    /// réduite dans le Dock, ni masquée avec son app) et pas entièrement
    /// recouverte ni sur un autre espace (`occlusionState`). Réduite, une
    /// fenêtre n'est plus `isVisible` : un observateur qui s'arrêtait là
    /// gardait la cadence ouverte (19-suivis).
    static func isSeen(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Branche les surfaces sur l'app : le relevé, et de quoi suivre la
    /// cadence. Une ligne dans `applicationDidFinishLaunching`.
    static func attach(sampler: Sampler, visibilityDidChange: @escaping () -> Void) {
        self.sampler = sampler
        self.visibilityDidChange = visibilityDidChange
        SharedStateWriter.shared.start(sampler: sampler)
    }

    /// Une surface (« fenetre », « tableau ») devient visible ou ne l'est plus.
    static func set(_ id: String, visible isVisible: Bool) {
        let changed = isVisible ? visible.insert(id).inserted : visible.remove(id) != nil
        if changed { visibilityDidChange?() }
    }

    /// Les entrées du menu de l'icône (clic droit), après « Réglages ».
    static func menuItems() -> [NSMenuItem] {
        let detach = NSMenuItem(title: "Détacher le panneau", action: #selector(SurfaceActions.detach), keyEquivalent: "")
        let dashboard = NSMenuItem(title: "Tableau de bord", action: #selector(SurfaceActions.dashboard), keyEquivalent: "")
        for item in [detach, dashboard] { item.target = SurfaceActions.shared }
        return [detach, dashboard]
    }
}

/// Cible des entrées de menu : `NSMenuItem` veut un objet.
@MainActor
final class SurfaceActions: NSObject {
    static let shared = SurfaceActions()

    @objc func detach() { FloatingWindow.shared.show(replacing: nil) }
    @objc func dashboard() { DashboardWindow.shared.show() }
}

// MARK: - Où la vue est dessinée

/// La surface qui porte une vue : le panneau, la fenêtre détachée ou le
/// tableau de bord. Le pied du panneau s'en sert pour ne pas proposer de
/// détacher une fenêtre déjà détachée.
enum SurfaceKind {
    case popover, floating, dashboard
}

private struct SurfaceKindKey: EnvironmentKey {
    static let defaultValue = SurfaceKind.popover
}

extension EnvironmentValues {
    var pulseSurface: SurfaceKind {
        get { self[SurfaceKindKey.self] }
        set { self[SurfaceKindKey.self] = newValue }
    }
}

// MARK: - Les boutons du pied du panneau

/// « Détacher » et « Tableau de bord », à gauche de ⚙ dans le pied du
/// panneau. Même dessin que les raccourcis voisins : 26 pt de côté, au-dessus
/// des 20 pt du HIG, symbole en `.secondary`.
struct SurfaceButtons: View {
    @Environment(\.pulseSurface) private var surface

    var body: some View {
        HStack(spacing: 8) {
            if surface == .popover {
                button("Détacher le panneau dans une fenêtre", symbol: "macwindow.on.rectangle") {
                    (NSApp.delegate as? AppDelegate)?.detachPanel()
                }
            }
            if surface != .dashboard {
                button("Tableau de bord", symbol: "rectangle.3.group") {
                    (NSApp.delegate as? AppDelegate)?.openDashboard()
                }
            }
        }
    }

    private func button(_ name: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

// MARK: - Contenu créé à l'ouverture, vidé à la fermeture

/// L'hôte SwiftUI d'une fenêtre de surface. Le contenu n'existe que pendant
/// que la fenêtre se voit : cachée, il est remplacé par un cadre vide de la
/// même taille — la fenêtre ne bouge pas, plus rien ne se recalcule.
@MainActor
final class SurfaceHost {
    let controller: NSHostingController<AnyView>
    private let make: () -> AnyView
    private(set) var isLive = false

    init(sizing: NSHostingSizingOptions, make: @escaping () -> AnyView) {
        self.make = make
        controller = NSHostingController(rootView: AnyView(EmptyView()))
        controller.sizingOptions = sizing
    }

    /// Crée le contenu s'il n'existe pas.
    func live() {
        guard !isLive else { return }
        isLive = true
        controller.rootView = make()
    }

    /// Vide le contenu, en gardant la taille de la fenêtre.
    func freeze(size: CGSize) {
        guard isLive else { return }
        isLive = false
        controller.rootView = AnyView(Color.clear.frame(width: size.width, height: size.height))
    }
}

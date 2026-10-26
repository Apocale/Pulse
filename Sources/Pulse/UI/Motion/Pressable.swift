import SwiftUI
import AppKit

// Survol et appui, pour tout ce qui se clique dans le panneau (chantier 10).
//
// Pourquoi : le retour. Sur Mac, un contrôle qui ne réagit pas au survol ne
// se distingue pas d'un texte ; un clic qui ne marque rien laisse un doute.
// Les lignes dépliables, les raccourcis, Réglages et Quitter réagissent donc
// tous de la même façon :
// - au survol, un voile à peine plus clair (sombre) ou plus foncé (clair),
//   posé en 120 ms ease-out ;
// - à l'appui, le contrôle se resserre (0,98 pour une ligne, 0,92 pour une
//   icône) en 80 ms, et revient en 160 ms au relâché.
//
// Le voile ne descend jamais sous le contraste mesuré : en sombre il reste
// plus foncé que le fond de référence des ratios (#393939), en clair il
// n'assombrit que de 3 %. `MotionTests` le vérifie pour chaque teinte.
//
// Réduire les animations : survol et appui restent visibles, sans
// transition ni resserrement.

/// Le voile de survol, mesuré : voir `MotionTests`.
enum Hover {
    /// Blanc à 5 % en sombre, noir à 3 % en clair.
    static let veil = NSColor(name: "pulseHoverVeil") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05)
            : NSColor(white: 0, alpha: 0.03)
    }
    static var color: Color { Color(nsColor: veil) }
}

/// Le style des boutons du panneau.
struct PulseButtonStyle: ButtonStyle {
    enum Kind {
        /// Une ligne entière, cliquable de bord à bord.
        case row
        /// Un symbole de 26 pt (raccourcis, Réglages) ou un court libellé.
        case icon
    }

    var kind: Kind = .row

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == PulseButtonStyle {
    /// Une ligne dépliable : voile au survol, resserrement à l'appui.
    static var pulseRow: PulseButtonStyle { PulseButtonStyle(kind: .row) }
    /// Une icône ou un court libellé de la barre de raccourcis.
    static var pulseIcon: PulseButtonStyle { PulseButtonStyle(kind: .icon) }
}

private struct PressableBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: PulseButtonStyle.Kind
    @State private var hovering = false
    /// `--snapshot x.png --survol` : tous les contrôles survolés, pour mesurer.
    @Environment(\.forcedHover) private var forcedHover

    var body: some View {
        let pressed = configuration.isPressed
        let lit = hovering || pressed || forcedHover
        let reduce = Motion.reduceMotion
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: kind == .icon ? 6 : 6, style: .continuous)
                    .fill(Hover.color)
                    // La ligne garde sa place : le voile déborde de 4 pt
                    // dans la marge de la carte, pas dans le texte.
                    .padding(.horizontal, kind == .row ? -4 : 0)
                    .padding(.vertical, kind == .row ? -2 : 0)
                    .opacity(lit ? 1 : 0)
            }
            .scaleEffect(pressed && !reduce ? (kind == .icon ? 0.92 : 0.98) : 1)
            .onHover { hovering = $0 }
            .animation(reduce ? nil : .easeOut(duration: pressed ? 0.08 : 0.16), value: pressed)
            .animation(reduce ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct ForcedHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Tous les contrôles du panneau dessinés survolés (`--survol`).
    var forcedHover: Bool {
        get { self[ForcedHoverKey.self] }
        set { self[ForcedHoverKey.self] = newValue }
    }
}

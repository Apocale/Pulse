import SwiftUI
import AppKit

// Le cadre du panneau en Liquid Glass (chantier 10), comme iStat Menus 7.5.
//
// **Le verre est déjà là.** Sous macOS 26, le cadre de NSPopover est du verre :
// `NSPopoverFrame` (un `NSVisualEffectView`) porte `_glassVariant` et
// `_updateGlassVariant`, et ses données privées un `glassView` — relevé par
// introspection du runtime, sans rien afficher (docs/chantiers/10-animations.md).
// Le fond opaque du panneau le recouvrait. Il suffit donc de le retirer là
// où il n'y a pas de donnée : le verre natif apparaît, avec sa forme (la
// flèche comprise), ses reflets, et son comportement sous Réduire la
// transparence et Augmenter le contraste — que nous n'aurions pas su imiter.
// Un second verre posé par-dessus en SwiftUI serait du verre sur du verre.
//
// **Jamais de verre sous une donnée.** Le verre laisse passer ce qu'il y a
// derrière la fenêtre — une timeline claire, un bureau — : une teinte posée
// dessus aurait un contraste inconnu. Les cartes et le verdict gardent donc
// un fond OPAQUE, celui-là même sur lequel les ratios de `Palette` sont
// mesurés ; seuls les marges, les interstices et la barre de raccourcis —
// des contrôles, ce pour quoi le verre est fait — sont en verre.
//
// **Réduire la transparence** : le fond opaque d'avant (#1E1E1E en sombre),
// relu à chaque ouverture du panneau.

private struct GlassFrameKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Le panneau laisse voir le verre de son cadre (marges, interstices,
    /// barre de raccourcis). Faux par défaut : rendus, aperçus et banc
    /// dessinent le panneau opaque.
    var glassFrame: Bool {
        get { self[GlassFrameKey.self] }
        set { self[GlassFrameKey.self] = newValue }
    }
}

enum Glass {
    /// Le verre est-il permis ? macOS 26 (le cadre de NSPopover n'est du verre
    /// que depuis), et Réduire la transparence éteint.
    @MainActor static var allowed: Bool {
        guard #available(macOS 26, *) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

/// Le fond d'une surface qui porte des données — une carte, le verdict :
/// opaque, toujours, verre ou pas autour.
struct DataSurface: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Palette.card))
    }
}

/// La surface opaque, seulement quand il y a du verre autour.
struct OptionalDataSurface: ViewModifier {
    var active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.modifier(DataSurface()) } else { content }
    }
}

/// Le fond de `--snapshot x.png --verre` : des bandes criardes à la place
/// du verre, que rien de Pulse n'utilise. Tout ce qui les laisse voir est
/// posé sur le verre.
struct GlassWitness: View {
    var body: some View {
        Canvas { context, size in
            let colors: [Color] = [Color(red: 1, green: 0, blue: 0.6), Color(red: 0, green: 0.9, blue: 0.3)]
            var x: CGFloat = -size.height
            var index = 0
            while x < size.width {
                var band = Path()
                band.move(to: CGPoint(x: x, y: size.height))
                band.addLine(to: CGPoint(x: x + size.height, y: 0))
                band.addLine(to: CGPoint(x: x + size.height + 24, y: 0))
                band.addLine(to: CGPoint(x: x + 24, y: size.height))
                band.closeSubpath()
                context.fill(band, with: .color(colors[index % 2]))
                x += 24
                index += 1
            }
        }
    }
}

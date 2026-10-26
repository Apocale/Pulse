import SwiftUI
import AppKit

/// Courbe normalisée sur [0…1].
struct LineSeries: Shape {
    var values: [Double]
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        func point(_ index: Int) -> CGPoint {
            let clamped = min(1, max(0, values[index]))
            return CGPoint(x: rect.minX + CGFloat(index) * step,
                           y: rect.maxY - CGFloat(clamped) * rect.height)
        }
        path.move(to: point(0))
        for i in 1..<values.count { path.addLine(to: point(i)) }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct Meter: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(tint)
                    .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(Motion.value, value: fraction)
        // La valeur est déjà énoncée par le libellé voisin : une jauge
        // muette évite un doublon à chaque arrêt de VoiceOver.
        .accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    var title: String
    var trailing: String?
    /// Non nil quand la section est dépliable : le triangle apparaît alors
    /// devant le titre, et son orientation suit l'état.
    var open: Bool? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let open { DisclosureChevron(open: open) }
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LegendDot: View {
    var color: Color
    var label: String

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// Fond du popover : une couleur OPAQUE, pas un matériau de vibrance.
///
/// NSPopover ne peint rien derrière une vue SwiftUI, et les deux modes de
/// mélange posent chacun un problème. `.behindWindow` échantillonne le bureau,
/// donc le contraste du texte dépend de la timeline affichée dessous ;
/// `.withinWindow` laisse carrément transparaître la fenêtre du dessous, la
/// fenêtre du popover étant elle-même transparente.
///
/// Pour un relevé chiffré, la lisibilité prime sur l'effet : `windowBackground`
/// suit l'apparence claire ou sombre et donne un fond dont on connaît
/// exactement la luminance — ce qui rend les ratios de contraste de Palette
/// vrais dans tous les cas, et pas seulement dans le meilleur.
///
/// **Ce fond porte désormais la règle à lui seul.** Elle était écrite sur
/// `GlassSurface`, qui n'existe plus : le verre des tuiles a été retiré, et il
/// ne reste de matériau que sur le bouton Quitter, qui ne porte aucune donnée.
/// Toute teinte de `Palette` posée dans le panneau est donc échantillonnée
/// contre CETTE luminance et contre aucune autre. Poser du verre sous un
/// symbole coloré, une courbe ou une jauge lui ferait au contraire
/// échantillonner une luminance inconnue — le bureau à travers la fenêtre, une
/// timeline claire par exemple — et les ratios mesurés cesseraient d'être
/// vrais : le bleu des séries passe alors sous le seuil de 3:1.
///
/// En sombre, plus `windowBackground` : sous macOS 26, dans un popover, il
/// rend #414141 — lu sur une capture réelle du panneau (09/10) et sur le
/// rendu hors écran, à l'identique. Sur ce gris, et plus encore sur les cartes
/// posées dessus (#4F4F4F), le bleu, le rouge et le violet tombaient entre
/// 2,2 et 2,5:1. Le fond devient donc #1E1E1E, le noir profond d'iStat
/// Menus : voir `Palette.panel` et les ratios mesurés dans le README.
struct PopoverBackground: View {
    /// Chantier 10 : sous macOS 26, le cadre de NSPopover est du verre ; le
    /// panneau le laisse voir hors des cartes (`UI/Themes/Glass.swift`).
    @Environment(\.glassFrame) private var glass

    var body: some View {
        if glass {
            // Le verre nu, ou voilé de la teinte du thème (Violet, Indigo,
            // Accent) : aucune donnée n'est posée là.
            Theme.current.glassTint().map { Color(nsColor: $0) } ?? Color.clear
        } else {
            Palette.panel
        }
    }
}

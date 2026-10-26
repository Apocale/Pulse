import SwiftUI

// Le survol des graphiques en barres du panneau (chantier 10) : un filet à
// la place visée, et une bulle qui dit l'heure puis la valeur. Le langage
// est celui de `HistoryChart` (chantier 02) — même filet, même bulle — pour
// qu'un graphique du panneau et un historique se lisent pareil.
//
// Pas d'animation : le filet suit le curseur, image pour image. Un retard
// sur un pointeur se lit comme de la lenteur, pas comme de la douceur.

/// Ce que dit la bulle pour une place du graphique : l'heure, puis une
/// ligne par valeur. Nil : rien à dire (place vide).
typealias BarReadout = @MainActor (Int) -> [String]?

struct BarHover: ViewModifier {
    /// Nombre de places, de gauche (la plus ancienne) à droite.
    let slots: Int
    let readout: BarReadout
    /// Le glissement du graphique qui défile, en part de place.
    var phase: Double = 0
    @State private var slot: Int?
    /// `--snapshot x.png --survol` : une place figée, pour regarder la bulle.
    @Environment(\.forcedHover) private var forcedHover

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                let width = geometry.size.width
                let step = width / CGFloat(max(1, slots))
                let shown = slot ?? (forcedHover ? max(0, slots - slots / 4) : nil)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { event in
                            switch event {
                            case .active(let point):
                                slot = min(slots - 1, max(0, Int(point.x / max(step, 0.001) + CGFloat(phase))))
                            case .ended:
                                slot = nil
                            }
                        }
                    if let shown, let lines = readout(shown) {
                        let x = (CGFloat(shown) + 0.5 - CGFloat(phase)) * step
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                        // À droite du filet, ou à gauche passé le milieu : la
                        // bulle ne sort jamais du graphique.
                        HStack(spacing: 0) {
                            if x > width / 2 {
                                HoverBubble(lines: lines).frame(width: max(0, x - 5), alignment: .trailing)
                                Spacer(minLength: 0)
                            } else {
                                Color.clear.frame(width: x + 5, height: 1)
                                HoverBubble(lines: lines)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// La bulle : l'heure en secondaire, les valeurs en primaire, sur le fond du
/// panneau — opaque, jamais une teinte de donnée sous du texte.
struct HoverBubble: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index]).foregroundStyle(index == 0 ? .secondary : .primary)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color.primary.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

/// « 14:32 » ou « 14:32:10 », l'heure de Paris de la machine.
enum HoverTime {
    private static let minutes: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let seconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @MainActor static func minute(_ date: Date) -> String { minutes.string(from: date) }
    @MainActor static func second(_ date: Date) -> String { seconds.string(from: date) }
}

/// `BarHover` quand le graphique a quelque chose à dire, rien sinon.
struct OptionalBarHover: ViewModifier {
    let slots: Int
    let readout: BarReadout?
    var phase: Double = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if let readout, slots > 0 {
            content.modifier(BarHover(slots: slots, readout: readout, phase: phase))
        } else {
            content
        }
    }
}

import SwiftUI
import AppKit

/// `--snapshot x.png --widget disque|memoire|forfait|tous [--taille petit|moyen]` :
/// le widget rendu hors écran, sur l'état que l'app écrirait maintenant —
/// le même calcul (`EtatBuilder`), sans rien écrire. `tous` : les trois,
/// petits puis moyens, sur une planche.
@MainActor
enum WidgetSnapshot {
    static func run(_ raw: String, to path: String, sampler: Sampler, light: Bool) {
        let etat = EtatBuilder.build(sampler)
        let content: AnyView
        if raw == "tous" {
            content = AnyView(VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(WidgetKind.allCases, id: \.self) { tile($0, .petit, etat) }
                }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(WidgetKind.allCases, id: \.self) { tile($0, .moyen, etat) }
                }
            })
        } else {
            guard let kind = WidgetKind(rawValue: raw) else {
                SurfaceSnapshot.fail("widget inconnu : \(raw) — disque, memoire, forfait, tous")
            }
            let size = Snapshot.value(after: "--taille").flatMap(WidgetSize.init(rawValue:)) ?? .petit
            content = AnyView(tile(kind, size, etat))
        }
        let view = content
            .padding(24)
            .background(Color(nsColor: light ? NSColor(white: 0.80, alpha: 1) : NSColor(white: 0.12, alpha: 1)))
            .environment(\.colorScheme, light ? .light : .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var png: Data?
        NSAppearance(named: light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            if let image = renderer.cgImage {
                png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let png, (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            SurfaceSnapshot.fail("rendu impossible")
        }
        print("→ \(path)")
    }

    /// Un widget du bureau : sa taille de macOS 26, ses marges, son fond.
    static func tile(_ kind: WidgetKind, _ size: WidgetSize, _ etat: EtatPartage?) -> some View {
        PulseWidgetView(kind: kind, size: size, etat: etat)
            .padding(14)
            .frame(width: size.points.width, height: size.points.height)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(WidgetTint.background))
    }
}

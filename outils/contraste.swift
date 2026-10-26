// Contraste WCAG des teintes de Palette sur le fond des cartes, lu sur les rendus.
//
//   ./.build/release/Pulse --snapshot /tmp/sombre.png
//   ./.build/release/Pulse --snapshot /tmp/clair.png --light
//   swift outils/contraste.swift /tmp/sombre.png /tmp/clair.png
//
// Le fond des cartes est lu sur le rendu : c'est ce que l'œil voit autour d'un
// anneau. Seuil des objets graphiques : 3:1. Une teinte translucide (le gris
// des libellés) est d'abord mêlée au fond.
import AppKit

/// La couleur la plus répandue du rendu, hors celle du panneau (lue dans le
/// coin, dans la marge) : le fond des cartes, quelle que soit la mise en page.
/// Le point fixe d'avant (100 px du bord droit, 230 du haut) tombait dans la
/// carte de droite du panneau à deux colonnes ; le socle rend les colonnes et
/// l'ordre réglables, et un anneau ou un espace entre deux cartes aurait
/// donné un faux fond, donc de faux ratios.
func fondDesCartes(_ rep: NSBitmapImageRep) -> NSColor {
    func cle(_ x: Int, _ y: Int) -> UInt32 {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    }
    let panneau = cle(4, 4)
    var compte: [UInt32: Int] = [:]
    for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 5) {
            let k = cle(x, y)
            if k != panneau { compte[k, default: 0] += 1 }
        }
    }
    let k = compte.max { $0.value < $1.value }?.key ?? panneau
    return NSColor(srgbRed: CGFloat(k >> 16 & 0xFF) / 255, green: CGFloat(k >> 8 & 0xFF) / 255,
                   blue: CGFloat(k & 0xFF) / 255, alpha: 1)
}

func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func lum(_ c: NSColor) -> CGFloat {
    let s = c.usingColorSpace(.sRGB)!
    return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
}
func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let la = lum(a), lb = lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}
func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
}

let warning = NSColor(name: nil) { a in
    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .systemOrange : NSColor(srgbRed: 0.722, green: 0.361, blue: 0.0, alpha: 1)
}
let tints: [(String, NSColor)] = [("data", .systemBlue), ("muted", .secondaryLabelColor), ("warning", warning),
                                  ("alert", .systemRed), ("tertiary", .systemPurple)]
var failed = false
// « - » à la place d'un rendu : un thème qui n'existe qu'en sombre (ou
// qu'en clair) ne se mesure que dans son apparence (chantier 10).
for (path, appearance) in [(CommandLine.arguments[1], NSAppearance.Name.darkAqua), (CommandLine.arguments[2], .aqua)] where path != "-" {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!
    let card = fondDesCartes(rep)
    print("\(appearance == .darkAqua ? "sombre" : "clair") : carte \(hex(card))")
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        for (name, color) in tints {
            let s = color.usingColorSpace(.sRGB)!, a = s.alphaComponent
            let mixed = NSColor(srgbRed: s.redComponent * a + card.redComponent * (1 - a),
                                green: s.greenComponent * a + card.greenComponent * (1 - a),
                                blue: s.blueComponent * a + card.blueComponent * (1 - a), alpha: 1)
            let r = ratio(mixed, card)
            if r < 3 { failed = true }
            print(String(format: "  %-9@ %@  %.2f:1 %@", name as NSString, hex(mixed), r, r >= 3 ? "" : "SOUS 3:1"))
        }
    }
}
exit(failed ? 1 : 0)

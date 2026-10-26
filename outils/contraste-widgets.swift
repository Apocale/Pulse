// Contraste des teintes des widgets sur LEUR fond, lu sur les rendus (chantier 13).
//
//   ./.build/release/Pulse --snapshot /tmp/w-sombre.png --widget tous
//   ./.build/release/Pulse --snapshot /tmp/w-clair.png --widget tous --light
//   swift outils/contraste-widgets.swift /tmp/w-sombre.png /tmp/w-clair.png
//
// Le fond est lu dans le premier widget de la planche (en bas à gauche, hors
// de tout texte). Seuil des objets graphiques : 3:1, comme `contraste.swift`.
import AppKit

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
let tints: [(String, NSColor)] = [("data", .systemBlue), ("warning", warning), ("alert", .systemRed)]
var failed = false
for (path, appearance) in [(CommandLine.arguments[1], NSAppearance.Name.darkAqua), (CommandLine.arguments[2], .aqua)] {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!
    // 24 pt de marge de planche, puis 10 pt dans le widget ; 150 pt plus bas.
    let background = rep.colorAt(x: (24 + 10) * 2, y: (24 + 150) * 2)!.usingColorSpace(.sRGB)!
    print("\(appearance == .darkAqua ? "sombre" : "clair") : fond du widget \(hex(background))")
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        for (name, color) in tints {
            let r = ratio(color, background)
            if r < 3 { failed = true }
            print(String(format: "  %-8@ %@  %.2f:1 %@", name as NSString, hex(color), r, r >= 3 ? "" : "SOUS 3:1"))
        }
    }
}
exit(failed ? 1 : 0)

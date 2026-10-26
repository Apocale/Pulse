import AppKit
import Testing
@testable import Pulse

/// Le mouvement du panneau (chantier 10) : la courbe, la cascade, et le
/// voile de survol, qui ne doit faire passer aucune teinte sous 3:1.
@Suite struct MotionTests {
    @Test func courbeForteQuiPartVite() {
        #expect(Curve.easeOut(0) == 0)
        #expect(Curve.easeOut(1) == 1)
        // Ease-out forte : à mi-temps, l'essentiel du chemin est fait.
        #expect(Curve.easeOut(0.5) > 0.85)
        // Croissante, sans rebond.
        var previous = 0.0
        for step in 1...100 {
            let value = Curve.easeOut(Double(step) / 100)
            #expect(value >= previous - 1e-9)
            #expect(value <= 1 + 1e-9)
            previous = value
        }
    }

    @Test func cascadeEnTroisCentsMillisecondes() {
        // La dernière carte commence et finit dans la fenêtre.
        #expect(Opening.start(rank: Opening.maxRank) + Opening.duration <= Opening.total + 1e-9)
        #expect(Opening.total <= 0.3)
        for rank in 0...(Opening.maxRank + 3) {
            #expect(Opening.entrance(0, rank: rank) == 0)
            #expect(Opening.entrance(1, rank: rank) == 1)
            #expect(Opening.fill(0, rank: rank) == 0)
            #expect(Opening.fill(1, rank: rank) == 1)
        }
        // Le verdict part le premier, les rangs suivants après lui.
        #expect(Opening.entrance(0.2, rank: 0) > Opening.entrance(0.2, rank: 2))
    }

    /// Le voile de survol posé sur le fond réel des cartes — #2C2C2C en
    /// sombre (0,171 lu sur le rendu), #FAFAFA en clair : chaque teinte de
    /// `Palette` y garde 3:1.
    @Test func voileDeSurvolMesure() {
        let cards: [(dark: Bool, card: NSColor)] = [
            (true, NSColor(srgbRed: 0.1709, green: 0.1709, blue: 0.1709, alpha: 1)),
            (false, NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)),
        ]
        for (dark, card) in cards {
            var veil: NSColor?
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                veil = Hover.veil.usingColorSpace(.sRGB)
            }
            guard let veil, let base = card.usingColorSpace(.sRGB) else {
                Issue.record("couleurs illisibles"); return
            }
            let a = veil.alphaComponent
            let lit = NSColor(srgbRed: veil.redComponent * a + base.redComponent * (1 - a),
                              green: veil.greenComponent * a + base.greenComponent * (1 - a),
                              blue: veil.blueComponent * a + base.blueComponent * (1 - a), alpha: 1)
            for role in PaletteRole.allCases {
                var tint: NSColor?
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    tint = role.nsColor.usingColorSpace(.sRGB)
                }
                guard let tint else { continue }
                let ta = tint.alphaComponent
                let mixed = NSColor(srgbRed: tint.redComponent * ta + lit.redComponent * (1 - ta),
                                    green: tint.greenComponent * ta + lit.greenComponent * (1 - ta),
                                    blue: tint.blueComponent * ta + lit.blueComponent * (1 - ta), alpha: 1)
                let ratio = Contrast.ratio(mixed, lit)
                #expect(ratio >= Contrast.threshold,
                        "\(role) sur le voile \(dark ? "sombre" : "clair") : \(Contrast.text(ratio))")
            }
        }
    }
}

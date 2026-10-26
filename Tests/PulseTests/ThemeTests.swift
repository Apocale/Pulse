import AppKit
import Testing
@testable import Pulse

/// Les thèmes du panneau (chantier 10) : chaque teinte de données garde 3:1
/// sur les fonds de chaque thème, dans chaque apparence où il existe — et,
/// pour Accent du système, avec chacun des huit accents de macOS.
@Suite struct ThemeTests {
    /// Les accents de Réglages Système › Apparence (graphite : le gris).
    static let accents: [(String, NSColor)] = [
        ("bleu", .systemBlue), ("violet", .systemPurple), ("rose", .systemPink), ("rouge", .systemRed),
        ("orange", .systemOrange), ("jaune", .systemYellow), ("vert", .systemGreen), ("graphite", .systemGray),
    ]

    private func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var out: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out ?? color
    }

    private func mix(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let a = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                       green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                       blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
    }

    /// Chaque teinte de `Palette` sur `background`, voile de survol compris.
    private func check(_ background: NSColor, dark: Bool, _ label: String) {
        let base = resolved(background, dark: dark)
        let lit = mix(resolved(Hover.veil, dark: dark), over: base)
        for surface in [base, lit] {
            for role in PaletteRole.allCases {
                let tint = mix(resolved(role.nsColor, dark: dark), over: surface)
                let ratio = Contrast.ratio(tint, surface)
                #expect(ratio >= Contrast.threshold, "\(label) · \(role) : \(Contrast.text(ratio))")
            }
        }
    }

    @Test func chaqueThemeGardeSesRatios() {
        for theme in PulseTheme.allCases where theme != .accent {
            for dark in theme.appearances {
                let name = "\(theme.name) \(dark ? "sombre" : "clair")"
                check(theme.card(dark: dark), dark: dark, "\(name), carte")
                if dark { check(theme.panel(dark: dark), dark: dark, "\(name), panneau") }
            }
        }
    }

    @Test func accentDuSystemeAvecLesHuitAccents() {
        for (name, accent) in Self.accents {
            let dark = resolved(accent, dark: true)
            let card = PulseTheme.accent.card(dark: true, accent: dark)
            #expect(Contrast.luminance(card) <= PulseTheme.darkCardLuminance + 1e-9, "accent \(name)")
            check(card, dark: true, "Accent \(name), carte")
            check(PulseTheme.accent.panel(dark: true, accent: dark), dark: true, "Accent \(name), panneau")
        }
    }

    /// La règle qui rend la mesure valable pour toute teinte acceptée : les
    /// cartes sombres ne sont jamais plus lumineuses que la grise mesurée,
    /// les claires jamais moins que #FAFAFA.
    @Test func luminanceDesCartesBornee() {
        let light = Contrast.luminance(PulseTheme.systeme.card(dark: false))
        for theme in PulseTheme.allCases {
            for dark in theme.appearances {
                let l = Contrast.luminance(theme.card(dark: dark))
                if dark {
                    #expect(l <= PulseTheme.darkCardLuminance + 1e-9, "\(theme.name) : \(l)")
                } else {
                    #expect(l >= light - 1e-9, "\(theme.name) : \(l)")
                }
            }
        }
    }

    /// Le thème Système rend exactement le panneau d'avant.
    @Test func systemeInchange() {
        let card = PulseTheme.systeme.card(dark: true).usingColorSpace(.sRGB)!
        #expect(abs(card.redComponent - 0.1709) < 1e-4)
        let panel = PulseTheme.systeme.panel(dark: true).usingColorSpace(.sRGB)!
        #expect(abs(panel.redComponent - 0.118) < 1e-4)
        #expect(PulseTheme.systeme.glassTint() == nil)
    }

    /// Un réglage absent, ou d'une version future, retombe sur Système sans
    /// rien emporter d'autre (règle dure n° 2).
    @Test func reglageTolerant() throws {
        let absent = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"rateUnit":"bits"}"#.utf8))
        #expect(absent.theme == .systeme)
        #expect(absent.rateUnit == .bits)
        let inconnu = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"theme":"arc-en-ciel"}"#.utf8))
        #expect(inconnu.theme == .systeme)
        let violet = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"theme":"violet"}"#.utf8))
        #expect(violet.theme == .violet)
    }
}

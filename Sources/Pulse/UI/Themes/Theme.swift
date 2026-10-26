import SwiftUI
import AppKit

// Les thèmes du panneau, façon iStat Menus (chantier 10).
//
// Un thème ne change QUE les fonds : celui du panneau (ou la teinte posée
// sur son verre) et celui des cartes. Les teintes de données restent celles
// de `Palette` et des réglages par série — et leur contraste ne bouge pas,
// par construction :
//
// **Le ratio WCAG ne dépend que de la luminance.** Une carte violette de
// même luminance qu'une carte grise donne exactement les mêmes ratios. Les
// cartes des thèmes sombres sont donc toutes AU PLUS aussi lumineuses que la
// carte grise mesurée (0,171, luminance 0,0247), et celles des thèmes clairs
// au moins autant que #FAFAFA : chaque teinte acceptée sur le thème Système
// l'est sur tous. `ThemeTests` le vérifie, teinte par teinte, accent par
// accent, et `outils/contraste.swift` le remesure sur les rendus
// (`--snapshot x.png --theme <id>`).

enum PulseTheme: String, CaseIterable, Codable, Identifiable {
    /// Suit l'apparence de macOS : le panneau d'avant.
    case systeme
    /// Toujours sombre, quelle que soit l'apparence de macOS.
    case sombre
    /// Toujours clair.
    case clair
    /// Sombre, fonds violets.
    case violet
    /// Sombre, fonds indigo.
    case indigo
    /// Sombre, fonds teintés de la couleur d'accent choisie dans Réglages
    /// Système — mesurée à chaque dessin, pour les huit accents.
    case accent

    var id: String { rawValue }

    var name: String {
        switch self {
        case .systeme: return "Système"
        case .sombre:  return "Sombre"
        case .clair:   return "Clair"
        case .violet:  return "Violet"
        case .indigo:  return "Indigo"
        case .accent:  return "Accent du système"
        }
    }

    /// L'apparence imposée au panneau ; nil : celle de macOS.
    var appearance: NSAppearance.Name? {
        switch self {
        case .systeme: return nil
        case .clair:   return .aqua
        case .sombre, .violet, .indigo, .accent: return .darkAqua
        }
    }

    /// Le thème n'existe qu'en sombre (ou qu'en clair) : la mesure du
    /// contraste ne porte que sur cette apparence.
    var appearances: [Bool] {
        switch appearance {
        case .some(.aqua): return [false]
        case .some: return [true]
        case .none: return [true, false]
        }
    }

    /// La luminance maximale d'une carte sombre : celle de la carte grise
    /// mesurée (0,171). Au-dessus, une teinte pourrait passer sous 3:1.
    static let darkCardLuminance = Contrast.luminance(NSColor(srgbRed: 0.1709, green: 0.1709, blue: 0.1709, alpha: 1))

    /// Le fond des cartes, opaque.
    func card(dark: Bool, accent: NSColor = .controlAccentColor) -> NSColor {
        switch self {
        case .systeme, .sombre, .clair:
            return dark ? NSColor(srgbRed: 0.1709, green: 0.1709, blue: 0.1709, alpha: 1)
                        : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        case .violet: return Self.rgb(0x2E, 0x24, 0x40)
        case .indigo: return Self.rgb(0x21, 0x29, 0x43)
        case .accent: return Self.tinted(accent, amount: 0.20, base: 0.13, ceiling: Self.darkCardLuminance * 0.97)
        }
    }

    /// Le fond du panneau, opaque : sous Réduire la transparence, et partout
    /// où le verre n'est pas permis.
    func panel(dark: Bool, accent: NSColor = .controlAccentColor) -> NSColor {
        switch self {
        case .systeme, .sombre, .clair:
            return dark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1) : .windowBackgroundColor
        case .violet: return Self.rgb(0x1A, 0x14, 0x26)
        case .indigo: return Self.rgb(0x13, 0x18, 0x2C)
        case .accent: return Self.tinted(accent, amount: 0.14, base: 0.08, ceiling: Self.darkCardLuminance * 0.5)
        }
    }

    /// La teinte posée sur le verre du cadre ; nil : le verre de macOS, nu.
    func glassTint(accent: NSColor = .controlAccentColor) -> NSColor? {
        switch self {
        case .systeme, .sombre, .clair: return nil
        case .violet: return Self.rgb(0x3A, 0x22, 0x66).withAlphaComponent(0.42)
        case .indigo: return Self.rgb(0x22, 0x2E, 0x6A).withAlphaComponent(0.42)
        case .accent:
            return (accent.usingColorSpace(.sRGB) ?? accent).withAlphaComponent(0.30)
        }
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// `accent` mêlé à un gris de valeur `base`, puis assombri jusqu'à ne
    /// pas dépasser la luminance `ceiling` : un accent jaune ne peut pas
    /// éclaircir la carte au point de faire tomber une teinte sous 3:1.
    static func tinted(_ accent: NSColor, amount: CGFloat, base: CGFloat, ceiling: Double) -> NSColor {
        var resolved = accent.usingColorSpace(.sRGB)
        if resolved == nil {
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                resolved = accent.usingColorSpace(.sRGB)
            }
        }
        let a = resolved ?? NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)
        var r = base + (a.redComponent - base) * amount
        var g = base + (a.greenComponent - base) * amount
        var b = base + (a.blueComponent - base) * amount
        for _ in 0..<40 {
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            if Contrast.luminance(color) <= ceiling { return color }
            r *= 0.96; g *= 0.96; b *= 0.96
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// Le thème du moment. Posé par l'app quand les réglages changent, et par
/// `--snapshot --theme` (sans rien écrire). Lu par les couleurs dynamiques de
/// `Palette` à chaque dessin : main thread seulement.
enum Theme {
    nonisolated(unsafe) static var current: PulseTheme = .systeme
}

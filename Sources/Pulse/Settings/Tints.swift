import AppKit
import SwiftUI

/// La teinte choisie pour une série, persistée en texte : un rôle de
/// `Palette` (« data »), une couleur système (« system:green ») ou une couleur
/// fixe (« #1E90FF »).
///
/// Règle dure n°4 : aucune couleur ne code une donnée sans ratio mesuré. Une
/// teinte n'est donc acceptée que si elle tient 3:1 sur le fond des cartes
/// dans les DEUX apparences ; sinon `color` vaut nil et la carte garde la
/// teinte de son module.
struct TintChoice: Hashable {
    let raw: String

    /// Les teintes proposées dans la fenêtre Réglages, dans l'ordre.
    static let candidates: [(raw: String, name: String)] = [
        ("data", "Bleu"), ("muted", "Gris"), ("tertiary", "Violet"),
        ("warning", "Orange"), ("alert", "Rouge"),
        ("system:indigo", "Indigo"), ("system:teal", "Bleu-vert"), ("system:cyan", "Cyan"),
        ("system:green", "Vert"), ("system:mint", "Menthe"), ("system:pink", "Rose"),
        ("system:brown", "Brun"), ("system:yellow", "Jaune"),
    ]

    static func name(of raw: String) -> String {
        candidates.first { $0.raw == raw }?.name ?? raw
    }

    /// La couleur AppKit, dynamique pour les rôles et les couleurs système.
    var nsColor: NSColor? {
        if let role = PaletteRole(rawValue: raw) { return role.nsColor }
        if raw.hasPrefix("system:") {
            switch raw.dropFirst("system:".count) {
            case "blue":   return .systemBlue
            case "green":  return .systemGreen
            case "teal":   return .systemTeal
            case "cyan":   return .systemCyan
            case "indigo": return .systemIndigo
            case "mint":   return .systemMint
            case "pink":   return .systemPink
            case "brown":  return .systemBrown
            case "yellow": return .systemYellow
            case "purple": return .systemPurple
            case "red":    return .systemRed
            case "orange": return .systemOrange
            case "gray":   return .systemGray
            default:       return nil
            }
        }
        return Self.hex(raw)
    }

    /// Ratios sur le fond des cartes, en sombre et en clair.
    var ratios: (dark: Double, light: Double)? {
        guard let nsColor else { return nil }
        return (Contrast.onCard(nsColor, dark: true), Contrast.onCard(nsColor, dark: false))
    }

    /// Acceptée : au moins 3:1 dans les deux apparences.
    var passes: Bool {
        guard let ratios else { return false }
        return min(ratios.dark, ratios.light) >= Contrast.threshold
    }

    /// La couleur, seulement si elle passe le contraste.
    var color: Color? {
        guard passes, let nsColor else { return nil }
        if let role = PaletteRole(rawValue: raw) { return role.color }
        return Color(nsColor: nsColor)
    }

    /// « #RRGGBB » → couleur sRGB fixe.
    private static func hex(_ text: String) -> NSColor? {
        guard text.count == 7, text.hasPrefix("#"), let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

extension PaletteRole {
    /// La même teinte que `color`, côté AppKit, pour la mesurer.
    var nsColor: NSColor {
        switch self {
        case .data:     return .systemBlue
        case .muted:    return .secondaryLabelColor
        case .warning:  return Palette.adaptiveWarning
        case .alert:    return .systemRed
        case .tertiary: return .systemPurple
        }
    }
}

/// Contraste WCAG, même formule qu'`outils/contraste.swift`.
enum Contrast {
    /// Seuil des objets graphiques (WCAG 1.4.11). Le texte en exige 4,5 :
    /// c'est pourquoi une teinte ne colore jamais du texte (règle dure n°6).
    static let threshold = 3.0

    /// Fond des cartes tel que le lit `outils/contraste.swift` sur le rendu
    /// (11/10) : #393939 en sombre, #FAFAFA en clair. En sombre la lecture
    /// surestime le gris — le rendu porte 0,171, soit #2C2C2C, mais le profil
    /// du PNG le convertit en #393939 — : le ratio retenu est donc prudent.
    static let darkCard = NSColor(srgbRed: 0x39 / 255, green: 0x39 / 255, blue: 0x39 / 255, alpha: 1)
    static let lightCard = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1)

    /// Le ratio d'une teinte, résolue dans l'apparence voulue, sur le fond
    /// des cartes. Une teinte translucide est d'abord mêlée au fond.
    static func onCard(_ color: NSColor, dark: Bool) -> Double {
        let card = dark ? darkCard : lightCard
        var resolved: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let s = resolved, let bg = card.usingColorSpace(.sRGB) else { return 0 }
        let a = s.alphaComponent
        let mixed = NSColor(srgbRed: s.redComponent * a + bg.redComponent * (1 - a),
                            green: s.greenComponent * a + bg.greenComponent * (1 - a),
                            blue: s.blueComponent * a + bg.blueComponent * (1 - a), alpha: 1)
        return ratio(mixed, bg)
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ color: NSColor) -> Double {
        guard let s = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    /// « 3,55:1 », virgule française.
    static func text(_ value: Double) -> String {
        String(format: "%.2f:1", value).replacingOccurrences(of: ".", with: ",")
    }
}

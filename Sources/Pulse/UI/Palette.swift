import SwiftUI
import AppKit

/// Couleurs choisies sur mesure de contraste, pas au jugé.
///
/// Mesurées le 11/10 sur le fond des CARTES tel que le rend le panneau —
/// #393939 en sombre, #FAFAFA en clair, lus sur le rendu hors écran, lui-même
/// identique pixel pour pixel à une capture réelle. Chaque teinte atteint au
/// moins 3:1 sur ces deux fonds — le seuil WCAG des objets graphiques, qui est
/// le bon pour une courbe ou un anneau (le seuil 4,5:1 vise le texte). Les
/// couleurs système sont celles de macOS 26, plus vives qu'avant : le bleu
/// sombre est #0091FF, plus #0A84FF. Script de mesure : voir le README.
///
/// Deux écueils évités :
///
/// - `.accentColor` ne code jamais une donnée. Elle suit le réglage Apparence
///   de l'utilisateur : en accent jaune elle tombe à 1,37:1 et la courbe de RAM
///   disparaît. Elle reste réservée à l'interactif, où macOS l'attend.
/// - `systemOrange` est inutilisable en clair (2,00:1). L'orange d'alerte est
///   donc dynamique : assombri en clair (4,18:1), système en sombre (6,51:1).
enum Palette {
    /// Séries de données neutres : mémoire, cœurs performance.
    static let data = Color(nsColor: .systemBlue)              // 3,39 clair · 3,55 sombre

    /// Avertissement : swap, pression mémoire élevée, saturation CPU.
    static let warning = Color(nsColor: adaptiveWarning)       // 4,42 clair · 5,14 sombre

    /// Alerte : plantage, volume saturé, pression critique.
    static let alert = Color(nsColor: .systemRed)              // 3,44 clair · 3,34 sombre

    /// Second plan de série : cœurs efficacité, applications hors montage.
    /// Pleine opacité — la multiplier tomberait sous le seuil.
    static let muted = Color(nsColor: .secondaryLabelColor)    // 3,92 clair · 4,71 sombre

    /// Réservée à l'interactif, jamais aux données.
    static let interactive = Color(nsColor: .controlAccentColor)

    /// Troisième série, quand le bleu et le gris sont pris : la mémoire
    /// compressée dans l'anneau de la mémoire. Violet et non rose : le rose
    /// d'iStat se confondait avec le rouge d'alerte de l'anneau de pression.
    static let tertiary = Color(nsColor: .systemPurple)        // 4,02 clair · 3,16 sombre

    /// Fond du panneau : celui du système en clair, #1E1E1E en sombre. Voir
    /// `PopoverBackground` pour la raison, et le README pour les ratios.
    /// Le thème (chantier 10, `UI/Themes/Theme.swift`) le choisit ; Système
    /// garde ces deux valeurs.
    static let panel = Color(nsColor: NSColor(name: "pulsePanel") { appearance in
        Theme.current.panel(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    })

    /// Fond des cartes : blanc presque plein en clair, à peine plus clair que
    /// le panneau en sombre. Les ratios des teintes sont mesurés sur CE
    /// fond-là, qui est celui que l'œil voit autour d'elles.
    ///
    /// OPAQUE (chantier 10) : le cadre du panneau est en verre sous macOS 26,
    /// et une carte translucide laisserait passer ce qu'il y a derrière la
    /// fenêtre sous les données. Les valeurs sont celles que rendait l'ancien
    /// voile — blanc à 6 % sur #1E1E1E (0,171), blanc à 72 % sur le fond
    /// clair (#FAFAFA) — : les ratios mesurés ne bougent pas.
    /// Le thème choisit la teinte, jamais une luminance plus haute en sombre
    /// (plus basse en clair) : les ratios mesurés tiennent (`ThemeTests`).
    static let card = Color(nsColor: NSColor(name: "pulseCard") { appearance in
        Theme.current.card(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    })

    /// Rail des anneaux et axe des graphiques : du décor, pas une donnée.
    static let track = Color.primary.opacity(0.12)

    /// Interne et non privée : la fenêtre Réglages la mesure (`Contrast`).
    static let adaptiveWarning = NSColor(name: "pulseWarning") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .systemOrange
                    : NSColor(srgbRed: 0.722, green: 0.361, blue: 0.0, alpha: 1)
    }
}

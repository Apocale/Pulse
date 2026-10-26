import SwiftUI
import AppKit

/// Un seul ressort pour tout ce qui bouge dans Pulse.
///
/// **Un ressort, pas une durée fixe.** Le sampler publie toutes les 1,5 s quand
/// le popover est ouvert : chaque animation est donc interrompue par la
/// suivante avant d'avoir fini. Un ressort repart de la valeur actuellement
/// affichée et absorbe l'interruption ; une courbe à durée fixe repart de la
/// valeur cible et produit un saut visible à chaque relevé.
///
/// **Amortissement critique, aucun rebond.** Un dépassement suggère l'inertie
/// d'un objet qu'on aurait lancé à la main. Ici rien n'est lancé : ce sont des
/// mesures qui arrivent. Le rebond se réserve aux gestes qui portent une
/// vitesse, et Pulse n'en a aucun.
///
/// Réponse 0,4 s : la valeur qu'Apple emploie pour un repositionnement.
enum Motion {
    static var value: Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1.0)
    }

    /// Réglage « Réduire les animations » de macOS, l'équivalent système de
    /// `prefers-reduced-motion`. Relu à chaque évaluation plutôt que mis en
    /// cache : il se change dans Réglages Système pendant que Pulse tourne, et
    /// une valeur figée au lancement ignorerait le changement.
    ///
    /// `nil` désactive l'animation sans rien changer d'autre : les valeurs
    /// restent exactes, elles sautent au lieu de glisser.
    static var reduceMotion: Bool {
        sansAnimation || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Banc (`--banc`) : le panneau ouvert y vit dans une fenêtre jamais
    /// affichée, où une animation SwiftUI tourne sans la synchronisation de
    /// l'écran — des dizaines de milliers d'images par seconde (README, « Une
    /// animation SwiftUI dans une fenêtre jamais affichée tourne sans
    /// frein ») qui gonflaient le coût « ouvert ». Le banc coupe donc les
    /// animations, comme « Réduire les animations » : les valeurs restent
    /// exactes, elles sautent. Jamais touché par l'app.
    nonisolated(unsafe) static var sansAnimation = false
}

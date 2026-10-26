import SwiftUI

// L'ouverture du panneau (chantier 10).
//
// Pourquoi animer : pour la continuité spatiale. Le panneau tombe de la barre
// de menus ; ses cartes se posent dans le même sens, de haut en bas, et leurs
// anneaux se remplissent jusqu'à leur valeur — on voit d'où vient chaque
// chiffre au lieu d'un écran qui claque. Ce qui ne bouge JAMAIS : les
// chiffres. Ils sont posés d'emblée, nets ; seul leur support graphique entre.
//
// Contraintes, toutes tenues ici :
// - 300 ms en tout, dernière carte comprise. Le panneau s'ouvre des dizaines
//   de fois par jour : au-delà, l'animation se ferait attendre.
// - Une courbe ease-out forte (0,23 ; 1 ; 0,32 ; 1) : le mouvement part vite,
//   au moment où l'œil regarde, et se pose en douceur. Jamais d'ease-in.
// - Opacité et position seulement : rien ne change la mise en page, donc la
//   taille du popover (que NSPopover ne sait pas animer, README) ne bouge pas.
// - Réduire les animations : tout est en place dès la première image.
// - Le contenu du popover est créé à chaque ouverture et libéré à la
//   fermeture (`AppDelegate.makeContent`) : la cascade se rejoue donc à chaque
//   ouverture, et ne coûte rien panneau fermé — il n'y a plus de vue.

/// Où en est l'ouverture du panneau : 0, rien n'est posé ; 1, tout est en
/// place. Vaut 1 par défaut : aperçus des Réglages, rendus hors écran, banc —
/// rien ne s'anime hors du panneau.
private struct OpeningKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

/// La part d'entrée d'une carte (opacité, chute), 0 → 1, posée par `Entrance`.
private struct EntranceKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

/// La part de remplissage des anneaux, jauges et barres d'une carte, 0 → 1.
private struct FillKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var opening: Double {
        get { self[OpeningKey.self] }
        set { self[OpeningKey.self] = newValue }
    }
    var entranceProgress: Double {
        get { self[EntranceKey.self] }
        set { self[EntranceKey.self] = newValue }
    }
    var fillProgress: Double {
        get { self[FillKey.self] }
        set { self[FillKey.self] = newValue }
    }
}

enum Opening {
    /// Toute la cascade, dernière carte comprise.
    static let total: Double = 0.30
    /// L'entrée d'une carte : opacité et chute.
    static let duration: Double = 0.20
    /// Décalage entre deux rangs. Quatre rangs au plus : 4 × 25 + 200 = 300 ms.
    static let stagger: Double = 0.025
    static let maxRank = 4
    /// Hauteur de la chute, en points : assez pour dire « ça vient d'en
    /// haut », trop peu pour qu'on suive un objet qui voyage.
    static let drop: CGFloat = 5

    /// Le départ d'un rang, en secondes.
    static func start(rank: Int) -> Double { Double(min(max(rank, 0), maxRank)) * stagger }

    /// L'entrée d'un rang à l'instant `global` (0 → 1 sur `total`).
    static func entrance(_ global: Double, rank: Int) -> Double {
        let elapsed = global * total - start(rank: rank)
        return Curve.easeOut(min(1, max(0, elapsed / duration)))
    }

    /// Le remplissage d'un rang : il part avec la carte et s'achève avec la
    /// cascade. Plus long que l'entrée, pour qu'on voie l'anneau tourner.
    static func fill(_ global: Double, rank: Int) -> Double {
        let begin = start(rank: rank)
        let elapsed = global * total - begin
        return Curve.easeOut(min(1, max(0, elapsed / (total - begin))))
    }
}

/// Une courbe de Bézier cubique, résolue comme le fait WebKit (`UnitBezier`) :
/// les valeurs viennent du skill animate, pas d'une approximation.
struct Curve {
    private let cx, bx, ax, cy, by, ay: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x; bx = 3 * (p2x - p1x) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }

    /// Ease-out forte, pour ce qui entre.
    static let strongEaseOut = Curve(0.23, 1, 0.32, 1)

    static func easeOut(_ x: Double) -> Double { strongEaseOut(x) }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return sampleY(solveX(x))
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveX(_ x: Double) -> Double {
        // Newton d'abord, la dichotomie si la pente s'écrase.
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-7 { return t }
            let slope = slopeX(t)
            if abs(slope) < 1e-7 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<40 {
            let value = sampleX(t)
            if abs(value - x) < 1e-7 { break }
            if x > value { low = t } else { high = t }
            t = (low + high) / 2
        }
        return t
    }
}

/// Fait entrer une vue au rang `rank` de la cascade : opacité, chute de
/// quelques points, et le remplissage de ses anneaux transmis à ses
/// descendants (`\.fillProgress`).
struct Entrance: ViewModifier {
    let rank: Int
    @Environment(\.opening) private var opening

    func body(content: Content) -> some View {
        let entrance = Opening.entrance(opening, rank: rank)
        content
            .environment(\.entranceProgress, entrance)
            .environment(\.fillProgress, Opening.fill(opening, rank: rank))
            .opacity(entrance)
            .offset(y: (entrance - 1) * Opening.drop)
    }
}

extension View {
    /// Rang de la vue dans la cascade d'ouverture du panneau.
    func entrance(rank: Int) -> some View { modifier(Entrance(rank: rank)) }
}

/// Fait courir `\.opening` de 0 à 1 à l'apparition du panneau, en `total`
/// secondes, puis s'arrête.
///
/// Une horloge, pas un ressort : la courbe de chaque carte est appliquée par
/// `Opening.entrance`, ce qui garde une seule source de temps pour toute la
/// cascade — celle que `--snapshot --ouverture` fige image par image.
///
/// **60 images par seconde au plus.** Une image de la cascade coûte 8 à 9 ms
/// de processeur (mesuré par `--snapshot --ouverture`, machine chargée) : à
/// 120 Hz, le fil principal ne suivrait pas et lâcherait des images au
/// hasard. À 60 Hz, 18 images régulières pour 300 ms, et un coût divisé par
/// deux. Ensuite l'horloge est mise en pause : plus une seule image.
struct OpeningDriver: ViewModifier {
    @State private var start: Date?
    @State private var done = Motion.reduceMotion

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: done)) { context in
            content.environment(\.opening, progress(at: context.date))
        }
        .onAppear {
            guard !done else { return }
            start = Date()
            // Une image de marge : la dernière image dessinée est bien à 1.
            DispatchQueue.main.asyncAfter(deadline: .now() + Opening.total + 0.02) { done = true }
        }
    }

    private func progress(at date: Date) -> Double {
        if done { return 1 }
        guard let start else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / Opening.total))
    }
}

/// La source de l'horloge d'ouverture : animée dans le vrai popover, figée
/// pour un rendu image par image, absente ailleurs (tout est posé).
struct OpeningSource: ViewModifier {
    var animates: Bool
    var frozen: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let frozen {
            content.environment(\.opening, frozen)
        } else if animates {
            content.modifier(OpeningDriver())
        } else {
            content
        }
    }
}

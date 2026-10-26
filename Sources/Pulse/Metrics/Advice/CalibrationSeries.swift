import Foundation

/// L'instrument qui manquait à la règle 10 : la charge de l'application hors
/// montage la plus occupée, en % d'UN cœur, dans l'historique longue durée.
///
/// La règle 10 (« Vivaldi occupe le processeur ») croise le processeur total,
/// déjà dans l'historique (`cpu.total`), et la charge d'une app, qui n'y était
/// pas : son seuil de 200 % d'un cœur ne pouvait pas se rejouer
/// (`outils/rejoue-seuils.py`, 11/10). Une valeur par relevé, prise sur le
/// balayage des processus que le `Sampler` fait de toute façon : un maximum
/// sur quelques centaines de groupes, rien de plus. ~1,5 Mo de base à 90
/// jours, comme toute série relevée toutes les 10 s.
///
/// « Hors montage » au sens d'`AppKind` : ni Premiere et ses semblables, ni un
/// encodeur. Approximation assumée : la règle exige en plus que cette app soit
/// la plus chargée de toutes, Premiere compris ; le rejeu sur le total et
/// cette série suffit à placer les deux seuils.
enum CalibrationSeries {
    static let busiestOther = "processeur.hors-montage"

    private static let declared: Void = {
        History.declare(SeriesInfo(busiestOther, "App hors montage la plus chargée (% d'un cœur)", .count))
    }()

    /// La charge de l'app hors montage la plus occupée, 0 s'il n'y en a pas.
    static func busiest(_ groups: [ProcessGroup]) -> Double {
        groups.lazy.filter { AppKind.of(bundleId: $0.bundleId) == .other }.map(\.cpu).max() ?? 0
    }

    /// Depuis la file d'échantillonnage, à chaque relevé. N'écrit rien quand
    /// `Persistence.enabled` est faux (`--snapshot`, `--banc`, tests).
    static func record(_ groups: [ProcessGroup]) {
        _ = declared
        History.record(busiestOther, busiest(groups))
    }
}

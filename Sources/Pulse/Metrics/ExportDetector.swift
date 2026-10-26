import Foundation

/// Un export en cours, tel qu'observé.
struct ExportActivity: Equatable {
    var app: String
    var began: Date
    /// Dernier instant où l'encodeur était encore au travail. La durée s'arrête
    /// là, et non à l'instant présent : le délai de grâce ci-dessous ne doit pas
    /// gonfler le chiffre affiché.
    var lastActive: Date

    var duration: TimeInterval { lastActive.timeIntervalSince(began) }
}

/// Détection d'export par la charge de l'ENCODEUR, jamais par celle de
/// Premiere.
///
/// Mesuré le 25 août sur un export réel, 68 relevés à 3 s d'intervalle
/// conservés dans `outils/reference-export-2026-08-25.csv` :
///
///     Premiere        au repos  0 à 286 %   ·   pendant l'export  161 à 282 %
///     Media Encoder   au repos  0 à  31 %   ·   pendant l'export  102 à 231 %
///
/// Le CPU de Premiere est inutilisable, et pas de justesse : son maximum au
/// repos DÉPASSE son maximum pendant l'export. Aucun seuil ne peut exister là.
/// Celui de Media Encoder sépare avec une marge de facteur 3.
///
/// L'attribution est acquise sans effort ici, parce que Media Encoder est une
/// application Adobe identifiée par son identifiant de bundle. C'est ce qui
/// distingue cette voie de celle des `VTEncoderXPCService`, partagés par toute
/// la machine et rattachés à `launchd` : un appel visio y ferait monter le même
/// compteur.
///
/// COUVRE UNIQUEMENT l'export passé par la file d'attente. Lancé directement
/// depuis Premiere, l'export ne démarre pas Media Encoder et n'est pas vu.
/// Voir les réserves du README avant d'élargir.
final class ExportDetector {
    /// Entre le maximum au repos (31 %) et le minimum en export (102 %), tous
    /// deux mesurés. En pourcentage d'UN cœur, comme partout dans Pulse.
    /// Lisible de l'extérieur pour que `--probe` affiche le seuil réellement
    /// appliqué, plutôt qu'une copie qui pourrait diverger.
    static let threshold = 60.0

    /// Media Encoder redescend entre deux fichiers d'une même file. Sans ce
    /// délai, une file de trois exports serait comptée comme trois exports.
    /// En contrepartie, la fin d'un export met jusqu'à 30 s à être constatée —
    /// la durée affichée, elle, cesse de croître tout de suite.
    private static let grace: TimeInterval = 30

    private var began: Date?
    private var lastActive: Date?
    private var app = ""

    /// - Returns: l'export en cours, ou `nil`.
    ///
    /// Un pic isolé ne déclenche rien : il faut deux relevés au-dessus du
    /// seuil, ce qui se lit au fait que `lastActive` a dépassé `began`. Media
    /// Encoder passe brièvement au-dessus de 30 % en ouvrant une file, et cela
    /// ne doit pas s'afficher comme un export.
    func observe(_ groups: [ProcessGroup], now: Date = Date()) -> ExportActivity? {
        let encoder = groups
            .filter { AppKind.of(bundleId: $0.bundleId) == .encoding }
            .max { $0.cpu < $1.cpu }

        if let encoder, encoder.cpu > Self.threshold {
            if began == nil { began = now }
            lastActive = now
            app = encoder.name
        } else if let last = lastActive, now.timeIntervalSince(last) > Self.grace {
            began = nil
            lastActive = nil
        }

        guard let began, let lastActive, lastActive > began else { return nil }
        return ExportActivity(app: app, began: began, lastActive: lastActive)
    }
}

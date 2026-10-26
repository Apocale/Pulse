import Foundation

/// Les écritures sur disque de Pulse, coupées d'un seul geste.
///
/// Pour `--snapshot`, qui fait tourner un vrai `Sampler` le temps d'un rendu,
/// à côté de l'app en cours : sans ce verrou il réécrirait l'historique, le
/// cumul réseau et le journal des verdicts de l'app — une marque de démarrage
/// fantôme dans le journal, au minimum, qui fausserait le bilan de `--probe`.
///
/// Posé une fois au lancement, avant tout relevé, jamais touché ensuite.
enum Persistence {
    nonisolated(unsafe) static var enabled = true
}

extension Persistence {
    /// Met un fichier illisible de côté, dans son dossier :
    /// « reglages.illisible.json » pour « reglages.json » — ou, si une mise
    /// de côté précédente porte déjà ce nom, « reglages.illisible-<date>.json ».
    /// Jamais d'effacement : avant le 11/10 (17-audit-code), chaque mise de
    /// côté supprimait la précédente, et un second incident emportait la
    /// seule copie qui gardait encore les données du premier.
    ///
    /// N'interroge pas `enabled` : chaque appelant sait s'il a le droit
    /// d'écrire (l'app, jamais `--probe` ni `--snapshot`). Rend la copie, nil
    /// si le fichier n'a pas pu être déplacé.
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var target = folder.appendingPathComponent("\(stem).illisible\(suffix)")
        if fm.fileExists(atPath: target.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: now)
            target = folder.appendingPathComponent("\(stem).illisible-\(stamp)\(suffix)")
            var attempt = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(stem).illisible-\(stamp)-\(attempt)\(suffix)")
                attempt += 1
            }
        }
        do {
            try fm.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}

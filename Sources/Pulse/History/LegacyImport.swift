import Foundation

/// La reprise de `history.json` dans la base, une fois, sans rien perdre.
///
/// Ce qui est repris : la série de la dernière heure (processeur, carte
/// graphique, mémoire utilisée, swap) et les 30 jours d'espace libre par
/// volume. `history.json` n'est NI réécrit NI déplacé : `HistoryStore` le
/// garde, avec le temps par application et les sessions, qui n'ont rien d'une
/// série temporelle.
///
/// Lecture tolérante (règle dure n° 2, appliquée à la main) : un point
/// auquel il manque un champ perd ce champ, pas le point ; un point illisible
/// est sauté, pas fatal. Seul un fichier qui n'est pas du JSON fait renoncer
/// — sans rien marquer, l'import se retente au lancement suivant.
enum LegacyImport {
    static let metaKey = "import.history-json"

    struct Report: Equatable {
        /// Points de la série d'une heure lus dans le fichier.
        var seriesPoints = 0
        /// Points d'espace libre lus, tous volumes confondus.
        var diskPoints = 0
        var volumes = 0
        /// Valeurs écrites dans la base (un point de série en porte quatre).
        var written = 0
        var fileBytes: Int64 = 0

        var summary: String {
            "\(seriesPoints) points de série, \(diskPoints) points de disque sur \(volumes) volume\(volumes > 1 ? "s" : "")"
        }
    }

    /// Les points que contient `history.json`, sans rien écrire nulle part.
    /// `nil` si le fichier n'existe pas ou n'est pas du JSON.
    static func read(_ url: URL, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory)
        -> (points: [SeriesDatabase.Point], report: Report)? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var report = Report(fileBytes: Int64(data.count))
        var points: [SeriesDatabase.Point] = []

        func number(_ any: Any?) -> Double? {
            guard let value = (any as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }

        for case let point as [String: Any] in root["series"] as? [Any] ?? [] {
            guard let time = number(point["t"]) else { continue }
            let t = Int64(time.rounded())
            report.seriesPoints += 1
            if let cpu = number(point["cpu"]) { points.append(.init(key: "cpu.total", t: t, v: cpu)) }
            if let gpu = number(point["gpu"]) { points.append(.init(key: "gpu", t: t, v: gpu)) }
            // `ram` est la part utilisée de la mémoire installée : la même
            // machine, donc le même total — la conversion est exacte.
            if let ram = number(point["ram"]) {
                points.append(.init(key: "memoire.utilisee", t: t, v: (ram * Double(physicalMemory)).rounded()))
            }
            if let swap = number(point["swap"]) { points.append(.init(key: "memoire.swap", t: t, v: swap)) }
        }

        for (volume, value) in root["volumes"] as? [String: Any] ?? [:] {
            var any = false
            for case let point as [String: Any] in value as? [Any] ?? [] {
                guard let time = number(point["t"]), let free = number(point["free"]) else { continue }
                points.append(.init(key: SeriesCatalog.volumeKey(volume), t: Int64(time.rounded()), v: free))
                report.diskPoints += 1
                any = true
            }
            if any { report.volumes += 1 }
        }
        return (points, report)
    }

    /// Importe `history.json` dans `database` si ce n'est pas déjà fait.
    /// Rend le bilan, ou `nil` s'il n'y avait rien à faire.
    @discardableResult
    static func runIfNeeded(from url: URL, into database: SeriesDatabase, now: Date = Date()) -> Report? {
        guard database.isWritable, database.meta(metaKey) == nil else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            database.setMeta(metaKey, encode(["t": now.timeIntervalSince1970, "etat": "aucun history.json"]))
            return nil
        }
        // Pas du JSON : on ne marque rien. `HistoryStore` le mettra de côté
        // s'il est vraiment abîmé, et l'import se retentera.
        guard let (points, read) = read(url) else { return nil }
        var report = read
        do {
            report.written = try database.importPoints(points, now: now)
        } catch {
            return nil
        }
        database.setMeta(metaKey, encode([
            "t": now.timeIntervalSince1970,
            "etat": "importé",
            "serie": report.seriesPoints,
            "disque": report.diskPoints,
            "volumes": report.volumes,
            "ecrits": report.written,
            "octets": report.fileBytes,
        ]))
        return report
    }

    /// Le bilan tel qu'écrit dans la base, pour `--probe`.
    static func stored(in database: SeriesDatabase) -> [String: Any]? {
        guard let text = database.meta(metaKey), let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

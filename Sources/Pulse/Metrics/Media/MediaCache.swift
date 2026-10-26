import Foundation

/// Le cache média d'Adobe, partagé par Premiere, After Effects et Media
/// Encoder : audio conformé, fichiers de crêtes, index des rushes.
///
/// Son emplacement se règle dans Premiere (Réglages › Cache des médias) et
/// s'écrit dans `~/Library/Preferences/com.Adobe.Common <version>.plist`,
/// clé `Media Cache` › `FolderPath` (les fichiers) et `DatabasePath` (la
/// base). Relevé le 11/10 : les deux dans `~/Library/Application
/// Support/Adobe/Common/`, 106 Go dans « Media Cache Files » (53 278
/// entrées), 41 Mo dans « Media Cache ». `du` met 1,7 s à le parcourir.
///
/// Pulse le MESURE et l'ouvre dans le Finder. Il ne supprime jamais rien :
/// Premiere tient une base qui référence ces fichiers, et un nettoyage à son
/// insu le forcerait à tout reconstruire au prochain projet.
enum MediaCache {
    struct Location: Equatable {
        /// Dossier des fichiers de cache (« Media Cache Files »).
        var files: URL
        /// Dossier de la base (« Media Cache »).
        var database: URL
        /// D'où vient l'emplacement : les préférences d'Adobe, ou le défaut.
        var fromPreferences: Bool
    }

    struct Measure: Equatable {
        var location: Location
        /// Octets occupés sur le disque, fichiers et base.
        var bytes: UInt64
        /// Dont les fichiers que rien n'a modifiés depuis 30 jours : ce que
        /// l'option « supprimer les fichiers de cache plus anciens que… » de
        /// Premiere libérerait.
        var staleBytes: UInt64
        var fileCount: Int
        /// Aucun des deux dossiers n'existe : Adobe n'a jamais tourné ici, ou
        /// le cache est sur un disque débranché. « 0 o » serait faux.
        var found: Bool = true
        /// Quand la mesure a été faite, et combien de temps elle a pris.
        var measuredAt: Date
        var seconds: Double
    }

    static let staleAge: TimeInterval = 30 * 86_400

    /// L'emplacement réel, lu dans les préférences de la version la plus
    /// récente ; à défaut, celui d'Adobe par défaut.
    static func location() -> Location {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? [])
            .filter { $0.hasPrefix("com.Adobe.Common ") && $0.hasSuffix(".plist") }
            .sorted { version(of: $0) > version(of: $1) }
        for name in candidates {
            guard let data = FileManager.default.contents(atPath: preferences.appendingPathComponent(name).path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let cache = plist["Media Cache"] as? [String: Any],
                  let folder = cache["FolderPath"] as? String else { continue }
            let database = cache["DatabasePath"] as? String ?? folder
            return Location(files: URL(fileURLWithPath: folder).appendingPathComponent("Media Cache Files", isDirectory: true),
                            database: URL(fileURLWithPath: database).appendingPathComponent("Media Cache", isDirectory: true),
                            fromPreferences: true)
        }
        let common = home.appendingPathComponent("Library/Application Support/Adobe/Common", isDirectory: true)
        return Location(files: common.appendingPathComponent("Media Cache Files", isDirectory: true),
                        database: common.appendingPathComponent("Media Cache", isDirectory: true),
                        fromPreferences: false)
    }

    /// « com.Adobe.Common 26.0.plist » → 26.0.
    static func version(of name: String) -> Double {
        let core = name.replacingOccurrences(of: "com.Adobe.Common ", with: "")
            .replacingOccurrences(of: ".plist", with: "")
        return Double(core) ?? 0
    }

    /// Parcourt le cache. Plus d'une seconde sur 50 000 fichiers : jamais sur
    /// le fil principal, et au plus une fois par demi-heure (`MediaCacheProbe`).
    static func measure(_ location: Location = location(), now: Date = Date()) -> Measure {
        let started = Date()
        var bytes: UInt64 = 0, stale: UInt64 = 0, count = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for folder in Set([location.files, location.database]) {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let size = UInt64(values.totalFileAllocatedSize ?? 0)
                bytes += size
                count += 1
                if let modified = values.contentModificationDate,
                   now.timeIntervalSince(modified) > staleAge { stale += size }
            }
        }
        let found = [location.files, location.database].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return Measure(location: location, bytes: bytes, staleBytes: stale, fileCount: count, found: found,
                       measuredAt: now, seconds: Date().timeIntervalSince(started))
    }
}

/// La dernière mesure du cache, refaite au plus toutes les 30 min, en tâche
/// de fond. Demandée à l'ouverture du panneau seulement : fermé, personne ne
/// la lit.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : son état passe par son verrou,
/// le parcours tourne sur sa propre file.
final class MediaCacheProbe: @unchecked Sendable {
    static let interval: TimeInterval = 30 * 60
    private let lock = NSLock()
    private var last: MediaCache.Measure?
    private var running = false
    private let queue = DispatchQueue(label: "com.isma.pulse.mediacache", qos: .background)

    var current: MediaCache.Measure? {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// Lance une mesure si la dernière a plus de 30 min. `done` est appelé
    /// sur la file de mesure quand elle aboutit.
    func refreshIfDue(now: Date = Date(), done: @escaping @Sendable (MediaCache.Measure) -> Void) {
        lock.lock()
        let due = !running && (last.map { now.timeIntervalSince($0.measuredAt) > Self.interval } ?? true)
        if due { running = true }
        lock.unlock()
        guard due else { return }
        queue.async { [weak self] in
            let measure = MediaCache.measure()
            guard let self else { return }
            self.lock.lock()
            self.last = measure
            self.running = false
            self.lock.unlock()
            done(measure)
        }
    }
}

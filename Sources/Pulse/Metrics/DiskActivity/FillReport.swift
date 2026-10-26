import Foundation
import CoreServices

/// Un dossier où des fichiers sont arrivés : « Client A/01 Rushes - Client A ».
struct FillFolder: Codable, Equatable {
    /// Chemin relatif à la racine du volume, deux niveaux au plus : le client
    /// et la catégorie, c'est la granularité des dossiers d'Isma.
    var path: String
    var bytes: Double
    var files: Int

    /// « Client A › 01 Rushes » : le nom du client répété en suffixe de la
    /// catégorie (« 01 Rushes - Client A ») n'apprend rien sous ce client.
    var label: String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return path }
        var child = parts[1]
        for suffix in [" - \(parts[0])", " – \(parts[0])", " \(parts[0])"] where child.hasSuffix(suffix) && child.count > suffix.count {
            child.removeLast(suffix.count)
            break
        }
        return "\(parts[0]) › \(child)"
    }

    init(path: String, bytes: Double, files: Int) {
        self.path = path; self.bytes = bytes; self.files = files
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? "?"
        bytes = (try? c.decodeIfPresent(Double.self, forKey: .bytes)) ?? 0
        files = (try? c.decodeIfPresent(Int.self, forKey: .files)) ?? 0
    }
}

/// « Qu'est-ce qui remplit Ssd 2 ? » : les octets ARRIVÉS sur un volume en
/// 24 h et en 7 jours, par dossier, d'après la date d'ajout de chaque fichier.
///
/// Arrivés, pas « grossis » : un fichier effacé depuis ne compte plus, un
/// fichier copié compte à la date de la copie (`kMDItemDateAdded`, la colonne
/// « Date d'ajout » du Finder), pas à celle du tournage.
struct FillReport: Codable, Equatable {
    var volumeKey: String
    var volumeName: String
    var at: Date
    var dayBytes: Double
    var weekBytes: Double
    var dayFiles: Int
    var weekFiles: Int
    /// Les dossiers, du plus rempli au moins rempli, 5 au plus.
    var day: [FillFolder]
    var week: [FillFolder]

    init(volumeKey: String, volumeName: String, at: Date, dayBytes: Double, weekBytes: Double,
         dayFiles: Int, weekFiles: Int, day: [FillFolder], week: [FillFolder]) {
        self.volumeKey = volumeKey; self.volumeName = volumeName; self.at = at
        self.dayBytes = dayBytes; self.weekBytes = weekBytes; self.dayFiles = dayFiles
        self.weekFiles = weekFiles; self.day = day; self.week = week
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeKey = (try? c.decodeIfPresent(String.self, forKey: .volumeKey)) ?? "?"
        volumeName = (try? c.decodeIfPresent(String.self, forKey: .volumeName)) ?? "?"
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? .distantPast
        dayBytes = (try? c.decodeIfPresent(Double.self, forKey: .dayBytes)) ?? 0
        weekBytes = (try? c.decodeIfPresent(Double.self, forKey: .weekBytes)) ?? 0
        dayFiles = (try? c.decodeIfPresent(Int.self, forKey: .dayFiles)) ?? 0
        weekFiles = (try? c.decodeIfPresent(Int.self, forKey: .weekFiles)) ?? 0
        day = (try? c.decodeIfPresent([FillFolder].self, forKey: .day)) ?? []
        week = (try? c.decodeIfPresent([FillFolder].self, forKey: .week)) ?? []
    }

    /// Un fichier arrivé : chemin relatif au volume, taille, date d'ajout.
    struct Arrival {
        var relativePath: String
        var bytes: Double
        var added: Date
    }

    /// Le bilan, sans Spotlight : testable sur des arrivées fabriquées.
    static func build(volumeKey: String, volumeName: String, arrivals: [Arrival], now: Date) -> FillReport {
        var day: [String: (bytes: Double, files: Int)] = [:]
        var week: [String: (bytes: Double, files: Int)] = [:]
        var dayBytes = 0.0, weekBytes = 0.0, dayFiles = 0, weekFiles = 0
        for a in arrivals {
            let age = now.timeIntervalSince(a.added)
            guard age < 7 * 86_400, age >= -3600 else { continue }
            let key = folderKey(a.relativePath)
            week[key, default: (0, 0)].bytes += a.bytes
            week[key, default: (0, 0)].files += 1
            weekBytes += a.bytes; weekFiles += 1
            if age < 86_400 {
                day[key, default: (0, 0)].bytes += a.bytes
                day[key, default: (0, 0)].files += 1
                dayBytes += a.bytes; dayFiles += 1
            }
        }
        func top(_ m: [String: (bytes: Double, files: Int)]) -> [FillFolder] {
            m.filter { $0.value.bytes > 0 }
                .sorted { $0.value.bytes > $1.value.bytes }
                .prefix(5)
                .map { FillFolder(path: $0.key, bytes: $0.value.bytes, files: $0.value.files) }
        }
        return FillReport(volumeKey: volumeKey, volumeName: volumeName, at: now,
                          dayBytes: dayBytes, weekBytes: weekBytes, dayFiles: dayFiles, weekFiles: weekFiles,
                          day: top(day), week: top(week))
    }

    /// Deux niveaux : « Client/Catégorie ». Un fichier posé à la racine se
    /// range sous « (racine) », un fichier d'un dossier de premier niveau
    /// sous ce dossier.
    static func folderKey(_ relative: String) -> String {
        let parts = relative.split(separator: "/")
        switch parts.count {
        case ...1: return "(racine)"
        case 2: return String(parts[0])
        default: return parts.prefix(2).joined(separator: "/")
        }
    }
}

/// Les arrivées d'un volume, demandées à l'index Spotlight que macOS tient
/// déjà : Pulse ne parcourt pas le disque.
///
/// Mesuré le 11/10 sur Ssd 2 (58 000 fichiers) : 943 fichiers arrivés en
/// 7 jours, 0,27 s de processeur pour Pulse. La réponse a mis 89 s à venir,
/// machine chargée (charge 18, ffmpeg lisant le disque) : c'est `mds` qui
/// travaille, sur son index, à sa priorité. D'où une requête toutes les 30 min
/// au plus, sur une file d'arrière-plan, jamais sur celle du relevé. Un
/// parcours du volume par Pulse, essayé à priorité d'arrière-plan pendant le
/// même travail, n'avait pas fini en 7 min 45.
enum SpotlightArrivals {
    /// Les fichiers arrivés en 7 jours sur le volume monté en `path`.
    /// `nil` si la requête n'a pas pu s'exécuter.
    static func query(volumePath path: String, days: Double = 7) -> [FillReport.Arrival]? {
        let predicate = "kMDItemDateAdded >= $time.now(-\(Int(days * 86_400))) && kMDItemContentType != \"public.folder\""
        guard let q = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else { return nil }
        MDQuerySetSearchScope(q, [path] as CFArray, 0)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        var out: [FillReport.Arrival] = []
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let full = MDItemCopyAttribute(item, kMDItemPath) as? String, full.hasPrefix(prefix),
                  let added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date else { continue }
            // Taille allouée quand l'index la connaît : c'est elle qui occupe
            // le disque ; sinon la taille du fichier.
            let size = (MDItemCopyAttribute(item, "kMDItemPhysicalSize" as CFString) as? NSNumber)?.doubleValue
                ?? (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.doubleValue ?? 0
            out.append(.init(relativePath: String(full.dropFirst(prefix.count)), bytes: size, added: added))
        }
        return out
    }
}

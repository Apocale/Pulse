import Foundation
import Darwin

enum IncidentKind: String, Codable, CaseIterable {
    case crash          // plantage franc, relevé par Crashpad
    case jetsam         // macOS a tué des processus faute de mémoire

    var label: String {
        switch self {
        case .crash: return "plantage"
        case .jetsam: return "processus tué (mémoire)"
        }
    }
}

struct Incident: Identifiable {
    var app: String
    var bundleId: String?
    var kind: IncidentKind
    var date: Date

    var id: String { "\(app)-\(kind.rawValue)-\(Int(date.timeIntervalSince1970))" }
}

/// Recense les incidents de montage à partir de DEUX sources distinctes.
///
/// La distinction est essentielle : Adobe embarque `crashpad_handler`, qui
/// installe son propre gestionnaire d'exception et empêche `ReportCrash`
/// d'Apple d'écrire quoi que ce soit. Vérifié sur cette machine : Premiere a
/// planté trois fois le 24 août sans produire un seul `.ips`. Une détection
/// de plantage bâtie sur les seuls rapports système serait silencieusement
/// inopérante — le pire des défauts, puisque l'app aurait l'air de marcher.
enum IncidentLog {
    static let systemReports = "/Library/Logs/DiagnosticReports"
    static let adobeCaches = NSString(string: "~/Library/Caches/Adobe").expandingTildeInPath

    enum Access {
        case granted
        /// Compte standard : le dossier appartient à root:_analyticsusers, dont
        /// l'appartenance découle du groupe admin. Aucune autorisation à
        /// demander — ce n'est pas du TCC, c'est POSIX.
        case denied
    }

    static func access() -> Access {
        (try? FileManager.default.contentsOfDirectory(atPath: systemReports)) != nil ? .granted : .denied
    }

    static func recent(since: Date) -> [Incident] {
        (crashes(since: since) + jetsamEvents(since: since)).sorted { $0.date > $1.date }
    }

    // MARK: - Source A : plantages relevés par Crashpad

    /// ~/Library/Caches/Adobe/<App>/<Version>/SentryIO-db/{completed,pending}/*.dmp
    /// La version fait partie du chemin et change à chaque mise à jour majeure :
    /// les niveaux sont donc énumérés, jamais codés en dur.
    /// `root` : le dossier des caches d'Adobe ; un autre pour les tests.
    static func crashes(since: Date, in root: String = adobeCaches) -> [Incident] {
        let manager = FileManager.default
        guard let apps = try? manager.contentsOfDirectory(atPath: root) else { return [] }

        var found: [Incident] = []
        for app in apps {
            let appPath = (root as NSString).appendingPathComponent(app)
            guard let versions = try? manager.contentsOfDirectory(atPath: appPath) else { continue }
            for version in versions {
                let base = [appPath, version, "SentryIO-db"].joined(separator: "/")
                for stage in ["completed", "pending"] {
                    let directory = (base as NSString).appendingPathComponent(stage)
                    guard let dumps = try? manager.contentsOfDirectory(atPath: directory) else { continue }
                    for dump in dumps where dump.hasSuffix(".dmp") {
                        let path = (directory as NSString).appendingPathComponent(dump)
                        guard let when = crashDate(path: path), when >= since else { continue }
                        found.append(Incident(app: app, bundleId: nil, kind: .crash, date: when))
                    }
                }
            }
        }
        return found
    }

    /// Crashpad écrit l'instant du plantage en attribut étendu. Le lire évite
    /// d'ouvrir un minidump de plusieurs mégaoctets pour n'en tirer qu'une date.
    private static func crashDate(path: String) -> Date? {
        if let raw = xattr(path, "org.chromium.crashpad.database.creation_time"),
           let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           // « inf » se lit aussi : une date hors bornes planterait l'identifiant.
           seconds.isFinite, (0..<4e9).contains(seconds) {
            return Date(timeIntervalSince1970: seconds)
        }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Source B : processus tués par macOS faute de mémoire

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    /// Seuls les JetsamEvent de ce dossier comptent. Les deux autres familles
    /// de rapports qu'on y trouve décrivent un montage ordinaire, et les
    /// remonter faisait crier l'app pour un comportement normal :
    ///
    /// - « disk writes » (`bug_type` 45) : 2 Gio écrits sur 24 h, franchis
    ///   par n'importe quel export. 39 des 70 rapports au premier relevé.
    /// - « cpu usage » (`bug_type` 22, `.cpu_resource.diag`) : 50 % d'UN cœur
    ///   tenus 3 min. Relevé le 09/10 : les 12 « CPU saturé » des 14 derniers
    ///   jours étaient tous Premiere, à 63 % d'un cœur sur 2 min — quand une
    ///   simple séance de montage le fait tourner à 187 %. macOS écrit
    ///   lui-même « Action taken: none ». Douze alertes, zéro panne.
    /// `folder` : les rapports de diagnostic ; un autre pour les tests.
    static func jetsamEvents(since: Date, in folder: String = systemReports) -> [Incident] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }

        var found: [Incident] = []
        for entry in entries where entry.hasPrefix("JetsamEvent") {
            let path = (folder as NSString).appendingPathComponent(entry)
            guard let when = eventDate(path: path, name: entry), when >= since else { continue }
            for victim in jetsamVictims(path: path)
            where !benignJetsamReasons.contains(victim.reason) {
                found.append(Incident(app: victim.name, bundleId: nil, kind: .jetsam, date: when))
            }
        }
        return found
    }

    /// Motifs de mise à mort qui ne disent rien de la santé de la machine :
    /// le processus a dépassé SON propre plafond, pas celui du système. Les
    /// deux JetsamEvent de cette machine sont de ce type — victimes
    /// `spotlightknowledged.updater` et `knowledgeconstructiond`, deux démons
    /// d'indexation de quelques dizaines de mégaoctets. Remontés en incident,
    /// ils faisaient lire « 2 processus tués (mémoire) » à un utilisateur dont
    /// rien n'avait été tué. Même motif d'exclusion que les « disk writes ».
    ///
    /// Liste de rejet et non d'acceptation : un motif inconnu doit remonter.
    /// Pour un outil de surveillance, montrer de trop vaut mieux que taire.
    private static let benignJetsamReasons: Set<String> = [
        "per-process-limit", "highwater", "idle-exit",
    ]

    /// Les processus réellement tués par un JetsamEvent, avec leur motif.
    ///
    /// Le fichier pèse quelques centaines de kilooctets parce qu'il liste TOUS
    /// les processus vivants à l'instant du relevé — 828 dans le dernier ici.
    /// Ce n'est pas la fiche d'une victime mais un instantané système : seuls
    /// les processus portant un `reason` ont été tués, généralement un seul.
    /// Le filtre de date en amont garantit qu'on n'ouvre que les fichiers de
    /// la fenêtre demandée.
    private static func jetsamVictims(path: String) -> [(name: String, reason: String)] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              let newline = text.firstIndex(of: "\n") else { return [] }

        // Un .ips est fait de DEUX documents JSON collés : une ligne d'en-tête
        // puis le corps. Passé entier à JSONSerialization, l'ensemble est
        // invalide — il faut couper à la première fin de ligne.
        guard let payload = String(text[text.index(after: newline)...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let processes = root["processes"] as? [[String: Any]] else { return [] }

        return processes.compactMap { process in
            guard let reason = process["reason"] as? String else { return nil }
            return (process["name"] as? String ?? "processus inconnu", reason)
        }
    }

    private static func eventDate(path: String, name: String) -> Date? {
        // L'attribut porte le fuseau ; le nom de fichier est en heure locale
        // implicite et se décale silencieusement.
        if let raw = xattr(path, "timestamp"), let parsed = stampFormatter.date(from: raw) {
            return parsed
        }
        return dateFromName(name)
    }

    private static let stamp = try? NSRegularExpression(
        pattern: "(\\d{4})-(\\d{2})-(\\d{2})-(\\d{2})(\\d{2})(\\d{2})")

    private static func dateFromName(_ name: String) -> Date? {
        guard let stamp else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = stamp.firstMatch(in: name, range: range) else { return nil }
        func part(_ index: Int) -> Int? {
            guard let r = Range(match.range(at: index), in: name) else { return nil }
            return Int(name[r])
        }
        var components = DateComponents()
        components.year = part(1); components.month = part(2); components.day = part(3)
        components.hour = part(4); components.minute = part(5); components.second = part(6)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)
    }

    // MARK: - Attributs étendus

    private static func xattr(_ path: String, _ name: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

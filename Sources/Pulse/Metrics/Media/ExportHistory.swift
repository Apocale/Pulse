import Foundation

/// Un export terminé.
struct ExportRecord: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable {
        case success, warning, failure
    }

    /// Unique et stable : relire deux fois le même journal ne double rien.
    var id: String
    /// « Media Encoder », « Premiere Pro ».
    var app: String
    /// Fin de l'export, en secondes depuis 1970.
    var end: Double
    /// Durée de l'encodage, en secondes.
    var duration: Double
    /// Le fichier produit. `nil` quand Pulse a vu l'encodeur travailler sans
    /// savoir où il écrivait.
    var output: String?
    var outcome: Outcome
    /// Taille du fichier produit, lue à l'ingestion. `nil` si le fichier
    /// n'existait plus ou si son volume n'était pas branché.
    var bytes: UInt64?
    /// D'où vient l'enregistrement : « journal d'AME » ou « vu par Pulse ».
    var source: String

    var start: Double { end - duration }

    init(id: String, app: String, end: Double, duration: Double, output: String?,
         outcome: Outcome, bytes: UInt64?, source: String) {
        self.id = id; self.app = app; self.end = end; self.duration = duration
        self.output = output; self.outcome = outcome; self.bytes = bytes; self.source = source
    }

    /// Règle dure n°2 : chaque champ en `decodeIfPresent`. Un champ ajouté
    /// plus tard ne doit jamais coûter l'historique déjà écrit.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tolerant(String.self, .id) ?? UUID().uuidString
        app = c.tolerant(String.self, .app) ?? "?"
        end = c.tolerant(Double.self, .end) ?? 0
        duration = c.tolerant(Double.self, .duration) ?? 0
        output = c.tolerant(String.self, .output)
        outcome = c.tolerant(Outcome.self, .outcome) ?? .success
        bytes = c.tolerant(UInt64.self, .bytes)
        source = c.tolerant(String.self, .source) ?? ""
    }
}

/// Le journal d'Adobe Media Encoder : chaque fichier encodé par sa file y
/// laisse un bloc — source, sortie, préréglage, débit, durée d'encodage — et
/// une ligne datée qui dit l'issue.
///
/// Relevé le 11/10 : 3 212 exports depuis le 25/03, dont 3 209 envoyés depuis
/// Premiere (la source est une copie du projet dans `/var/folders/…/T/`).
/// C'est la voie d'export ordinaire d'Isma, et ce journal la décrit mieux que
/// n'importe quelle mesure : fichier de sortie, durée, issue, heure de fin.
///
/// Encodé en UTF-16 (marque FF FE en tête). L'export lancé directement depuis
/// Premiere, sans la file d'AME, n'y figure pas — voir 08-medias.md.
enum AMEJournal {
    static let source = "journal d'AME"

    /// Le journal de la version la plus récente d'AME installée.
    static func url() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Adobe/Adobe Media Encoder", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return nil }
        // « 26.0 » avant « 25.0 » ; la bêta vit dans un autre dossier.
        let sorted = versions.filter { Double($0) != nil }
            .sorted { (Double($0) ?? 0) > (Double($1) ?? 0) }
        for version in sorted {
            let file = base.appendingPathComponent(version).appendingPathComponent("AMEEncodingLog.txt")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// Les exports terminés que décrit `text`.
    ///
    /// Lu octet par octet, en UTF-8 : 48 000 lignes dont l'immense majorité ne
    /// sert à rien. Les découper en `String` puis les rogner coûtait plus
    /// d'une seconde sous charge (relevé du 11/10) ; ici seules les trois
    /// lignes utiles d'un bloc deviennent du texte.
    static func parse(_ text: String) -> [ExportRecord] {
        let bytes = Array(text.utf8)
        var records: [ExportRecord] = []
        var output: String?
        var duration: Double?
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            defer { lineStart = lineEnd + 1 }
            var a = lineStart, b = lineEnd
            while a < b, bytes[a] == 0x20 || bytes[a] == 0x09 { a += 1 }
            while b > a, bytes[b - 1] == 0x0D || bytes[b - 1] == 0x20 { b -= 1 }
            guard a < b else { continue }
            let line = bytes[a..<b]
            if bytes[a] == UInt8(ascii: "-") {
                if line.starts(with: sourceTag) {
                    output = nil
                    duration = nil
                } else if line.starts(with: outputTag) {
                    output = String(decoding: line.dropFirst(outputTag.count), as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                } else if line.starts(with: timeTag) {
                    duration = seconds(String(decoding: line.dropFirst(timeTag.count), as: UTF8.self))
                }
            } else if (0x30...0x39).contains(bytes[a]), let path = output,
                      let separator = line.firstRange(of: separatorTag) {
                let status = line[separator.upperBound...]
                let outcome: ExportRecord.Outcome
                if status.elementsEqual(successTag) { outcome = .success }
                else if status.elementsEqual(warningTag) { outcome = .warning }
                else if status.elementsEqual(failureTag) { outcome = .failure }
                else { continue }      // « Queue Started », « Queue Paused »…
                guard let end = stamp(line[..<separator.lowerBound]) else { continue }
                records.append(ExportRecord(id: "ame-\(Int(end))-\(path)", app: "Media Encoder",
                                            end: end, duration: duration ?? 0, output: path,
                                            outcome: outcome, bytes: nil, source: source))
                output = nil
                duration = nil
            }
        }
        return records
    }

    private static let sourceTag = Array("- Source File:".utf8)
    private static let outputTag = Array("- Output File:".utf8)
    private static let timeTag = Array("- Encoding Time:".utf8)
    private static let separatorTag = Array(" : ".utf8)
    private static let successTag = Array("File Successfully Encoded".utf8)
    private static let warningTag = Array("File Encoded with warning".utf8)
    private static let failureTag = Array("Encoding Failed".utf8)

    /// « 10/11/2026 03:54:14 AM », heure locale → secondes depuis 1970.
    /// À la main : un `DateFormatter` coûtait 20 µs par ligne.
    static func stamp<C: Collection>(_ text: C) -> Double? where C.Element == UInt8 {
        var numbers: [Int] = [], current = -1, pm: Bool?
        for byte in text {
            if (0x30...0x39).contains(byte) {
                current = (current < 0 ? 0 : current * 10) + Int(byte - 0x30)
            } else {
                if current >= 0 { numbers.append(current); current = -1 }
                if byte == UInt8(ascii: "A") { pm = false }
                if byte == UInt8(ascii: "P") { pm = true }
            }
        }
        if current >= 0 { numbers.append(current) }
        guard numbers.count == 6, let pm else { return nil }
        var hour = numbers[3] % 12
        if pm { hour += 12 }
        var parts = DateComponents()
        parts.month = numbers[0]; parts.day = numbers[1]; parts.year = numbers[2]
        parts.hour = hour; parts.minute = numbers[4]; parts.second = numbers[5]
        return Calendar.current.date(from: parts)?.timeIntervalSince1970
    }

    /// « 00:08:09 » → 489.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Le texte du journal, quel que soit son encodage.
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    /// La fin du journal, à partir de l'octet `offset` : AME ne fait
    /// qu'ajouter, et relire 3,4 Mo à chaque export pour une dizaine de
    /// lignes nouvelles gardait ~7 Mo en mémoire le temps du découpage.
    ///
    /// L'encodage se lit sur les deux premiers octets du fichier : en UTF-16
    /// une tranche commence sur un octet pair, et sans marque elle se décode
    /// dans le boutisme de la marque. Une ligne coupée en tête de tranche est
    /// sans danger : elle ne ressemble à aucune ligne utile.
    static func read(_ url: URL, from offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2) else { return nil }
        let little = head.starts(with: [0xFF, 0xFE])
        let big = head.starts(with: [0xFE, 0xFF])
        let start = (little || big) ? max(2, offset & ~1) : offset
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        if little { return String(data: data, encoding: .utf16LittleEndian) }
        if big { return String(data: data, encoding: .utf16BigEndian) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// L'historique des exports : le journal d'AME, relu quand il change, et ce
/// que Pulse a vu lui-même. Persisté dans `exports.json`, à part de
/// history.json et relu de façon tolérante : un fichier abîmé ne peut rien
/// coûter d'autre que lui-même. 90 jours.
///
/// Pourquoi recopier le journal d'AME : AME peut le vider ou le perdre à une
/// réinstallation, et la taille du fichier produit n'y figure pas — elle est
/// lue ici à l'ingestion, tant que le disque est branché.
///
/// Touché depuis la file d'échantillonnage, lu depuis le fil principal : d'où
/// le verrou.
final class ExportHistory {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("exports.json")
    }
    static let retention: TimeInterval = 90 * 86_400

    private let lock = NSLock()
    private var records: [String: ExportRecord] = [:]
    /// Date de modification et taille du journal à la dernière lecture : il
    /// n'est relu que s'il a changé, soit à la fin de chaque export.
    private var journalStamp: (Date, UInt64)?
    /// Jusqu'où le journal a été lu.
    private var journalOffset: UInt64?
    /// Au premier relevé, la fin seulement : 2 Mo couvrent plus que les
    /// 90 jours gardés (3,4 Mo pour six mois et demi le 11/10).
    static let firstRead: UInt64 = 2_000_000
    /// À chaque relecture, un peu avant la fin connue : un bloc écrit en deux
    /// fois serait relu en entier. L'ingestion ignore ce qu'elle connaît déjà.
    static let overlap: UInt64 = 16_000

    /// Le journal d'AME vit dans ~/Documents, que macOS protège : y regarder,
    /// même pour constater qu'il n'existe pas, fait demander « Pulse souhaite
    /// accéder aux fichiers de votre dossier Documents ». Cherché dès la
    /// création de l'historique, il faisait surgir cette demande à la
    /// première ouverture du panneau sur un Mac neuf, carte Médias masquée
    /// (26/10). Il n'est donc cherché que quand l'historique des exports est
    /// voulu : carte Médias affichée, règle « Export terminé » allumée
    /// (`relireJournal`), ou un historique déjà nourri par ce journal — celui
    /// d'Isma, qui ne doit pas avoir de trou.
    private enum Journal {
        /// Donné à la création (tests ; `--probe`, qui lit le journal lui-même).
        case fixed(URL?)
        /// Celui de ce Mac, pas encore cherché.
        case notLookedUp
        case lookedUp(URL?)
    }
    private var journal: Journal
    private let lookup: () -> URL?
    private let fileURL: URL
    private var lastLive: ExportActivity?
    private var lastUpdate: Date?

    /// L'historique de l'app : le journal d'AME de ce Mac, cherché seulement
    /// quand il est permis de le lire.
    /// - Parameter lookup: pour les tests, la recherche du journal.
    init(file: URL = ExportHistory.url, lookup: @escaping () -> URL? = AMEJournal.url) {
        journal = .notLookedUp
        self.lookup = lookup
        fileURL = file
        load()
    }

    init(journal: URL?, file: URL = ExportHistory.url) {
        self.journal = .fixed(journal)
        lookup = { nil }
        self.fileURL = file
        load()
    }

    /// Un historique figé, en mémoire : ni journal d'AME, ni exports.json
    /// lus ou écrits. Celui du relevé des rendus (`Releve`, 19-suivis).
    init(figé records: [ExportRecord]) {
        journal = .fixed(nil)
        lookup = { nil }
        fileURL = URL(fileURLWithPath: "/dev/null/pulse-exports-figes.json")
        for record in records { self.records[record.id] = record }
    }

    /// Un relevé : relit le journal s'il a changé, et clôt l'export vu en
    /// direct quand il vient de finir. Quelques microsecondes quand rien ne
    /// bouge (un `stat`), d'où l'appel à chaque relevé, panneau fermé compris.
    /// - Parameter journalWanted: la carte Médias est affichée — le journal
    ///   d'AME peut alors être cherché (voir `Journal`).
    func update(live: ExportActivity?, journalWanted: Bool = true, now: Date = Date()) {
        var changed = readJournal(now: now, wanted: journalWanted)
        // Un export vu en direct qui vient de se terminer : gardé seulement
        // si le journal d'AME ne le décrit pas déjà, mieux — et seulement si
        // le suivi a été continu. Le module ne relève rien panneau fermé :
        // après une fermeture, la dernière vue de l'export est ancienne, et
        // sa fin réelle inconnue. On ne l'invente pas.
        if let previous = lastLive, live == nil,
           let last = lastUpdate, now.timeIntervalSince(last) < 10 {
            changed = recordLive(previous) || changed
        }
        lastLive = live
        lastUpdate = now
        if changed { save() }
    }

    /// Le journal d'AME seul, relu s'il a changé, sans toucher au suivi en
    /// direct : la règle « Export terminé » y lit le fichier produit et son
    /// issue, panneau fermé compris (19-suivis). Sur la file du relevé,
    /// comme `update`.
    func relireJournal(now: Date = Date()) {
        if readJournal(now: now, wanted: true) { save() }
    }

    /// Le journal à lire, s'il est permis de le chercher (voir `Journal`).
    private func journalURL(wanted: Bool) -> URL? {
        switch journal {
        case .fixed(let url), .lookedUp(let url):
            return url
        case .notLookedUp:
            guard wanted || hasJournalRecords else { return nil }
            let url = lookup()
            journal = .lookedUp(url)
            return url
        }
    }

    private var hasJournalRecords: Bool {
        lock.lock(); defer { lock.unlock() }
        return records.values.contains { $0.source == AMEJournal.source }
    }

    /// Rend vrai si des exports nouveaux sont entrés.
    private func readJournal(now: Date, wanted: Bool) -> Bool {
        var changed = false
        if let journal = journalURL(wanted: wanted),
           let attributes = try? FileManager.default.attributesOfItem(atPath: journal.path),
           let date = attributes[.modificationDate] as? Date,
           let size = (attributes[.size] as? NSNumber)?.uint64Value,
           journalStamp.map({ $0.0 != date || $0.1 != size }) ?? true {
            journalStamp = (date, size)
            // Plus court qu'à la dernière lecture : AME a vidé ou remplacé
            // son journal, on repart de sa fin.
            let start: UInt64
            if let offset = journalOffset, offset <= size {
                start = offset > Self.overlap ? offset - Self.overlap : 0
            } else {
                start = size > Self.firstRead ? size - Self.firstRead : 0
            }
            if let text = AMEJournal.read(journal, from: start) {
                changed = ingest(AMEJournal.parse(text), now: now) || changed
            }
            journalOffset = size
        }
        return changed
    }

    /// Ajoute les exports absents. Rend vrai si quelque chose a changé.
    @discardableResult
    func ingest(_ incoming: [ExportRecord], now: Date = Date()) -> Bool {
        let horizon = now.timeIntervalSince1970 - Self.retention
        let recent = now.timeIntervalSince1970 - 7 * 86_400
        lock.lock()
        let fresh = incoming.filter { $0.end >= horizon && records[$0.id] == nil }
        lock.unlock()
        guard !fresh.isEmpty else { return false }
        // La taille, hors verrou : un `stat` par fichier de la semaine, pas
        // des trois mille du journal — un disque débranché ferait attendre.
        let sized = fresh.map { record -> ExportRecord in
            var record = record
            if record.end >= recent, record.outcome != .failure, let path = record.output,
               let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value {
                record.bytes = size
            }
            return record
        }
        lock.lock(); defer { lock.unlock() }
        for record in sized { records[record.id] = record }
        // Un export vu en direct que le journal décrit désormais : le
        // journal l'emporte, il sait où le fichier est allé.
        for record in sized where record.source == AMEJournal.source {
            records = records.filter { _, other in
                !(other.source == ExportHistory.liveSource && other.app == record.app
                  && abs(other.end - record.end) < 120)
            }
        }
        return true
    }

    static let liveSource = "vu par Pulse"

    private func recordLive(_ live: ExportActivity) -> Bool {
        let end = live.lastActive.timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        if records.values.contains(where: { $0.app == Fmt.appName(live.app) && abs($0.end - end) < 120 }) {
            return false
        }
        let record = ExportRecord(id: "pulse-\(Int(live.began.timeIntervalSince1970))",
                                  app: Fmt.appName(live.app), end: end, duration: live.duration,
                                  output: nil, outcome: .success, bytes: nil, source: Self.liveSource)
        records[record.id] = record
        return true
    }

    /// Les exports terminés depuis `since`, du plus récent au plus ancien.
    func exports(since: Date) -> [ExportRecord] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = since.timeIntervalSince1970
        return records.values.filter { $0.end >= cutoff }.sorted { $0.end > $1.end }
    }

    /// Ceux d'aujourd'hui, jour civil local.
    func today(now: Date = Date()) -> [ExportRecord] {
        exports(since: Calendar.current.startOfDay(for: now))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    // MARK: - Persistance

    private struct File: Codable {
        var version = 1
        var exports: [ExportRecord] = []

        init(exports: [ExportRecord]) { self.exports = exports }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.tolerant(Int.self, .version) ?? 1
            // Élément par élément : un enregistrement illisible est sauté,
            // il n'emporte pas les autres. Une liste absente est une liste
            // vide ; présente mais d'une autre forme, le fichier est mis de
            // côté par `load` plutôt qu'écrasé.
            guard c.contains(.exports) else { return }
            var list = try c.nestedUnkeyedContainer(forKey: .exports)
            var out: [ExportRecord] = []
            while !list.isAtEnd {
                if let record = try? list.decode(ExportRecord.self) { out.append(record) }
                else { _ = try? list.decode(Skip.self) }
            }
            exports = out
        }

        private struct Skip: Decodable {}
    }

    /// Illisible — pas du JSON, ou une liste d'une autre forme — : mis de
    /// côté (exports.illisible.json) plutôt qu'écrasé à la première
    /// sauvegarde, qui n'y aurait remis que la fin du journal d'AME : les
    /// exports vus en direct et les tailles déjà relevées étaient perdus
    /// (17-audit-code).
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            if Persistence.enabled { Persistence.setAside(fileURL) }
            return
        }
        lock.lock(); defer { lock.unlock() }
        for record in file.exports { records[record.id] = record }
    }

    private func save() {
        guard Persistence.enabled else { return }
        lock.lock()
        let horizon = Date().timeIntervalSince1970 - Self.retention
        records = records.filter { $0.value.end >= horizon }
        let file = File(exports: records.values.sorted { $0.end < $1.end })
        lock.unlock()
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension Array where Element == ExportRecord {
    /// Durée cumulée d'encodage.
    var totalDuration: TimeInterval { reduce(0) { $0 + $1.duration } }
}

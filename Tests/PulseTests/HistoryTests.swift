import Foundation
import Testing
@testable import Pulse

/// La base des séries (`Sources/Pulse/History/`), sur des fichiers jetables :
/// jamais le vrai `historique.sqlite`, jamais le vrai `history.json`.
@Suite(.serialized) struct HistoryTests {
    /// 11/10/2026 12:00 UTC : une heure ronde, pour lire les tranches à l'œil.
    static let noon: Int64 = 1_791_720_000

    static func threadCPUTime() -> Double { SeriesRecorder.threadCPU() }

    /// `ri_diskio_byteswritten` du processus de test.
    static func bytesWrittenByThisProcess() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_diskio_byteswritten : 0
    }

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-historique-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func database(_ folder: URL) -> SeriesDatabase {
        SeriesDatabase(url: folder.appendingPathComponent(SeriesDatabase.fileName), readOnly: false,
                       now: Date(timeIntervalSince1970: TimeInterval(noon)))
    }

    static func at(_ t: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    // MARK: - Agrégation

    /// Six points par minute : la minute en garde la moyenne, le min, le max
    /// et le nombre ; la tranche de 10 min pondère par ce nombre.
    @Test func lesMinutesEtLesDixMinutesResumentLesPointsBruts() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Self.database(folder)
        #expect(db.state == .ready)

        // 12:00:00 → 12:19:50, un point toutes les 10 s : la valeur vaut la
        // minute (0 à 19), plus un écart de 0 à 5 dans la minute.
        var points: [SeriesDatabase.Point] = []
        for i in 0..<120 {
            let t = Self.noon + Int64(i) * 10
            points.append(.init(key: "cpu.total", t: t, v: Double(i / 6) + Double(i % 6)))
        }
        try db.insert(points, now: Self.at(Self.noon + 1200))

        let minutes = db.buckets(key: "cpu.total", from: Self.noon, to: Self.noon + 1200, bucket: 60,
                                 now: Self.noon + 2 * 86_400)   // force l'étage des minutes
        #expect(minutes.count == 20)
        #expect(minutes.first == .init(t: Self.noon, avg: 2.5, min: 0, max: 5, count: 6))
        #expect(minutes.last == .init(t: Self.noon + 1140, avg: 21.5, min: 19, max: 24, count: 6))

        let tens = db.buckets(key: "cpu.total", from: Self.noon, to: Self.noon + 1200, bucket: 600,
                              now: Self.noon + 30 * 86_400)  // force l'étage des 10 min
        #expect(tens.count == 2)
        #expect(tens[0] == .init(t: Self.noon, avg: 7.0, min: 0, max: 14, count: 60))
        #expect(tens[1] == .init(t: Self.noon + 600, avg: 17.0, min: 10, max: 24, count: 60))
    }

    /// Une minute écrite à moitié par un lot se complète au lot suivant :
    /// l'agrégation se recalcule depuis les points bruts, sans état à tenir.
    @Test func uneMinuteCoupeeEntreDeuxLotsSeComplete() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Self.database(folder)

        let first = (0..<3).map { SeriesDatabase.Point(key: "gpu", t: Self.noon + Int64($0) * 10, v: 0.1) }
        try db.insert(first, now: Self.at(Self.noon + 25))
        let second = (3..<6).map { SeriesDatabase.Point(key: "gpu", t: Self.noon + Int64($0) * 10, v: 0.7) }
        try db.insert(second, now: Self.at(Self.noon + 55))

        let minute = db.buckets(key: "gpu", from: Self.noon, to: Self.noon + 60, bucket: 60, now: Self.noon + 2 * 86_400)
        #expect(minute.count == 1)
        #expect(abs((minute.first?.avg ?? 0) - 0.4) < 1e-9)
        #expect(minute.first?.count == 6)
        let ten = db.buckets(key: "gpu", from: Self.noon, to: Self.noon + 600, bucket: 600, now: Self.noon + 30 * 86_400)
        #expect(ten.first?.count == 6)
        #expect(abs((ten.first?.avg ?? 0) - 0.4) < 1e-9)
    }

    // MARK: - Purge

    /// Chaque étage garde sa durée, pas plus : 24 h de bruts, 7 j de
    /// minutes, 90 j de tranches de 10 min. Et la purge des bruts n'efface
    /// rien des étages agrégés.
    @Test func laPurgeRespecteLaDureeDeChaqueEtage() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Self.database(folder)

        // Un point par jour, de J-100 à aujourd'hui, chacun écrit « le jour
        // même » comme le ferait l'app.
        for day in stride(from: 100, through: 0, by: -1) {
            let t = Self.noon - Int64(day) * 86_400
            try db.insert([.init(key: "memoire.swap", t: t, v: Double(day))], now: Self.at(t + 30))
        }
        try db.purge(now: Self.at(Self.noon + 60))

        let stats = try #require(db.stats(for: "memoire.swap"))
        #expect(stats.rows[.raw] == 1, "bruts : seul le point d'aujourd'hui a moins de 24 h")
        #expect(stats.rows[.minute] == 7, "minutes : J-6 à aujourd'hui")
        #expect(stats.rows[.tenmin] == 90, "10 min : J-89 à aujourd'hui")
        #expect(stats.first == Self.noon - 89 * 86_400)
    }

    // MARK: - Base illisible

    /// Un fichier qui n'est pas une base est renommé, octet pour octet, et
    /// une base neuve prend sa place.
    @Test func uneBaseIllisibleEstMiseDeCoteJamaisEffacee() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: url)

        let db = Self.database(folder)
        #expect(db.state == .ready)
        #expect(db.setAside.count == 1)
        let aside = try #require(db.setAside.first)
        #expect(aside.lastPathComponent.hasPrefix("historique.illisible-"))
        #expect(try Data(contentsOf: aside) == garbage, "le fichier mis de côté a changé")

        try db.insert([.init(key: "cpu.total", t: Self.noon, v: 0.5)], now: Self.at(Self.noon + 1))
        #expect(db.stats(for: "cpu.total")?.rows[.raw] == 1)
    }

    /// Une vraie base, abîmée au milieu : `quick_check` la refuse avant toute
    /// écriture, et elle est mise de côté avec son journal.
    @Test func uneBaseAbimeeAuMilieuEstMiseDeCote() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        do {
            let db = Self.database(folder)
            let points = (0..<5000).map { SeriesDatabase.Point(key: "cpu.total", t: Self.noon + Int64($0) * 10, v: 0.25) }
            try db.insert(points, now: Self.at(Self.noon + 50_000))
            db.close()
        }
        var bytes = try Data(contentsOf: url)
        #expect(bytes.count > 4 * 4096)
        for i in (2 * 4096)..<(3 * 4096) { bytes[i] = 0xA5 }
        try bytes.write(to: url)

        let reopened = Self.database(folder)
        #expect(reopened.state == .ready)
        #expect(reopened.setAside.count >= 1)
        #expect(try Data(contentsOf: try #require(reopened.setAside.first)) == bytes)
        #expect(reopened.keys.isEmpty, "la base neuve ne doit rien hériter de l'abîmée")
    }

    /// Une base écrite par un Pulse plus récent : lue, jamais écrite.
    @Test func uneBasePlusRecenteNEstPasEcrite() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let db = Self.database(folder)
            try db.insert([.init(key: "cpu.total", t: Self.noon, v: 0.5)], now: Self.at(Self.noon + 1))
            db.setMeta("schema", "99")
            db.close()
        }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let before = try Data(contentsOf: url)
        let db = Self.database(folder)
        #expect(db.state == .newerSchema(99))
        #expect(!db.isWritable)
        try db.insert([.init(key: "cpu.total", t: Self.noon + 10, v: 0.9)], now: Self.at(Self.noon + 11))
        db.close()
        #expect(try Data(contentsOf: url) == before)
    }

    /// Une base d'avant la colonne `bound` : lue telle quelle en lecture
    /// seule, complétée sans rien perdre à l'ouverture en écriture.
    @Test func uneColonneAjouteeApresCoupNeCassePasLaBase() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        do {
            let old = try SQLiteConnection(path: url.path, readOnly: false)
            try old.exec("""
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                INSERT INTO meta VALUES ('schema', '1');
                CREATE TABLE series (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, label TEXT);
                INSERT INTO series VALUES (1, 'disque.X.libre', 'Ssd 2');
                CREATE TABLE raw (s INTEGER NOT NULL, t INTEGER NOT NULL, v REAL NOT NULL, PRIMARY KEY (s, t)) WITHOUT ROWID;
                INSERT INTO raw VALUES (1, \(Self.noon - 60), 5e11);
                """)
        }
        let reader = SeriesDatabase(url: url, readOnly: true)
        #expect(reader.state == .ready)
        #expect(reader.label("disque.X.libre") == "Ssd 2")
        #expect(reader.bound("disque.X.libre") == nil)

        let writer = Self.database(folder)
        #expect(writer.state == .ready)
        #expect(writer.setAside.isEmpty)
        try writer.insert([.init(key: "disque.X.libre", t: Self.noon, v: 4e11)], bounds: ["disque.X.libre": 2e12],
                          now: Self.at(Self.noon + 1))
        #expect(writer.bound("disque.X.libre") == 2e12)
        let raw = writer.buckets(key: "disque.X.libre", from: Self.noon - 120, to: Self.noon + 1, bucket: 1, now: Self.noon)
        #expect(raw.map(\.avg) == [5e11, 4e11])
    }

    /// Toutes les lignes des trois étages, dans un ordre fixe : de quoi
    /// comparer une base avant et après migration.
    static func allRows(_ url: URL) throws -> [String] {
        let db = try SQLiteConnection(path: url.path, readOnly: true)
        var rows: [String] = []
        for (table, columns) in [("raw", "s, t, v"), ("minute", "s, t, avg, min, max, n"), ("tenmin", "s, t, avg, min, max, n")] {
            guard (try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = '\(table)'") ?? 0) > 0 else { continue }
            let statement = try db.prepare("SELECT \(columns) FROM \(table) ORDER BY s, t")
            let count = Int32(columns.split(separator: ",").count)
            while try statement.step() {
                rows.append(table + ":" + (0..<count).map { statement.text($0) ?? "∅" }.joined(separator: "|"))
            }
        }
        return rows
    }

    static func createV1(_ url: URL) throws {
        let v1 = try SQLiteConnection(path: url.path, readOnly: false)
        try v1.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            INSERT INTO meta VALUES ('schema', '1'), ('creee', '\(noon - 3600)');
            CREATE TABLE series (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, label TEXT, bound REAL);
            INSERT INTO series VALUES (1, 'cpu.total', NULL, NULL), (2, 'disque.X.libre', 'Ssd 2', 2e12);
            CREATE TABLE raw (s INTEGER NOT NULL, t INTEGER NOT NULL, v REAL NOT NULL, PRIMARY KEY (s, t)) WITHOUT ROWID;
            CREATE TABLE minute (s INTEGER NOT NULL, t INTEGER NOT NULL, avg REAL NOT NULL, min REAL NOT NULL,
                                 max REAL NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (s, t)) WITHOUT ROWID;
            CREATE TABLE tenmin (s INTEGER NOT NULL, t INTEGER NOT NULL, avg REAL NOT NULL, min REAL NOT NULL,
                                 max REAL NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (s, t)) WITHOUT ROWID;
            WITH RECURSIVE c(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM c WHERE x < 359)
                INSERT INTO raw SELECT 1 + x % 2, \(noon - 3600) + x * 10, x * 0.001 FROM c;
            WITH RECURSIVE c(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM c WHERE x < 299)
                INSERT INTO minute SELECT 1 + x % 2, \(noon - 18_000) + x * 60, x * 0.5, x * 0.25, x, 6 FROM c;
            WITH RECURSIVE c(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM c WHERE x < 999)
                INSERT INTO tenmin SELECT 1 + x % 2, \(noon - 600_000) + x * 600, x * 1e9, x * 9e8, x * 1.1e9, 60 FROM c;
            """)
    }

    /// Schéma 1 → 2 (clé (s, t) → (t, s), WAL → journal de retour arrière) :
    /// chaque ligne de chaque étage passe à l'identique, rien n'est mis de
    /// côté, et la base répond ensuite normalement.
    @Test func laBaseDuSchema1PasseAuSchema2SansPerdreUneLigne() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        try Self.createV1(url)
        let before = try Self.allRows(url)
        #expect(before.count == 360 + 300 + 1000)

        let db = Self.database(folder)
        #expect(db.state == .ready)
        #expect(db.migratedFrom == 1)
        #expect(db.setAside.isEmpty)
        #expect(db.meta("schema") == "2")
        #expect(!SeriesDatabase.isWAL(url))
        #expect(db.bound("disque.X.libre") == 2e12 && db.label("disque.X.libre") == "Ssd 2")
        db.close()
        #expect(try Self.allRows(url) == before, "une ligne a changé pendant la migration")
        let sql = try SQLiteConnection(path: url.path, readOnly: true)
            .scalarText("SELECT sql FROM sqlite_master WHERE name = 'tenmin'") ?? ""
        #expect(sql.contains("PRIMARY KEY (t, s)"))

        // Et elle sert : un lot s'écrit et s'agrège.
        let again = Self.database(folder)
        #expect(again.migratedFrom == nil)
        try again.insert([.init(key: "cpu.total", t: Self.noon + 5, v: 0.9)], now: Self.at(Self.noon + 10))
        #expect(again.buckets(key: "cpu.total", from: Self.noon, to: Self.noon + 60, bucket: 60,
                              now: Self.noon + 2 * 86_400).first?.avg == 0.9)
    }

    /// La preuve sur une COPIE de la vraie base d'Isma (schéma 1) :
    /// `PULSE_COPIE_BASE=/chemin/copie.sqlite swift test --filter copieBaseReelle`.
    /// Le test recopie encore la copie dans un dossier jetable : le fichier
    /// donné n'est jamais ouvert en écriture.
    @Test func copieBaseReelle() throws {
        guard let path = ProcessInfo.processInfo.environment["PULSE_COPIE_BASE"] else { return }
        #expect(!path.contains("/Library/Application Support/"), "jamais la vraie base")
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.copyItem(atPath: path + suffix, toPath: url.path + suffix)
        }
        // Le journal reporté dans la copie jetable, comme le ferait l'app.
        try SQLiteConnection(path: url.path, readOnly: false).exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let before = try Self.allRows(url)
        let db = SeriesDatabase(url: url, readOnly: false)
        let after = try Self.allRows(url)
        print("copie de la vraie base : schéma \(db.migratedFrom.map(String.init) ?? "déjà 2") → \(db.meta("schema") ?? "?"), "
              + "\(before.count) lignes avant, \(after.count) après, identiques : \(before == after), WAL : \(SeriesDatabase.isWAL(url))")
        #expect(db.state == .ready)
        #expect(db.setAside.isEmpty)
        #expect(after == before)
    }

    /// Le contenu exact d'un dossier : noms et octets de chaque fichier.
    static func contents(_ folder: URL) -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map {
            ($0, (try? Data(contentsOf: folder.appendingPathComponent($0))) ?? Data())
        })
    }

    /// `--probe`, `--snapshot` et `--banc` lisent la base pendant que l'app
    /// l'écrit : pas un octet ne doit bouger dans le dossier, aucun fichier
    /// ne doit naître. En WAL, le simple fait de lire écrivait dans `-shm` —
    /// `verifie.sh` l'a vu le 11/10.
    @Test func lireNEcritRienDansLeDossier() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        do {
            let db = Self.database(folder)
            try db.insert((0..<50).map { .init(key: "cpu.total", t: Self.noon - 600 + Int64($0) * 10, v: 0.4) },
                          now: Self.at(Self.noon))
            db.close()
        }
        #expect(!SeriesDatabase.isWAL(url))
        let before = Self.contents(folder)
        let reader = SeriesDatabase(url: url, readOnly: true)
        #expect(reader.state == .ready)
        let reading = SeriesRecorder.reading(database: reader, keys: ["cpu.total"], range: .hour, now: Self.at(Self.noon))
        #expect(reading.lines[0].buckets.count == 17)   // 490 s de points, tranches de 30 s
        _ = reader.stats(for: "cpu.total")
        _ = HistoryProbe.lines(now: Self.at(Self.noon), url: url)
        reader.close()
        #expect(Self.contents(folder) == before, "un lecteur a écrit dans le dossier")
    }

    /// La base de la première version, née en WAL et tenue ouverte par l'app
    /// en cours : lue sans rien écrire (immuable), puis convertie au
    /// lancement suivant, sans perdre un point.
    @Test func uneBaseEnWALSeLitSansRienEcrireEtSeConvertit() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        do {
            let db = Self.database(folder)
            try db.insert([.init(key: "gpu", t: Self.noon - 100, v: 0.3)], now: Self.at(Self.noon))
            db.close()
        }
        // L'app de la première version : WAL, et un point encore dans le journal.
        var app: SQLiteConnection? = try SQLiteConnection(path: url.path, readOnly: false)
        try app?.exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
        try app?.exec("INSERT INTO raw (s, t, v) SELECT id, \(Self.noon - 50), 0.6 FROM series WHERE key = 'gpu'")
        #expect(SeriesDatabase.isWAL(url))
        let before = Self.contents(folder)
        #expect(before.keys.contains(SeriesDatabase.fileName + "-shm"))

        let reader = SeriesDatabase(url: url, readOnly: true)
        let seen = reader.buckets(key: "gpu", from: Self.noon - 3600, to: Self.noon, bucket: 1, now: Self.noon)
        #expect(seen.map(\.avg) == [0.3], "immuable : le point du journal n'est pas encore visible")
        reader.close()
        #expect(Self.contents(folder) == before, "la lecture a écrit dans le dossier")

        app = nil   // l'app quitte : SQLite reporte le journal dans la base
        let upgraded = Self.database(folder)
        #expect(upgraded.state == .ready)
        #expect(!SeriesDatabase.isWAL(url))
        let all = upgraded.buckets(key: "gpu", from: Self.noon - 3600, to: Self.noon, bucket: 1, now: Self.noon)
        #expect(all.map(\.avg) == [0.3, 0.6])
    }

    /// `--snapshot` et `--probe` : lecture seule, aucune base créée.
    @Test func laLectureSeuleNeCreeRien() {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let db = SeriesDatabase(url: url, readOnly: true)
        #expect(db.state == .missing)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { false })
        recorder.record("cpu.total", 0.5, now: 0)
        recorder.record("cpu.total", 0.6, now: 100)
        recorder.flush()
        let reading = recorder.readingNow(keys: ["cpu.total"], range: .hour)
        #expect(reading.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Migration

    static let legacy = """
    {"version": 1,
     "series": [
       {"t": 1791719400.4, "ram": 0.5, "swap": 1073741824, "cpu": 0.25, "gpu": 0.75},
       {"t": 1791719415.2, "ram": 0.25, "swap": 0, "cpu": 0.5},
       {"t": "illisible", "ram": 0.1},
       {"ram": 0.9}
     ],
     "volumes": {
       "UUID-SSD": [{"t": 1789128000, "free": 900000000000, "freeStrict": 899000000000},
                    {"t": 1791460800, "free": 700000000000},
                    {"t": 1791719400, "free": 650000000000}],
       "UUID-VIDE": []
     },
     "apps": {"2026-10-11": {"com.adobe.PremierePro.26": {"name": "Adobe Premiere Pro 2026", "focus": 3600}}},
     "sessions": []}
    """

    /// Tout ce qui est lisible passe, rien n'est inventé, et `history.json`
    /// ressort identique à l'octet.
    @Test func laMigrationReprendHistoryJsonSansRienPerdre() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("history.json")
        try Data(Self.legacy.utf8).write(to: json)
        let before = try Data(contentsOf: json)
        let db = Self.database(folder)

        let report = try #require(LegacyImport.runIfNeeded(from: json, into: db, now: Self.at(Self.noon)))
        #expect(report.seriesPoints == 2, "deux points lisibles sur quatre")
        #expect(report.diskPoints == 3)
        #expect(report.volumes == 1)
        // 2 × (cpu, mémoire, swap) + 1 gpu + 3 points de disque
        #expect(report.written == 10)
        #expect(try Data(contentsOf: json) == before, "history.json a été modifié")

        // La série d'une heure, au point près, dans l'étage brut.
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        let cpu = db.buckets(key: "cpu.total", from: Self.noon - 3600, to: Self.noon, bucket: 1, now: Self.noon)
        #expect(cpu.map(\.t) == [1_791_719_400, 1_791_719_415])
        #expect(cpu.map(\.avg) == [0.25, 0.5])
        let memory = db.buckets(key: "memoire.utilisee", from: Self.noon - 3600, to: Self.noon, bucket: 1, now: Self.noon)
        #expect(memory.map(\.avg) == [(0.5 * ram).rounded(), (0.25 * ram).rounded()])
        #expect(db.buckets(key: "gpu", from: Self.noon - 3600, to: Self.noon, bucket: 1, now: Self.noon).count == 1,
                "un gpu absent ne devient pas un zéro")

        // Le disque, vieux de 30 jours : dans l'étage des 10 min, et le
        // point de J-3 aussi dans celui des minutes.
        let disk = SeriesCatalog.volumeKey("UUID-SSD")
        let tens = db.buckets(key: disk, from: Self.noon - 90 * 86_400, to: Self.noon + 1, bucket: 600, now: Self.noon)
        #expect(tens.map(\.avg) == [900e9, 700e9, 650e9])
        let minutes = db.buckets(key: disk, from: Self.noon - 7 * 86_400, to: Self.noon + 1, bucket: 60, now: Self.noon)
        #expect(minutes.map(\.avg) == [700e9, 650e9])

        // Une seule fois.
        #expect(LegacyImport.runIfNeeded(from: json, into: db, now: Self.at(Self.noon)) == nil)
        #expect(LegacyImport.stored(in: db)?["etat"] as? String == "importé")
    }

    /// Un relevé vivant a toujours le dernier mot : l'import n'écrase rien.
    @Test func laMigrationNEcrasePasUnReleveVivant() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("history.json")
        try Data(Self.legacy.utf8).write(to: json)
        let db = Self.database(folder)
        try db.insert([.init(key: "cpu.total", t: 1_791_719_400, v: 0.99)], now: Self.at(Self.noon))
        LegacyImport.runIfNeeded(from: json, into: db, now: Self.at(Self.noon))
        let cpu = db.buckets(key: "cpu.total", from: Self.noon - 3600, to: Self.noon, bucket: 1, now: Self.noon)
        #expect(cpu.first?.avg == 0.99)
    }

    /// Un `history.json` qui n'est pas du JSON : rien d'importé, rien de
    /// marqué — l'import se retentera — et le fichier n'est pas touché.
    @Test func unHistoryJsonIllisibleNEstNiImporteNiTouche() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("history.json")
        try Data("{\"series\": [".utf8).write(to: json)
        let db = Self.database(folder)
        #expect(LegacyImport.runIfNeeded(from: json, into: db, now: Self.at(Self.noon)) == nil)
        #expect(db.meta(LegacyImport.metaKey) == nil)
        #expect(try Data(contentsOf: json) == Data("{\"series\": [".utf8))
    }

    /// La preuve sur une COPIE du vrai `history.json` d'Isma, jamais sur
    /// l'original : `PULSE_COPIE_HISTORY=/chemin/de/la/copie.json swift test
    /// --filter copieReelle`. Sans la variable, le test ne fait rien.
    @Test func copieReelle() throws {
        guard let path = ProcessInfo.processInfo.environment["PULSE_COPIE_HISTORY"] else { return }
        let source = URL(fileURLWithPath: path)
        #expect(!path.contains("/Library/Application Support/"), "jamais le vrai fichier")
        let before = try Data(contentsOf: source)
        let (points, read) = try #require(LegacyImport.read(source))
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let db = SeriesDatabase(url: folder.appendingPathComponent(SeriesDatabase.fileName), readOnly: false, now: now)
        let report = try #require(LegacyImport.runIfNeeded(from: source, into: db, now: now))
        #expect(report == LegacyImport.Report(seriesPoints: read.seriesPoints, diskPoints: read.diskPoints,
                                              volumes: read.volumes, written: report.written, fileBytes: read.fileBytes))
        #expect(try Data(contentsOf: source) == before, "la copie a été modifiée")

        // Chaque point lisible se retrouve, à sa valeur, dans l'étage qui
        // couvre son âge.
        let nowT = Int64(now.timeIntervalSince1970)
        var checked = 0, missing: [SeriesDatabase.Point] = []
        for point in points {
            let tier = SeriesDatabase.tier(from: point.t, now: nowT)
            guard point.t >= nowT - SeriesDatabase.Tier.tenmin.retention else { continue }
            let found = db.buckets(key: point.key, from: point.t - (point.t % tier.step), to: point.t + 1,
                                   bucket: tier == .raw ? 1 : tier.step, now: nowT)
            let match = tier == .raw ? found.first(where: { $0.t == point.t }) : found.last
            if let match, abs(match.avg - point.v) <= max(1e-9, abs(point.v) * 1e-12) { checked += 1 } else { missing.append(point) }
        }
        print("copie réelle : \(read.summary) · \(report.written) valeurs écrites · \(checked) retrouvées · \(missing.count) absentes · \(Fmt.bytes(UInt64(read.fileBytes))) lus")
        #expect(missing.isEmpty, "absents : \(missing.prefix(5))")
    }

    /// Une base de démonstration pour regarder le composant avec `--snapshot`
    /// sans toucher à la vraie : `PULSE_DEMO_BASE=/tmp/demo.sqlite swift test
    /// --filter baseDeDemo`, puis `PULSE_HISTORIQUE=/tmp/demo.sqlite
    /// .build/release/Pulse --snapshot x.png --historique`. 90 jours de
    /// journées de montage simulées (nuits éteintes comprises), plus, si
    /// `PULSE_COPIE_HISTORY` est donnée, l'import d'une COPIE de history.json.
    @Test func baseDeDemo() throws {
        guard let path = ProcessInfo.processInfo.environment["PULSE_DEMO_BASE"] else { return }
        #expect(!path.contains("/Library/Application Support/"), "jamais la vraie base")
        let url = URL(fileURLWithPath: path)
        let db = SeriesDatabase(url: url, readOnly: false)
        let now = Int64(Date().timeIntervalSince1970)
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        var points: [SeriesDatabase.Point] = []
        func add(_ t: Int64) {
            let hour = Double((t + 7200) % 86_400) / 3600
            // Mac en veille de 1 h à 8 h : pas de point, un trou.
            guard hour >= 8 || hour < 1 else { return }
            let work = hour >= 9.5 && hour < 19.5 && (t / 86_400) % 7 < 6
            let wave = (sin(Double(t) / 1700) + 1) / 2
            let cpu = work ? 0.18 + 0.5 * wave * wave : 0.05 + 0.06 * wave
            points.append(.init(key: "cpu.total", t: t, v: min(1, cpu)))
            points.append(.init(key: "gpu", t: t, v: work ? 0.25 + 0.5 * wave : 0.03))
            points.append(.init(key: "memoire.utilisee", t: t, v: (work ? 0.62 + 0.25 * wave : 0.42) * ram))
            points.append(.init(key: "memoire.swap", t: t, v: work ? 2e9 + 5e9 * wave : 1.2e9))
            points.append(.init(key: "reseau.reception", t: t, v: work ? 4e5 + 3e6 * wave * wave : 2e4))
            points.append(.init(key: "reseau.envoi", t: t, v: work ? 6e4 + 4e5 * wave : 5e3))
        }
        for t in stride(from: now - 90 * 86_400, to: now - 86_400, by: 600) { add(t) }
        for t in stride(from: now - 86_400, to: now, by: 10) { add(t) }
        let written = try db.importPoints(points, now: Date(timeIntervalSince1970: TimeInterval(now)))
        var imported = "pas de copie"
        if let copy = ProcessInfo.processInfo.environment["PULSE_COPIE_HISTORY"] {
            #expect(!copy.contains("/Library/Application Support/"))
            imported = LegacyImport.runIfNeeded(from: URL(fileURLWithPath: copy), into: db)?.summary ?? "rien"
        }
        db.close()
        print("base de démonstration : \(written) points simulés, import : \(imported) → \(path)")
    }

    // MARK: - Plages

    /// Les cinq plages : la bonne largeur de tranche, le bon étage, un début
    /// aligné sur l'heure locale, et rien au-delà de maintenant.
    @Test func chaquePlageLitSesTranches() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Self.database(folder)
        // 100 jours d'un point toutes les 10 min (la valeur = l'heure UTC),
        // plus les 24 dernières heures toutes les 10 s.
        var points: [SeriesDatabase.Point] = []
        for t in stride(from: Self.noon - 100 * 86_400, to: Self.noon - 86_400, by: 600) {
            points.append(.init(key: "cpu.total", t: t, v: Double((t % 86_400) / 3600) / 24))
        }
        for t in stride(from: Self.noon - 86_400, to: Self.noon, by: 10) {
            points.append(.init(key: "cpu.total", t: t, v: Double((t % 86_400) / 3600) / 24))
        }
        _ = try db.importPoints(points, now: Self.at(Self.noon))

        let paris = TimeZone(identifier: "Europe/Paris")!   // UTC+2 le 11/10
        for range in HistoryRange.allCases {
            let reading = SeriesRecorder.reading(database: db, keys: ["cpu.total"], range: range,
                                                 now: Self.at(Self.noon), timeZone: paris)
            let buckets = try #require(reading.lines.first?.buckets)
            #expect(reading.bucket == Int64(range.bucket))
            #expect((reading.from + 7200) % reading.bucket == 0, "\(range.rawValue) : début non aligné sur l'heure locale")
            #expect(reading.from <= Self.noon - Int64(range.seconds))
            #expect(reading.from > Self.noon - Int64(range.seconds) - reading.bucket)
            #expect(buckets.allSatisfy { $0.t >= reading.from && $0.t < reading.to })
            #expect(buckets.count >= Int(range.seconds / range.bucket) - 1, "\(range.rawValue) : \(buckets.count) tranches")
            #expect(buckets.count <= Int(range.seconds / range.bucket) + 1)
            #expect(reading.bound == 1 && reading.scaleTop == 1)
        }

        // 24 h : des tranches de 10 min, chacune de 60 points bruts.
        let day = SeriesRecorder.reading(database: db, keys: ["cpu.total"], range: .day,
                                         now: Self.at(Self.noon), timeZone: paris)
        #expect(day.lines[0].buckets.dropFirst().allSatisfy { $0.count == 60 })
        // 90 j : des tranches de 12 h, de minuit à midi heure de Paris, soit
        // 22:00 → 10:00 UTC : la moyenne des heures 22, 23, 0…9.
        let quarter = SeriesRecorder.reading(database: db, keys: ["cpu.total"], range: .quarter,
                                             now: Self.at(Self.noon), timeZone: paris)
        let night = try #require(quarter.lines[0].buckets.first { ($0.t + 7200) % 86_400 == 0 })
        #expect(abs(night.avg - (22.0 + 23 + 0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9) / 12 / 24) < 1e-9)
        #expect(night.min == 0 && abs(night.max - 23.0 / 24) < 1e-12)
    }

    /// Les points pas encore écrits comptent : le graphique d'une heure finit
    /// maintenant.
    @Test func lesPointsPasEncoreEcritsSontLus() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Self.database(folder)
        try db.insert([.init(key: "gpu", t: Self.noon - 40, v: 0.2)], now: Self.at(Self.noon - 30))
        let reading = SeriesRecorder.reading(database: db,
                                             unwritten: [.init(key: "gpu", t: Self.noon - 31, v: 0.4),
                                                         .init(key: "gpu", t: Self.noon - 10, v: 0.9),
                                                         .init(key: "autre", t: Self.noon - 10, v: 5)],
                                             keys: ["gpu"], range: .hour, now: Self.at(Self.noon),
                                             timeZone: TimeZone(identifier: "UTC")!)
        let buckets = reading.lines[0].buckets
        #expect(buckets.count == 2)
        #expect(buckets[0].count == 2 && abs(buckets[0].avg - 0.3) < 1e-12)
        #expect(buckets[1] == .init(t: Self.noon - 30, avg: 0.9, min: 0.9, max: 0.9, count: 1))
    }

    /// Une série sans dénominateur (le swap, le débit) n'a pas d'échelle
    /// réelle : la courbe se cale sur son maximum observé.
    @Test func uneSerieSansDenominateurSeCaleSurSonMaximum() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = Self.database(folder)
        try db.insert([.init(key: "memoire.swap", t: Self.noon - 100, v: 2e9),
                       .init(key: "memoire.swap", t: Self.noon - 50, v: 7e9)], now: Self.at(Self.noon))
        let reading = SeriesRecorder.reading(database: db, keys: ["memoire.swap"], range: .hour, now: Self.at(Self.noon))
        #expect(reading.bound == nil)
        #expect(reading.scaleTop == 7e9)
        let memory = SeriesRecorder.reading(database: db, keys: ["memoire.utilisee"], range: .hour, now: Self.at(Self.noon))
        #expect(memory.bound == Double(ProcessInfo.processInfo.physicalMemory))
    }

    // MARK: - Enregistreur

    /// Relevés → fenêtres de 10 s moyennées → lot écrit. Simulé : 2 min de
    /// relevés toutes les 5 s, comme le Sampler panneau fermé.
    @Test func lEnregistreurMoyenneChaqueFenetreDeDixSecondes() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        for i in 0..<24 {
            let now = Double(Self.noon) + Double(i) * 5
            recorder.record("cpu.total", i % 2 == 0 ? 0.2 : 0.4, now: now)
        }
        recorder.flush(timeout: 5, now: Double(Self.noon) + 120)
        let db = SeriesDatabase(url: url, readOnly: true)
        let raw = db.buckets(key: "cpu.total", from: Self.noon, to: Self.noon + 200, bucket: 1, now: Self.noon + 200)
        #expect(raw.count == 12, "\(raw.count) points pour 2 min")
        #expect(raw.allSatisfy { abs($0.avg - 0.3) < 1e-12 })
        #expect(zip(raw, raw.dropFirst()).allSatisfy { $1.t - $0.t == 10 })
    }

    /// Une fenêtre ouverte avant une mise en veille et fermée au réveil garde
    /// l'heure de ses relevés : les valeurs de 23 h ne sont pas datées de 8 h.
    @Test func uneVeilleNeDecalePasLesPoints() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        let evening = Double(Self.noon)
        recorder.record("cpu.total", 0.9, now: evening)
        recorder.record("cpu.total", 0.7, now: evening + 5)
        // Neuf heures de veille, puis le premier relevé du réveil.
        recorder.record("cpu.total", 0.1, now: evening + 9 * 3600)
        recorder.flush(timeout: 5, now: evening + 9 * 3600 + 1)
        let db = SeriesDatabase(url: url, readOnly: true)
        let raw = db.buckets(key: "cpu.total", from: Self.noon - 10, to: Self.noon + 10 * 3600, bucket: 1,
                             now: Self.noon + 9 * 3600)
        #expect(raw.map(\.t) == [Self.noon + 5, Self.noon + 9 * 3600])
        #expect(abs(raw[0].avg - 0.8) < 1e-12)
    }

    /// Une série déclarée par un module emporte sa déclaration dans la base :
    /// `--probe`, un autre processus où le module n'a rien déclaré, y lit
    /// « 62 °C » et non « 62 ».
    @Test func uneSerieDeclareeGardeSonUniteDansLaBase() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let key = "essai.temperature.\(UUID().uuidString)"
        History.declare(SeriesInfo(key, "Processeur, température", .celsius, bound: 110))
        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        recorder.record(key, 62, now: Double(Self.noon))
        recorder.flush(timeout: 5, now: Double(Self.noon) + 10)
        let db = SeriesDatabase(url: url, readOnly: true)
        #expect(db.unit(key) == .celsius)
        #expect(db.label(key) == "Processeur, température")
        #expect(db.bound(key) == 110)
        let stored = SeriesCatalog.info("autre.\(key)", label: db.label(key), bound: db.bound(key), unit: db.unit(key))
        #expect(stored.unit.format(62) == "62\u{00A0}°C")
    }

    /// `--probe` imprime chaque chiffre en entier, même long : la colonne
    /// tronquait « 4671 tr/min » en « 4671 tr/ » (relevé sur la vraie base,
    /// 11/10 05:46).
    @Test func leProbeNeTronqueAucunChiffre() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let key = "essai.ventilateurs.\(UUID().uuidString.prefix(4))"
        History.declare(SeriesInfo(key, "Ventilateurs", .rpm, bound: 5563))
        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        recorder.record(key, 4493, now: Double(Self.noon) - 20)
        recorder.record(key, 4671, now: Double(Self.noon) - 5)
        recorder.flush(timeout: 5, now: Double(Self.noon))
        let text = HistoryProbe.lines(now: Self.at(Self.noon + 1), url: url).joined(separator: "\n")
        #expect(text.contains("(5563\u{00A0}tr/min)"), "échelle tronquée :\n\(text)")
        #expect(text.contains("4582\u{00A0}tr/min / 4671\u{00A0}tr/min"), "moyenne / pointe tronquées :\n\(text)")
    }

    /// Les vrais capteurs, branchés comme dans le Sampler : le premier relevé
    /// du processeur (des zéros de référence) n'est pas écrit, un volume
    /// garde son nom et sa capacité.
    @Test func lesSeriesDeBaseSontReleveesDepuisLesVraisCapteurs() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        let cpu = CPUMonitor()
        let start = Date().timeIntervalSince1970
        // Fenêtre 1 : le relevé de référence du processeur, seul.
        recorder.record(cpu: cpu.sample(), memory: MemoryMonitor.sample(), gpu: GPUMonitor.utilization())
        recorder.flush(timeout: 5, now: start)
        Thread.sleep(forTimeInterval: 0.3)
        // Fenêtre 2 : un vrai relevé, le débit et les volumes.
        recorder.record(cpu: cpu.sample(), memory: MemoryMonitor.sample(), gpu: nil, now: start + 10)
        recorder.record(network: NetworkSample(connected: true, rxRate: 2000, txRate: 500), now: start + 10)
        let volumes = DiskMonitor.volumes()
        recorder.record(volumes: volumes, now: start + 10)
        recorder.flush(timeout: 5, now: start + 10)

        let db = SeriesDatabase(url: url, readOnly: true)
        let now = Int64(start) + 11
        func raw(_ key: String) -> [SeriesDatabase.Bucket] {
            db.buckets(key: key, from: Int64(start) - 1, to: now + 1, bucket: 1, now: now)
        }
        #expect(raw("cpu.total").count == 1, "le relevé de référence (zéros) a été écrit")
        #expect(raw("cpu.total").first?.t == Int64((start + 10).rounded()))
        #expect((raw("cpu.total").first?.avg ?? 0) > 0)
        #expect(raw("memoire.utilisee").count == 2)
        #expect((raw("memoire.utilisee").first?.avg ?? 0) > 1e9)
        #expect(raw("reseau.reception").first?.avg == 2000)
        if let root = volumes.first {
            let key = SeriesCatalog.volumeKey(root.historyKey)
            #expect(raw(key).first?.avg == Double(root.available))
            #expect(db.label(key) == root.name)
            #expect(db.bound(key) == Double(root.total))
        }
    }

    // MARK: - Taille et coût

    /// Une base de 90 jours pleins pour ces séries, en régime établi :
    /// remplie directement en SQL dans l'ordre où l'app écrit — le temps,
    /// puis la série —, puis un jour de plus et la vraie purge. Les volumes
    /// (`disque.<uuid>.libre`) sont relevés toutes les 2 min, tout le reste
    /// toutes les 10 s ; octets entiers pour la mémoire, le réseau et les
    /// volumes, réels ailleurs (températures, parts, débits moyennés).
    static func baseDeQuatreVingtDixJours(_ keys: [String], dans folder: URL,
                                          now: Int64) throws -> (url: URL, octets: Int) {
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        do {
            let db = SeriesDatabase(url: url, readOnly: false)
            try db.insert(keys.map { .init(key: $0, t: now - 91 * 86_400, v: 0) })
            db.close()
        }

        let fill = try SQLiteConnection(path: url.path, readOnly: false)
        try fill.exec("CREATE TEMP TABLE plan (s INTEGER, bytes INTEGER, every INTEGER)")
        for (index, key) in keys.enumerated() {
            let volume = key.hasPrefix("disque.") && key.hasSuffix(".libre")
            let bytes = (key.hasPrefix("memoire") && key != "memoire.pression") || volume
                || key.hasPrefix("reseau")
            // Les volumes sont relevés toutes les 2 min panneau fermé.
            try fill.exec("INSERT INTO plan VALUES (\(index + 1), \(bytes ? 1 : 0), \(volume ? 12 : 1))")
        }
        // Des octets entiers comme l'app les écrit, ou des parts de 1.
        let value = "CASE WHEN bytes THEN abs(random() % 30000000000) ELSE abs(random() % 1000000) / 1000000.0 END"
        try fill.exec("BEGIN")
        // Un jour de plus que la conservation : la purge aura de quoi faire.
        for (table, step, count) in [("raw", 10, 8640 * 2), ("minute", 60, 10_080 + 1440), ("tenmin", 600, 12_960 + 144)] {
            let columns = table == "raw" ? "s, t, v" : "s, t, avg, min, max, n"
            let values = table == "raw" ? value : "\(value), \(value), \(value), 6"
            // Un volume relevé toutes les 2 min remplit chaque tranche de
            // 10 min, mais une minute sur deux seulement, un brut sur douze.
            let cadence = table == "tenmin" ? "" : (table == "raw" ? "WHERE x % every = 0" : "WHERE every = 1 OR x % 2 = 0")
            try fill.exec("""
                WITH RECURSIVE c(x) AS (SELECT 0 UNION ALL SELECT x + 1 FROM c WHERE x < \(count - 1))
                INSERT OR REPLACE INTO \(table) (\(columns))
                SELECT s, \(now) - (\(count) - x) * \(step), \(values) FROM c, plan \(cadence) ORDER BY x, s
                """)
        }
        try fill.exec("COMMIT")

        let db = SeriesDatabase(url: url, readOnly: false)
        try db.purge(now: Self.at(now))
        db.close()
        return (url, Int(db.fileBytes.main + db.fileBytes.wal))
    }

    /// 19-suivis : TOUTES les séries que Pulse déclare, au pire — chaque
    /// série de module relevée toutes les 10 s, quand l'énergie ne l'est que
    /// toutes les 5 min panneau fermé et les capteurs seulement si la barre
    /// les montre — avec les débits disque (lecture, écriture) et trois
    /// volumes : sous les 50 Mo visés à 90 jours, et la place qui reste.
    @Test func toutesLesSeriesTiennentSousCinquanteMo() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Int64(Date().timeIntervalSince1970)
        let builtIn = SeriesCatalog.builtIn.map(\.key)
        let volumes = ["A", "B", "C"].map { SeriesCatalog.volumeKey("VOLUME-\($0)") }
        let sensors = SensorStore.historyKeys
        let modules = [sensors.cpu, sensors.gpu, sensors.fans, sensors.power]
            + PowerSampler.series.map(\.key)
            + [CalibrationSeries.busiestOther, DiskActivity.historyKeys.read, DiskActivity.historyKeys.write]
        let (_, size) = try Self.baseDeQuatreVingtDixJours(builtIn + modules + volumes, dans: folder, now: now)
        let perSeries = Double(size) / Double(builtIn.count + modules.count)
        print("90 jours, \(builtIn.count) séries de base + \(modules.count) de modules (débits disque compris) "
              + "+ \(volumes.count) volumes : \(Fmt.bytes(UInt64(size))) — \(Fmt.bytes(perSeries)) par série, "
              + "place pour \(Int((50e6 - Double(size)) / perSeries)) séries de plus sous 50 Mo")
        #expect(modules.count == 9)
        #expect(size < 50_000_000)
    }

    /// 90 jours pleins des 14 séries de base et de trois volumes, en régime
    /// établi : sous 50 Mo. Remplissage direct en SQL, dans l'ordre où l'app
    /// écrit — le temps, puis la série — : les pages se remplissent comme en
    /// vrai (90 % mesurés, contre 55 % série par série). Puis un jour de plus
    /// et la vraie purge, pour compter aussi les pages libérées qui attendent
    /// d'être reprises.
    @Test func quatreVingtDixJoursTiennentSousCinquanteMo() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Int64(Date().timeIntervalSince1970)
        let builtIn = SeriesCatalog.builtIn.map(\.key)
        let volumes = ["A", "B", "C"].map { SeriesCatalog.volumeKey("VOLUME-\($0)") }
        let (url, size) = try Self.baseDeQuatreVingtDixJours(builtIn + volumes, dans: folder, now: now)
        let perSeries = Double(size) / Double(builtIn.count)
        print("90 jours, \(builtIn.count) séries + \(volumes.count) volumes : \(Fmt.bytes(UInt64(size))) — "
              + "\(Fmt.bytes(perSeries)) par série relevée toutes les 10 s, "
              + "place pour \(Int((50e6 - Double(size)) / perSeries)) séries de modules sous 50 Mo")
        #expect(size < 50_000_000)

        // L'ouverture au lancement : `quick_check` lit chaque page, une fois.
        let openStart = Self.threadCPUTime()
        let opened = SeriesDatabase(url: url, readOnly: false)
        let openSpent = Self.threadCPUTime() - openStart
        #expect(opened.state == .ready)
        opened.close()
        print("ouverture d'une base de 90 jours (quick_check compris) : \(Int((openSpent * 1000).rounded())) ms de CPU, une fois par lancement")
        #expect(openSpent < 1)

        // Le prix de la clé (t, s) : lire UNE série parcourt toutes les autres.
        let reader = SeriesDatabase(url: url, readOnly: true)
        var timings: [String] = []
        for range in HistoryRange.allCases {
            let start = Self.threadCPUTime()
            let reading = SeriesRecorder.reading(database: reader, keys: ["cpu.total"], range: range,
                                                 now: Self.at(now))
            let spent = Self.threadCPUTime() - start
            timings.append("\(range.rawValue) \(Int((spent * 1000).rounded())) ms (\(reading.lines[0].buckets.count) tranches)")
            #expect(spent < 0.5, "\(range.rawValue) : \(spent) s pour lire une série")
        }
        print("lire cpu.total sur une base pleine : " + timings.joined(separator: " · "))
    }

    /// Le coût de l'enregistrement en régime établi, compté par
    /// l'enregistreur lui-même (temps CPU des fils qui travaillent) : une
    /// heure simulée — 720 relevés du Sampler, 1800 relevés réseau, 60 lots
    /// écrits, agrégés et purgés — sur une base qui porte déjà 24 h de
    /// points. Budget : 0,05 % d'un cœur, soit 1,8 s par heure.
    @Test func uneHeureDEnregistrementCouteMoinsDeCinqDixMillemesDUnCoeur() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let keys = SeriesCatalog.builtIn.map(\.key)
        do {
            // 24 h déjà là : les arbres B ont leur taille de croisière.
            let db = SeriesDatabase(url: url, readOnly: false, now: Self.at(Self.noon))
            var warm: [SeriesDatabase.Point] = []
            for t in stride(from: Self.noon - 86_400, to: Self.noon, by: 10) {
                for key in keys { warm.append(.init(key: key, t: t, v: Double(t % 97) / 97)) }
            }
            _ = try db.importPoints(warm, now: Self.at(Self.noon))
            db.close()
        }

        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        let start = Double(Self.noon)
        let writtenBefore = Self.bytesWrittenByThisProcess()
        for second in 0..<3600 {
            let now = start + Double(second)
            if second % 5 == 0 {
                recorder.record(keys.map { ($0, Double((second / 5) % 89) / 89) }, now: now)
            }
            if second % 2 == 0 {
                recorder.record([("reseau.envoi", 1e5), ("reseau.reception", 2e6)], now: now)
            }
        }
        recorder.flush(timeout: 30, now: start + 3600)
        let spent = recorder.cpuSpent
        let share = spent / 3600
        // Octets réellement écrits sur le disque par le processus (journal
        // WAL et reports dans la base) : l'usure du SSD et l'énergie, que le
        // temps CPU ne dit pas. Les autres suites ne touchent pas au disque.
        let written = Self.bytesWrittenByThisProcess() - writtenBefore
        print("une heure d'enregistrement : \(String(format: "%.1f", spent * 1000)) ms de CPU, soit "
              + "\(String(format: "%.4f", share * 100)) % d'un cœur · \(Fmt.bytes(UInt64(written))) écrits, "
              + "soit \(Fmt.bytes(UInt64(written) * 24)) par jour")
        #expect(share < 0.0005)

        // Et tout est là : 360 fenêtres de 10 s sur l'heure.
        let db = SeriesDatabase(url: url, readOnly: true)
        let raw = db.buckets(key: "cpu.total", from: Self.noon, to: Self.noon + 3601, bucket: 1, now: Self.noon + 3600)
        #expect(raw.count == 360)
    }
}

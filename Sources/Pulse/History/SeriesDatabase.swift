import Foundation
import SQLite3

/// La base des séries temporelles : `historique.sqlite`, à côté de
/// `history.json` dans Application Support/Pulse.
///
/// Trois étages, comme les graphes d'iStat Menus :
///
/// | étage    | pas    | gardé | sert les plages |
/// |----------|--------|-------|-----------------|
/// | `raw`    | 10 s   | 24 h  | 1 h, 24 h       |
/// | `minute` | 1 min  | 7 j   | 7 j             |
/// | `tenmin` | 10 min | 90 j  | 30 j, 90 j      |
///
/// Les étages agrégés gardent la moyenne, le minimum, le maximum et le nombre
/// de points bruts : une pointe de 100 % d'un après-midi reste visible dans la
/// tranche de douze heures qui la contient, au lieu de se fondre dans la
/// moyenne.
///
/// L'agrégation est SANS ÉTAT : après chaque lot, les tranches touchées par le
/// lot sont recalculées depuis l'étage du dessous. Une minute écrite à moitié
/// se complète au lot suivant ; un redémarrage, une veille, un lot rejoué ne
/// laissent jamais de tranche fausse. Rien à reprendre, pas de « filigrane » à
/// garder juste.
///
/// Clé primaire (t, s) — le temps d'abord —, depuis le schéma 2. En (s, t),
/// chaque série avait ses propres pages : un lot salissait au moins une page
/// par série et par étage, et la base écrivait 16,1 Mo par heure sur le SSD.
/// En (t, s), un lot s'ajoute à la fin, toutes séries mêlées, sur quelques
/// pages ; la purge retire le début, des pages entières : 2,9 Mo par heure.
/// Le prix : lire UNE série parcourt les lignes de toutes — 14 ms pour 90
/// jours sur une base pleine, sur la file de l'historique.
///
/// Pas sûre entre fils : `SeriesRecorder` ne la touche que depuis sa file.
final class SeriesDatabase {
    struct Point: Equatable {
        var key: String
        var t: Int64
        var v: Double
    }

    /// Une tranche de lecture.
    struct Bucket: Equatable {
        /// Début de la tranche, secondes Unix.
        var t: Int64
        var avg: Double
        var min: Double
        var max: Double
        /// Nombre de points bruts (10 s) couverts.
        var count: Int64
    }

    enum Tier: String, CaseIterable {
        case raw, minute, tenmin

        /// Durée de conservation.
        var retention: Int64 {
            switch self {
            case .raw:    return 86_400
            case .minute: return 7 * 86_400
            case .tenmin: return 90 * 86_400
            }
        }

        var step: Int64 {
            switch self {
            case .raw:    return 10
            case .minute: return 60
            case .tenmin: return 600
            }
        }

        var label: String {
            switch self {
            case .raw:    return "bruts 10 s"
            case .minute: return "minutes"
            case .tenmin: return "10 min"
            }
        }
    }

    enum State: Equatable {
        /// Ouverte, lisible et — hors lecture seule — inscriptible.
        case ready
        /// Lecture seule demandée et aucun fichier : rien à lire, rien créé.
        case missing
        /// Écrite par un Pulse plus récent : lue, jamais écrite.
        case newerSchema(Int)
        /// Ni lisible ni remplaçable. Le message dit pourquoi.
        case unavailable(String)
    }

    struct SeriesStats {
        var key: String
        var label: String?
        var rows: [Tier: Int64]
        var first: Int64?
        var last: Int64?
        var lastValue: Double?
    }

    /// 1 : clé (s, t), journal WAL (11/10, 05:08). 2 : clé (t, s), journal de
    /// retour arrière.
    static let schemaVersion = 2
    static let fileName = "historique.sqlite"

    let url: URL
    let readOnly: Bool
    private(set) var state: State = .missing
    /// Fichiers mis de côté pendant cette ouverture : la base illisible n'est
    /// jamais effacée, elle est renommée et `--probe` le dit.
    private(set) var setAside: [URL] = []
    private var connection: SQLiteConnection?
    private var ids: [String: Int64] = [:]
    private var labels: [String: String] = [:]
    private var bounds: [String: Double] = [:]
    private var units: [String: SeriesUnit] = [:]

    var isWritable: Bool { state == .ready && !readOnly && connection != nil }

    init(url: URL, readOnly: Bool, now: Date = Date()) {
        self.url = url
        self.readOnly = readOnly
        open(now: now)
    }

    // MARK: - Ouverture

    private func open(now: Date) {
        let fm = FileManager.default
        if readOnly {
            guard fm.fileExists(atPath: url.path) else { state = .missing; return }
            do {
                // Une base encore en WAL se lit « immuable » : sans verrou ni
                // fichier -shm, donc sans rien écrire — au prix des points
                // du journal pas encore reportés dans la base.
                let db = try SQLiteConnection(path: url.path, readOnly: true,
                                              immutable: Self.isWAL(url))
                connection = db
                try loadSeries(upgrade: false)
                state = try checkVersion(db)
            } catch {
                connection = nil
                state = .unavailable("\(error)")
            }
            return
        }

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            do {
                let db = try SQLiteConnection(path: url.path, readOnly: false)
                // `quick_check` lit chaque page : quelques dizaines de ms, une
                // fois au lancement, sur la file de l'historique. C'est le prix
                // pour découvrir une base abîmée AVANT d'écrire dedans.
                let verdict = try db.scalarText("PRAGMA quick_check(1)")
                guard verdict == "ok" else {
                    throw SQLiteError(code: SQLITE_CORRUPT, message: "quick_check : \(verdict ?? "rien")")
                }
                let version = try Self.storedVersion(db)
                if let version, version > Self.schemaVersion {
                    // Une base plus récente n'est pas abîmée : elle ne sera
                    // jamais mise de côté, même si ce Pulse la lit mal.
                    connection = db
                    try? loadSeries(upgrade: false)
                    state = .newerSchema(version)
                    return
                }
                connection = db
            } catch {
                connection = nil
                // Une base tenue par un autre processus au-delà de 2 s
                // (SQLITE_BUSY), un disque qui renâcle, la mémoire : rien ne
                // dit qu'elle est abîmée. On n'y touche pas, rien n'est écrit
                // cette fois, l'enregistreur rouvrira au lot suivant. Avant
                // (17-audit-code), TOUTE erreur la mettait de côté — une base
                // saine renommée sous les pieds de l'app qui l'écrivait, par
                // exemple par une seconde instance au lancement.
                guard (error as? SQLiteError)?.isCorruption == true else {
                    state = .unavailable("base momentanément illisible, laissée telle quelle : \(error)")
                    return
                }
                // Abîmée : mise de côté, puis base neuve. Si le fichier ne
                // peut même pas être déplacé, on n'écrit RIEN : écrire
                // par-dessus serait l'effacer.
                guard setAsideFiles(reason: "\(error)", now: now) else {
                    state = .unavailable("base illisible et impossible à mettre de côté : \(error)")
                    return
                }
            }
        }

        do {
            if connection == nil {
                connection = try SQLiteConnection(path: url.path, readOnly: false)
            }
            try configure()
            try loadSeries(upgrade: true)
            state = .ready
        } catch {
            connection = nil
            state = .unavailable("\(error)")
        }
    }

    private static func storedVersion(_ db: SQLiteConnection) throws -> Int? {
        let hasMeta = try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'") ?? 0
        guard hasMeta > 0 else { return nil }
        return (try db.scalarText("SELECT value FROM meta WHERE key = 'schema'")).flatMap { Int($0) }
    }

    /// L'en-tête SQLite dit le mode du journal : octet 18 à 2 pour WAL.
    static func isWAL(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2
    }

    private func checkVersion(_ db: SQLiteConnection) throws -> State {
        if let version = try Self.storedVersion(db), version > Self.schemaVersion { return .newerSchema(version) }
        return .ready
    }

    /// Journal de retour arrière (`DELETE`), pas WAL. En WAL, un lecteur
    /// d'un autre processus — `--probe`, `--snapshot`, `--banc` — écrit dans
    /// le fichier `-shm` rien qu'en lisant : `verifie.sh` l'a vu, une écriture
    /// dans les données d'Isma malgré la persistance coupée. En journal de
    /// retour arrière, un lecteur ne pose que des verrous : aucun octet écrit.
    /// L'écrivain attend au plus 2 s qu'un lecteur ait fini (`busy_timeout`),
    /// un lot toutes les 5 min. `synchronous = FULL` : une coupure de courant
    /// peut coûter le dernier lot, jamais l'intégrité de la base.
    ///
    /// Une base née en WAL (la première version, 11/10) est convertie ici ;
    /// si un lecteur la tient à cet instant, la conversion attend le
    /// lancement suivant, sans rien empêcher d'autre.
    private func configure() throws {
        guard let db = connection else { return }
        try? db.exec("PRAGMA journal_mode = DELETE")
        try db.exec("""
            PRAGMA synchronous = FULL;
            PRAGMA cache_size = -512;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS series (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, label TEXT,
                                               bound REAL, unit TEXT);
            """)
        // Échouée (un lecteur tenait la base au-delà de 2 s), la migration
        // est annulée en bloc et se retente au lancement suivant ; d'ici là
        // les requêtes, qui ne dépendent pas de l'ordre de la clé, servent.
        if try Self.storedVersion(db) == 1 { try? migrateToTimeFirst() }
        try db.exec("""
            \(Self.tableSQL("raw", columns: "v REAL NOT NULL", ifNotExists: true));
            \(Self.tableSQL("minute", columns: Self.aggregateColumns, ifNotExists: true));
            \(Self.tableSQL("tenmin", columns: Self.aggregateColumns, ifNotExists: true));
            INSERT OR IGNORE INTO meta (key, value) VALUES ('schema', '\(Self.schemaVersion)');
            """)
        if meta("creee") == nil { setMeta("creee", String(Int64(Date().timeIntervalSince1970))) }
    }

    private static let aggregateColumns = "avg REAL NOT NULL, min REAL NOT NULL, max REAL NOT NULL, n INTEGER NOT NULL"

    private static func tableSQL(_ name: String, columns: String, ifNotExists: Bool) -> String {
        "CREATE TABLE \(ifNotExists ? "IF NOT EXISTS " : "")\(name) (s INTEGER NOT NULL, t INTEGER NOT NULL, "
            + "\(columns), PRIMARY KEY (t, s)) WITHOUT ROWID"
    }

    /// Schéma 1 → 2 : la clé (s, t) devient (t, s). Chaque étage est recopié
    /// ligne pour ligne dans une table neuve, puis l'ancienne s'efface et la
    /// neuve prend son nom — le tout en UNE transaction : soit la base est
    /// entièrement au schéma 2, soit elle reste intacte au schéma 1.
    private func migrateToTimeFirst() throws {
        guard let db = connection else { return }
        try db.transaction {
            for (table, columns, names) in [("raw", "v REAL NOT NULL", "s, t, v"),
                                            ("minute", Self.aggregateColumns, "s, t, avg, min, max, n"),
                                            ("tenmin", Self.aggregateColumns, "s, t, avg, min, max, n")] {
                let exists = try db.scalarInt(
                    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'") ?? 0
                guard exists > 0 else { continue }
                try db.exec("""
                    DROP TABLE IF EXISTS \(table)_v2;
                    \(Self.tableSQL("\(table)_v2", columns: columns, ifNotExists: false));
                    INSERT INTO \(table)_v2 (\(names)) SELECT \(names) FROM \(table) ORDER BY t, s;
                    DROP TABLE \(table);
                    ALTER TABLE \(table)_v2 RENAME TO \(table);
                    """)
            }
            try db.exec("UPDATE meta SET value = '\(Self.schemaVersion)' WHERE key = 'schema'")
        }
        migratedFrom = 1
    }

    /// Le schéma d'où cette ouverture a migré la base, pour les tests et
    /// `--probe`.
    private(set) var migratedFrom: Int?

    /// `upgrade` : ajouter les colonnes venues après coup. Jamais en lecture
    /// seule, jamais sur la base d'un Pulse plus récent.
    private func loadSeries(upgrade: Bool) throws {
        guard let db = connection else { return }
        let hasSeries = try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'series'") ?? 0
        guard hasSeries > 0 else { return }
        // Une colonne ajoutée après coup se lit si elle est là, et son
        // absence n'empêche pas de lire le reste (règle dure n° 2, côté base).
        var columns: Set<String> = []
        let info = try db.prepare("PRAGMA table_info(series)")
        while try info.step() { if let name = info.text(1) { columns.insert(name) } }
        for (column, type) in [("bound", "REAL"), ("unit", "TEXT")] where !columns.contains(column) && upgrade {
            try db.exec("ALTER TABLE series ADD COLUMN \(column) \(type)")
            columns.insert(column)
        }
        let statement = try db.prepare("SELECT id, key, label, \(columns.contains("bound") ? "bound" : "NULL"), "
                                       + "\(columns.contains("unit") ? "unit" : "NULL") FROM series")
        while try statement.step() {
            guard let key = statement.text(1) else { continue }
            ids[key] = statement.int64(0)
            if let label = statement.text(2) { labels[key] = label }
            if !statement.isNull(3) { bounds[key] = statement.double(3) }
            if let unit = statement.text(4).flatMap(SeriesUnit.init(rawValue:)) { units[key] = unit }
        }
    }

    /// Renomme la base illisible — et son journal, qui peut contenir des
    /// points validés — en `historique.illisible-<date>.sqlite`. Jamais
    /// d'effacement, jamais d'écrasement d'une mise de côté précédente.
    private func setAsideFiles(reason: String, now: Date) -> Bool {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = url.deletingLastPathComponent()
        var target = folder.appendingPathComponent("historique.illisible-\(formatter.string(from: now)).sqlite")
        var attempt = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("historique.illisible-\(formatter.string(from: now))-\(attempt).sqlite")
            attempt += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            return false
        }
        setAside.append(target)
        // Le journal suit la base : il peut porter la seule copie d'un lot.
        for suffix in ["-journal", "-wal", "-shm"] {
            let companion = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: companion.path) else { continue }
            let moved = URL(fileURLWithPath: target.path + suffix)
            if (try? fm.moveItem(at: companion, to: moved)) != nil { setAside.append(moved) }
        }
        let note = folder.appendingPathComponent(target.lastPathComponent + ".txt")
        try? "Mise de côté par Pulse le \(now) : \(reason)\n".write(to: note, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Métadonnées

    func meta(_ key: String) -> String? {
        guard let db = connection, let statement = try? db.prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
        statement.bind(1, key)
        guard (try? statement.step()) == true else { return nil }
        return statement.text(0)
    }

    func setMeta(_ key: String, _ value: String) {
        guard isWritableOrConfiguring, let db = connection,
              let statement = try? db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)") else { return }
        statement.bind(1, key)
        statement.bind(2, value)
        _ = try? statement.step()
    }

    /// `configure` écrit la date de création avant que l'état passe à `.ready`.
    private var isWritableOrConfiguring: Bool { !readOnly && connection != nil }

    // MARK: - Écriture

    /// Identifiant entier d'une série : la clé texte n'est écrite qu'une fois,
    /// chaque point ne porte qu'un petit entier.
    ///
    /// Le libellé, l'unité et le dénominateur réel (`bound`) d'une série qui
    /// n'est pas au catalogue — un volume et sa capacité, une température
    /// déclarée par un module — sont gardés avec elle : `--probe` et
    /// `--snapshot`, d'autres processus où le module n'a rien déclaré,
    /// affichent ainsi la même unité et la même échelle que l'app.
    private func id(for key: String, label: String?, bound: Double? = nil, unit: SeriesUnit? = nil) throws -> Int64 {
        guard let db = connection else { throw SQLiteError(code: SQLITE_MISUSE, message: "base fermée") }
        if let known = ids[key] {
            if (label != nil && labels[key] != label) || (bound != nil && bounds[key] != bound)
                || (unit != nil && units[key] != unit) {
                let update = try db.prepare("""
                    UPDATE series SET label = coalesce(?, label), bound = coalesce(?, bound),
                                      unit = coalesce(?, unit) WHERE id = ?
                    """)
                update.bind(1, label)
                if let bound { update.bind(2, bound) } else { update.bind(2, nil as String?) }
                update.bind(3, unit?.rawValue)
                update.bind(4, known)
                try update.step()
                if let label { labels[key] = label }
                if let bound { bounds[key] = bound }
                if let unit { units[key] = unit }
            }
            return known
        }
        let insert = try db.prepare("INSERT OR IGNORE INTO series (key, label, bound, unit) VALUES (?, ?, ?, ?)")
        insert.bind(1, key)
        insert.bind(2, label)
        if let bound { insert.bind(3, bound) } else { insert.bind(3, nil as String?) }
        insert.bind(4, unit?.rawValue)
        try insert.step()
        let select = try db.prepare("SELECT id FROM series WHERE key = ?")
        select.bind(1, key)
        guard try select.step() else { throw db.lastError }
        let id = select.int64(0)
        ids[key] = id
        if let label { labels[key] = label }
        if let bound { bounds[key] = bound }
        if let unit { units[key] = unit }
        return id
    }

    /// Écrit un lot de points bruts, puis recalcule les tranches qu'il touche
    /// dans les deux étages agrégés — le tout en UNE transaction.
    ///
    /// Une série déclarée par un module (`History.declare`) emporte sa
    /// déclaration avec elle, la première fois et à chaque changement.
    func insert(_ points: [Point], labels newLabels: [String: String] = [:],
                bounds newBounds: [String: Double] = [:], now: Date = Date()) throws {
        guard isWritable, let db = connection, !points.isEmpty else { return }
        try db.transaction {
            let insert = try db.prepare("INSERT OR REPLACE INTO raw (s, t, v) VALUES (?, ?, ?)")
            var oldest: [Int64: Int64] = [:]
            var described: [String: Int64] = [:]
            for point in points where point.v.isFinite {
                let s: Int64
                if let known = described[point.key] {
                    s = known
                } else {
                    let declared = SeriesCatalog.declaredInfo(point.key)
                    s = try id(for: point.key, label: newLabels[point.key] ?? declared?.label,
                               bound: newBounds[point.key] ?? declared?.bound, unit: declared?.unit)
                    described[point.key] = s
                }
                insert.bind(1, s)
                insert.bind(2, point.t)
                insert.bind(3, point.v)
                try insert.step()
                insert.reset()
                oldest[s] = min(oldest[s] ?? point.t, point.t)
            }
            try aggregate(oldest, now: Int64(now.timeIntervalSince1970))
        }
    }

    /// Les tranches touchées, recalculées depuis l'étage du dessous.
    ///
    /// Toutes séries ensemble, depuis la plus ancienne minute du lot : la clé
    /// (t, s) range le lot à la fin de la table, et la requête ne lit que
    /// lui. Une tranche d'une série absente du lot est recalculée à
    /// l'identique.
    ///
    /// Jamais en deçà de ce que l'étage du dessous garde ENTIER : une minute à
    /// cheval sur la purge des points bruts serait recalculée sur la moitié de
    /// ses points, et l'écraserait. Un lot vivant ne remonte de toute façon
    /// qu'à quelques minutes ; c'est la garantie qui compte.
    private func aggregate(_ oldest: [Int64: Int64], now: Int64) throws {
        guard let db = connection, let first = oldest.values.min() else { return }
        let rawComplete = Self.floor(now - Tier.raw.retention, 60) + 60
        let minuteComplete = Self.floor(now - Tier.minute.retention, 600) + 600
        let minute = try db.prepare("""
            INSERT OR REPLACE INTO minute (s, t, avg, min, max, n)
            SELECT s, (t / 60) * 60 AS b, avg(v), min(v), max(v), count(*)
            FROM raw WHERE t >= ?1 GROUP BY s, b
            """)
        minute.bind(1, max(Self.floor(first, 60), rawComplete))
        try minute.step()
        let tenmin = try db.prepare("""
            INSERT OR REPLACE INTO tenmin (s, t, avg, min, max, n)
            SELECT s, (t / 600) * 600 AS b, sum(avg * n) / sum(n), min(min), max(max), sum(n)
            FROM minute WHERE t >= ?1 GROUP BY s, b
            """)
        tenmin.bind(1, max(Self.floor(first, 600), minuteComplete))
        try tenmin.step()
    }

    /// Points venus d'ailleurs (`LegacyImport`), éventuellement anciens.
    ///
    /// Chaque étage reçoit ce qui tombe dans SA durée de conservation,
    /// agrégé depuis les seuls points importés, et rien n'écrase ce qui est
    /// déjà là (`OR IGNORE`) : un relevé vivant a toujours le dernier mot.
    /// Rejouer l'import ne change donc rien.
    func importPoints(_ points: [Point], labels newLabels: [String: String] = [:],
                      now: Date = Date()) throws -> Int {
        guard isWritable, let db = connection, !points.isEmpty else { return 0 }
        let t = Int64(now.timeIntervalSince1970)
        var written = 0
        try db.transaction {
            try db.exec("CREATE TEMP TABLE IF NOT EXISTS import (s INTEGER NOT NULL, t INTEGER NOT NULL, v REAL NOT NULL)")
            try db.exec("DELETE FROM import")
            let insert = try db.prepare("INSERT INTO import (s, t, v) VALUES (?, ?, ?)")
            for point in points where point.v.isFinite && point.t >= t - Tier.tenmin.retention {
                insert.bind(1, try id(for: point.key, label: newLabels[point.key]))
                insert.bind(2, point.t)
                insert.bind(3, point.v)
                try insert.step()
                insert.reset()
            }
            try db.exec("""
                INSERT OR IGNORE INTO raw (s, t, v)
                    SELECT s, t, avg(v) FROM import WHERE t >= \(t - Tier.raw.retention) GROUP BY s, t;
                INSERT OR IGNORE INTO minute (s, t, avg, min, max, n)
                    SELECT s, (t / 60) * 60 AS b, avg(v), min(v), max(v), count(*)
                    FROM import WHERE t >= \(t - Tier.minute.retention) GROUP BY s, b;
                INSERT OR IGNORE INTO tenmin (s, t, avg, min, max, n)
                    SELECT s, (t / 600) * 600 AS b, avg(v), min(v), max(v), count(*)
                    FROM import GROUP BY s, b;
                """)
            written = Int(try db.scalarInt("SELECT count(*) FROM import") ?? 0)
            try db.exec("DELETE FROM import")
        }
        return written
    }

    /// Retire ce qui a dépassé sa durée de conservation, étage par étage.
    /// Rien n'est perdu à tort : un point brut n'est retiré qu'après 24 h,
    /// quand sa minute et sa tranche de 10 min sont écrites depuis longtemps.
    func purge(now: Date = Date()) throws {
        guard isWritable, let db = connection else { return }
        let t = Int64(now.timeIntervalSince1970)
        try db.transaction {
            // Clé (t, s) : le début de chaque étage, des pages entières.
            for tier in Tier.allCases {
                let delete = try db.prepare("DELETE FROM \(tier.rawValue) WHERE t < ?")
                delete.bind(1, t - tier.retention)
                try delete.step()
            }
        }
    }

    static func floor(_ t: Int64, _ step: Int64) -> Int64 {
        t >= 0 ? (t / step) * step : ((t - step + 1) / step) * step
    }

    // MARK: - Lecture

    /// L'étage qui couvre une plage commençant à `from` : le plus fin qui la
    /// contient encore.
    static func tier(from: Int64, now: Int64) -> Tier {
        if from >= now - Tier.raw.retention { return .raw }
        if from >= now - Tier.minute.retention { return .minute }
        return .tenmin
    }

    /// Tranches de `bucket` secondes sur [from, to), alignées sur l'heure
    /// locale (`offset` = décalage UTC en secondes) : une tranche de 12 h
    /// commence à minuit et à midi, pas à 2 h du matin.
    func buckets(key: String, from: Int64, to: Int64, bucket: Int64, offset: Int64 = 0,
                 now: Int64 = Int64(Date().timeIntervalSince1970)) -> [Bucket] {
        buckets(keys: [key], from: from, to: to, bucket: bucket, offset: offset, now: now)[key] ?? []
    }

    /// Plusieurs séries en UN parcours : avec la clé (t, s), lire une série
    /// sur une plage parcourt de toute façon les lignes de toutes. `--probe`
    /// lit ainsi ses vingt séries sur cinq plages en cinq parcours.
    func buckets(keys: [String], from: Int64, to: Int64, bucket: Int64, offset: Int64 = 0,
                 now: Int64 = Int64(Date().timeIntervalSince1970)) -> [String: [Bucket]] {
        let wanted = Dictionary(keys.compactMap { key in ids[key].map { ($0, key) } }, uniquingKeysWith: { a, _ in a })
        guard let db = connection, !wanted.isEmpty, bucket > 0 else { return [:] }
        let tier = Self.tier(from: from, now: now)
        let values = tier == .raw ? "avg(v), min(v), max(v), count(*)" : "sum(avg * n) / sum(n), min(min), max(max), sum(n)"
        let filter = wanted.count == 1 ? "s = \(wanted.keys.first!)" : "s IN (\(wanted.keys.map(String.init).joined(separator: ",")))"
        let sql = """
            SELECT s, ((t + ?3) / ?4) * ?4 - ?3 AS b, \(values)
            FROM \(tier.rawValue) WHERE t >= ?1 AND t < ?2 AND \(filter) GROUP BY s, b ORDER BY s, b
            """
        guard let statement = try? db.prepare(sql) else { return [:] }
        statement.bind(1, from)
        statement.bind(2, to)
        statement.bind(3, offset)
        statement.bind(4, bucket)
        var out: [String: [Bucket]] = [:]
        while (try? statement.step()) == true {
            guard let key = wanted[statement.int64(0)] else { continue }
            out[key, default: []].append(Bucket(t: statement.int64(1), avg: statement.double(2),
                                                min: statement.double(3), max: statement.double(4),
                                                count: statement.int64(5)))
        }
        return out
    }

    // MARK: - Bilan

    var keys: [String] { ids.keys.sorted() }

    func label(_ key: String) -> String? { labels[key] }

    func bound(_ key: String) -> Double? { bounds[key] }

    func unit(_ key: String) -> SeriesUnit? { units[key] }

    /// Taille sur disque, journal compris (WAL d'une base de la première
    /// version, ou journal de retour arrière pendant une écriture).
    var fileBytes: (main: Int64, wal: Int64) {
        func size(_ path: String) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        return (size(url.path), size(url.path + "-wal") + size(url.path + "-journal"))
    }

    func stats(for key: String) -> SeriesStats? { allStats()[key] }

    /// Le bilan de toutes les séries, en un parcours par étage : avec la clé
    /// (t, s), compter une seule série parcourt de toute façon tout l'étage.
    func allStats() -> [String: SeriesStats] {
        guard let db = connection else { return [:] }
        let keyOf = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
        var out: [String: SeriesStats] = [:]
        for (key, _) in ids { out[key] = SeriesStats(key: key, label: labels[key], rows: [:]) }
        for tier in Tier.allCases {
            if let statement = try? db.prepare("SELECT s, count(*), min(t) FROM \(tier.rawValue) GROUP BY s") {
                while (try? statement.step()) == true {
                    guard let key = keyOf[statement.int64(0)], var stats = out[key] else { continue }
                    stats.rows[tier] = statement.int64(1)
                    let first = statement.int64(2)
                    stats.first = min(stats.first ?? first, first)
                    out[key] = stats
                }
            }
            // `max(t)` SEUL agrégat de la requête : SQLite rend alors la valeur
            // de la même ligne — le dernier point. Le plus récent est pris dans
            // l'étage le plus fin qui en a un.
            let value = tier == .raw ? "v" : "avg"
            if let statement = try? db.prepare("SELECT s, max(t), \(value) FROM \(tier.rawValue) GROUP BY s") {
                while (try? statement.step()) == true {
                    guard let key = keyOf[statement.int64(0)], out[key]?.last == nil else { continue }
                    out[key]?.last = statement.int64(1)
                    out[key]?.lastValue = statement.double(2)
                }
            }
        }
        return out
    }

    /// Libère la connexion (fin des tests, fermeture de l'app).
    func close() {
        connection = nil
    }
}

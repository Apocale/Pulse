import Foundation

/// L'historique longue durée, vu de l'extérieur : déclarer une série,
/// l'alimenter, la lire par plage.
///
/// Pour un module (chantiers 04 à 08), deux lignes suffisent :
///
///     History.declare(SeriesInfo("capteurs.cpu", "Processeur", .celsius))
///     History.record("capteurs.cpu", 62.5)          // à chaque relevé
///
/// puis `HistoryChart(keys: ["capteurs.cpu"])` pour le graphique. Chaque
/// série coûte environ 1 Mo de disque à 90 jours si elle est relevée toutes
/// les 10 s ou plus souvent : regrouper ce qui peut l'être (une moyenne des
/// capteurs d'un même organe plutôt que vingt capteurs).
enum History {
    static func declare(_ info: SeriesInfo) { SeriesCatalog.declare(info) }

    /// Depuis n'importe quel fil. Les relevés d'une même fenêtre de 10 s sont
    /// moyennés en un point ; rien n'est écrit quand `Persistence.enabled`
    /// est faux (`--snapshot`).
    static func record(_ key: String, _ value: Double) { SeriesRecorder.shared.record(key, value) }

    static func reading(_ keys: [String], range: HistoryRange) async -> HistoryReading {
        await SeriesRecorder.shared.reading(keys: keys, range: range)
    }
}

/// Ce que montre un graphique : une ou plusieurs séries de même unité, en
/// tranches, sur une plage.
struct HistoryReading {
    struct Line {
        var info: SeriesInfo
        var buckets: [SeriesDatabase.Bucket]
    }

    var range: HistoryRange
    /// Début de la plage, aligné sur une tranche, et fin (maintenant).
    var from: Int64
    var to: Int64
    var bucket: Int64
    var lines: [Line]

    var isEmpty: Bool { lines.allSatisfy { $0.buckets.isEmpty } }

    /// Le dénominateur réel commun aux séries, s'il existe (règle dure n° 7).
    var bound: Double? {
        let bounds = lines.map(\.info.bound)
        guard let first = bounds.first, let value = first, bounds.allSatisfy({ $0 == value }) else { return nil }
        return value
    }

    /// Le plus haut relevé de la plage — la pointe, pas la plus haute
    /// moyenne : l'échelle « max 6,5 Go » et la « pointe 6,5 Go » du résumé
    /// disent ainsi le même chiffre, et aucune tranche ne sort du cadre.
    var observedMax: Double {
        lines.flatMap(\.buckets).map(\.max).max() ?? 0
    }

    /// Le haut de l'échelle : le dénominateur réel, sinon le maximum observé,
    /// nommé comme tel sur le graphique.
    var scaleTop: Double {
        if let bound, bound > 0 { return bound }
        return max(observedMax, 1e-9)
    }

    /// Le premier point réellement enregistré dans la plage : « depuis le
    /// 11/10 » plutôt qu'un « il y a 90 j » que rien ne couvre.
    var firstData: Int64? { lines.compactMap { $0.buckets.first?.t }.min() }
}

/// L'enregistreur : relevés → fenêtres de 10 s → lots écrits toutes les
/// 5 min, sur une file à lui, jamais sur le main thread.
///
/// Coût mesuré (voir `docs/chantiers/02-historique.md`) : 0,0012 % d'un
/// cœur et 2,9 Mo écrits par heure, sans minuterie à lui — les fenêtres se
/// ferment au fil des relevés que le `Sampler` fait de toute façon, et la
/// base ne se réveille qu'une fois toutes les 5 min.
///
/// `@unchecked Sendable` : tout état mutable est soit sous `lock`, soit
/// confiné à `queue` — c'est ce qui permet la lecture `async`.
final class SeriesRecorder: @unchecked Sendable {
    static let shared = SeriesRecorder()

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
    }

    /// `PULSE_HISTORIQUE=/chemin/base.sqlite` remplace la base — pour rendre
    /// un `--snapshot` sur une copie, jamais sur les vrais fichiers.
    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["PULSE_HISTORIQUE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return folder.appendingPathComponent(SeriesDatabase.fileName)
    }

    /// Fenêtre d'un point brut. 9,5 s et non 10 : le `Sampler` relève toutes
    /// les 5 s fermé, et un seuil de 10 s pile tomberait une fois sur deux à
    /// 15 s selon la gigue de la minuterie — ce qu'on lit d'ailleurs dans la
    /// série d'une heure de history.json (14,85 s en médiane).
    static let window: Double = 9.5
    /// Un lot toutes les 5 min, une purge par heure. Chaque lot salit au
    /// moins une page par série et par étage, quelle que soit sa taille :
    /// mesuré sur une base de 24 h, un lot par minute et une purge par lot
    /// écrivaient 19,3 Mo par heure sur le SSD, autant que la réécriture de
    /// history.json. Les points pas encore écrits restent lus par les
    /// graphiques ; une coupure de courant en coûte 5 min au plus, une
    /// fermeture normale aucun (`flush`).
    static let writeInterval: Double = 300
    static let purgeInterval: Double = 3600

    let url: URL
    let legacyURL: URL?
    private let persistent: () -> Bool
    let queue: DispatchQueue

    private struct Accumulator {
        var sum = 0.0
        var count = 0
    }

    // Sous `lock` : touchés depuis la file d'échantillonnage et les modules.
    private let lock = NSLock()
    private var accumulators: [String: Accumulator] = [:]
    private var windowStart: Double?
    /// Heure du dernier relevé de la fenêtre en cours : celle de son point.
    private var windowLast: Double = 0
    /// Seconde du dernier point émis : deux fenêtres n'en partagent jamais.
    private var lastEmitted: Int64 = .min
    private var pending: [SeriesDatabase.Point] = []
    private var pendingLabels: [String: String] = [:]
    private var pendingBounds: [String: Double] = [:]
    private var lastWrite: Double = 0
    /// Temps CPU passé dans `record`, sur le fil de l'appelant.
    private var recordingCPU: Double = 0

    // Sur `queue` seulement.
    private var database: SeriesDatabase?
    private var lastError: String?
    /// Temps CPU passé à écrire, agréger et purger.
    private var writingCPU: Double = 0
    private var writes = 0
    private var lastPurge: Double = 0
    private let started = Date().timeIntervalSince1970

    init(url: URL = SeriesRecorder.defaultURL,
         legacyURL: URL? = SeriesRecorder.folder.appendingPathComponent("history.json"),
         persistent: @escaping () -> Bool = { Persistence.enabled }) {
        self.url = url
        self.legacyURL = legacyURL
        self.persistent = persistent
        queue = DispatchQueue(label: "com.isma.pulse.historique", qos: .utility)
    }

    /// Ouvre la base tout de suite — et fait l'import — plutôt qu'au premier
    /// lot : `--probe` montre ainsi l'historique repris dès le lancement.
    func start() {
        queue.async { [weak self] in self?.openIfNeeded() }
    }

    // MARK: - Relevés

    func record(_ key: String, _ value: Double, label: String? = nil,
                now: Double = Date().timeIntervalSince1970) {
        record([(key, value)], labels: label.map { [key: $0] } ?? [:], now: now)
    }

    /// Plusieurs valeurs d'un même relevé, sous une seule prise du verrou.
    func record(_ values: [(String, Double)], labels: [String: String] = [:], bounds: [String: Double] = [:],
                now: Double = Date().timeIntervalSince1970) {
        guard persistent() else { return }
        let cpuStart = Self.threadCPU()
        var batch: [SeriesDatabase.Point]?
        lock.lock()
        if let start = windowStart, now - start >= Self.window {
            closeWindow()
        }
        if windowStart == nil { windowStart = now }
        windowLast = now
        for (key, value) in values where value.isFinite {
            var accumulator = accumulators[key] ?? Accumulator()
            accumulator.sum += value
            accumulator.count += 1
            accumulators[key] = accumulator
        }
        for (key, label) in labels { pendingLabels[key] = label }
        for (key, bound) in bounds { pendingBounds[key] = bound }
        if !pending.isEmpty, now - lastWrite >= Self.writeInterval {
            batch = pending
            pending.removeAll(keepingCapacity: true)
            lastWrite = now
        }
        let labelsToWrite = batch == nil ? [:] : pendingLabels
        let boundsToWrite = batch == nil ? [:] : pendingBounds
        recordingCPU += Self.threadCPU() - cpuStart
        lock.unlock()

        if let batch {
            queue.async { [weak self] in self?.write(batch, labels: labelsToWrite, bounds: boundsToWrite, now: now) }
        }
    }

    /// Toujours appelée avec le verrou pris. Un point par série de la
    /// fenêtre, daté de son DERNIER relevé, pas de sa fermeture : une fenêtre
    /// ouverte à 23 h, avant une mise en veille, et fermée par le premier
    /// relevé du réveil à 8 h, daterait sinon de 8 h des valeurs de 23 h.
    /// Toutes les séries d'une fenêtre partagent la même seconde — le survol
    /// les lit ensemble —, et deux fenêtres jamais la même.
    private func closeWindow() {
        let t = max(Int64(windowLast.rounded()), lastEmitted + 1)
        lastEmitted = t
        for (key, accumulator) in accumulators where accumulator.count > 0 {
            pending.append(.init(key: key, t: t, v: accumulator.sum / Double(accumulator.count)))
        }
        accumulators.removeAll(keepingCapacity: true)
        windowStart = nil
    }

    /// Ferme la fenêtre en cours et écrit tout, en attendant au plus
    /// `timeout` : appelé à la fermeture de Pulse, sur le main thread, qui ne
    /// doit jamais rester bloqué sur un disque.
    func flush(timeout: TimeInterval = 1, now: Double = Date().timeIntervalSince1970) {
        guard persistent() else { return }
        lock.lock()
        if windowStart != nil { closeWindow() }
        let batch = pending
        pending.removeAll()
        lastWrite = now
        let labels = pendingLabels
        let bounds = pendingBounds
        lock.unlock()

        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.write(batch, labels: labels, bounds: bounds, now: now)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: - Base (sur `queue`)

    private func openIfNeeded() {
        // Une base momentanément illisible (tenue ailleurs, disque lent) se
        // rouvre au lot suivant plutôt que de laisser toute la session sans
        // historique.
        if let database, !database.isWritable, case .unavailable = database.state, persistent() {
            database.close()
            self.database = nil
        }
        guard database == nil else { return }
        let db = SeriesDatabase(url: url, readOnly: !persistent())
        database = db
        if db.isWritable, let legacyURL {
            LegacyImport.runIfNeeded(from: legacyURL, into: db)
        }
    }

    /// `now` : l'heure du lot, pour l'agrégation et la purge.
    private func write(_ batch: [SeriesDatabase.Point], labels: [String: String], bounds: [String: Double],
                       now: Double) {
        guard !batch.isEmpty else { return }
        let cpuStart = Self.threadCPU()
        defer { writingCPU += Self.threadCPU() - cpuStart }
        openIfNeeded()
        guard let db = database, db.isWritable else { return }
        let date = Date(timeIntervalSince1970: now)
        do {
            try db.insert(batch, labels: labels, bounds: bounds, now: date)
            // Une heure de trop dans un étage ne se voit pas ; une page
            // salie par série à chaque lot, si.
            if now - lastPurge >= Self.purgeInterval {
                try db.purge(now: date)
                lastPurge = now
            }
            lastError = nil
        } catch let error as SQLiteError where error.isCorruption {
            // Abîmée en cours de route : on la referme, la réouverture la
            // met de côté (jamais effacée) et repart d'une base neuve.
            database?.close()
            database = nil
            openIfNeeded()
            try? database?.insert(batch, labels: labels, bounds: bounds, now: date)
            lastError = "\(error)"
        } catch {
            lastError = "\(error)"
        }
        // Le coût mesuré, gardé dans la base pour `--probe` — un autre
        // processus, qui ne peut pas lire ces compteurs —, une écriture sur
        // deux, soit toutes les dix minutes.
        writes += 1
        if writes % 2 == 1 {
            lock.lock()
            let recording = recordingCPU
            lock.unlock()
            database?.setMeta("cout", Self.costJSON(cpu: recording + writingCPU, since: started, now: now))
        }
    }

    // MARK: - Coût

    /// Temps CPU du fil appelant, en secondes. Le compteur du processus
    /// mêlerait tout Pulse ; celui du fil ne compte que ce que fait
    /// l'historique.
    static func threadCPU() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }

    /// Temps CPU dépensé par l'historique depuis la création de
    /// l'enregistreur : relevés et écritures. Attend la file.
    var cpuSpent: Double {
        let writing = queue.sync { writingCPU }
        lock.lock(); defer { lock.unlock() }
        return recordingCPU + writing
    }

    static func costJSON(cpu: Double, since: Double, now: Double) -> String {
        let object: [String: Any] = ["cpu": cpu, "depuis": since, "maj": now]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Lecture

    /// Synchrone : pour `--snapshot`, qui rend une image d'un trait. Ne pas
    /// appeler depuis le main thread de l'app : utiliser la version `async`.
    func readingNow(keys: [String], range: HistoryRange, now: Date = Date()) -> HistoryReading {
        queue.sync { readOnQueue(keys: keys, range: range, now: now) }
    }

    func reading(keys: [String], range: HistoryRange, now: Date = Date()) async -> HistoryReading {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: readOnQueue(keys: keys, range: range, now: now))
            }
        }
    }

    private func readOnQueue(keys: [String], range: HistoryRange, now: Date) -> HistoryReading {
        openIfNeeded()
        // Les points pas encore écrits (au plus une minute) comptent aussi :
        // le graphique d'une heure finit maintenant, pas il y a une minute.
        lock.lock()
        let unwritten = pending
        lock.unlock()
        return Self.reading(database: database, unwritten: unwritten, keys: keys, range: range, now: now)
    }

    /// Le calcul de lecture, sans file ni verrou : testable tel quel.
    static func reading(database: SeriesDatabase?, unwritten: [SeriesDatabase.Point] = [],
                        keys: [String], range: HistoryRange, now: Date,
                        timeZone: TimeZone = .current) -> HistoryReading {
        let nowT = Int64(now.timeIntervalSince1970)
        let offset = Int64(timeZone.secondsFromGMT(for: now))
        let bucket = Int64(range.bucket)
        let from = SeriesDatabase.floor(nowT - Int64(range.seconds) + offset, bucket) - offset
        let to = nowT + 1
        let stored = database?.buckets(keys: keys, from: from, to: to, bucket: bucket, offset: offset, now: nowT) ?? [:]
        let lines = keys.map { key -> HistoryReading.Line in
            var buckets = stored[key] ?? []
            let extra = unwritten.filter { $0.key == key && $0.t >= from && $0.t < to }
            if !extra.isEmpty { buckets = merge(buckets, extra, bucket: bucket, offset: offset) }
            return .init(info: SeriesCatalog.info(key, label: database?.label(key), bound: database?.bound(key),
                                                  unit: database?.unit(key)),
                         buckets: buckets)
        }
        return HistoryReading(range: range, from: from, to: to, bucket: bucket, lines: lines)
    }

    /// Ajoute des points bruts à des tranches déjà lues, en pondérant par le
    /// nombre de points.
    static func merge(_ buckets: [SeriesDatabase.Bucket], _ points: [SeriesDatabase.Point],
                      bucket: Int64, offset: Int64) -> [SeriesDatabase.Bucket] {
        var byStart = Dictionary(uniqueKeysWithValues: buckets.map { ($0.t, $0) })
        for point in points {
            let start = SeriesDatabase.floor(point.t + offset, bucket) - offset
            if var existing = byStart[start] {
                let n = Double(existing.count)
                existing.avg = (existing.avg * n + point.v) / (n + 1)
                existing.min = min(existing.min, point.v)
                existing.max = max(existing.max, point.v)
                existing.count += 1
                byStart[start] = existing
            } else {
                byStart[start] = .init(t: start, avg: point.v, min: point.v, max: point.v, count: 1)
            }
        }
        return byStart.values.sorted { $0.t < $1.t }
    }

    /// Pour `--probe` : l'état de la base de CETTE instance.
    var lastWriteError: String? { queue.sync { lastError } }
}

// MARK: - Les séries de base, alimentées par le Sampler

extension SeriesRecorder {
    /// Un relevé du `Sampler` : processeur, carte graphique, mémoire.
    func record(cpu: CPUSample, memory: MemorySample, gpu: Double?, now: Double = Date().timeIntervalSince1970) {
        var values: [(String, Double)] = []
        // Le premier relevé du processeur ne sert que de référence et rend
        // des zéros : l'enregistrer inventerait un creux à chaque lancement.
        if cpu.total > 0 || cpu.user > 0 || cpu.system > 0 {
            values += [("cpu.total", cpu.total), ("cpu.utilisateur", cpu.user), ("cpu.systeme", cpu.system),
                       ("cpu.performance", cpu.performance), ("cpu.efficacite", cpu.efficiency)]
        }
        // `nil` = lecture en échec : pas de point, plutôt qu'un zéro que rien
        // ne distinguerait d'un vrai repos (le piège de la série d'une heure).
        if let gpu { values.append(("gpu", gpu)) }
        if memory.total > 0 {
            values += [("memoire.utilisee", Double(memory.used)), ("memoire.apps", Double(memory.app)),
                       ("memoire.systeme", Double(memory.wired)), ("memoire.compressee", Double(memory.compressed)),
                       ("memoire.swap", Double(memory.swapUsed))]
        }
        if let pressure = memory.pressure { values.append(("memoire.pression", pressure)) }
        record(values, now: now)
    }

    /// Le débit, relevé toutes les 2 s : la moyenne des cinq relevés d'une
    /// fenêtre fait exactement les octets passés pendant ses 10 s.
    func record(network: NetworkSample, now: Double = Date().timeIntervalSince1970) {
        record([("reseau.envoi", network.txRate), ("reseau.reception", network.rxRate)], now: now)
    }

    /// L'espace libre de chaque volume, purgeable compris — le « libres » du
    /// panneau. Clé par UUID, nom en libellé : il suit les renommages.
    func record(volumes: [VolumeSample], now: Double = Date().timeIntervalSince1970) {
        guard persistent() else { return }
        var values: [(String, Double)] = []
        var labels: [String: String] = [:]
        var bounds: [String: Double] = [:]
        for volume in volumes {
            let key = SeriesCatalog.volumeKey(volume.historyKey)
            values.append((key, Double(volume.available)))
            labels[key] = volume.name
            // La capacité : le dénominateur réel de l'espace libre, gardé
            // dans la base pour que tout lecteur trace la même échelle.
            bounds[key] = Double(volume.total)
        }
        record(values, labels: labels, bounds: bounds, now: now)
    }
}

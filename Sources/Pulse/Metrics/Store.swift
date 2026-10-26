import Foundation

struct SeriesPoint: Codable {
    var t: Double
    var ram: Double       // fraction 0…1
    var swap: Double      // octets
    var cpu: Double
    var gpu: Double
}

/// Règle dure n°2, dans une extension pour garder l'initialiseur membre à
/// membre : un champ ajouté plus tard ne doit pas coûter l'heure de séries
/// déjà écrite.
extension SeriesPoint {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.tolerant(Double.self, .t) ?? 0
        ram = c.tolerant(Double.self, .ram) ?? 0
        swap = c.tolerant(Double.self, .swap) ?? 0
        cpu = c.tolerant(Double.self, .cpu) ?? 0
        gpu = c.tolerant(Double.self, .gpu) ?? 0
    }
}

struct DiskPoint: Codable {
    var t: Double
    var free: Double            // octets libres, purgeable INCLUS (« importantUsage »)
    /// Octets libres au sens POSIX, purgeable exclu. C'est lui qui porte la
    /// tendance : le purgeable est repris par macOS sans que l'utilisateur ait
    /// rien écrit — un instantané Time Machine libéré faisait passer le disque
    /// de démarrage pour un volume qui se vide de 12 Go d'un coup.
    /// `nil` sur un point écrit avant l'ajout du champ.
    var freeStrict: Double?

    init(t: Double, free: Double, freeStrict: Double?) {
        self.t = t
        self.free = free
        self.freeStrict = freeStrict
    }

    /// Décodage écrit à la main, comme `HistoryStore.File` et pour la même
    /// raison : `freeStrict` est un champ ajouté après coup. Le décodeur
    /// synthétisé lèverait `keyNotFound` sur tout point antérieur, et l'échec
    /// remonterait jusqu'au `try?` de `File` — effaçant les 30 jours de
    /// tendance de remplissage au premier lancement.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.tolerant(Double.self, .t) ?? 0
        free = c.tolerant(Double.self, .free) ?? 0
        freeStrict = c.tolerant(Double.self, .freeStrict)
    }
}

struct AppRecord: Codable {
    var name: String
    var focus: Double   // secondes au premier plan
}

/// Règle dure n°2. Le décodeur synthétisé, sous le `try?` de tout le
/// dictionnaire `apps`, aurait effacé les 90 jours de temps par application
/// au premier champ ajouté ici (17-audit-code).
extension AppRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.tolerant(String.self, .name) ?? "?"
        focus = c.tolerant(Double.self, .focus) ?? 0
    }
}

/// Prévision de saturation d'un volume, estimée sur les intervalles calmes de
/// l'espace libre observé. C'est la métrique qui compte vraiment quand on
/// travaille avec des rushes : un disque plein coûte une demi-journée.
struct FillForecast {
    var bytesPerDay: Double   // négatif = le volume se remplit
    var daysUntilFull: Double?
    /// Intervalles écartés parce qu'ils portaient une opération en masse.
    var ruptures: Int
    /// Durée effectivement retenue pour la pente, ruptures déduites.
    var calmSeconds: TimeInterval
    /// Fenêtre d'où vient le rythme retenu : 72 h, ou 24 h quand les
    /// dernières 24 h vont moins vite (voir `HistoryStore.forecast`).
    var window: TimeInterval = HistoryStore.trendWindow
}

extension FillForecast {
    /// La tendance en mots, pour le panneau comme pour le verdict.
    ///
    /// Une prévision sans échéance ne veut pas dire que le volume se vide :
    /// elle recouvre aussi un volume qui se remplit trop lentement pour qu'une
    /// date ait un sens — l'échéance est tue au-delà de 400 jours. Les deux
    /// formulations d'avant tombaient dans le piège. Le verdict écrivait « se
    /// vide de -3,0 Go par jour », vérifié sur `Fmt.bytes`. Le panneau
    /// affichait « tendance en cours de calcul », alors que la tendance
    /// était calculée. Un Extreme Pro à 1,5 To libres y arrive sous
    /// 3,75 Go par jour.
    var trendText: String {
        if let days = daysUntilFull { return "plein dans \(Fmt.days(days))" }
        if bytesPerDay > 0 { return "se vide de \(Fmt.bytes(bytesPerDay, digits: 1)) par jour" }
        if bytesPerDay < 0 { return "se remplit lentement" }
        return "stable"
    }
}

/// Historique persistant. Un seul fichier JSON, écrit au plus une fois par
/// minute : à ce volume de données, une base serait de l'ingénierie gratuite.
final class HistoryStore {
    /// Interne et non privée : `HistoryTests` la décode telle que le disque
    /// la donne.
    struct File: Codable {
        var version: Int = 1
        var volumes: [String: [DiskPoint]] = [:]
        var series: [SeriesPoint] = []
        /// jour ("2026-08-24") → identifiant de bundle → temps cumulé
        var apps: [String: [String: AppRecord]] = [:]
        var sessions: [EditingSession] = []

        init() {}

        /// Décodage écrit à la main, et non synthétisé.
        ///
        /// Le décodeur généré par Swift lève `keyNotFound` sur une clé absente
        /// même quand la propriété a une valeur par défaut. Combiné à un
        /// `try?`, cela effaçait tout l'historique dès qu'un champ était ajouté
        /// au schéma — soit à chaque mise à jour de Pulse. Chaque champ est
        /// donc lu en `decodeIfPresent`.
        ///
        /// Et chaque élément à part (`Lossy`) : un seul enregistrement
        /// illisible — une session sans début, un jour d'apps abîmé — faisait
        /// échouer tout son tableau, que la sauvegarde suivante écrasait.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.tolerant(Int.self, .version) ?? 1
            volumes = (c.tolerant([String: [Lossy<DiskPoint>]].self, .volumes) ?? [:])
                .mapValues { $0.compactMap(\.value) }
            series = (c.tolerant([Lossy<SeriesPoint>].self, .series) ?? []).compactMap(\.value)
            apps = (c.tolerant([String: [String: Lossy<AppRecord>]].self, .apps) ?? [:])
                .mapValues { $0.compactMapValues(\.value) }
            sessions = (c.tolerant([Lossy<EditingSession>].self, .sessions) ?? []).compactMap(\.value)
        }
    }

    private static let seriesWindow: TimeInterval = 60 * 60      // 60 min de graphe
    private static let diskWindow: TimeInterval = 30 * 24 * 3600 // 30 jours de tendance
    private static let diskInterval: TimeInterval = 600          // un point / 10 min
    private static let appWindow: Int = 90                       // 90 jours d'usage applicatif
    static let trendWindow: TimeInterval = 72 * 3600             // tendance : 72 h glissantes
    static let recentWindow: TimeInterval = 24 * 3600            // le rythme dure-t-il encore ?
    private static let minObservation: TimeInterval = 6 * 3600   // plancher d'observation calme
    private static let ruptureFraction = 0.05                    // 5 % du volume déplacés d'un coup
    /// 5 To/j, soit 58 Mo/s. Le seuil sépare un débit de COPIE d'un débit de
    /// TRAVAIL : un export ProRes écrit autour de 30 Mo/s et doit être compté,
    /// une ingestion de carte tourne à 200-400 Mo/s et doit être écartée.
    /// Descendu à 400 Go/j, il rejetait 3,3 Go écrits en 10 minutes — donc
    /// chaque intervalle d'un export, soit exactement les moments où le disque
    /// se remplit vraiment.
    private static let maxSustainedPerDay = 5e12
    /// Ancienneté maximale du dernier point avant qu'on renonce à la tendance.
    /// La fenêtre glissante s'ancre sur le dernier point enregistré, et non sur
    /// l'heure courante, pour absorber une mise en veille — mais rien ne
    /// bornait jusqu'ici cette ancienneté : une pente mesurée douze jours plus
    /// tôt continuait d'annoncer une échéance, calculée sur un disque qui
    /// n'existe plus. Deux heures, soit douze intervalles manqués : de quoi
    /// traverser une veille ou un redémarrage, pas plusieurs jours.
    /// Interne, et non privée : `Probe` s'en sert pour nommer la raison.
    static let maxStaleness: TimeInterval = 2 * 3600

    /// Le store est écrit depuis la file d'échantillonnage ET depuis le main
    /// thread (suivi applicatif). Sans verrou, les deux corrompraient le
    /// dictionnaire à la première coïncidence.
    private let lock = NSLock()

    private let url: URL
    private var file = File()
    private var lastSave: Date = .distantPast

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(File.self, from: data) {
                file = decoded
            } else if Persistence.enabled {
                // Illisible malgré le décodage tolérant : on met de côté plutôt
                // que d'écraser. L'historique reste récupérable à la main.
                Persistence.setAside(url)
            }
        }
        lock.lock(); prune(); lock.unlock()
    }

    var series: [SeriesPoint] {
        lock.lock(); defer { lock.unlock() }
        return file.series
    }

    func appendSeries(_ point: SeriesPoint) {
        lock.lock(); defer { lock.unlock() }
        file.series.append(point)
        prune()
    }

    // MARK: - Sessions de montage

    /// Insertion idempotente. Une session ouverte est écrite une première fois
    /// quand Pulse quitte, puis réécrite quand l'application de montage quitte
    /// vraiment : même identifiant, un seul enregistrement.
    func appendSession(_ session: EditingSession) {
        lock.lock(); defer { lock.unlock() }
        if let index = file.sessions.firstIndex(where: { $0.id == session.id }) {
            file.sessions[index] = session
        } else {
            file.sessions.append(session)
        }
        prune()
    }

    func session(id: String) -> EditingSession? {
        lock.lock(); defer { lock.unlock() }
        return file.sessions.first { $0.id == id }
    }

    func sessions(since: Date) -> [EditingSession] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = since.timeIntervalSince1970
        return file.sessions.filter { $0.start >= cutoff }.sorted { $0.start > $1.start }
    }

    // MARK: - Usage applicatif

    /// Jour civil local, « 2026-10-09 ».
    ///
    /// Sans DateFormatter : en créer un à chaque appel coûtait 40 fois plus
    /// (0,081 ms contre 0,002), et le relevé réseau appelle ceci deux fois
    /// toutes les deux secondes. Sortie identique, vérifiée sur trois ans de
    /// dates espacées de 37 min, minuits et changements d'heure compris.
    static func dayKey(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    func addFocusTime(bundleId: String, name: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        let day = Self.dayKey()
        var today = file.apps[day] ?? [:]
        var record = today[bundleId] ?? AppRecord(name: name, focus: 0)
        record.focus += seconds
        record.name = name          // suit les renommages de version d'app
        today[bundleId] = record
        file.apps[day] = today
        prune()
    }

    /// Classement du jour, du plus utilisé au moins utilisé.
    func focusUsage(day: String = HistoryStore.dayKey()) -> [AppUsage] {
        lock.lock(); defer { lock.unlock() }
        return (file.apps[day] ?? [:])
            .map { AppUsage(bundleId: $0.key, name: $0.value.name, focus: $0.value.focus) }
            .sorted { $0.focus > $1.focus }
    }

    func focusTotal(day: String = HistoryStore.dayKey()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return (file.apps[day] ?? [:]).values.reduce(0) { $0 + $1.focus }
    }

    func appendVolumes(_ volumes: [VolumeSample], now: Double) {
        lock.lock(); defer { lock.unlock() }
        for volume in volumes {
            let key = volume.historyKey
            var points = file.volumes[key] ?? []
            if let last = points.last, now - last.t < Self.diskInterval { continue }
            points.append(DiskPoint(t: now,
                                    free: Double(volume.available),
                                    freeStrict: Double(volume.availableStrict)))
            file.volumes[key] = points
        }
        prune()
    }

    /// Tendance estimée sur les intervalles CALMES des 72 dernières heures.
    ///
    /// Une régression au sens des moindres carrés sur tous les points est
    /// inutilisable ici : une copie ou une suppression en masse forme une
    /// marche d'escalier qui s'empare de toute la pente. Mesuré sur cette
    /// machine — 207 Go supprimés du disque de rushes en 17 minutes, puis 14 h
    /// de remplissage lent — la régression annonçait « se vide de 172 Go par
    /// jour » quand le volume se remplissait de 3 Go par jour. Le signe était
    /// inversé : sur un disque à 90 %, l'alerte ne pouvait jamais partir.
    ///
    /// Restreindre la fenêtre à 72 h n'y changeait rien, et aggravait même le
    /// cas récent : sur 30 jours la marche finit diluée, sur 72 h elle possède
    /// la pente à elle seule.
    ///
    /// Chaque intervalle est donc jugé séparément. Ceux qui portent une
    /// opération en masse — plus de 5 % du volume d'un coup, ou un débit
    /// qu'aucun usage ne tient sur la durée — sont écartés ; la pente est la
    /// moyenne des autres, pondérée par leur durée. Ingérer une carte ou vider
    /// le disque ne fausse plus rien : ces gestes ne sont pas un rythme.
    ///
    /// nil en dessous de 6 h d'observation calme : extrapoler sur moins
    /// produirait un chiffre alarmiste et faux.
    ///
    /// Le rythme doit DURER : le plus lent des deux, 72 h ou 24 h, est retenu.
    /// Relevé le 09/10 sur Ssd 2 : 650 Go écrits en 7 h dans la nuit de jeudi
    /// — un téléchargement, à 7 Go les 10 min, trop lent pour passer pour une
    /// opération en masse —, puis 596 Go effacés d'un coup à 16 h 30, écartés
    /// eux. La moyenne des 72 h annonçait 88 Go par jour et « plein dans
    /// ~8 jours » sur un disque immobile depuis 30 h : 0,11 Go par jour sur
    /// les dernières 24 h. Le plus lent des deux ne fait jamais crier plus
    /// fort qu'avant ; il tait une rafale finie. Et un disque qui se remplit
    /// vraiment chaque jour se remplit aussi sur 24 h — son alerte reste.
    /// `free` est l'espace disponible mesuré à l'instant, purgeable compris —
    /// la même grandeur que `DiskPoint.free`, mais d'aujourd'hui.
    func forecast(for key: String, capacity: UInt64, free: UInt64,
                  now: Date = Date()) -> FillForecast? {
        lock.lock(); defer { lock.unlock() }
        guard let stored = file.volumes[key], let last = stored.last else { return nil }
        guard now.timeIntervalSince1970 - last.t <= Self.maxStaleness else { return nil }
        return Self.forecast(points: stored, capacity: capacity, free: free)
    }

    /// Le calcul lui-même, sans le store : testable sur des points fabriqués.
    static func forecast(points stored: [DiskPoint], capacity: UInt64, free: UInt64) -> FillForecast? {
        guard let last = stored.last else { return nil }
        let points = stored.filter { $0.t >= last.t - trendWindow }
        guard points.count >= 2 else { return nil }

        let bulk = Double(capacity) * ruptureFraction
        let long = calmRate(points, since: last.t - trendWindow, bulk: bulk)
        guard long.seconds >= minObservation else { return nil }

        var chosen = long, window = trendWindow
        let recent = calmRate(points, since: last.t - recentWindow, bulk: bulk)
        if recent.seconds >= minObservation, recent.perSecond > long.perSecond {
            chosen = recent
            window = recentWindow
        }

        let perSecond = chosen.perSecond          // octets libres gagnés par seconde
        var days: Double?
        if perSecond < 0 {                         // le volume se remplit
            // Le reste à courir se compte sur l'espace réellement disponible,
            // purgeable compris : macOS le reprend seul avant de saturer.
            // Et sur la mesure du moment, pas sur `last.free` : le dernier
            // point a jusqu'à dix minutes, et bien davantage après une pause.
            // Les afficher côte à côte donnait deux espaces libres qui se
            // contredisaient sur la même ligne.
            let d = Double(free) / -perSecond / 86_400
            if d.isFinite, d >= 0, d < 400 { days = d }
        }
        return FillForecast(bytesPerDay: perSecond * 86_400,
                            daysUntilFull: days,
                            ruptures: chosen.ruptures,
                            calmSeconds: chosen.seconds,
                            window: window)
    }

    /// Rythme moyen des intervalles CALMES qui commencent après `since`,
    /// pondéré par leur durée.
    private static func calmRate(_ points: [DiskPoint], since: Double,
                                 bulk: Double) -> (perSecond: Double, seconds: Double, ruptures: Int) {
        var freed = 0.0, seconds = 0.0, ruptures = 0
        for (a, b) in zip(points, points.dropFirst()) where a.t >= since {
            let dt = b.t - a.t
            guard dt > 0 else { continue }

            // Jamais une mesure stricte comparée à une mesure purgeable
            // incluse : l'écart entre les deux atteint 50 Go sur le disque de
            // démarrage et passerait pour un remplissage soudain. Les points
            // antérieurs au champ sont donc comparés entre eux, sur `free`.
            let df: Double
            if let sa = a.freeStrict, let sb = b.freeStrict {
                df = sb - sa
            } else {
                df = b.free - a.free
            }

            if abs(df) > bulk || abs(df) / dt * 86_400 > maxSustainedPerDay {
                ruptures += 1
                continue
            }
            freed += df
            seconds += dt
        }
        return (seconds > 0 ? freed / seconds : 0, seconds, ruptures)
    }

    /// Ancienneté du dernier point enregistré pour ce volume, `nil` s'il n'a
    /// jamais été observé. Distingue les deux silences possibles de
    /// `forecast` : pas encore assez de calme, ou relevés trop anciens.
    /// Les points d'espace libre d'un volume, du plus ancien au plus récent,
    /// bornés aux `days` derniers jours comptés depuis le DERNIER point — même
    /// ancrage que `forecast`, pour que la courbe montre exactement ce sur quoi
    /// la pente a été calculée.
    func volumeHistory(for key: String, days: Double) -> [DiskPoint] {
        lock.lock(); defer { lock.unlock() }
        guard let stored = file.volumes[key], let last = stored.last else { return [] }
        return stored.filter { $0.t >= last.t - days * 86_400 }
    }

    /// Temps total au premier plan, jour par jour, du plus ancien au plus
    /// récent. Les jours sans relevé rendent zéro plutôt que d'être absents :
    /// une barre manquante et une barre nulle ne disent pas la même chose.
    func focusByDay(days: Int, from today: Date = Date()) -> [(day: Date, seconds: TimeInterval)] {
        lock.lock(); defer { lock.unlock() }
        let calendar = Calendar.current
        var out: [(Date, TimeInterval)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.dayKey(date)
            let total = (file.apps[key] ?? [:]).values.reduce(0) { $0 + $1.focus }
            out.append((calendar.startOfDay(for: date), total))
        }
        return out
    }

    func lastSampleAge(for key: String, now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let last = file.volumes[key]?.last else { return nil }
        return now.timeIntervalSince1970 - last.t
    }

    /// Banc (`--banc`) : la prochaine `saveIfNeeded` écrit, sans attendre sa
    /// minute — pour mesurer ce que coûte la réécriture de history.json.
    func rendSauvegardeDue() {
        lock.lock(); lastSave = .distantPast; lock.unlock()
    }

    /// L'encodage se fait sous verrou, l'écriture en dehors.
    ///
    /// `write(options: .atomic)` crée un fichier temporaire puis le renomme :
    /// plusieurs appels système. Les tenir sous verrou bloquait le main thread
    /// à chaque ouverture du popover, le temps d'une écriture disque.
    func saveIfNeeded(force: Bool = false) {
        guard Persistence.enabled else { return }
        lock.lock()
        guard force || Date().timeIntervalSince(lastSave) > 60 else { lock.unlock(); return }
        lastSave = Date()
        let data = try? JSONEncoder().encode(file)
        lock.unlock()

        guard let data else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Toujours appelée avec le verrou déjà pris.
    private func prune() {
        let now = Date().timeIntervalSince1970
        file.series.removeAll { now - $0.t > Self.seriesWindow }
        for (key, points) in file.volumes {
            file.volumes[key] = points.filter { now - $0.t <= Self.diskWindow }
        }
        let sessionCutoff = now - Double(Self.appWindow) * 86_400
        file.sessions.removeAll { ($0.end ?? $0.start) < sessionCutoff }
        if file.apps.count > Self.appWindow {
            for day in file.apps.keys.sorted().dropLast(Self.appWindow) {
                file.apps.removeValue(forKey: day)
            }
        }
    }
}

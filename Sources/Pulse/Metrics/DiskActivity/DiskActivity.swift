import Foundation
import Combine

/// Un disque physique tel que la carte le montre : le matériel, les volumes
/// qu'il porte, ce qu'il lit et écrit en ce moment, sa santé.
struct DiskLine: Identifiable, Equatable {
    var disk: PhysicalDisk
    /// Volumes montés sur ce disque, dans l'ordre de `DiskMonitor`.
    var volumes: [VolumeSample]
    /// Octets par seconde sur le dernier intervalle. `nil` au premier relevé.
    var read: Double?
    var write: Double?
    /// Journal SMART, quand le contrôleur le publie.
    var health: DiskHealth? = nil

    var id: UInt64 { disk.id }

    /// « Ssd 2 », ou le modèle quand rien n'est monté (une carte en lecture
    /// seule, un disque démonté mais branché).
    var name: String { volumes.first?.name ?? disk.model }

    static func == (a: DiskLine, b: DiskLine) -> Bool {
        a.disk == b.disk && a.read == b.read && a.write == b.write && a.health == b.health
            && a.volumes.map(\.historyKey) == b.volumes.map(\.historyKey)
    }
}

/// Un point du graphique miroir : débit total de tous les disques physiques.
struct DiskTrailPoint: Equatable {
    var t: Double           // secondes, horloge monotone
    var interval: Double    // durée couverte par ce débit, se terminant en `t`
    var read: Double
    var write: Double
}

/// Tout ce que la carte Disques affiche, publié d'un bloc.
struct DiskActivityState: Equatable {
    var disks: [DiskLine] = []
    /// Les 3 dernières minutes, du plus ancien au plus récent.
    var trail: [DiskTrailPoint] = []
    /// Applications qui écrivent, de la plus active à la moins active.
    var writers: [ProcessGroup] = []
    /// Applications qui lisent.
    var readers: [ProcessGroup] = []
    /// Écritures massives en cours, nommées.
    var ingestions: [Ingestion] = []
    /// Les dernières écritures massives closes, 7 jours, les plus récentes
    /// d'abord.
    var recent: [Ingestion] = []

    static func == (a: DiskActivityState, b: DiskActivityState) -> Bool {
        a.disks == b.disks && a.trail == b.trail && a.ingestions == b.ingestions && a.recent == b.recent
            && a.writers.map(\.bundleId) == b.writers.map(\.bundleId)
            && a.writers.map(\.diskWrite) == b.writers.map(\.diskWrite)
            && a.readers.map(\.bundleId) == b.readers.map(\.bundleId)
            && a.readers.map(\.diskRead) == b.readers.map(\.diskRead)
    }
}

/// L'activité des disques, relevée au rythme du `Sampler` — 1,5 s panneau
/// ouvert, 5 s fermé — sur SA file d'échantillonnage, et publiée d'un bloc sur
/// le main thread.
///
/// Rien ne tourne à part : pas de minuterie à soi, pas de réveil de plus. Les
/// compteurs du pilote étant cumulés, un relevé espacé ne perd aucun octet, il
/// moyenne seulement sur un intervalle plus long.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : nourrie sur la file du relevé,
/// publiée sur le fil principal ; « ce qui remplit » sur sa propre file,
/// par le journal, qui a son verrou.
final class DiskActivity: ObservableObject, @unchecked Sendable {
    @Published private(set) var state = DiskActivityState()
    /// « Ce qui remplit » chaque volume externe, par clé d'historique. Publié
    /// à part : il change toutes les 30 min, pas à chaque relevé.
    @Published private(set) var fill: [String: FillReport] = [:]

    /// Durée du graphique miroir, celle du graphique réseau.
    static let trailSpan: TimeInterval = 180
    /// En dessous, une application n'« écrit » pas : journaux, préférences,
    /// caches de quelques octets. 100 ko/s.
    static let appFloor: Double = 100_000
    /// Le journal SMART bouge à l'échelle de l'heure : relu toutes les 10 min.
    static let healthInterval: TimeInterval = 600
    /// Profondeur de la liste des épisodes clos.
    static let recentWindow: TimeInterval = 7 * 86_400
    /// « Ce qui remplit » se redemande à Spotlight toutes les 30 min, la
    /// première fois 2 min après le lancement : le dernier bilan, gardé dans
    /// disques.json, couvre l'attente. 0,27 s de processeur par requête sur
    /// Ssd 2, soit 0,015 % d'un cœur amorti — mais 0,45 % s'il tombait dans
    /// la première minute, celle que mesure `--banc`, qui dirait un coût
    /// permanent qu'il n'est pas.
    static let fillInterval: TimeInterval = 1800
    static let fillFirstDelay: TimeInterval = 120
    /// La requête automatique est COUPÉE tant qu'Isma n'a pas dit oui. Lancée
    /// par l'app (et non depuis un terminal, dont elle hérite des droits),
    /// une requête sur un disque externe pourrait faire afficher à macOS, une
    /// fois, « Pulse souhaite accéder aux fichiers d'un volume amovible » ; le
    /// contrat des chantiers interdit de déclencher une demande d'autorisation
    /// sur son écran (11/10), et ce point n'a pas pu être vérifié sans en
    /// courir le risque. Le dernier bilan connu reste affiché ;
    /// `--probe --remplissage` fait la requête depuis le terminal.
    static let fillAutomatic = false

    // MARK: État de la file d'échantillonnage — jamais touché ailleurs.

    private var known: [UInt64: PhysicalDisk] = [:]
    private var meter = DiskRateMeter()
    /// Chemin de volume → pilote du disque qui le porte. Recalculé quand
    /// l'ensemble des volumes change, pas à chaque relevé.
    private var volumeMap: [String: UInt64] = [:]
    private var mappedKeys: [String] = []
    private var trail: [DiskTrailPoint] = []
    private var detector = IngestionDetector()
    private lazy var journal = DiskJournal()
    private var health: [UInt64: (at: Double, value: DiskHealth?)] = [:]
    private var networkRx: Double = 0
    /// Fichiers ouverts en écriture, par application, relus toutes les 30 s
    /// au plus : une copie ne change pas de disque en cours de route.
    private var devicesCache: [String: (at: Double, devices: Set<UInt32>)] = [:]
    /// Requêtes Spotlight : leur propre file, d'arrière-plan. La réponse peut
    /// mettre une minute et demie sur une machine chargée ; la file du relevé
    /// ne l'attend jamais.
    private let fillQueue = DispatchQueue(label: "com.isma.pulse.remplissage", qos: .background)
    /// Clé de volume → instant (horloge monotone) de la dernière demande.
    private var fillAsked: [String: Double] = [:]
    private var started: Double?
    private var fillLoaded = false

    private func cachedDevices(_ group: ProcessGroup) -> Set<UInt32> {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        if let cached = devicesCache[group.bundleId], now - cached.at < 30 { return cached.devices }
        let devices = WrittenDevices.devices(of: group.pids)
        devicesCache = devicesCache.filter { now - $0.value.at < 30 }
        devicesCache[group.bundleId] = (now, devices)
        return devices
    }

    /// Le débit réseau du moment, depuis `Sampler.sampleNetwork` (même file).
    func observeNetwork(rx: Double) {
        networkRx = rx
    }

    // MARK: - Pour les règles (19-suivis)

    /// Les écritures massives closes des dernières heures (20 au plus),
    /// publiées panneau fermé compris tant qu'une règle allumée les écoute.
    /// Écrites et lues sur le fil principal seulement : le surveillant des
    /// règles y trouve les copies de rushes terminées.
    private(set) var copiesTerminees: [Ingestion] = []

    private static let ecouteLock = NSLock()
    nonisolated(unsafe) private static var ecoute = false

    /// Une règle allumée écoute-t-elle les fins de copie ? Posé par
    /// `SurveillantRegles` ; faux par défaut : coût nul.
    static var ecouteCopies: Bool {
        get { ecouteLock.lock(); defer { ecouteLock.unlock() }; return ecoute }
        set { ecouteLock.lock(); ecoute = newValue; ecouteLock.unlock() }
    }

    /// Panneau ouvert ou fermé, depuis `Sampler.setPopoverOpen`, sur la file
    /// d'échantillonnage. Fermé, personne ne regarde : ni publication vers le
    /// main thread, ni lecture SMART. Restent les compteurs (63 µs), qui
    /// nourrissent le miroir des 3 min et le journal des écritures massives —
    /// c'est quand le panneau est fermé que la nuit se télécharge.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
    }
    private var panelOpen = false

    /// Un relevé. Appelé par `Sampler.tick`, sur la file d'échantillonnage.
    func observe(processes: [ProcessGroup], volumes: [VolumeSample], exporting: Bool) {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let readings = DiskIO.read(known: known)
        known = Dictionary(readings.map { ($0.disk.id, $0.disk) }, uniquingKeysWith: { a, _ in a })
        let rates = meter.update(now: now,
                                 readings: Dictionary(readings.map { ($0.disk.id, $0.counters) },
                                                      uniquingKeysWith: { a, _ in a }))

        let keys = volumes.map(\.historyKey)
        if keys != mappedKeys || volumeMap.values.contains(where: { known[$0] == nil }) {
            volumeMap = Self.map(volumes)
            mappedKeys = keys
        }

        // SMART : panneau ouvert seulement, à l'ouverture puis toutes les
        // 10 min, disques compatibles seulement. Un disque débranché est
        // oublié. Une lecture manquée (client exclusif tenu par un autre outil)
        // garde la valeur connue et se retente au relevé suivant passé 10 s.
        health = health.filter { known[$0.key] != nil }
        for disk in known.values where disk.smartCapable && panelOpen {
            if let cached = health[disk.id], now - cached.at < Self.healthInterval { continue }
            if let fresh = SMARTReader.read(driverID: disk.id) {
                health[disk.id] = (now, fresh)
            } else {
                health[disk.id] = (now - Self.healthInterval + 10, health[disk.id]?.value)
            }
        }

        var lines = Self.lines(disks: readings.map(\.disk), volumes: volumes, map: volumeMap, rates: rates)
        for i in lines.indices { lines[i].health = health[lines[i].id]?.value }

        if !rates.isEmpty {
            let interval = rates.values.map(\.interval).max() ?? 0
            let read = rates.values.reduce(0) { $0 + $1.read }
            let write = rates.values.reduce(0) { $0 + $1.write }
            trail.append(DiskTrailPoint(t: now, interval: interval, read: read, write: write))
            trail.removeAll { $0.t < now - Self.trailSpan - 10 }
            Self.recordHistory(read: read, write: write)
        }

        var active: [Ingestion] = []
        if let interval = rates.values.map(\.interval).max(), interval > 0 {
            let (open, finished) = detector.observe(Self.ingestionInput(
                lines: lines, interval: interval, networkRx: networkRx,
                processes: processes, exporting: exporting, devices: cachedDevices))
            active = open
            journal.record(active: open, finished: finished)
            // Pour la règle « Copie de rushes terminée » (19-suivis), panneau
            // fermé compris : quelques fois par jour, et seulement si une
            // règle allumée l'écoute — sinon rien ne part vers le fil principal.
            if !finished.isEmpty, Self.ecouteCopies {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.copiesTerminees = Array((self.copiesTerminees + finished).suffix(20))
                }
            }
        }
        refreshFill(volumes: volumes, now: now)
        guard panelOpen else { return }
        let horizon = Date().addingTimeInterval(-Self.recentWindow)
        let recent = Array(journal.finished.filter { $0.lastActive >= horizon }.prefix(5))

        let next = DiskActivityState(
            disks: lines,
            trail: trail,
            writers: Array(processes.filter { $0.diskWrite >= Self.appFloor }
                .sorted { $0.diskWrite > $1.diskWrite }.prefix(5)),
            readers: Array(processes.filter { $0.diskRead >= Self.appFloor }
                .sorted { $0.diskRead > $1.diskRead }.prefix(5)),
            ingestions: active,
            recent: recent)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != next else { return }
            self.state = next
        }
    }

    /// « Ce qui remplit » : le dernier bilan connu tout de suite, puis une
    /// requête Spotlight par volume externe toutes les 30 min, la première
    /// 2 min après le lancement.
    private func refreshFill(volumes: [VolumeSample], now: Double) {
        let journal = self.journal
        if !fillLoaded {
            fillLoaded = true
            started = now
            let saved = journal.fill
            DispatchQueue.main.async { [weak self] in self?.fill = saved }
        }
        guard Self.fillAutomatic, let started, now - started >= Self.fillFirstDelay else { return }
        for volume in volumes where !volume.isInternal {
            let key = volume.historyKey
            if let asked = fillAsked[key], now - asked < Self.fillInterval { continue }
            fillAsked[key] = now
            let (path, name) = (volume.path, volume.name)
            fillQueue.async { [weak self] in
                guard let arrivals = SpotlightArrivals.query(volumePath: path) else { return }
                let report = FillReport.build(volumeKey: key, volumeName: name, arrivals: arrivals, now: Date())
                journal.record(fill: report)
                DispatchQueue.main.async { [weak self] in self?.fill[key] = report }
            }
        }
    }

    // MARK: - Historique longue durée (19-suivis)

    /// Le débit total des disques physiques, celui du miroir des 3 min,
    /// gardé 90 jours (`History`, chantier 02) : la copie de 3 h du matin,
    /// l'export de la veille se retrouvent après coup. Deux séries pour tous
    /// les disques, pas deux par disque : ~1,5 Mo de base chacune à 90 jours,
    /// et un disque branché une fois n'ouvre pas deux séries de plus
    /// (mesuré, `HistoryTests.toutesLesSeriesTiennentSousCinquanteMo`).
    static let historyKeys = (read: "disques.lecture", write: "disques.ecriture")

    private static let declared: Void = {
        History.declare(SeriesInfo(historyKeys.read, "Disques, lecture", .bytesPerSecond))
        History.declare(SeriesInfo(historyKeys.write, "Disques, écriture", .bytesPerSecond))
    }()

    /// À chaque relevé, panneau fermé compris, sur la file d'échantillonnage :
    /// moyennés par fenêtres de 10 s par l'enregistreur, rien d'écrit quand
    /// la persistance est coupée (`--snapshot`, `--banc`, tests).
    private static func recordHistory(read: Double, write: Double) {
        _ = declared
        SeriesRecorder.shared.record([(historyKeys.read, read), (historyKeys.write, write)])
    }

    // MARK: - Calculs sans état, partagés avec `--probe`

    /// Ce que voit le détecteur d'ingestion à partir des lignes du relevé.
    ///
    /// Les fichiers ouverts ne se lisent que quand un disque externe écrit
    /// assez pour ouvrir un épisode, et pour les trois applications qui
    /// écrivent le plus : `devices` fournit cette lecture (mise en cache par
    /// l'app, directe pour `--probe`).
    static func ingestionInput(lines: [DiskLine], interval: Double, networkRx: Double,
                               processes: [ProcessGroup], exporting: Bool,
                               now: Date = Date(),
                               devices: (ProcessGroup) -> Set<UInt32>) -> IngestionInput {
        let busy = lines.contains { !$0.disk.isInternal && ($0.write ?? 0) >= IngestionDetector.activeRate }
        let mounts = busy ? WrittenDevices.volumeDevices() : [:]
        let writers = processes.filter { $0.diskWrite >= appFloor }.sorted { $0.diskWrite > $1.diskWrite }
        let inspected = Set(busy ? writers.prefix(3).map(\.bundleId) : [])
        return IngestionInput(
            now: now,
            interval: interval,
            disks: lines.map { line in
                IngestionInput.Disk(id: line.id,
                                    name: line.volumes.first?.name ?? line.disk.model,
                                    volumeKey: line.volumes.first?.historyKey,
                                    isInternal: line.disk.isInternal,
                                    isRemovable: line.disk.isRemovable,
                                    read: line.read ?? 0, write: line.write ?? 0,
                                    devices: Set(line.volumes.compactMap { mounts[$0.path] }))
            },
            networkRx: networkRx,
            apps: writers.map {
                IngestionInput.App(name: DiskProbe.appLabel($0), read: $0.diskRead, write: $0.diskWrite,
                                   encoder: AppKind.of(bundleId: $0.bundleId) == .encoding,
                                   devices: inspected.contains($0.bundleId) ? devices($0) : nil)
            },
            exporting: exporting)
    }

    /// Volume → disque physique, par l'IORegistry. Les volumes sans pilote de
    /// bloc (réseau, image disque) restent hors de la carte des disques.
    static func map(_ volumes: [VolumeSample]) -> [String: UInt64] {
        let devices = DiskIO.mountedDevices()
        var out: [String: UInt64] = [:]
        for volume in volumes {
            if let bsd = devices[volume.path], let id = DiskIO.driverID(forBSDName: bsd) {
                out[volume.path] = id
            }
        }
        return out
    }

    /// Une ligne par disque physique : l'interne d'abord, puis les externes
    /// dans l'ordre de leurs volumes. Un disque sans volume monté reste listé
    /// s'il travaille — une carte qu'on lit, un disque qu'on efface.
    static func lines(disks: [PhysicalDisk], volumes: [VolumeSample], map: [String: UInt64],
                      rates: [UInt64: DiskRateMeter.Rate]) -> [DiskLine] {
        var out: [DiskLine] = []
        for disk in disks {
            let mounted = volumes.filter { map[$0.path] == disk.id }
            let rate = rates[disk.id]
            let busy = (rate?.read ?? 0) + (rate?.write ?? 0) > 0
            guard !mounted.isEmpty || busy else { continue }
            out.append(DiskLine(disk: disk, volumes: mounted, read: rate?.read, write: rate?.write))
        }
        let order = Dictionary(volumes.enumerated().map { ($0.element.path, $0.offset) },
                               uniquingKeysWith: { a, _ in a })
        return out.sorted { a, b in
            if a.disk.isInternal != b.disk.isInternal { return a.disk.isInternal }
            let ra = a.volumes.compactMap { order[$0.path] }.min() ?? Int.max
            let rb = b.volumes.compactMap { order[$0.path] }.min() ?? Int.max
            return (ra, a.disk.bsdName) < (rb, b.disk.bsdName)
        }
    }
}

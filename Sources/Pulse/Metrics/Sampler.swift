import Foundation
import Combine

/// Boucle d'échantillonnage. Tout le travail se fait sur une file dédiée ;
/// seule la publication revient sur le main thread.
///
/// La cadence s'adapte : 1,5 s quand le popover est ouvert, 5 s sinon.
/// Les appels mach coûtent quelques microsecondes, le coût réel c'est
/// l'énumération des volumes — d'où son propre intervalle de 30 s.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : l'état privé vit sur `queue`
/// (« lu et écrit sur la file d'échantillonnage seulement »), les `@Published`
/// sont écrits sur le fil principal, la cadence aussi (`isOpen`,
/// intervalles). Relu par la revue de concurrence du 11/10.
final class Sampler: ObservableObject, @unchecked Sendable {
    @Published private(set) var memory = MemorySample()
    @Published private(set) var cpu = CPUSample()
    @Published private(set) var gpu: Double?
    @Published private(set) var volumes: [VolumeSample] = []
    @Published private(set) var series: [SeriesPoint] = []
    @Published private(set) var forecasts: [String: FillForecast] = [:]
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var focusTotal: TimeInterval = 0
    @Published private(set) var session: EditingSession?
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var processes: [ProcessGroup] = []
    /// Export en cours, détecté sur la charge de l'encodeur. Voir ExportDetector.
    @Published private(set) var export: ExportActivity?
    /// Le jugement rendu sur l'état de la machine, hystérisé. Voir VerdictEngine.
    @Published private(set) var verdict: Verdict = .pending
    @Published private(set) var network = NetworkSample()
    /// Les derniers débits, du plus ancien au plus récent : 3 min à raison
    /// d'un relevé toutes les 2 s. Le graphique miroir du menu réseau, celui
    /// d'iStat. En mémoire seulement — rien à garder d'un lancement à l'autre.
    @Published private(set) var networkTrail: [NetworkSample] = []
    static let networkTrailLength = 90
    /// Carte graphique, moteurs médias, exports, cache média (chantier 08,
    /// `Metrics/Media/`). Publié panneau ouvert seulement.
    @Published private(set) var medias = MediaState()
    /// Figé avec le relevé des rendus (`Releve.exports`, 19-suivis) : ni
    /// journal d'AME ni exports.json.
    let mediaTracker: MediaTracker
    /// Lu et écrit sur la file d'échantillonnage seulement.
    private var mediaOpen = false
    /// Activité, santé et remplissage des disques (chantier 05). Nourrie à
    /// chaque relevé, sur la file d'échantillonnage ; publie elle-même.
    let disks = DiskActivity()

    private let queue = DispatchQueue(label: "com.isma.pulse.sampler", qos: .utility)
    private let cpuMonitor = CPUMonitor()
    private let processMonitor = ProcessMonitor()
    private let exportDetector = ExportDetector()
    /// Comme `exportDetector` : porte un état qui n'appartient qu'à la file
    /// d'échantillonnage. Jamais touché depuis le main thread.
    private let verdictEngine = VerdictEngine()
    private let verdictJournal = VerdictJournal()
    private let networkTracker = NetworkTracker()
    private let store = HistoryStore()
    private var tracker: AppTracker?
    private var sessions: SessionTracker?
    private var timer: DispatchSourceTimer?
    private var networkTimer: DispatchSourceTimer?
    /// Le débit s'affiche « en direct » dans la barre de menus : il a son
    /// propre rythme, 2 s, panneau ouvert ou non. Le relevé général retombe à
    /// 5 s panneau fermé — trop lent pour un débit qu'on regarde bouger. Les
    /// deux minuteries partagent la même file : NetworkTracker n'est touché
    /// que depuis elle.
    private let networkInterval: TimeInterval = Sampler.networkPeriod
    /// Un relevé de débit toutes les 2 s : le survol du graphique miroir en
    /// déduit l'heure de chaque barre (chantier 10).
    static let networkPeriod: TimeInterval = 2

    /// Copie possédée par la file de sampling : évite tout aller-retour
    /// synchrone vers le main thread (source classique d'interblocage).
    private var cachedVolumes: [VolumeSample] = []
    /// Mêmes copies possédées par la file, pour les entrées du barème qui ne
    /// sont rafraîchies que toutes les 60 ou 120 s : le verdict s'évalue à
    /// chaque relevé et ne peut pas relire les valeurs publiées.
    private var cachedForecasts: [String: FillForecast] = [:]
    private var cachedVolumeAges: [String: TimeInterval] = [:]
    private var cachedIncidents: [Incident] = []
    private var cachedSeries: [SeriesPoint] = []
    private var lastVolumeScan: Double = 0
    /// Dernier balayage COMPLET des volumes, purgeable compris (la clé
    /// « pour usage important », 105 à 117 ms de CPU sur les cœurs E, contre
    /// 1 ms pour le reste — 15-audit-perf, 11/10). Panneau fermé, il n'est
    /// refait que toutes les 10 min, le pas de l'historique des disques ;
    /// ouvert, à chaque balayage.
    private var lastImportantScan: Double = 0
    static let importantInterval: Double = 600
    /// Lu et écrit sur la file d'échantillonnage seulement.
    private var volumeScanInterval: Double = 120
    private var lastSeriesAppend: Double = 0
    private var lastForecast: Double = 0
    private var lastIncidentScan: Double = 0
    private var lastTick: Double = 0

    /// Réglables (fenêtre Réglages, `RefreshSettings`) ; lus et écrits sur le
    /// main thread seulement, comme `isOpen`.
    private var openInterval: TimeInterval = 1.5
    private var idleInterval: TimeInterval = 5
    private var isOpen = false

    /// La cadence choisie par Isma. Panneau fermé, jamais sous 5 s : c'est
    /// le budget de moins de 1 % d'un cœur (`RefreshSettings.sanitized`).
    func setIntervals(open: TimeInterval, closed: TimeInterval) {
        guard open != openInterval || closed != idleInterval else { return }
        openInterval = open
        idleInterval = max(5, closed)
        schedule(interval: isOpen ? openInterval : idleInterval)
    }

    init() {
        mediaTracker = MediaTracker()
        series = store.series
        cachedSeries = series
        // AppTracker s'abonne à NSWorkspace et pose un Timer sur RunLoop.main :
        // il doit naître sur le main thread.
        tracker = AppTracker(store: store) { [weak self] in self?.refreshApps() }
        sessions = SessionTracker(store: store) { [weak self] in self?.refreshSession() }
        refreshApps()
        refreshSession()
        SeriesRecorder.shared.start()   // historique longue durée (History/)
        queue.async { [weak self] in self?.tick() }
        schedule(interval: idleInterval)

        let n = DispatchSource.makeTimerSource(queue: queue)
        n.schedule(deadline: .now() + networkInterval, repeating: networkInterval,
                   leeway: .milliseconds(200))
        n.setEventHandler { [weak self] in self?.sampleNetwork() }
        n.resume()
        networkTimer = n
    }

    /// Banc d'essai (chantier 03) : un sampler qui ne relève rien et publie
    /// un relevé figé — ni minuterie, ni capteur, ni écriture. Les tests de
    /// rendu comparent les cartes à des images de référence : un chiffre qui
    /// bougerait d'une exécution à l'autre les rendrait inutiles. Ne jamais
    /// l'ouvrir (`setPopoverOpen`) : les relevés réels reprendraient.
    /// Construit par `Releve.sampler()`, qui coupe d'abord la persistance.
    init(figé relevé: Releve) {
        memory = relevé.memory
        cpu = relevé.cpu
        gpu = relevé.gpu
        volumes = relevé.volumes
        series = relevé.series
        forecasts = relevé.forecasts
        apps = relevé.apps
        focusTotal = relevé.focusTotal
        session = relevé.session
        incidents = relevé.incidents
        processes = relevé.processes
        export = relevé.export
        verdict = relevé.verdict
        network = relevé.network
        networkTrail = relevé.networkTrail
        joursFiges = relevé.networkDays
        maintenantFige = relevé.maintenant
        medias = relevé.medias
        mediaTracker = MediaTracker(history: ExportHistory(figé: relevé.exports))
    }

    /// Le cumul réseau du relevé figé, à la place de `reseau.json`.
    private var joursFiges: [(day: Date, usage: [NetworkTracker.Usage])]?

    /// L'heure d'un relevé figé, pour ce qui se compte jusqu'à « aujourd'hui »
    /// (le forfait du mois). Nil : l'heure qu'il est.
    private(set) var maintenantFige: Date?

    private func sampleNetwork() {
        let now = networkTracker.sample()
        disks.observeNetwork(rx: now.rxRate)
        SeriesRecorder.shared.record(network: now)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.network = now
            self.networkTrail = Array((self.networkTrail + [now]).suffix(Self.networkTrailLength))
        }
    }

    private func refreshSession() {
        let current = sessions?.current
        if Thread.isMainThread {
            session = current
        } else {
            DispatchQueue.main.async { [weak self] in self?.session = current }
        }
    }

    /// Recalcule le classement du jour. Appelé à chaque bascule d'application
    /// et à chaque ouverture du popover, pas à la cadence d'échantillonnage :
    /// le classement bouge à l'échelle de la minute, pas de la seconde.
    private func refreshApps() {
        let usage = store.focusUsage()
        let total = store.focusTotal()
        if Thread.isMainThread {
            apps = usage
            focusTotal = total
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.apps = usage
                self?.focusTotal = total
            }
        }
    }

    func setPopoverOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        schedule(interval: open ? openInterval : idleInterval)
        // Disques : toutes les 30 s sous les yeux de l'utilisateur, toutes les
        // 2 min sinon. Lire l'espace libre « important » réveille le service
        // de purge de macOS : 60 ms par balayage au profileur (09/10), le
        // poste le plus cher d'un relevé. Fermé, seul le journal des verdicts
        // lit le résultat — Pulse n'envoie aucune notification — et
        // l'historique ne garde qu'un point toutes les 10 min. Fermé, cette
        // clé n'est donc relue que toutes les 10 min (`lastImportantScan`) :
        // les balayages de 2 min lisent le libre strict seul, 1 ms.
        queue.async { [weak self] in
            self?.volumeScanInterval = open ? 30 : 120
            self?.mediaOpen = open
        }
        queue.async { [weak self] in self?.disks.setPanelOpen(open) }
        if open {
            tracker?.flush()
            refreshApps()
            // Un relevé forcé quelques millisecondes après le précédent ferait
            // calculer les taux CPU sur une fenêtre minuscule : l'affichage
            // serait faux au moment précis où l'utilisateur le regarde.
            queue.async { [weak self] in
                guard let self else { return }
                // Rescan forcé des incidents : le barème lit une fenêtre de
                // 24 h glissantes, et le balayage ordinaire n'a lieu que
                // toutes les 120 s. Sans ce forçage, le verdict arriverait
                // jusqu'à deux minutes en retard sur un plantage — c'est-à-dire
                // précisément au moment où l'utilisateur ouvre le panneau pour
                // comprendre ce qui vient de se passer.
                let fresh = IncidentLog.recent(since: Date().addingTimeInterval(-14 * 86_400))
                self.cachedIncidents = fresh
                self.lastIncidentScan = Date().timeIntervalSince1970
                DispatchQueue.main.async { [weak self] in self?.incidents = fresh }
                // Fermé, le dernier balayage des disques peut dater de 2 min.
                self.lastVolumeScan = 0

                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                if now - self.lastTick > 0.5 { self.tick() }
            }
        }
    }

    // MARK: - Lectures à la demande
    //
    // Interrogées seulement quand un panneau est déplié, donc pas publiées :
    // les tenir dans `@Published` ferait recalculer trente jours de points à
    // chaque relevé, pour un panneau le plus souvent fermé. `HistoryStore`
    // prend son verrou, l'appel depuis le main thread est sûr.

    func volumeHistory(for key: String, days: Double) -> [DiskPoint] {
        store.volumeHistory(for: key, days: days)
    }

    func focusByDay(days: Int) -> [(day: Date, seconds: TimeInterval)] {
        store.focusByDay(days: days)
    }

    func networkHistory(days: Int) -> [(day: Date, usage: [NetworkTracker.Usage])] {
        if let joursFiges { return Array(joursFiges.suffix(days)) }
        return networkTracker.history(days: days)
    }

    func recentSessions(days: Int) -> [EditingSession] {
        store.sessions(since: Date().addingTimeInterval(-Double(days) * 86_400))
    }

    func flush() {
        tracker?.flush()
        sessions?.flush()
        // Pas de queue.sync : HistoryStore a son propre verrou, et attendre la
        // file d'échantillonnage bloquerait le main thread sans borne si le
        // relevé en cours est coincé sur un volume réseau qui ne répond plus.
        store.saveIfNeeded(force: true)
        verdictJournal.markStop()
        networkTracker.flush()
        SeriesRecorder.shared.flush()
    }

    private func schedule(interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        lastTick = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let now = Date().timeIntervalSince1970
        let mem = MemoryMonitor.sample()
        let cpuSample = cpuMonitor.sample()
        let gpuValue = GPUMonitor.utilization()
        // Balayage complet d'environ 900 PID. Le poste le plus cher du relevé
        // fermé : au profileur du Pulse installé (11/10), 16 ms de CPU par
        // balayage sur les cœurs E où l'app tourne, le tiers de son budget —
        // et non 1,3 ms, mesuré sur un cœur P. Un seul appel au noyau par
        // processus depuis (`ProcessMonitor`).
        let processGroups = processMonitor.sample()
        // Sur la file d'échantillonnage : le détecteur porte un état qui ne
        // doit être touché que d'ici, jamais depuis le main thread.
        let exportNow = exportDetector.observe(processGroups)
        let mediaNow = mediaTracker.tick(groups: processGroups, export: exportNow, gpu: gpuValue, open: mediaOpen)
        sessions?.observe(memory: mem)
        SeriesRecorder.shared.record(cpu: cpuSample, memory: mem, gpu: gpuValue)
        CalibrationSeries.record(processGroups)   // seuil de la règle 10 (chantier 12)

        var vols: [VolumeSample]?
        if now - lastVolumeScan > volumeScanInterval {
            lastVolumeScan = now
            let complet = volumeScanInterval < 120 || now - lastImportantScan >= Self.importantInterval
            if complet { lastImportantScan = now }
            let scanned = DiskMonitor.volumes(important: complet, connus: cachedVolumes)
            store.appendVolumes(scanned, now: now)
            SeriesRecorder.shared.record(volumes: scanned)
            cachedVolumes = scanned
            vols = scanned
        }
        disks.observe(processes: processGroups, volumes: cachedVolumes, exporting: exportNow != nil)

        var newSeries: [SeriesPoint]?
        if now - lastSeriesAppend > 10 {
            lastSeriesAppend = now
            store.appendSeries(SeriesPoint(t: now,
                                           ram: mem.usedFraction,
                                           swap: Double(mem.swapUsed),
                                           cpu: cpuSample.total,
                                           gpu: gpuValue ?? 0))
            newSeries = store.series
            cachedSeries = newSeries ?? []
        }

        var newForecasts: [String: FillForecast]?
        if now - lastForecast > 60, !cachedVolumes.isEmpty {
            lastForecast = now
            var map: [String: FillForecast] = [:]
            for v in cachedVolumes {
                if let f = store.forecast(for: v.historyKey, capacity: v.total, free: v.available) {
                    map[v.historyKey] = f
                }
            }
            newForecasts = map
            cachedForecasts = map
            var ages: [String: TimeInterval] = [:]
            for v in cachedVolumes {
                if let age = store.lastSampleAge(for: v.historyKey) { ages[v.historyKey] = age }
            }
            cachedVolumeAges = ages
        }

        // Lire les en-têtes d'une centaine de rapports coûte quelques
        // millisecondes : inutile de le refaire à chaque relevé.
        var newIncidents: [Incident]?
        if now - lastIncidentScan > 120 {
            lastIncidentScan = now
            newIncidents = IncidentLog.recent(since: Date().addingTimeInterval(-14 * 86_400))
            cachedIncidents = newIncidents ?? []
        }

        // Le verdict s'évalue ICI, sur la file d'échantillonnage : l'état
        // d'hystérésis (« la condition tient depuis N secondes ») n'a pas de
        // verrou, et il doit survivre à la fermeture du popover — la cadence
        // retombe alors à 5 s mais le décompte, lui, est en secondes.
        let verdictNow = verdictEngine.evaluate(
            VerdictInput(memory: mem,
                         cpu: cpuSample,
                         volumes: cachedVolumes,
                         forecasts: cachedForecasts,
                         volumeAges: cachedVolumeAges,
                         incidents: cachedIncidents,
                         processes: processGroups,
                         export: exportNow,
                         series: cachedSeries))
        verdictJournal.record(verdictNow)

        store.saveIfNeeded()

        // Des copies figées pour le fil principal : ces variables du relevé
        // ne bougent plus, mais le compilateur veut des constantes (Swift 6).
        let (volsLus, seriesLues, previsionsLues, incidentsLus) = (vols, newSeries, newForecasts, newIncidents)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.memory = mem
            self.cpu = cpuSample
            self.gpu = gpuValue
            if let volsLus { self.volumes = volsLus }
            if let seriesLues { self.series = seriesLues }
            if let previsionsLues { self.forecasts = previsionsLues }
            self.session = self.sessions?.current
            if let incidentsLus { self.incidents = incidentsLus }
            self.processes = processGroups
            self.export = exportNow
            if let mediaNow { self.medias = mediaNow }
            self.verdict = verdictNow
        }
    }

    /// Les exports terminés depuis `depuis`, journal d'AME relu sur la file
    /// du relevé — là où `MediaTracker` le relit, jamais deux fils à la
    /// fois. Pour la règle « Export terminé », qui nomme le fichier produit
    /// et son issue (19-suivis) : appelé à la fin d'un export, règle allumée
    /// seulement. ~1 ms (la fin du journal), 25 ms la première fois.
    func exportsTermines(depuis: Date, _ fin: @escaping @Sendable @MainActor ([ExportRecord]) -> Void) {
        queue.async { [weak self] in
            guard let history = self?.mediaTracker.history else { return }
            history.relireJournal()
            let records = history.exports(since: depuis)
            DispatchQueue.main.async { MainActor.assumeIsolated { fin(records) } }
        }
    }
}

// MARK: - Banc (`--banc`)

extension Sampler {
    /// Les tâches lentes du relevé panneau fermé, par période.
    ///
    /// Une fenêtre de 20 s du banc ne les voit presque jamais, et jamais au
    /// hasard : le banc démarre comme l'app, tout tourne au premier relevé,
    /// puis une minute ou deux plus tard — après la fin du banc. Elles
    /// pèsent pourtant ~0,1 point dans le Pulse installé (relevé le 11/10,
    /// fenêtres de 10 s : 65 à 90 ms, et 100 à 170 ms quand elles tombent).
    /// `--banc` les rend dues au relevé suivant, mesure ce relevé, et répartit
    /// l'écart sur leur période.
    enum TachesLentes: CaseIterable {
        /// Espace libre strict des volumes, et incidents.
        case deuxMinutes
        /// Prévision de remplissage, identités des processus, history.json
        /// et reseau.json (écrits seulement si la persistance est active).
        case uneMinute
        /// L'espace purgeable des volumes (`lastImportantScan`).
        case dixMinutes

        /// Leur période panneau fermé, en secondes (`volumeScanInterval`,
        /// `lastIncidentScan`, `lastForecast`, `saveIfNeeded`,
        /// `importantInterval`).
        var periode: Double {
            switch self {
            case .deuxMinutes: return 120
            case .uneMinute: return 60
            case .dixMinutes: return Sampler.importantInterval
            }
        }

        var nom: String {
            switch self {
            case .deuxMinutes: return "disques et incidents"
            case .uneMinute: return "prévision, identités, écritures"
            case .dixMinutes: return "espace purgeable des volumes"
            }
        }
    }

    /// Sur la file d'échantillonnage, comme tout l'état du relevé : la tâche
    /// tourne au relevé suivant, puis reprend sa période.
    func rendDues(_ taches: TachesLentes) {
        queue.async { [weak self] in
            guard let self else { return }
            switch taches {
            case .deuxMinutes:
                self.lastVolumeScan = 0
                self.lastIncidentScan = 0
            case .uneMinute:
                self.lastForecast = 0
                self.processMonitor.oublieLesIdentites()
                self.store.rendSauvegardeDue()
                self.networkTracker.rendSauvegardeDue()
            case .dixMinutes:
                self.lastVolumeScan = 0
                self.lastImportantScan = 0
            }
        }
    }
}

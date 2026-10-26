import Foundation
import Darwin

/// Un fichier média en cours d'écriture par un encodeur ou une application
/// de montage : la sortie d'un export, vue de l'extérieur.
struct WrittenFile: Equatable, Identifiable {
    var path: String
    var app: String
    var bytes: UInt64
    /// Octets par seconde depuis le relevé précédent, `nil` au premier.
    var rate: Double?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Ce que le chantier 08 publie : carte graphique et moteurs, exports, cache.
struct MediaState: Equatable {
    var engines: MediaSample?
    var exportsToday: [ExportRecord] = []
    /// Le plus récent, aujourd'hui ou avant.
    var lastExport: ExportRecord?
    var cache: MediaCache.Measure?
    /// Fichiers média tenus ouverts en écriture par un encodeur ou une app de
    /// montage. Instrument : ne nourrit aucune détection tant qu'un export
    /// réel depuis Premiere n'a pas été relevé (08-medias.md).
    var writing: [WrittenFile] = []
}

/// Le module médias, branché sur le `Sampler` en une ligne par relevé.
///
/// Ce qu'il coûte, mesuré le 11/10 :
/// - panneau fermé : RIEN, carte affichée ou non. Ni `stat`, ni IOReport,
///   ni historique chargé — tout naît à la première ouverture. Rien n'est
///   perdu : le journal d'AME garde les exports, et sa fin est relue à
///   l'ouverture suivante ;
/// - panneau ouvert : un `stat` du journal par relevé (69 µs), pour la
///   ligne « Export » de la carte Montage ;
/// - et seulement si la carte Médias est affichée ou si le dépliant des
///   exports est ouvert : IOReport et les clients du GPU (4,1 ms), les
///   fichiers des apps de montage (0,6 ms), la liste de leurs processus
///   toutes les 30 s (6,6 ms), le cache média toutes les 30 min en tâche de
///   fond.
///
/// Touché depuis la file d'échantillonnage seulement, sauf `history`, qui
/// a son verrou.
final class MediaTracker {
    /// La carte est-elle affichée (réglage d'Isma) ? Écrit depuis le fil
    /// principal par `MediaModule.stateDidChange`, lu sur la file
    /// d'échantillonnage : d'où le verrou. Vraie par défaut — `--snapshot`
    /// et `--probe` ne passent pas par le registre.
    private static let shownLock = NSLock()
    nonisolated(unsafe) private static var shown = true

    static func setShown(_ value: Bool) {
        shownLock.lock(); shown = value; shownLock.unlock()
    }

    static var isShown: Bool {
        shownLock.lock(); defer { shownLock.unlock() }
        return shown
    }

    /// Les vues ouvertes qui montrent le GPU et l'encodeur hors de la carte
    /// Médias : le dépliant des exports de la carte Montage.
    nonisolated(unsafe) private static var viewers = 0

    static func addViewer() {
        shownLock.lock(); viewers += 1; shownLock.unlock()
    }

    static func removeViewer() {
        shownLock.lock(); viewers = max(0, viewers - 1); shownLock.unlock()
    }

    /// `--snapshot` : `ImageRenderer` ne déclenche pas `onAppear`, le
    /// dépliant ne s'y annoncerait jamais.
    nonisolated(unsafe) private static var forced = false

    /// Quelqu'un regarde-t-il le GPU et l'encodeur ?
    static var wantsEngines: Bool {
        shownLock.lock(); defer { shownLock.unlock() }
        return shown || viewers > 0 || forced
    }

    /// Créé au premier relevé panneau ouvert, carte affichée : l'abonnement
    /// IOReport et la table des fréquences ne coûtent rien tant que personne
    /// ne regarde. File d'échantillonnage seulement.
    private lazy var monitor = MediaMonitor()
    private let cache = MediaCacheProbe()
    private let historyLock = NSLock()
    private var loadedHistory: ExportHistory?

    /// - Parameter history: pour les tests, un historique sur des fichiers
    ///   jetables — jamais le journal ni l'exports.json d'Isma.
    init(history: ExportHistory? = nil) {
        loadedHistory = history
    }

    /// L'historique des exports, chargé (exports.json) à la première
    /// demande. Lu aussi depuis le fil principal par la carte : d'où le verrou.
    var history: ExportHistory {
        historyLock.lock(); defer { historyLock.unlock() }
        if let loadedHistory { return loadedHistory }
        let created = ExportHistory()
        loadedHistory = created
        return created
    }
    private var previousSizes: [String: (bytes: UInt64, time: Double)] = [:]
    private var pidCache: (time: Double, key: [String], list: [(pid_t, ProcessGroup)])?

    /// Lance tout de suite la mesure du cache, sans attendre l'ouverture du
    /// panneau : pour `--snapshot`, qui rend la carte six secondes après le
    /// lancement. L'app, elle, ne l'appelle pas — 2 s de parcours au
    /// démarrage compteraient dans le budget panneau fermé.
    func warmUp() {
        Self.shownLock.lock(); Self.forced = true; Self.shownLock.unlock()
        cache.refreshIfDue { _ in }
    }

    /// - Parameters:
    ///   - groups: le relevé des applications du même tick.
    ///   - export: l'export vu en direct par `ExportDetector`.
    ///   - gpu: l'occupation du GPU lue par le socle au même relevé. La carte
    ///     reprend CE chiffre : relu quelques millisecondes plus tard, le
    ///     compteur du pilote a donné 0 % quand la carte Processeur affichait
    ///     92 % sur le même rendu (11/10).
    ///   - open: panneau ouvert.
    /// - Returns: l'état à publier, ou `nil` panneau fermé.
    func tick(groups: [ProcessGroup], export: ExportActivity?, gpu: Double? = nil, open: Bool) -> MediaState? {
        // Panneau fermé : aucun travail, pas même le `stat` du journal.
        guard open else {
            previousSizes = [:]
            pidCache = nil
            return nil
        }
        history.update(live: export, journalWanted: Self.isShown)
        var state = MediaState()
        state.exportsToday = history.today()
        state.lastExport = history.exports(since: Date().addingTimeInterval(-ExportHistory.retention)).first
        // Ni carte Médias ni dépliant : l'historique suffit à la ligne
        // « Export » de la carte Montage.
        guard Self.wantsEngines else {
            previousSizes = [:]
            pidCache = nil
            return state
        }
        state.engines = monitor.sample()
        if let gpu { state.engines?.gpuUtilization = gpu }
        cache.refreshIfDue { _ in }
        state.cache = cache.current
        state.writing = writtenFiles(groups)
        return state
    }

    /// Les sorties en cours : fichiers média ouverts en écriture par les
    /// processus des encodeurs et des applications de montage.
    private func writtenFiles(_ groups: [ProcessGroup]) -> [WrittenFile] {
        let watched = groups.filter {
            let kind = AppKind.of(bundleId: $0.bundleId)
            return (kind == .encoding || kind == .editing) && $0.bundlePath != nil
        }
        guard !watched.isEmpty else { previousSizes = [:]; return [] }
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        var out: [WrittenFile] = []
        var sizes: [String: (UInt64, Double)] = [:]
        // La liste des PID se garde 30 s : la refaire coûte un parcours des
        // ~900 processus, et Premiere ne change pas d'auxiliaires à chaque
        // seconde. Elle est refaite aussitôt qu'une app de la liste change.
        let key = watched.map(\.bundleId).sorted()
        if pidCache == nil || pidCache!.key != key || now - pidCache!.time > 30 {
            pidCache = (now, key, Self.pids(of: watched))
        }
        for (pid, group) in pidCache?.list ?? [] {
            for path in OpenFiles.mediaWritten(by: pid) where !out.contains(where: { $0.path == path }) {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
                var rate: Double?
                if let before = previousSizes[path], now > before.time, bytes >= before.bytes {
                    rate = Double(bytes - before.bytes) / (now - before.time)
                }
                sizes[path] = (bytes, now)
                out.append(WrittenFile(path: path, app: Fmt.appName(group.name), bytes: bytes, rate: rate))
            }
        }
        previousSizes = sizes
        return out
    }

    /// Les processus dont l'exécutable vit dans le bundle de l'un des groupes.
    /// Un parcours des PID (1 ms environ), fait panneau ouvert seulement.
    /// Les moteurs web des panneaux d'extension : 60 processus sous
    /// Premiere (relevé du 11/10), qui tiennent leurs journaux et leurs
    /// caches mais n'écrivent jamais une vidéo. Les parcourir doublait le
    /// coût du relevé.
    static func ignore(path: String) -> Bool {
        path.contains("CEPHtmlEngine")
    }

    static func pids(of groups: [ProcessGroup]) -> [(pid_t, ProcessGroup)] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, count)
        guard written > 0 else { return [] }
        var out: [(pid_t, ProcessGroup)] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(written) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(nulTerminated: buffer)
            guard !ignore(path: path) else { continue }
            if let group = groups.first(where: { path.hasPrefix($0.bundlePath! + "/") }) {
                out.append((pid, group))
            }
        }
        return out
    }
}

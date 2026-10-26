import Foundation
import AppKit

struct EditingSession: Codable, Identifiable {
    var bundleId: String
    var name: String
    var start: Double
    var end: Double?
    var peakMemoryFraction: Double = 0
    var peakMemoryBytes: Double = 0
    var peakSwap: Double = 0

    var id: String { "\(bundleId)-\(start)" }

    init(bundleId: String, name: String, start: Double) {
        self.bundleId = bundleId
        self.name = name
        self.start = start
    }

    /// Tolérant aux champs absents, pour la même raison que HistoryStore.File :
    /// cette structure gagnera des champs (exports, incidents) et les sessions
    /// déjà enregistrées doivent survivre. Sans application ni début, une
    /// session ne veut rien dire : elle échoue SEULE, `File` la saute.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        name = c.tolerant(String.self, .name) ?? bundleId
        start = try c.decode(Double.self, forKey: .start)
        end = c.tolerant(Double.self, .end)
        peakMemoryFraction = c.tolerant(Double.self, .peakMemoryFraction) ?? 0
        peakMemoryBytes = c.tolerant(Double.self, .peakMemoryBytes) ?? 0
        peakSwap = c.tolerant(Double.self, .peakSwap) ?? 0
    }
    var isOpen: Bool { end == nil }
    var duration: TimeInterval { (end ?? Date().timeIntervalSince1970) - start }
}

/// Ouvre une session quand une application de montage démarre, la referme
/// quand elle quitte, et retient au passage les pics de mémoire et de swap.
///
/// C'est l'unité qui intéresse un monteur : « ma session Premiere de cet
/// après-midi » veut dire quelque chose, « la mémoire à 14h07 » non.
final class SessionTracker {
    private let store: HistoryStore
    private let onChange: () -> Void
    private let lock = NSLock()
    private var open: [String: EditingSession] = [:]
    /// Dernière fois que chaque application de montage est passée au premier plan.
    private var lastActive: [String: Double] = [:]

    init(store: HistoryStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(launched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(terminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(activated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Une app de montage déjà ouverte au démarrage de Pulse compte aussi :
        // sa date de lancement donne le vrai début de session, pas l'instant présent.
        for app in NSWorkspace.shared.runningApplications {
            adopt(app)
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Cycle de vie

    @objc private func launched(_ note: Notification) {
        adopt(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    @objc private func activated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              AppKind.of(bundleId: bundleId) == .editing else { return }
        lock.lock(); defer { lock.unlock() }
        lastActive[bundleId] = Date().timeIntervalSince1970
    }

    @objc private func terminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        lock.lock()
        lastActive.removeValue(forKey: bundleId)
        guard var session = open.removeValue(forKey: bundleId) else { lock.unlock(); return }
        session.end = Date().timeIntervalSince1970
        lock.unlock()

        store.appendSession(session)
        onChange()
    }

    private func adopt(_ app: NSRunningApplication?) {
        guard let app, let bundleId = app.bundleIdentifier,
              AppKind.of(bundleId: bundleId) == .editing else { return }
        lock.lock(); defer { lock.unlock() }
        guard open[bundleId] == nil else { return }
        let start = app.launchDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        var session = EditingSession(bundleId: bundleId,
                                     name: app.localizedName ?? bundleId,
                                     start: start)
        // Au redémarrage de Pulse, l'application de montage tourne toujours et
        // sa date de lancement est inchangée : l'identifiant de session est
        // donc identique à celui déjà persisté. Sans réhydratation, les pics
        // repartiraient de zéro et le prochain appendSession — idempotent par
        // identifiant — ÉCRASERAIT les valeurs déjà mesurées.
        if let saved = store.session(id: session.id) {
            session.peakMemoryFraction = max(session.peakMemoryFraction, saved.peakMemoryFraction)
            session.peakMemoryBytes = max(session.peakMemoryBytes, saved.peakMemoryBytes)
            session.peakSwap = max(session.peakSwap, saved.peakSwap)
        }
        open[bundleId] = session
        if app.isActive { lastActive[bundleId] = Date().timeIntervalSince1970 }
    }

    // MARK: - Pics

    /// Appelé depuis la file d'échantillonnage à chaque relevé.
    ///
    /// Les sessions ouvertes sont réécrites au passage : `pkill`, un forçage à
    /// quitter ou une coupure de courant n'exécutent jamais
    /// `applicationWillTerminate`, et une session qui n'existerait qu'en
    /// mémoire serait perdue en entier.
    func observe(memory: MemorySample) {
        lock.lock()
        guard !open.isEmpty else { lock.unlock(); return }
        let fraction = memory.usedFraction
        let used = Double(memory.used)
        let swap = Double(memory.swapUsed)
        for key in Array(open.keys) {
            guard var session = open[key] else { continue }
            session.peakMemoryFraction = max(session.peakMemoryFraction, fraction)
            session.peakMemoryBytes = max(session.peakMemoryBytes, used)
            session.peakSwap = max(session.peakSwap, swap)
            open[key] = session
        }
        let snapshot = Array(open.values)
        lock.unlock()
        // Hors verrou : appendSession prend celui du store, pas celui-ci.
        for session in snapshot { store.appendSession(session) }
    }

    /// La session affichée quand plusieurs applications de montage sont
    /// ouvertes : celle où l'utilisateur travaille réellement, c'est-à-dire la
    /// dernière passée au premier plan. Trier par date de lancement mettrait en
    /// avant une app ouverte le matin et oubliée depuis.
    var current: EditingSession? {
        lock.lock(); defer { lock.unlock() }
        return open.values.max { a, b in
            (lastActive[a.bundleId] ?? a.start) < (lastActive[b.bundleId] ?? b.start)
        }
    }

    /// Referme les sessions ouvertes sans les perdre, quand Pulse quitte.
    func flush() {
        lock.lock()
        let sessions = open.values
        lock.unlock()
        for var session in sessions {
            session.end = Date().timeIntervalSince1970
            store.appendSession(session)
        }
    }
}

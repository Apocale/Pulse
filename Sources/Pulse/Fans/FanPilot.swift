import Foundation
import AppKit
import Combine
import PulseFanKit

/// Le pilote des ventilateurs, côté Pulse (chantier 14).
///
/// En mode AUTOMATIQUE — le défaut —, il ne fait rien : ni minuterie, ni
/// lecture, ni connexion au helper. Hors de l'automatique, et seulement si le
/// helper est installé, il relit toutes les 5 s la température et les bornes
/// des ventilateurs (le lecteur en LECTURE SEULE du chantier 04, ~0,6 ms),
/// en tire une consigne et l'envoie au helper — c'est aussi le battement de
/// cœur : sans lui, le helper rend la main à macOS au bout de 15 s.
///
/// Les sécurités sont dans le helper (`FanController`) ; ici, ce que seul
/// Pulse voit : la température qui ne se lit plus (trois lectures de suite →
/// automatique), la veille, la sortie de l'app.
@MainActor
final class FanPilot: ObservableObject {
    static let shared = FanPilot()

    @Published private(set) var settings: FanSettings
    /// La dernière réponse du helper ; nil s'il n'a pas répondu.
    @Published private(set) var helper: FanStatus?
    /// Le dernier battement : température, niveau, consignes, ou ce qui
    /// empêche de piloter.
    @Published private(set) var report = FanEngine.Report()

    let store: FanSettingsStore
    private let engine = FanEngine()
    private var asleep = false
    private var observers: [NSObjectProtocol] = []

    init(store: FanSettingsStore = FanSettingsStore()) {
        self.store = store
        settings = store.load()
        // `--snapshot x.png --reglages ventilateurs --ventilateurs curve` :
        // la page dans un autre mode, EN MÉMOIRE (rien n'est écrit).
        if !store.writes, let raw = Snapshot.value(after: "--ventilateurs"), let mode = FanMode(rawValue: raw) {
            settings.mode = mode
        }
        engine.onReport = { [weak self] report in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.report = report
                    if let status = report.status { self?.helper = status }
                }
            }
        }
    }

    /// Au lancement de Pulse : si Isma avait choisi un mode, il reprend —
    /// le helper, lui, ne reprend jamais seul. Automatique : rien.
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FanPilot.shared.setAsleep(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            // Le helper refuse toute consigne dans les 10 s qui suivent le
            // réveil : reprise juste après.
            DispatchQueue.main.asyncAfter(deadline: .now() + FanProtocol.wakeGrace + 1) {
                MainActor.assumeIsolated { FanPilot.shared.setAsleep(false) }
            }
        })
        apply()
    }

    /// Un réglage changé depuis la page Ventilateurs.
    func update(_ change: (inout FanSettings) -> Void) {
        var next = settings
        change(&next)
        next.curve = next.curve.sanitized
        next.fixedLevel = min(max(next.fixedLevel, 0), 1)
        guard next != settings else { return }
        settings = next
        store.save(next)
        apply()
    }

    /// À la sortie de l'app : la main à macOS tout de suite, sans attendre
    /// que le helper voie la connexion se fermer (il le verrait aussi).
    func shutdown() {
        engine.halt(sendAutomatic: true, wait: true)
    }

    /// Une demande d'état, pour la page et pour `--probe` : n'écrit rien.
    /// Sans helper installé, aucune connexion n'est tentée.
    func refresh() {
        guard FanHelperService.isInstalled else {
            helper = nil
            return
        }
        engine.status()
    }

    private func setAsleep(_ value: Bool) {
        asleep = value
        apply()
    }

    private func apply() {
        if settings.mode == .automatic || asleep || !FanHelperService.isInstalled {
            engine.halt(sendAutomatic: true, wait: false)
            if settings.mode != .automatic, !FanHelperService.isInstalled {
                report = FanEngine.Report(problem: "Helper non installé : macOS garde la main.")
            } else {
                report = FanEngine.Report()
            }
            return
        }
        engine.run(settings)
    }
}

/// Le moteur du pilote : tout son état vit sur SA file.
final class FanEngine: @unchecked Sendable {
    /// Ce que montre la page, à chaque battement.
    struct Report: Equatable {
        var temperature: Double?
        var level: Double?
        var targets: [Double] = []
        var status: FanStatus?
        var problem: String?
    }

    var onReport: (Report) -> Void = { _ in }

    private let queue = DispatchQueue(label: "com.isma.pulse.ventilateurs", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var settings = FanSettings()
    /// Créés à la première consigne, rendus au retour en automatique : en
    /// automatique, Pulse ne tient même pas de connexion au SMC pour ça.
    private var monitor: SensorMonitor?
    private var client: FanXPCClient?
    private var follower = FanFollower()
    private var misses = 0
    /// Une consigne a été envoyée depuis le dernier automatique.
    private var driving = false

    /// Trois lectures de suite sans température : automatique.
    static let maxMisses = 3

    func run(_ settings: FanSettings) {
        queue.async { [self] in
            if settings.mode != self.settings.mode || settings.sensor != self.settings.sensor { follower.reset() }
            self.settings = settings
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: FanProtocol.heartbeat, leeway: .milliseconds(500))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// Arrête le battement ; si une consigne était posée, rend la main.
    func halt(sendAutomatic: Bool, wait: Bool) {
        let work: @Sendable () -> Void = { [self] in
            timer?.cancel()
            timer = nil
            monitor = nil
            follower.reset()
            misses = 0
            if sendAutomatic, driving, let client {
                driving = false
                if wait {
                    _ = client.sendAndWait(.automatic(), timeout: 1)
                } else {
                    client.send(.automatic()) { [weak self] status in self?.onReport(Report(status: status)) }
                }
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    func status() {
        queue.async { [self] in
            link().send(.status) { [weak self] status in
                self?.onReport(Report(status: status, problem: status == nil ? "Le helper ne répond pas." : nil))
            }
        }
    }

    private func link() -> FanXPCClient {
        if let client { return client }
        let made = FanXPCClient()
        client = made
        return made
    }

    /// Toutes les 5 s hors de l'automatique, sur la file du moteur.
    private func tick() {
        if monitor == nil { monitor = SensorMonitor() }
        guard let sample = monitor?.sample(withReport: false) else { return }
        let fans = sample.fans.map {
            FanReading(index: $0.index, actual: $0.rpm, min: $0.min, max: $0.max, target: $0.target, manual: $0.forced)
        }
        let decision = Self.decide(settings: settings, fans: fans,
                                   cpu: sample.cpuTemperature, gpu: sample.gpuTemperature,
                                   follower: &follower, misses: &misses)
        switch decision {
        case .hold(let targets, let level, let temperature):
            driving = true
            link().send(.hold(targets)) { [weak self] status in
                var report = Report(temperature: temperature, level: level, targets: targets, status: status)
                if let status, !status.accepted { report.problem = "Refusé : \(status.refusal?.phrase ?? "?")." }
                if status == nil { report.problem = "Le helper ne répond pas : il rend la main seul au bout de 15 s." }
                self?.onReport(report)
            }
        case .wait(let problem):
            onReport(Report(problem: problem))
        case .release(let reason, let problem):
            driving = false
            link().send(.automatic(reason)) { [weak self] status in
                self?.onReport(Report(status: status, problem: problem))
            }
        }
    }

    enum Decision: Equatable {
        case hold(targets: [Double], level: Double, temperature: Double?)
        /// Rien d'envoyé ce battement-ci (le helper garde la consigne
        /// précédente, au plus 15 s).
        case wait(String)
        /// Rendre la main à macOS.
        case release(FanFallback, String)
    }

    /// Le choix d'un battement, pur et testé : quel niveau, quelles
    /// consignes, ou pourquoi rendre la main.
    static func decide(settings: FanSettings, fans: [FanReading], cpu: Double?, gpu: Double?,
                       follower: inout FanFollower, misses: inout Int) -> Decision {
        guard !fans.isEmpty, fans.allSatisfy(\.limitsAreSane) else {
            misses += 1
            return misses >= maxMisses ? .release(.sensorLost, "Les ventilateurs ne se lisent plus : macOS reprend la main.")
                                       : .wait("Lecture des ventilateurs manquée.")
        }
        switch settings.mode {
        case .automatic:
            return .release(.requested, "")
        case .fixed:
            misses = 0
            let level = settings.fixedLevel
            return .hold(targets: FanPlan.targets(level: level, fans: fans), level: level, temperature: nil)
        case .curve:
            guard let celsius = settings.sensor.pick(cpu: cpu, gpu: gpu) else {
                misses += 1
                return misses >= maxMisses ? .release(.sensorLost, "La température ne se lit plus : macOS reprend la main.")
                                           : .wait("Température manquée.")
            }
            misses = 0
            let held = follower.feed(celsius)
            let level = FanPlan.quantized(settings.curve.level(at: held))
            return .hold(targets: FanPlan.targets(level: level, fans: fans), level: level, temperature: celsius)
        }
    }
}

/// `ventilateurs.json`, à côté de `reglages.json` : fichier à part, relu de
/// façon tolérante (`FanSettings`), jamais écrit quand la persistance est
/// coupée (`--snapshot`, `--probe`, `--banc`). Absent : automatique.
struct FanSettingsStore {
    let url: URL
    /// Faux sous `--snapshot`, `--probe`, `--banc` (`Persistence`) : lu,
    /// jamais écrit. Figé à la création, comme `SettingsStore`.
    let writes: Bool

    init(url: URL = FanSettingsStore.defaultURL, writes: Bool? = nil) {
        self.url = url
        self.writes = writes ?? Persistence.enabled
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("ventilateurs.json")
    }

    func load() -> FanSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(FanSettings.self, from: data) else { return FanSettings() }
        return settings
    }

    func save(_ settings: FanSettings) {
        guard writes else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

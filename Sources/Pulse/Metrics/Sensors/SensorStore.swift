import Foundation
import Combine

/// Les capteurs, publiés pour l'interface.
///
/// Sa propre file et sa propre minuterie, à côté du `Sampler` et non dedans :
/// le module (`SensorsModule`) règle la cadence selon l'état que le registre
/// lui donne. 1,5 s panneau ouvert, comme le `Sampler` ; 30 s panneau fermé,
/// pour que la puissance soit là dès l'ouverture et que le segment de barre
/// de menus, s'il est allumé, suive ; ARRÊT complet quand la carte est
/// masquée et le segment éteint. Une lecture coûte ~4 ms de CPU (`--probe`,
/// section CAPTEURS) : 0,013 % d'un cœur panneau fermé.
///
/// Le lecteur est créé à la première lecture, sur la file : sa création
/// (abonnement IOReport, tables DVFS) coûte ~0,14 s de CPU, une seule fois,
/// jamais sur le main thread.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : l'état de lecture vit sur sa file,
/// les valeurs publiées sont écrites sur le fil principal.
final class SensorStore: ObservableObject, @unchecked Sendable {
    /// Celui de l'app, que le module pilote. `--snapshot --capteurs` crée le
    /// sien.
    @MainActor static let shared = SensorStore(cadence: .stopped)

    @Published private(set) var sample: SensorSample?

    static let openInterval: TimeInterval = 1.5
    static let closedInterval: TimeInterval = 30

    enum Cadence: Equatable { case stopped, closed, open }

    private let queue = DispatchQueue(label: "com.isma.pulse.capteurs", qos: .utility)
    /// Touchés seulement depuis `queue`.
    private var monitor: SensorMonitor?
    private var warmupScheduled = false
    /// IOReport (puissance, fréquences) seulement panneau ouvert.
    private var readReport = false
    /// Touchés seulement depuis le main thread.
    private var timer: DispatchSourceTimer?
    private(set) var cadence: Cadence = .stopped

    init(cadence: Cadence = .open) {
        setCadence(cadence)
    }

    deinit { timer?.cancel() }

    /// Banc d'essai (chantier 03) : publie un relevé figé, arrête la lecture,
    /// et plus rien ne la relance — pour les images de référence de
    /// `--rendus`.
    func figer(_ releve: SensorSample) {
        setCadence(.stopped)
        fige = true
        sample = releve
    }

    /// Touché seulement depuis le main thread, comme `cadence`.
    private var fige = false

    /// Change de rythme. À l'ouverture, un relevé tout de suite : la puissance
    /// est alors la moyenne depuis la dernière lecture, jusqu'à 30 s — juste,
    /// et remplacée 1,5 s plus tard par celle de l'instant.
    func setCadence(_ new: Cadence) {
        guard !fige, new != cadence else { return }
        cadence = new
        timer?.cancel()
        timer = nil
        // Avant la minuterie, sur la même file sérielle : la première lecture
        // voit déjà le bon mode.
        let withReport = new == .open
        queue.async { [weak self] in self?.readReport = withReport }
        guard new != .stopped else { return }
        let interval = new == .open ? Self.openInterval : Self.closedInterval
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Fermé, une marge de 2 s : le système regroupe le réveil avec
        // d'autres, ce qui compte plus que la précision d'une lecture lente.
        t.schedule(deadline: new == .open ? .now() : .now() + interval, repeating: interval,
                   leeway: .milliseconds(new == .open ? 300 : 2000))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if monitor == nil { monitor = SensorMonitor() }
        guard let fresh = monitor?.sample(withReport: readReport) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.fige else { return }
            self.sample = fresh
        }
        record(fresh)
        // À l'ouverture, IOReport n'a encore qu'une référence : ni puissance
        // ni fréquence. Une seconde lecture 0,6 s plus tard les donne, sans
        // attendre le relevé suivant. Vu au rendu du panneau entier (11/10) :
        // sans elle, la référence arrivait si tard que les anneaux sortaient
        // « illisible ».
        if fresh.reportPending, !warmupScheduled {
            warmupScheduled = true
            queue.asyncAfter(deadline: .now() + IOReportSampler.minimumInterval + 0.1) { [weak self] in
                self?.warmupScheduled = false
                self?.tick()
            }
        }
    }

    // MARK: - Historique longue durée (chantier 02)

    /// Quatre séries, une par organe — pas vingt capteurs : environ 1 Mo
    /// chacune à 90 jours. Ce qu'un monteur veut retrouver : la chaleur et le
    /// souffle pendant un export, la puissance de la machine entière.
    static let historyKeys = (cpu: "capteurs.processeur", gpu: "capteurs.graphique",
                              fans: "capteurs.ventilateurs", power: "capteurs.puissance")
    /// Touché seulement depuis `queue`.
    private var declared = false

    /// Depuis la file des capteurs ; rien n'est écrit quand la persistance est
    /// coupée (`--snapshot`, `--banc`), c'est `History` qui le garantit.
    private func record(_ s: SensorSample) {
        let keys = Self.historyKeys
        if !declared {
            declared = true
            History.declare(SeriesInfo(keys.cpu, "Processeur, température", .celsius))
            History.declare(SeriesInfo(keys.gpu, "Carte graphique, température", .celsius))
            // Le maximum d'Apple (`F0Mx`) est un dénominateur réel.
            History.declare(SeriesInfo(keys.fans, "Ventilateurs", .rpm, bound: SensorSample.mean(s.fans.map(\.max))))
            History.declare(SeriesInfo(keys.power, "Machine entière, puissance", .watts))
        }
        if let value = s.cpuTemperature { History.record(keys.cpu, value) }
        if let value = s.gpuTemperature { History.record(keys.gpu, value) }
        if let value = SensorSample.mean(s.fans.map(\.rpm)) { History.record(keys.fans, value) }
        if let value = s.systemPower { History.record(keys.power, value) }
    }
}

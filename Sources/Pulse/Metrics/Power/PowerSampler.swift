import Foundation
import Combine

/// L'échantillonneur de la carte Énergie, à sa propre cadence, sur sa propre
/// file : la batterie bouge à l'échelle de la minute, pas de la seconde.
///
/// - Panneau ouvert : batterie toutes les 5 s, accessoires toutes les 30 s.
/// - Panneau fermé : un relevé toutes les 5 min, pour l'historique (charge
///   et consommation, base du chantier 02). Ni accessoires, ni processus
///   lancé.
/// - Santé selon macOS (`system_profiler`, 0,09 s de processeur) : une fois
///   au lancement — sans quoi l'anneau passerait de 82 à 81 % sous les yeux
///   d'Isma à la première ouverture —, puis toutes les 6 h, panneau ouvert.
/// - Carte masquée : plus rien (`update(enabled:panelOpen:)`).
///
/// Même patron que `Sampler` : l'état propre à la file n'est touché que
/// d'elle, les `@Published` seulement depuis le main thread.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : la lecture vit sur sa file, la
/// publication sur le fil principal.
final class PowerSampler: ObservableObject, @unchecked Sendable {
    @Published private(set) var sample = PowerSample()
    @Published private(set) var accessories: [PowerAccessory] = []
    /// Nil tant que `system_profiler` n'a pas répondu, ou s'il a échoué : la
    /// carte affiche alors la santé calculée, et le dit.
    @Published private(set) var health: BatteryHealthReport?

    /// Les séries de l'historique longue durée (chantier 02).
    static let chargeKey = "energie.charge"
    static let consumptionKey = "energie.consommation"
    static let series = [SeriesInfo(chargeKey, "Charge de la batterie", .fraction, bound: 1),
                         // Pas de dénominateur : la machine peut tirer plus que son
                         // chargeur, la batterie complétant (règle dure n° 7).
                         SeriesInfo(consumptionKey, "Consommation", .watts)]

    static let openInterval: TimeInterval = 5
    static let closedInterval: TimeInterval = 300
    static let accessoryInterval: TimeInterval = 30
    static let healthInterval: TimeInterval = 6 * 3600

    private let queue = DispatchQueue(label: "com.isma.pulse.power", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Propres à la file.
    private var isOpen = false
    private var isEnabled = true
    private var lastAccessories: Date = .distantPast
    private var lastHealth: Date = .distantPast
    private var lastRecorded: (date: Date, sample: PowerSample)?
    /// Sa propre connexion au SMC, ouverte au premier relevé, sur la file.
    private lazy var smc: SMCReader? = SMCReader()

    init() {
        Self.series.forEach(History.declare)
        // Une première lecture tout de suite (1,2 ms) : une carte créée
        // aussitôt — rendu hors écran, première ouverture — a déjà ses
        // chiffres.
        sample = PowerMonitor.read(smc: SMCReader())
        accessories = PowerMonitor.accessories()
        queue.async { [weak self] in self?.tick() }
        schedule(Self.closedInterval)
    }

    /// Banc d'essai (chantier 03) : un relevé figé, sans lecture ni
    /// minuterie, que rien ne change ensuite — pour les images de référence
    /// de `--rendus`. Installé par `EnergyModule.installer`.
    init(figé sample: PowerSample, accessories: [PowerAccessory], health: BatteryHealthReport?) {
        fige = true
        self.sample = sample
        self.accessories = accessories
        self.health = health
    }

    /// Vrai pour un échantillonneur figé : `update` ne le relance jamais.
    private var fige = false

    deinit { timer?.cancel() }

    func setPanelOpen(_ open: Bool) {
        update(enabled: true, panelOpen: open)
    }

    /// Carte masquée par Isma : plus aucun relevé, coût nul. Affichée : la
    /// cadence du panneau, ouvert ou fermé.
    func update(enabled: Bool, panelOpen: Bool) {
        guard !fige else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let open = enabled && panelOpen
            guard enabled != self.isEnabled || open != self.isOpen else { return }
            self.isEnabled = enabled
            self.isOpen = open
            guard enabled else {
                self.timer?.cancel()
                self.timer = nil
                return
            }
            self.schedule(open ? Self.openInterval : Self.closedInterval)
            if open { self.tick() }
        }
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        let reading = PowerMonitor.read(smc: smc)

        var newAccessories: [PowerAccessory]?
        if isOpen, now.timeIntervalSince(lastAccessories) >= Self.accessoryInterval - 1 {
            lastAccessories = now
            newAccessories = PowerMonitor.accessories()
        }

        // Rien n'est écrit quand `Persistence.enabled` est faux : l'historique
        // y veille lui-même (`--snapshot`, `--banc`).
        for (key, value) in Self.historyValues(previous: lastRecorded, current: reading, now: now) {
            History.record(key, value)
        }
        lastRecorded = (now, reading)

        let accessoires = newAccessories   // figée pour le fil principal
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.sample != reading { self.sample = reading }
            if let accessoires, accessoires != self.accessories { self.accessories = accessoires }
        }

        // Le seul processus lancé par la carte : au lancement, puis panneau
        // ouvert seulement, jamais plus d'une fois toutes les 6 h, et jamais
        // sans batterie.
        if isOpen || lastHealth == .distantPast, reading.hasBattery,
           now.timeIntervalSince(lastHealth) >= Self.healthInterval {
            lastHealth = now
            if let report = PowerMonitor.healthReport() {
                DispatchQueue.main.async { [weak self] in self?.health = report }
            }
        }
    }

    /// Ce qu'un relevé verse à l'historique : la charge, et la consommation.
    ///
    /// Panneau fermé, les relevés sont espacés de 5 min : un instant y vaut
    /// un tirage au sort entre deux pics d'export. La consommation est alors
    /// la MOYENNE de l'intervalle, tirée du compteur de la jauge ; à 5 s
    /// d'écart, la valeur du moment (SMC), celle que la carte affiche.
    static func historyValues(previous: (date: Date, sample: PowerSample)?, current: PowerSample,
                              now: Date) -> [(String, Double)] {
        var values: [(String, Double)] = []
        if current.hasBattery, let level = current.level { values.append((chargeKey, level)) }
        let spaced = previous.map { now.timeIntervalSince($0.date) >= 60 } ?? false
        if spaced, let average = averageWatts(from: previous?.sample, to: current) {
            values.append((consumptionKey, average))
        } else if let watts = current.displayedWatts {
            values.append((consumptionKey, watts))
        }
        return values
    }

    /// Puissance moyenne entre deux lectures du compteur de la jauge, en
    /// watts. Nil si le compteur n'a pas avancé ou est reparti de zéro.
    static func averageWatts(from previous: PowerSample?, to current: PowerSample) -> Double? {
        guard let s0 = previous?.loadSum, let c0 = previous?.loadCount,
              let s1 = current.loadSum, let c1 = current.loadCount, c1 > c0, s1 >= s0 else { return nil }
        return (s1 - s0) / (c1 - c0) / 1000
    }
}

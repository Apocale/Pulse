import Foundation
import WidgetKit

/// L'état partagé, calculé côté app : à partir du relevé déjà fait, mis en
/// mots par `Fmt` comme dans le panneau. Pur, donc testé.
enum EtatBuilder {
    /// Le disque de rushes : parmi les disques EXTERNES branchés, celui qui
    /// porte le plus de données. Le nom ne sert pas : « Ssd » ou « Ssd 2 »
    /// selon le montage (README, « Les points de montage ne sont pas stables »).
    static func rushes(_ volumes: [VolumeSample]) -> VolumeSample? {
        volumes.filter { !$0.isInternal }.max { $0.used < $1.used }
    }

    static func build(memory: MemorySample,
                      volumes: [VolumeSample],
                      forecasts: [String: FillForecast],
                      verdict: Verdict,
                      forfait: EtatForfait?,
                      now: Date = Date()) -> EtatPartage {
        var etat = EtatPartage()
        etat.date = now

        etat.verdict.niveau = verdict.level.rawValue
        etat.verdict.phrase = verdict.phrase
        etat.verdict.preuve = verdict.evidence
        etat.verdict.symbole = verdict.symbol
        etat.verdict.calme = verdict.rule != 0 && verdict.level != .warning && verdict.level != .alert

        etat.memoire.utilisee = Fmt.memory(memory.used)
        etat.memoire.totale = Fmt.memory(memory.total, digits: 0)   // « sur 32 Go », comme la carte
        etat.memoire.fraction = memory.usedFraction
        etat.memoire.pression = memory.pressureLabel
        etat.memoire.pressionFraction = memory.pressure
        etat.memoire.swap = Fmt.memory(memory.swapUsed)
        etat.memoire.swapOctets = memory.swapUsed

        etat.disques = volumes.map { volume in
            var disque = DisquePartage()
            disque.id = volume.historyKey
            disque.nom = volume.name
            disque.libre = Fmt.bytes(volume.available)
            disque.libreOctets = volume.available
            disque.total = Fmt.bytes(volume.total)
            disque.occupation = volume.usedFraction
            disque.occupationTexte = Fmt.occupancy(volume.usedFraction)
            disque.interne = volume.isInternal
            if let forecast = forecasts[volume.historyKey] {
                disque.joursAvantPlein = forecast.daysUntilFull
                disque.tendance = forecast.daysUntilFull.map { Fmt.fullBy(days: $0, from: now) } ?? forecast.trendText
            }
            return disque
        }
        etat.rushes = rushes(volumes)?.historyKey

        if let forfait {
            var partage = ForfaitPartage()
            let today = forfait.parJour.last?.octets ?? 0
            partage.aujourdhui = Fmt.bytes(today)
            partage.aujourdhuiOctets = today
            partage.cycle = Fmt.bytes(forfait.consomme)
            partage.cycleOctets = forfait.consomme
            partage.quota = forfait.quota.map { Fmt.bytes($0) }
            partage.fraction = forfait.fraction
            partage.renouvellement = forfait.fin
            partage.echeance = forfait.epuiseVers.map { "épuisé vers le \(dayMonth.string(from: $0))" }
            etat.forfait = partage
        }
        return etat
    }

    /// L'état du moment, tiré du relevé de l'app.
    @MainActor
    static func build(_ sampler: Sampler, now: Date = Date()) -> EtatPartage {
        build(memory: sampler.memory, volumes: sampler.volumes, forecasts: sampler.forecasts,
              verdict: sampler.verdict, forfait: sampler.forfait, now: now)
    }

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM"
        return f
    }()
}

/// Écrit `etat-partage.json` pour les widgets : au plus une fois par minute,
/// seulement si une valeur a changé (ou toutes les 10 min, pour que le
/// widget sache que ses chiffres sont frais). Une minuterie d'une minute,
/// tolérance 20 s : un réveil de plus par minute, quand le relevé en fait
/// déjà douze.
///
/// Les widgets se rafraîchissent d'eux-mêmes (`Timeline`, toutes les 5 min).
/// L'app ne leur demande de se recharger que si le verdict change de niveau :
/// macOS rationne ces demandes, elles sont gardées pour ce qui compte.
@MainActor
final class SharedStateWriter {
    static let shared = SharedStateWriter()
    static let interval: TimeInterval = 60
    static let refreshEvery: TimeInterval = 600

    private var timer: Timer?
    private weak var sampler: Sampler?
    private var last: EtatPartage?
    private var lastWrite = Date.distantPast
    private(set) var writes = 0

    func start(sampler: Sampler) {
        self.sampler = sampler
        // `--snapshot`, `--probe`, `--banc` : rien ne s'écrit, pas de minuterie.
        guard Persistence.enabled, timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// L'état du moment, pour les actions Raccourcis exécutées dans l'app.
    var current: EtatPartage? { sampler.map { EtatBuilder.build($0) } }

    private func tick() {
        guard let state = current, state.verdict.phrase != Verdict.pending.phrase else { return }
        let now = Date()
        if let last, state.sameValues(as: last), now.timeIntervalSince(lastWrite) < Self.refreshEvery { return }
        guard write(state) else { return }
        if let last, last.verdict.niveau != state.verdict.niveau {
            WidgetCenter.shared.reloadAllTimelines()
        }
        last = state
        lastWrite = now
    }

    /// Écriture atomique : le widget ne lit jamais un fichier à moitié écrit.
    @discardableResult
    func write(_ state: EtatPartage, to url: URL = EtatPartage.url(), enabled: Bool = Persistence.enabled) -> Bool {
        guard enabled, let data = try? state.encoded() else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        writes += 1
        return true
    }
}

import Foundation

/// Ce que le helper sait faire du matériel. Deux implémentations : le SMC
/// réel, dans l'exécutable du helper seulement, et `SimulatedFans` pour les
/// tests — aucune autre.
public protocol FanHardware: AnyObject {
    /// Les ventilateurs tels que le SMC les lit, nil s'il ne répond pas.
    func readFans() -> [FanReading]?
    /// Vitesse imposée (true) ou rendue à macOS (false).
    func setManual(_ manual: Bool, fan: Int) -> Bool
    /// Consigne en tr/min. Appelée seulement par `FanController`, avec une
    /// valeur déjà bornée par le minimum et le maximum d'Apple.
    func setTarget(_ rpm: Double, fan: Int) -> Bool
}

/// Le cerveau du helper : chaque consigne, chaque battement et chaque
/// événement du système passent par lui, et TOUTES les sécurités sont ici —
/// testées contre un SMC simulé (`FanSafetyTests`), sans root.
///
/// - jamais sous le minimum ni au-dessus du maximum d'Apple, relus au SMC à
///   chaque consigne : la valeur du client n'est jamais crue ;
/// - retour en automatique quand Pulse quitte ou plante (connexion fermée),
///   quand le battement manque 15 s, à la mise en veille, quand macOS signale
///   une pression thermique forte, quand le SMC ne répond plus, quand le
///   helper démarre ou s'arrête ;
/// - pas de reprise pendant 10 min après une pression forte, ni dans les 10 s
///   qui suivent un réveil.
///
/// Pas thread-safe : une seule file, celle du helper.
public final class FanController {
    public enum State: Equatable {
        case automatic
        case manual(targets: [Double])
    }

    public private(set) var state: State = .automatic
    public private(set) var fallback: FanFallback = .none
    public private(set) var fallbackDate: Double?
    /// Le client qui a posé la consigne en cours.
    public private(set) var owner: Int?
    public private(set) var pressure: Int?
    private var deadline: Double = 0
    private var lockedUntil: Double = 0
    private var graceUntil: Double = 0
    private var asleep = false
    /// Le dernier refus journalisé : un refus répété à chaque battement
    /// (pause thermique) ne s'écrit qu'une fois.
    private var lastRefusal: FanRefusal?
    /// Combien de ventilateurs le SMC annonçait à la dernière lecture : de
    /// quoi rendre la main même quand il ne répond plus.
    private var knownFans = 0
    /// Les ventilateurs que le SMC n'a pas rendus à macOS : `F<n>Md = 0`
    /// refusé, ou relu à 1 après l'écriture. Le chien de garde retente (1 s,
    /// puis deux fois plus espacé, une minute au plus) et le helper ne sort
    /// pas tant qu'il en reste : sans cela, un refus passager laissait un
    /// ventilateur imposé jusqu'au redémarrage — l'état se disait
    /// « automatique », plus rien ne tournait pour le rattraper (17-audit-code).
    public private(set) var pendingRestore: [Int] = []
    private var retryDelay: Double = 1
    private var nextRetry: Double = 0
    /// Écritures de consigne depuis le démarrage du Mac (relues au
    /// lancement du helper, voir `FanProtocol.writeBudget`).
    public private(set) var writesUsed: Int
    public var writeBudget = FanProtocol.writeBudget
    /// Appelé après chaque écriture de consigne : le démon la note sur
    /// disque, pour qu'un helper relancé garde le compte du démarrage.
    public var onWrite: (Int) -> Void = { _ in }
    private var lastDecrease = -Double.infinity

    public let hardware: FanHardware
    /// Une ligne par changement : consigne nouvelle, retour en automatique,
    /// refus. Pas une par battement.
    public var log: (String) -> Void

    public init(hardware: FanHardware, now: Double, writesUsed: Int = 0, log: @escaping (String) -> Void = { _ in }) {
        self.hardware = hardware
        self.log = log
        self.writesUsed = max(0, writesUsed)
        // Un helper qui (re)démarre ne sait pas ce qu'a laissé le précédent,
        // peut-être tué au milieu d'une consigne : tout ventilateur resté
        // imposé est rendu à macOS.
        let fans = hardware.readFans() ?? []
        knownFans = fans.count
        if fans.contains(where: \.manual) {
            restore(.helperStart, now: now)
        }
    }

    public var isManual: Bool { if case .manual = state { return true }; return false }

    /// Le chien de garde n'a besoin de tourner que si une consigne est posée,
    /// ou si un retour en automatique reste à rattraper.
    public var needsWatchdog: Bool { isManual || !pendingRestore.isEmpty }

    // MARK: - Demandes du client

    public func handle(_ request: FanRequest, client: Int, now: Double) -> FanStatus {
        switch request.command {
        case .status:
            return status(now: now)
        case .automatic:
            if isManual || hardware.readFans()?.contains(where: \.manual) == true {
                restore(request.reason, now: now)
            }
            return status(now: now)
        case .hold:
            if let refusal = hold(request.targets, client: client, now: now) {
                return status(now: now, accepted: false, refusal: refusal)
            }
            return status(now: now)
        case .uninstall:
            // Le démon efface ses fichiers ; ici, rendre la main d'abord.
            if isManual || hardware.readFans()?.contains(where: \.manual) == true {
                restore(.helperStop, now: now)
            }
            return status(now: now)
        }
    }

    /// Pose une consigne, ou dit pourquoi non. Chaque consigne acceptée vaut
    /// battement de cœur.
    private func hold(_ targets: [Double], client: Int, now: Double) -> FanRefusal? {
        if asleep { return .asleep }
        if now < graceUntil { return .wakeGrace }
        if now < lockedUntil || (pressure ?? 0) >= FanProtocol.heavyPressure { return .thermalLock }
        guard let fans = hardware.readFans(), !fans.isEmpty else {
            if isManual { restore(.hardwareError, now: now) }
            return .hardware
        }
        knownFans = fans.count
        guard targets.count == fans.count else { return .wrongCount }
        guard fans.allSatisfy(\.limitsAreSane) else {
            if isManual { restore(.hardwareError, now: now) }
            return .hardware
        }
        var bounded = zip(fans, targets).map { fan, rpm in fan.clamp(rpm).rounded() }
        // Une baisse attend une minute après la précédente : la consigne en
        // place reste, plus forte. Une hausse passe tout de suite.
        var lowered = false
        for (i, fan) in fans.enumerated() where fan.manual {
            guard let current = fan.target, bounded[i] < current - 0.5 else { continue }
            if now - lastDecrease < FanProtocol.decreaseInterval {
                bounded[i] = fan.clamp(current).rounded()
            } else {
                lowered = true
            }
        }
        // Les écritures que cette consigne coûte, avant d'en faire une.
        let needed = zip(fans, bounded).reduce(0) { sum, pair in
            let (fan, rpm) = pair
            return sum + (fan.manual ? 0 : 1) + (!fan.manual || abs((fan.target ?? -1) - rpm) >= 1 ? 1 : 0)
        }
        if needed > 0, writesUsed + needed > writeBudget {
            if isManual || fans.contains(where: \.manual) { restore(.writeBudget, now: now) }
            return .writeBudget
        }
        if lowered { lastDecrease = now }
        for (fan, rpm) in zip(fans, bounded) {
            // L'ordre compte : en automatique, macOS réécrit la consigne en
            // continu ; le mode imposé d'abord, la vitesse ensuite.
            if !fan.manual {
                countWrite()
                guard hardware.setManual(true, fan: fan.index) else {
                    restore(.hardwareError, now: now)
                    return .hardware
                }
            }
            if !fan.manual || abs((fan.target ?? -1) - rpm) >= 1 {
                countWrite()
                guard hardware.setTarget(rpm, fan: fan.index) else {
                    restore(.hardwareError, now: now)
                    return .hardware
                }
            }
        }
        let changed = state != .manual(targets: bounded) || owner != client
        state = .manual(targets: bounded)
        owner = client
        pendingRestore = []
        deadline = now + FanProtocol.timeout
        if changed {
            let detail = bounded.enumerated().map { "\($0.offset)=\(Int($0.element))" }.joined(separator: " ")
            log("consigne \(detail) tr/min (client \(client))")
        }
        return nil
    }

    // MARK: - Événements du système

    /// Toutes les secondes tant qu'une consigne est posée, ou qu'un retour en
    /// automatique reste à rattraper.
    public func tick(now: Double) {
        if isManual, now > deadline {
            restore(.heartbeatLost, now: now)
        } else if !isManual, !pendingRestore.isEmpty, now >= nextRetry {
            retryRestore(now: now)
        }
    }

    /// La connexion d'un client s'est fermée : Pulse a quitté ou planté.
    public func clientGone(_ client: Int, now: Double) {
        guard owner == client else { return }
        owner = nil
        if isManual { restore(.clientGone, now: now) }
    }

    public func willSleep(now: Double) {
        asleep = true
        if isManual {
            restore(.sleep, now: now)
        } else if !pendingRestore.isEmpty {
            retryRestore(now: now)
        }
    }

    public func didWake(now: Double) {
        asleep = false
        graceUntil = now + FanProtocol.wakeGrace
    }

    /// Niveau publié par macOS (`com.apple.system.thermalpressurelevel`).
    public func thermal(_ level: Int, now: Double) {
        pressure = level
        guard level >= FanProtocol.heavyPressure else { return }
        lockedUntil = now + FanProtocol.thermalLock
        if isManual { restore(.thermal, now: now) }
    }

    /// Le helper s'arrête (SIGTERM, désinstallation, extinction).
    public func stop(now: Double) {
        if isManual || hardware.readFans()?.contains(where: \.manual) == true {
            restore(.helperStop, now: now)
        }
    }

    // MARK: -

    private func countWrite() {
        writesUsed += 1
        onWrite(writesUsed)
    }

    /// Rend chaque ventilateur à macOS. Écrit même si la lecture échoue : un
    /// SMC muet à la lecture peut encore accepter l'écriture qui compte.
    private func restore(_ reason: FanFallback, now: Double) {
        let fans = hardware.readFans()
        let indices = fans.map { $0.map(\.index) } ?? Array(0..<knownFans)
        var failed: [Int] = []
        for fan in indices where !hardware.setManual(false, fan: fan) { failed.append(fan) }
        state = .automatic
        owner = nil
        fallback = reason
        fallbackDate = now
        pendingRestore = stillForced(after: failed)
        retryDelay = 1
        nextRetry = now + retryDelay
        log("automatique : \(reason.phrase)" + (failed.isEmpty ? "" : " — ÉCHEC sur le ventilateur \(failed.map(String.init).joined(separator: ", "))"))
    }

    /// Nouvel essai d'un retour en automatique refusé par le SMC. Une ligne
    /// au journal quand il aboutit, aucune à chaque échec (le premier est
    /// déjà écrit).
    private func retryRestore(now: Double) {
        let failed = pendingRestore.filter { !hardware.setManual(false, fan: $0) }
        let still = stillForced(after: failed)
        if still.isEmpty {
            log("automatique rendu au nouvel essai : ventilateur \(pendingRestore.map(String.init).joined(separator: ", "))")
        } else {
            retryDelay = Swift.min(retryDelay * 2, FanProtocol.restoreRetryCap)
            nextRetry = now + retryDelay
        }
        pendingRestore = still
    }

    /// Les ventilateurs encore imposés après un retour en automatique : ce
    /// que le SMC relit, s'il répond — un refus d'écrire sur un ventilateur
    /// déjà rendu ne compte pas — ; sinon ceux dont l'écriture a échoué.
    private func stillForced(after failed: [Int]) -> [Int] {
        guard let fans = hardware.readFans() else { return failed }
        return fans.filter(\.manual).map(\.index)
    }

    public func status(now: Double, accepted: Bool = true, refusal: FanRefusal? = nil) -> FanStatus {
        if let refusal, refusal != lastRefusal { log("refus : \(refusal.phrase)") }
        if accepted || refusal != nil { lastRefusal = refusal }
        return FanStatus(accepted: accepted, refusal: refusal, manual: isManual, fallback: fallback,
                         fallbackAge: fallbackDate.map { Int64(max(0, now - $0)) },
                         lockRemaining: Int64(max(0, (lockedUntil - now).rounded(.up))),
                         pressure: pressure.map(Int64.init),
                         helperPID: Int64(ProcessInfo.processInfo.processIdentifier),
                         writesUsed: Int64(writesUsed),
                         fans: hardware.readFans() ?? [])
    }
}

/// Un SMC simulé, pour les tests et pour `PulseHelper --simule` : deux
/// ventilateurs aux bornes de ce M2 Max (relevées le 11/10), qui retiennent
/// chaque écriture et comptent toute consigne hors bornes.
public final class SimulatedFans: FanHardware {
    public var fans: [FanReading]
    /// L'automatique de macOS : la consigne qu'il pose quand on lui rend la main.
    public var automaticTarget: Double = 2_000
    public var mute = false
    public var failWrites = false
    /// Combien des prochains retours en automatique (`F<n>Md = 0`) le SMC
    /// refuse : le ventilateur reste imposé, comme un refus passager du vrai.
    public var refusedRestores = 0
    public private(set) var writes: [String] = []
    /// Consignes écrites hors du minimum et du maximum : doit rester à 0.
    public private(set) var violations = 0

    public init(fans: [FanReading] = SimulatedFans.m2Max) { self.fans = fans }

    /// F0 : 1 350 → 5 349 tr/min ; F1 : 1 522 → 5 777 (SMC, 11/10).
    public static let m2Max = [
        FanReading(index: 0, actual: 2_000, min: 1_350, max: 5_349, target: 2_000, manual: false),
        FanReading(index: 1, actual: 2_100, min: 1_522, max: 5_777, target: 2_100, manual: false),
    ]

    public func readFans() -> [FanReading]? { mute ? nil : fans }

    public func setManual(_ manual: Bool, fan: Int) -> Bool {
        writes.append("F\(fan)Md=\(manual ? 1 : 0)")
        guard !failWrites, fans.indices.contains(fan) else { return false }
        if !manual, refusedRestores > 0 {
            refusedRestores -= 1
            return false
        }
        fans[fan].manual = manual
        if !manual {
            fans[fan].target = automaticTarget
            fans[fan].actual = automaticTarget
        }
        return true
    }

    public func setTarget(_ rpm: Double, fan: Int) -> Bool {
        writes.append("F\(fan)Tg=\(Int(rpm))")
        guard !failWrites, fans.indices.contains(fan) else { return false }
        if rpm < fans[fan].min || rpm > fans[fan].max { violations += 1 }
        fans[fan].target = rpm
        fans[fan].actual = rpm
        return true
    }
}

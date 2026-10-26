import Foundation

// Le contrat entre Pulse et son helper privilégié (chantier 14).
//
// Un service Mach du domaine système et des messages XPC faits UNIQUEMENT
// d'entiers 64 bits, lus clé par clé : pas de chaîne, pas de tableau, pas de
// données à interpréter venues du client. Tout ce qu'un client — même
// malveillant — peut demander tient dans `FanRequest` : l'état, l'automatique,
// ou une consigne que le helper borne lui-même entre le minimum et le maximum
// d'Apple, lus au SMC.
//
// Cette bibliothèque est liée à l'app ET au helper, mais elle n'écrit rien :
// la commande d'écriture du SMC n'existe que dans l'exécutable du helper
// (`Sources/PulseHelper/Daemon/SMCFans.swift`).

public enum FanProtocol {
    /// Étiquette launchd du helper, et nom de son service Mach.
    public static let label = "com.isma.pulse.helper"
    /// Identifiant de signature de l'app autorisée à piloter.
    public static let clientIdentifier = "com.isma.pulse"
    /// Version du protocole : un message d'une autre version est refusé.
    public static let version: Int64 = 1

    /// Pulse renvoie sa consigne toutes les 5 s, panneau ouvert ou fermé.
    public static let heartbeat: TimeInterval = 5
    /// Sans nouvelles depuis 15 s — trois battements manqués —, le helper
    /// revient en automatique de lui-même.
    public static let timeout: TimeInterval = 15
    /// Après une pression thermique forte, aucune consigne pendant 10 min.
    public static let thermalLock: TimeInterval = 600
    /// Au réveil, 10 s d'automatique avant d'accepter une consigne.
    public static let wakeGrace: TimeInterval = 10
    /// Le helper s'arrête après 60 s sans client, en automatique.
    public static let idleExit: TimeInterval = 60
    /// Garde-fou sur le nombre de ventilateurs (le SMC en annonce 2 ici).
    public static let maxFans = 8

    /// Le helper installé : hors du bundle, dans des dossiers que seul root
    /// peut écrire (root:wheel 755, relevé le 11/10). Les recompilations de
    /// Pulse.app ne le touchent pas, et un processus d'Isma ne peut pas le
    /// remplacer par autre chose qui tournerait en root.
    public static let installedHelper = "/Library/PrivilegedHelperTools/com.isma.pulse.helper"
    public static let installedPlist = "/Library/LaunchDaemons/com.isma.pulse.helper.plist"

    /// Écritures de consigne (mode imposé, vitesse) permises par démarrage du
    /// Mac. Un relevé publié sur M4 Max sous macOS 26.6 voit le SMC refuser
    /// toute écriture de ventilateur après une centaine par démarrage
    /// (github.com/alfaiotadev/apple-silicon-smc-fan-write-limit) — non
    /// vérifié sur ce M2 Max. Le helper s'arrête donc bien avant, et garde
    /// le reste pour rendre la main : le retour en automatique, lui, n'est
    /// jamais compté ni refusé.
    public static let writeBudget = 60
    /// Une consigne ne baisse qu'une fois par minute au plus (elle monte
    /// tout de suite) : moins d'écritures, moins de va-et-vient audibles.
    public static let decreaseInterval: TimeInterval = 60
    /// Un retour en automatique refusé par le SMC se retente 1 s plus tard,
    /// puis deux fois plus espacé, jusqu'à une fois par minute.
    public static let restoreRetryCap: TimeInterval = 60

    /// Le plist launchd du helper installé, tel qu'il est écrit dans
    /// `/Library/LaunchDaemons`.
    public static func launchdPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>Program</key>
            <string>\(installedHelper)</string>
            <key>MachServices</key>
            <dict>
                <key>\(label)</key>
                <true/>
            </dict>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
        </dict>
        </plist>

        """
    }
    /// Niveau de pression thermique de macOS à partir duquel le helper rend
    /// la main : 2, « forte » (0 nominale, 1 modérée, 3 et 4 au-delà).
    public static let heavyPressure = 2

    /// Les clés des messages. Une consigne : `t0`, `t1`… en tr/min.
    public enum Key {
        public static let version = "v"
        public static let command = "c"
        public static let reason = "r"
        public static let count = "n"
        public static func target(_ fan: Int) -> String { "t\(fan)" }

        public static let accepted = "ok"
        public static let refusal = "ref"
        public static let manual = "man"
        public static let fallback = "fb"
        public static let fallbackAge = "fba"
        public static let lockRemaining = "lock"
        public static let pressure = "pr"
        public static let helperPID = "pid"
        public static let writesUsed = "w"
        public static func actual(_ fan: Int) -> String { "a\(fan)" }
        public static func minimum(_ fan: Int) -> String { "mn\(fan)" }
        public static func maximum(_ fan: Int) -> String { "mx\(fan)" }
        public static func fanTarget(_ fan: Int) -> String { "tg\(fan)" }
        public static func fanManual(_ fan: Int) -> String { "md\(fan)" }
    }
}

/// Ce que Pulse peut demander au helper. Rien d'autre n'existe.
public enum FanCommand: Int64, Sendable {
    /// Lire l'état : rien n'est écrit.
    case status = 1
    /// Rendre la main à macOS.
    case automatic = 2
    /// Imposer une consigne, et prouver qu'on est toujours là (battement).
    case hold = 3
    /// Se désinstaller : rendre la main, effacer son plist et son binaire,
    /// sortir de launchd. Le sens sûr : n'importe quel client peut le
    /// demander, le pire est un helper absent.
    case uninstall = 4
}

/// Pourquoi les ventilateurs sont revenus en automatique.
public enum FanFallback: Int64, CaseIterable, Sendable {
    case none = 0
    /// Pulse l'a demandé (mode automatique choisi).
    case requested = 1
    /// Plus de battement de cœur depuis `FanProtocol.timeout`.
    case heartbeatLost = 2
    /// Pulse a quitté ou planté : sa connexion s'est fermée.
    case clientGone = 3
    /// Le Mac se met en veille.
    case sleep = 4
    /// macOS signale une pression thermique forte.
    case thermal = 5
    /// La température qui pilote la courbe ne se lit plus.
    case sensorLost = 6
    /// Le helper démarre : il ne sait pas ce qu'a laissé le précédent.
    case helperStart = 7
    /// Le helper s'arrête (désinstallation, extinction).
    case helperStop = 8
    /// Une lecture ou une écriture du SMC a échoué.
    case hardwareError = 9
    /// Le budget d'écritures du SMC pour ce démarrage est épuisé.
    case writeBudget = 10

    /// La phrase de la page Réglages et du journal.
    public var phrase: String {
        switch self {
        case .none:          return "aucun retour pour l'instant"
        case .requested:     return "mode automatique choisi"
        case .heartbeatLost: return "Pulse ne répondait plus depuis 15 s"
        case .clientGone:    return "Pulse a quitté"
        case .sleep:         return "mise en veille"
        case .thermal:       return "macOS signalait une pression thermique forte"
        case .sensorLost:    return "la température ne se lisait plus"
        case .helperStart:   return "démarrage du helper"
        case .helperStop:    return "arrêt du helper"
        case .hardwareError: return "le SMC n'a pas répondu"
        case .writeBudget:   return "budget d'écritures du SMC atteint pour ce démarrage"
        }
    }
}

/// Pourquoi une consigne a été refusée.
public enum FanRefusal: Int64, CaseIterable, Sendable {
    case malformed = 1
    case wrongCount = 2
    case thermalLock = 3
    case wakeGrace = 4
    case asleep = 5
    case hardware = 6
    case writeBudget = 7

    public var phrase: String {
        switch self {
        case .malformed:   return "message mal formé"
        case .wrongCount:  return "nombre de ventilateurs différent de celui du SMC"
        case .thermalLock: return "pause de 10 min après une pression thermique forte"
        case .wakeGrace:   return "réveil récent : automatique pendant 10 s"
        case .asleep:      return "Mac en veille"
        case .hardware:    return "le SMC n'a pas répondu"
        case .writeBudget: return "budget d'écritures du SMC atteint : automatique jusqu'au prochain démarrage"
        }
    }
}

/// Une demande décodée. Le helper ne lit que ces clés-là.
public struct FanRequest: Equatable, Sendable {
    public var command: FanCommand
    /// Consignes en tr/min, une par ventilateur, dans l'ordre du SMC.
    public var targets: [Double]
    /// Pour `.automatic` : `requested` ou `sensorLost`, rien d'autre.
    public var reason: FanFallback

    public init(command: FanCommand, targets: [Double] = [], reason: FanFallback = .requested) {
        self.command = command
        self.targets = targets
        self.reason = reason
    }

    public static let status = FanRequest(command: .status)
    public static func automatic(_ reason: FanFallback = .requested) -> FanRequest {
        FanRequest(command: .automatic, reason: reason)
    }
    public static func hold(_ targets: [Double]) -> FanRequest { FanRequest(command: .hold, targets: targets) }

    /// Décode un message à partir d'un accès aux entiers par clé. Toute
    /// valeur absente, hors bornes ou d'une autre version : nil, et le
    /// helper répond « mal formé » sans rien toucher.
    public static func decode(_ value: (String) -> Int64?) -> FanRequest? {
        guard value(FanProtocol.Key.version) == FanProtocol.version,
              let raw = value(FanProtocol.Key.command), let command = FanCommand(rawValue: raw)
        else { return nil }
        switch command {
        case .status:
            return .status
        case .uninstall:
            return FanRequest(command: .uninstall)
        case .automatic:
            // Un client ne peut invoquer que deux raisons ; les autres sont
            // celles du helper lui-même.
            let reason = value(FanProtocol.Key.reason).flatMap(FanFallback.init(rawValue:)) ?? .requested
            return .automatic(reason == .sensorLost ? .sensorLost : .requested)
        case .hold:
            guard let count = value(FanProtocol.Key.count), count >= 1, count <= Int64(FanProtocol.maxFans)
            else { return nil }
            var targets: [Double] = []
            for fan in 0..<Int(count) {
                guard let rpm = value(FanProtocol.Key.target(fan)), rpm >= 0, rpm <= 100_000 else { return nil }
                targets.append(Double(rpm))
            }
            return .hold(targets)
        }
    }

    /// Les entiers du message, prêts pour un dictionnaire XPC.
    public func encode() -> [String: Int64] {
        var out: [String: Int64] = [FanProtocol.Key.version: FanProtocol.version,
                                    FanProtocol.Key.command: command.rawValue]
        switch command {
        case .status, .uninstall:
            break
        case .automatic:
            out[FanProtocol.Key.reason] = reason.rawValue
        case .hold:
            out[FanProtocol.Key.count] = Int64(targets.count)
            for (fan, rpm) in targets.enumerated() {
                out[FanProtocol.Key.target(fan)] = Int64(rpm.isFinite ? max(0, rpm.rounded()) : 0)
            }
        }
        return out
    }
}

/// Un ventilateur tel que le SMC le lit.
public struct FanReading: Equatable, Sendable {
    public var index: Int
    /// Vitesse mesurée (`F0Ac`), tr/min.
    public var actual: Double
    /// Minimum et maximum d'Apple (`F0Mn`, `F0Mx`) : les bornes de toute consigne.
    public var min: Double
    public var max: Double
    /// Consigne en cours (`F0Tg`), celle de macOS en automatique.
    public var target: Double?
    /// `F0Md` à 1 : vitesse imposée.
    public var manual: Bool

    public init(index: Int, actual: Double, min: Double, max: Double, target: Double?, manual: Bool) {
        self.index = index
        self.actual = actual
        self.min = min
        self.max = max
        self.target = target
        self.manual = manual
    }

    /// Des bornes qu'on peut croire : un maximum au-dessus d'un minimum
    /// positif. Sinon aucune consigne n'est posée.
    public var limitsAreSane: Bool { min > 0 && max > min && max < 20_000 }

    /// Une consigne ramenée entre le minimum et le maximum d'Apple.
    public func clamp(_ rpm: Double) -> Double {
        guard rpm.isFinite else { return min }
        return Swift.min(Swift.max(rpm, min), max)
    }
}

/// La réponse du helper, à toute demande.
public struct FanStatus: Equatable, Sendable {
    public var accepted: Bool
    public var refusal: FanRefusal?
    /// Une consigne est imposée en ce moment.
    public var manual: Bool
    /// Le dernier retour en automatique, et depuis combien de secondes.
    public var fallback: FanFallback
    public var fallbackAge: Int64?
    /// Secondes avant la fin de la pause thermique, 0 sinon.
    public var lockRemaining: Int64
    /// Pression thermique de macOS, nil si illisible.
    public var pressure: Int64?
    public var helperPID: Int64
    /// Écritures de consigne faites depuis le démarrage du Mac, sur
    /// `FanProtocol.writeBudget`.
    public var writesUsed: Int64
    public var fans: [FanReading]

    public init(accepted: Bool, refusal: FanRefusal? = nil, manual: Bool, fallback: FanFallback,
                fallbackAge: Int64? = nil, lockRemaining: Int64 = 0, pressure: Int64? = nil,
                helperPID: Int64 = 0, writesUsed: Int64 = 0, fans: [FanReading] = []) {
        self.writesUsed = writesUsed
        self.accepted = accepted
        self.refusal = refusal
        self.manual = manual
        self.fallback = fallback
        self.fallbackAge = fallbackAge
        self.lockRemaining = lockRemaining
        self.pressure = pressure
        self.helperPID = helperPID
        self.fans = fans
    }

    public func encode() -> [String: Int64] {
        typealias K = FanProtocol.Key
        var out: [String: Int64] = [K.version: FanProtocol.version,
                                    K.accepted: accepted ? 1 : 0,
                                    K.manual: manual ? 1 : 0,
                                    K.fallback: fallback.rawValue,
                                    K.lockRemaining: lockRemaining,
                                    K.helperPID: helperPID,
                                    K.writesUsed: writesUsed,
                                    K.count: Int64(fans.count)]
        if let refusal { out[K.refusal] = refusal.rawValue }
        if let fallbackAge { out[K.fallbackAge] = fallbackAge }
        if let pressure { out[K.pressure] = pressure }
        func rpm(_ value: Double) -> Int64 { value.isFinite ? Int64(value.rounded()) : 0 }
        for fan in fans {
            out[K.actual(fan.index)] = rpm(fan.actual)
            out[K.minimum(fan.index)] = rpm(fan.min)
            out[K.maximum(fan.index)] = rpm(fan.max)
            if let target = fan.target { out[K.fanTarget(fan.index)] = rpm(target) }
            out[K.fanManual(fan.index)] = fan.manual ? 1 : 0
        }
        return out
    }

    public static func decode(_ value: (String) -> Int64?) -> FanStatus? {
        typealias K = FanProtocol.Key
        guard value(K.version) == FanProtocol.version, let accepted = value(K.accepted),
              let manual = value(K.manual) else { return nil }
        let count = Int(max(0, min(value(K.count) ?? 0, Int64(FanProtocol.maxFans))))
        let fans: [FanReading] = (0..<count).compactMap { fan in
            guard let actual = value(K.actual(fan)), let lo = value(K.minimum(fan)), let hi = value(K.maximum(fan))
            else { return nil }
            return FanReading(index: fan, actual: Double(actual), min: Double(lo), max: Double(hi),
                              target: value(K.fanTarget(fan)).map(Double.init), manual: value(K.fanManual(fan)) == 1)
        }
        return FanStatus(accepted: accepted == 1,
                         refusal: value(K.refusal).flatMap(FanRefusal.init(rawValue:)),
                         manual: manual == 1,
                         fallback: value(K.fallback).flatMap(FanFallback.init(rawValue:)) ?? .none,
                         fallbackAge: value(K.fallbackAge),
                         lockRemaining: value(K.lockRemaining) ?? 0,
                         pressure: value(K.pressure),
                         helperPID: value(K.helperPID) ?? 0,
                         writesUsed: value(K.writesUsed) ?? 0,
                         fans: fans)
    }
}

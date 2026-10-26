import Foundation

/// L'unité d'une série : elle choisit le format d'affichage, jamais l'échelle.
///
/// Deux conventions d'octets, comme partout dans Pulse (règle dure n° 3) :
/// la mémoire en base 1024 (`Fmt.memory`), le stockage et le réseau en base
/// 1000 (`Fmt.bytes`).
enum SeriesUnit: String {
    /// Part de 1 : processeur, carte graphique, pression.
    case fraction
    /// Octets de mémoire, base 1024.
    case memoryBytes
    /// Octets de stockage, base 1000.
    case storageBytes
    /// Octets par seconde, base 1000.
    case bytesPerSecond
    case celsius
    case watts
    case rpm
    case count

    func format(_ value: Double) -> String {
        switch self {
        case .fraction:       return Fmt.percent(value)
        case .memoryBytes:    return Fmt.memory(value)
        case .storageBytes:   return Fmt.bytes(value)
        case .bytesPerSecond: return "\(Fmt.bytes(value))/s"
        case .celsius:        return "\(Int(value.rounded()))\u{00A0}°C"
        case .watts:          return String(format: "%.1f\u{00A0}W", value).replacingOccurrences(of: ".", with: ",")
        case .rpm:            return "\(Int(value.rounded()))\u{00A0}tr/min"
        case .count:          return "\(Int(value.rounded()))"
        }
    }
}

/// Ce qu'on sait d'une série : son nom, son unité, et — s'il existe — le total
/// auquel elle se rapporte.
///
/// `bound` est le dénominateur RÉEL de la série (règle dure n° 7) : 1 pour un
/// pourcentage, la mémoire installée, la capacité d'un volume. Sans lui, le
/// graphique ne trace jamais de barres, seulement une courbe sur l'échelle de
/// son maximum observé, nommée comme telle — le swap, le débit, une
/// température n'ont pas de « plein ».
struct SeriesInfo {
    var key: String
    var label: String
    var unit: SeriesUnit
    var bound: Double?

    init(_ key: String, _ label: String, _ unit: SeriesUnit, bound: Double? = nil) {
        self.key = key
        self.label = label
        self.unit = unit
        self.bound = bound
    }
}

/// Le catalogue des séries connues. Les séries de base sont déclarées ici ;
/// un module (chantiers 04 à 08) déclare les siennes avec `declare`, puis les
/// alimente avec `History.record` — voir `History`.
///
/// Une série non déclarée s'enregistre quand même : elle s'affiche alors sous
/// sa clé, sans dénominateur, donc en courbe.
enum SeriesCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var declared: [String: SeriesInfo] = [:]

    /// Les séries de base, alimentées par `Sampler`.
    static let builtIn: [SeriesInfo] = {
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return [
            SeriesInfo("cpu.total", "Processeur", .fraction, bound: 1),
            SeriesInfo("cpu.utilisateur", "Processeur, utilisateur", .fraction, bound: 1),
            SeriesInfo("cpu.systeme", "Processeur, système", .fraction, bound: 1),
            SeriesInfo("cpu.performance", "Cœurs performance", .fraction, bound: 1),
            SeriesInfo("cpu.efficacite", "Cœurs efficacité", .fraction, bound: 1),
            SeriesInfo("gpu", "Carte graphique", .fraction, bound: 1),
            SeriesInfo("memoire.utilisee", "Mémoire utilisée", .memoryBytes, bound: ram),
            SeriesInfo("memoire.apps", "Mémoire des apps", .memoryBytes, bound: ram),
            SeriesInfo("memoire.systeme", "Mémoire système", .memoryBytes, bound: ram),
            SeriesInfo("memoire.compressee", "Mémoire compressée", .memoryBytes, bound: ram),
            SeriesInfo("memoire.pression", "Pression mémoire", .fraction, bound: 1),
            // Le total du swap grandit à la demande : pas un dénominateur.
            SeriesInfo("memoire.swap", "Swap", .memoryBytes),
            SeriesInfo("reseau.envoi", "Envoi", .bytesPerSecond),
            SeriesInfo("reseau.reception", "Réception", .bytesPerSecond),
        ]
    }()

    /// Une série par volume, indexée par UUID comme `HistoryStore` : le point
    /// de montage change (« Ssd », « Ssd 2 »), l'UUID non.
    static func volumeKey(_ historyKey: String) -> String { "disque.\(historyKey).libre" }

    static func declare(_ info: SeriesInfo) {
        lock.lock(); defer { lock.unlock() }
        declared[info.key] = info
    }

    /// La déclaration d'une série, ou une déclaration minimale tirée de sa
    /// clé et de ce que la base garde d'elle (libellé, dénominateur, unité) :
    /// jamais `nil`, une série inconnue reste lisible.
    static func info(_ key: String, label storedLabel: String? = nil, bound storedBound: Double? = nil,
                     unit storedUnit: SeriesUnit? = nil) -> SeriesInfo {
        if let found = declaredInfo(key) { return found }
        if let known = builtIn.first(where: { $0.key == key }) { return known }
        if key.hasPrefix("disque."), key.hasSuffix(".libre") {
            return SeriesInfo(key, storedLabel ?? "Volume", storedUnit ?? .storageBytes, bound: storedBound)
        }
        return SeriesInfo(key, storedLabel ?? key, storedUnit ?? .count, bound: storedBound)
    }

    /// Ce qu'un module a déclaré dans CE processus, et rien d'autre.
    static func declaredInfo(_ key: String) -> SeriesInfo? {
        lock.lock(); defer { lock.unlock() }
        return declared[key]
    }
}

/// Les plages de lecture, celles d'iStat Menus plus une : 1 h, 24 h, 7 j,
/// 30 j, 90 j.
///
/// La largeur de tranche vise 120 à 180 tranches par plage : deux points de
/// large dans une colonne de 296 pt, ce que l'œil sépare encore et ce que le
/// survol sait viser. Des durées rondes, pour que le survol dise « 14:00 », pas
/// « 14:24 ».
enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1 h"
    case day = "24 h"
    case week = "7 j"
    case month = "30 j"
    case quarter = "90 j"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hour:    return 3600
        case .day:     return 86_400
        case .week:    return 7 * 86_400
        case .month:   return 30 * 86_400
        case .quarter: return 90 * 86_400
        }
    }

    /// Largeur d'une tranche.
    var bucket: TimeInterval {
        switch self {
        case .hour:    return 30
        case .day:     return 600
        case .week:    return 3600
        case .month:   return 4 * 3600
        case .quarter: return 12 * 3600
        }
    }

    /// Pour VoiceOver et `--probe` : « 1 h » se lit mal à voix haute.
    var spoken: String {
        switch self {
        case .hour:    return "la dernière heure"
        case .day:     return "les dernières 24 heures"
        case .week:    return "les 7 derniers jours"
        case .month:   return "les 30 derniers jours"
        case .quarter: return "les 90 derniers jours"
        }
    }
}

import Foundation
import IOKit

/// La carte graphique et les moteurs médias, sur le dernier intervalle.
///
/// Chaque champ est optionnel : `nil` veut dire « ce Mac ne le publie pas
/// sans root », jamais zéro. Le décodeur vidéo (AVD) et les moteurs ProRes
/// n'ont AUCUN canal IOReport lisible ici (relevé le 11/10 sur M2 Max) : ils
/// n'apparaissent donc pas, plutôt qu'à un 0 % inventé.
struct MediaSample: Equatable {
    /// Occupation du GPU selon son pilote (« Device Utilization % »).
    var gpuUtilization: Double?
    /// Puissance du GPU, en watts (« GPU Energy »).
    var gpuPower: Double?
    /// Fréquence moyenne pendant le temps où le GPU est allumé, en MHz.
    var gpuFrequency: Double?
    /// Fréquence maximale de la table, en MHz : 1 398 sur ce M2 Max.
    var gpuMaxFrequency: Double?
    /// Mémoire que le GPU tient en ce moment (« In use system memory »).
    /// Mémoire unifiée : elle est prise sur la même RAM que les applications.
    var gpuMemory: UInt64?
    /// Encodeur vidéo matériel (H.264, HEVC), en watts (canal « AVE »).
    var encoderPower: Double?
    /// Scaler et rotation matériels, en watts (canal « MSR »).
    var scalerPower: Double?
    /// Moteur neuronal, en watts (canal « ANE ») : les effets à base d'IA de
    /// Premiere (reconnaissance de scènes, amélioration de la voix).
    var neuralPower: Double?
    /// Les applications qui occupent le GPU, de la plus gourmande à la moins.
    var gpuApps: [GPUAppUsage] = []
    /// Durée de l'intervalle mesuré, en secondes.
    var interval: Double = 0

    /// L'encodeur matériel travaille-t-il ? Seuil posé, PAS mesuré pendant
    /// un export : au repos il dépense 5 mW (relevé du 11/10). À calibrer sur
    /// un export réel avant de nourrir une détection (voir 08-medias.md).
    static let encoderBusyWatts = 0.05
}

/// Lit la carte graphique et les moteurs médias.
///
/// Uniquement panneau ouvert : relever IOReport et les 71 clients du GPU à
/// chaque tick fermé ferait sortir Pulse de son budget (moins de 1 % d'un
/// cœur). Un intervalle de plus de 10 s — le panneau a été fermé entre-temps
/// — est jeté plutôt que moyenné : il décrirait le passé, pas l'instant.
///
/// N'est touché que depuis une seule file à la fois (celle du `Sampler`, ou
/// `--probe`) : pas de verrou.
final class MediaMonitor {
    /// Le lecteur IOReport du chantier 04 (`Sensors/IOReport.swift`), avec
    /// son propre abonnement : il ne lit que ce que cette carte affiche.
    private let report = IOReportSampler(groups: [
        ("Energy Model", nil),
        ("GPU Stats", "GPU Performance States"),
    ])
    private let clients = GPUClients()
    /// MHz par état de performance, P1 en tête, lus une fois dans `pmgr` :
    /// 444 à 1 398 MHz sur ce M2 Max (`DVFSTables`, chantier 04).
    let frequencies: [Double] = DVFSTables.read().gpu

    static let maxInterval: Double = 10

    var available: Bool { report != nil }

    /// - Returns: `nil` au premier appel, ou après une pause de plus de 10 s :
    ///   il faut deux relevés rapprochés.
    func sample() -> MediaSample? {
        let apps = clients.sample()
        guard let report, let (channels, elapsed) = report.sample(), elapsed <= Self.maxInterval else { return nil }

        var out = MediaSample()
        out.interval = elapsed
        out.gpuApps = apps
        out.gpuMaxFrequency = frequencies.last
        let stats = Self.acceleratorStatistics()
        out.gpuUtilization = stats.utilization
        out.gpuMemory = stats.memoryInUse

        for channel in channels {
            if channel.states.isEmpty {
                guard let watts = IOReportMath.watts(energy: channel.value, unit: channel.unit, seconds: elapsed)
                else { continue }
                switch channel.name {
                case "GPU Energy": out.gpuPower = watts
                case "AVE0":       out.encoderPower = (out.encoderPower ?? 0) + watts
                case "MSR0":       out.scalerPower = (out.scalerPower ?? 0) + watts
                case "ANE0":       out.neuralPower = (out.neuralPower ?? 0) + watts
                default: break
                }
            } else if channel.name == "GPUPH",
                      let clock = IOReportMath.frequency(states: channel.states, table: frequencies),
                      clock.active > 0 {
                // Moyenne sur le seul temps allumé : un GPU éteint 90 % du
                // temps n'est pas « à 140 MHz ».
                out.gpuFrequency = clock.mhz
            }
        }
        return out
    }

    /// Occupation et mémoire du GPU, dans les statistiques de son pilote.
    static func acceleratorStatistics() -> (utilization: Double?, memoryInUse: UInt64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOObjectRelease(iterator) }
        var utilization: Double?, memory: UInt64?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            if let value = stats["Device Utilization %"] as? NSNumber {
                utilization = max(utilization ?? 0, min(1, value.doubleValue / 100))
            }
            if let value = stats["In use system memory"] as? NSNumber {
                memory = (memory ?? 0) + value.uint64Value
            }
        }
        return (utilization, memory)
    }
}

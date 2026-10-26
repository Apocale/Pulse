import Foundation
import IOKit

/// Taux d'occupation du GPU, lu dans l'IORegistry.
/// Aucun privilège requis : le pilote publie ses compteurs en clair,
/// contrairement à powermetrics qui exige sudo.
enum GPUMonitor {
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // La seule clé lue, et non toutes les propriétés du pilote : le
            // noyau sérialise alors une entrée au lieu de plusieurs dizaines,
            // à chaque relevé, panneau fermé compris.
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }

            // Uniquement « Device Utilization % », qui est bien un pourcentage.
            // Les autres compteurs du dict sont des cumuls en nanosecondes :
            // les lire comme un taux donnerait n'importe quoi.
            if let value = stats["Device Utilization %"] as? NSNumber {
                best = max(best ?? 0, min(1, value.doubleValue / 100.0))
            }
        }
        return best
    }
}

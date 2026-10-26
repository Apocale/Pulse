import Foundation
import Darwin

/// Snapshot mémoire calqué sur les catégories du Moniteur d'activité.
struct MemorySample {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// Taille des fichiers de swap ACTUELLEMENT alloués, pas un plafond :
    /// macOS l'agrandit à la demande. Observé passer de 2 à 9,7 Gio en une
    /// soirée. Ne jamais l'afficher comme dénominateur — le ratio resterait
    /// collé autour de 90 % quel que soit l'état réel de la machine.
    var swapTotal: UInt64 = 0
    /// 1 = normale, 2 = avertissement, 4 = critique (kern.memorystatus_vm_pressure_level)
    var pressureLevel: Int32 = 1
    /// Pression en part de 1, comme l'anneau « Pressure » d'iStat Menus : le
    /// complément de la mémoire libre que publie le noyau
    /// (`kern.memorystatus_level`). Le même chiffre que donne l'outil d'Apple
    /// `memory_pressure` — vérifié le 11/10 : 36 % libres des deux côtés.
    /// `nil` si le noyau ne répond pas : jamais un zéro inventé.
    var pressure: Double?

    /// « Mémoire utilisée » telle que l'affiche macOS : app + wired + compressée.
    var used: UInt64 { app &+ wired &+ compressed }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// Niveau de pression, énoncé à partir de faits observables et non d'un
    /// ratio inventé.
    ///
    /// La version précédente calculait (wired + compressée) / total et
    /// annonçait « modérée » au-delà de 45 %. Ce seuil ne correspondait à rien :
    /// il excluait la mémoire applicative, qui est pourtant la source de la
    /// pression, et affichait donc bas au moment où la machine saturait.
    /// Le noyau publie déjà son propre verdict — autant s'y tenir, et compléter
    /// par le swap, qui est la preuve que la machine paie déjà.
    var pressureLabel: String {
        switch pressureLevel {
        case 4: return "critique"
        case 2: return "élevée"
        default: return swapUsed > 0 ? "modérée" : "normale"
        }
    }
}

enum MemoryMonitor {
    private static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    static func sample() -> MemorySample {
        var s = MemorySample()
        s.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        if kr == KERN_SUCCESS {
            let page = pageSize
            let purgeable = UInt64(stats.purgeable_count)
            let internalPages = UInt64(stats.internal_page_count)
            let externalPages = UInt64(stats.external_page_count)
            // Mémoire applicative = pages anonymes non purgeables.
            s.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.wired = UInt64(stats.wire_count) * page
            s.compressed = UInt64(stats.compressor_page_count) * page
            s.cached = (externalPages + purgeable) * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            s.pressureLevel = level
        }

        var free: Int32 = 0
        var freeSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &free, &freeSize, nil, 0) == 0, (0...100).contains(free) {
            s.pressure = Double(100 - free) / 100
        }

        return s
    }
}

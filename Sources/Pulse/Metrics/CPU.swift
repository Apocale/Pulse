import Foundation
import Darwin

struct CPUSample {
    var total: Double = 0          // 0…1, tous cœurs confondus
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
    var performance: Double = 0    // moyenne du cluster P
    var efficiency: Double = 0     // moyenne du cluster E
    /// Charge moyenne sur 1, 5 et 15 min, celle de `uptime`.
    var load: [Double] = []
}

/// L'heure du démarrage, celle que lit `uptime` : le temps allumé compte la
/// veille, comme dans iStat Menus et dans le Terminal.
enum SystemClock {
    /// Variable et non constante : le relevé figé des tests de rendu la fixe
    /// (`Releve.sampler()`), sans quoi « Allumé depuis » changerait à chaque
    /// minute et aucune image de référence ne tiendrait.
    nonisolated(unsafe) static var bootDate: Date? = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
    }()
}

/// Lit les compteurs de ticks par cœur et en dérive un taux d'occupation
/// entre deux échantillons. Un seul échantillon ne veut rien dire : la
/// première mesure sert uniquement de référence.
final class CPUMonitor {
    /// Sur Apple Silicon, host_processor_info énumère les cœurs E avant les cœurs P.
    static let efficiencyCores: Int = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    static let performanceCores: Int = sysctlInt("hw.perflevel0.logicalcpu") ?? 0

    private var previous: [[UInt32]] = []

    func sample() -> CPUSample {
        var out = CPUSample()
        var cpuInfo: processor_info_array_t?
        var numCPUs: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &numCPUs, &cpuInfo, &infoCount) == KERN_SUCCESS,
              let info = cpuInfo else { return out }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(numCPUs))
        for core in 0..<Int(numCPUs) {
            let base = core * states
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }

        guard previous.count == current.count else {
            previous = current
            out.perCore = Array(repeating: 0, count: current.count)
            return out
        }

        var totalBusy = 0.0, totalAll = 0.0, totalUser = 0.0, totalSystem = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for (core, ticks) in current.enumerated() {
            let old = previous[core]
            // Les compteurs sont sur 32 bits et rebouclent : &- gère le passage à zéro.
            let user = Double(ticks[0] &- old[0])
            let sys = Double(ticks[1] &- old[1])
            let idle = Double(ticks[2] &- old[2])
            let nice = Double(ticks[3] &- old[3])
            let all = user + sys + idle + nice
            let busy = user + sys + nice
            perCore.append(all > 0 ? min(1, busy / all) : 0)
            totalBusy += busy; totalAll += all
            totalUser += user + nice; totalSystem += sys
        }

        previous = current
        out.perCore = perCore
        if totalAll > 0 {
            out.total = min(1, totalBusy / totalAll)
            out.user = totalUser / totalAll
            out.system = totalSystem / totalAll
        }

        let e = Self.efficiencyCores
        if perCore.count >= e + Self.performanceCores, e > 0 {
            out.efficiency = perCore[0..<e].reduce(0, +) / Double(e)
            let p = perCore[e...]
            out.performance = p.isEmpty ? 0 : p.reduce(0, +) / Double(p.count)
        }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { out.load = loads }
        return out
    }
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int = 0
    var size = MemoryLayout<Int>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
    return String(nulTerminated: bytes)
}

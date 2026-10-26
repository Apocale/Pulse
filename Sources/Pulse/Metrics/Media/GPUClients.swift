import Foundation
import IOKit
import Darwin

/// Une application et sa part du temps GPU sur le dernier intervalle.
struct GPUAppUsage: Equatable, Identifiable {
    var bundleId: String
    var name: String
    /// Le bundle .app, pour l'icône. `nil` hors bundle.
    var bundlePath: String?
    /// Temps GPU consommé par seconde : 0,42 = 42 % du temps. Plusieurs
    /// applications peuvent occuper le GPU en même temps, la somme peut donc
    /// dépasser 100 % — d'où l'absence de barre (règle dure n°7).
    var share: Double

    var id: String { bundleId }
}

/// Le temps GPU par application, lu dans l'IORegistry, sans root.
///
/// Chaque client Metal ouvre un `AGXDeviceUserClient` sous l'accélérateur ;
/// il porte son créateur (« pid 451, WindowServer ») et `AppUsage`, une
/// liste dont chaque entrée cumule `accumulatedGPUTime` en NANOSECONDES —
/// vérifié le 11/10 : WindowServer à 251,7 s de GPU après 48 min allumé.
/// Seul l'écart entre deux relevés dit la charge, comme pour le CPU.
///
/// 71 clients au repos : relevé panneau ouvert seulement.
final class GPUClients {
    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: Double?
    /// pid → application. Oublié une fois par minute : un PID se réattribue.
    private var identities: [pid_t: (id: String, name: String, path: String?)] = [:]
    private var identitiesSince: Double = 0

    /// - Returns: les applications qui ont occupé le GPU depuis l'appel
    ///   précédent, de la plus gourmande à la moins gourmande. Vide au premier
    ///   appel, qui sert de référence.
    func sample(now: Double = Double(DispatchTime.now().uptimeNanoseconds) / 1e9) -> [GPUAppUsage] {
        let read = Self.readTotals()
        let current = read.mapValues(\.time)
        defer { previous = current; previousTime = now }
        guard let last = previousTime, now - last > 0.2 else { return [] }
        let elapsed = now - last
        if now - identitiesSince > 60 { identities = [:]; identitiesSince = now }

        var byApp: [String: GPUAppUsage] = [:]
        for (pid, total) in current {
            guard let before = previous[pid], total > before else { continue }
            let share = Double(total - before) / 1e9 / elapsed
            let who = identity(pid, creator: read[pid]?.name ?? "")
            var usage = byApp[who.id] ?? GPUAppUsage(bundleId: who.id, name: who.name, bundlePath: who.path, share: 0)
            usage.share += share
            byApp[who.id] = usage
        }
        return byApp.values.sorted { $0.share > $1.share }
    }

    /// pid → temps GPU cumulé de tous ses clients, en ns, et le nom que
    /// porte le créateur (tronqué à 16 caractères par le noyau).
    static func readTotals() -> [pid_t: (time: UInt64, name: String)] {
        var totals: [pid_t: (time: UInt64, name: String)] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return totals }
        defer { IOObjectRelease(iterator) }
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = Self.pid(fromCreator: creator),
                      let usage = property(client, "AppUsage") as? [[String: Any]], !usage.isEmpty else { continue }
                let time = usage.reduce(UInt64(0)) { sum, entry in
                    sum &+ ((entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
                }
                let name = creator.split(separator: ",", maxSplits: 1).last
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                totals[pid, default: (0, name)].time &+= time
            }
        }
        return totals
    }

    /// « pid 451, WindowServer » → 451.
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Le bundle le plus englobant de l'exécutable, comme `ProcessMonitor` :
    /// les auxiliaires de Premiere comptent pour Premiere.
    private func identity(_ pid: pid_t, creator: String) -> (id: String, name: String, path: String?) {
        if let known = identities[pid] { return known }
        var buffer = [CChar](repeating: 0, count: 4096)
        let found: (id: String, name: String, path: String?)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(nulTerminated: buffer)
            if let range = path.range(of: ".app/") {
                let bundle = String(path[path.startIndex..<range.lowerBound]) + ".app"
                found = Self.bundleIdentity(bundle)
            } else {
                let name = (path as NSString).lastPathComponent
                found = ("exec:" + name, name, nil)
            }
        } else {
            // Processus d'un autre utilisateur (WindowServer) : son chemin
            // est illisible, mais son nom figure dans le créateur.
            found = ("exec:" + creator, creator.isEmpty ? "pid \(pid)" : creator, nil)
        }
        identities[pid] = found
        return found
    }

    private static func bundleIdentity(_ path: String) -> (id: String, name: String, path: String?) {
        var id = path
        var name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        if let info = ProtectedFolders.bundleInfo(path) {
            if let bundleId = info["CFBundleIdentifier"] as? String { id = bundleId }
            if let display = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String, !display.isEmpty {
                name = display
            }
        }
        return (id, name, path)
    }
}

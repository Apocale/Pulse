import Foundation
import Darwin

struct ProcessGroup: Identifiable {
    var bundleId: String
    var name: String
    /// Pourcentage d'UN cœur, comme le Moniteur d'activité : 1200 % au plafond
    /// sur cette machine à 12 cœurs logiques.
    var cpu: Double
    /// Empreinte mémoire réelle, colonne « Mémoire » du Moniteur d'activité.
    var footprint: UInt64
    var processCount: Int
    /// Le bundle .app de l'application, pour son icône. `nil` pour un
    /// exécutable hors bundle, regroupé sous son propre nom.
    var bundlePath: String? = nil
    /// Octets lus et écrits sur disque par seconde, processus auxiliaires
    /// compris : `ri_diskio_bytesread` / `written`, la colonne « Disque » du
    /// Moniteur d'activité. Lus dans le même appel que la mémoire (chantier 05).
    var diskRead: Double = 0
    var diskWrite: Double = 0
    /// Les processus du groupe : pour savoir SUR QUEL disque une application
    /// écrit, par ses fichiers ouverts (`WrittenDevices`, chantier 05).
    var pids: [pid_t] = []

    var id: String { bundleId }
}

/// Échantillonne CPU et mémoire par application, processus auxiliaires compris.
///
/// Deux pièges que ce code évite, et qui rendent faux la plupart des exemples
/// trouvés en ligne :
///
/// 1. `pti_total_user` / `pti_total_system` ne sont PAS des nanosecondes mais
///    des unités de temps mach. Sur Apple Silicon la timebase vaut 125/3, soit
///    41,67 ns par unité : les lire comme des nanosecondes divise le CPU par
///    41,67. Sur Intel la timebase est 1/1, ce qui masque complètement le bug.
///    `ri_user_time` / `ri_system_time`, lus ici à leur place, sont dans la
///    même unité.
///
/// 2. `pti_resident_size` n'est pas ce qu'affiche macOS. Il ignore les pages
///    compressées et les allocations IOSurface/GPU — décisives en mémoire
///    unifiée. Écart mesuré jusqu'à 41× sur un service de décodage vidéo.
///    La bonne valeur est `ri_phys_footprint` de `proc_pid_rusage`.
final class ProcessMonitor {
    /// Identifiant, nom affiché, et chemin du bundle quand il y en a un.
    typealias Identity = (id: String, name: String, path: String?)
    private static let machToNanoseconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private var previous: [pid_t: UInt64] = [:]
    /// Octets disque cumulés par processus au relevé précédent.
    private var previousIO: [pid_t: (read: UInt64, written: UInt64)] = [:]
    private var previousTime: Double?
    /// chemin du bundle → (identifiant, nom). Lire un Info.plist coûte un
    /// accès disque : on ne le fait qu'une fois par application.
    private var bundleCache: [String: Identity] = [:]

    /// pid → application, résolue une fois par processus.
    ///
    /// Lire le chemin de l'exécutable puis y chercher le bundle, pour chacun
    /// des ~900 processus et à chaque relevé, coûtait plus que tout le reste
    /// du balayage (profileur, 09/10). Un processus ne change pas
    /// d'exécutable ; l'heure de début, lue dans le même appel que la
    /// mémoire, écarte un PID réattribué à un autre programme. Le tout est
    /// oublié une fois par minute, au cas où un processus se serait remplacé
    /// lui-même (`exec`) en gardant son PID.
    private var identities: [pid_t: (start: UInt64, identity: Identity)] = [:]
    private var identitiesSince: Double = 0

    /// Banc (`--banc`) : les identités sont relues au balayage suivant, comme
    /// chaque minute, pour mesurer ce que coûte cette relecture.
    func oublieLesIdentites() { identitiesSince = 0 }

    /// Agrège par application. Les processus dont l'exécutable vit dans le
    /// bundle d'une app connue lui sont rattachés : Premiere sans ses
    /// satellites afficherait moins que la réalité.
    func sample() -> [ProcessGroup] {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let elapsed = previousTime.map { now - $0 } ?? 0
        previousTime = now

        var totals: [String: ProcessGroup] = [:]
        var current: [pid_t: UInt64] = [:]
        var currentIO: [pid_t: (read: UInt64, written: UInt64)] = [:]
        if now - identitiesSince > 60 {
            identities = [:]
            identitiesSince = now
        }
        var seen: [pid_t: (start: UInt64, identity: Identity)] = [:]

        for pid in Self.allPIDs() {
            // UN appel par processus : `proc_pid_rusage` donne à la fois le
            // temps CPU, l'empreinte, les octets disque et l'heure de début.
            // Le relevé lisait aussi `PROC_PIDTASKINFO` pour le seul temps
            // CPU, la même valeur à l'unité mach près (vérifié sur 670
            // processus le 11/10 : écart maximal 0,07 %, le temps écoulé
            // entre les deux lectures). Au profileur, ces appels au noyau
            // faisaient l'essentiel du balayage, et le balayage le tiers du
            // Pulse installé panneau fermé. La version 2 de la structure
            // suffit : la 6 ajoute instructions, cycles et énergie, que le
            // noyau additionne fil par fil — 30 % plus chère.
            var usage = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            // Échoue avec EPERM sur les processus d'un autre uid : c'est un
            // contrôle du noyau, aucune autorisation ne peut le lever. Un
            // processus terminé (zombie) se lit encore ici, plus par
            // `PROC_PIDTASKINFO` : écarté comme avant.
            guard rc == 0, usage.ri_proc_exit_abstime == 0 else { continue }

            let ticks = usage.ri_user_time &+ usage.ri_system_time
            current[pid] = ticks
            let footprint = usage.ri_phys_footprint

            let identity: Identity
            if let known = identities[pid], known.start == usage.ri_proc_start_abstime {
                identity = known.identity
            } else {
                guard let path = Self.executablePath(pid) else { continue }
                identity = self.identity(ofExecutable: path)
            }
            seen[pid] = (usage.ri_proc_start_abstime, identity)

            var cpu = 0.0
            if elapsed > 0, let old = previous[pid], ticks >= old {
                let nanoseconds = Double(ticks - old) * Self.machToNanoseconds
                cpu = nanoseconds / 1e9 / elapsed * 100
            }

            // Débit disque : écart des compteurs cumulés, comme le CPU. Un
            // compteur qui recule signale un PID réattribué : rien plutôt
            // qu'un débit négatif.
            var diskRead = 0.0, diskWrite = 0.0
            let io = (read: usage.ri_diskio_bytesread, written: usage.ri_diskio_byteswritten)
            currentIO[pid] = io
            if elapsed > 0, let old = previousIO[pid], io.read >= old.read, io.written >= old.written {
                diskRead = Double(io.read - old.read) / elapsed
                diskWrite = Double(io.written - old.written) / elapsed
            }

            var group = totals[identity.id]
                ?? ProcessGroup(bundleId: identity.id, name: identity.name,
                                cpu: 0, footprint: 0, processCount: 0, bundlePath: identity.path)
            group.cpu += cpu
            group.footprint += footprint
            group.processCount += 1
            group.diskRead += diskRead
            group.diskWrite += diskWrite
            group.pids.append(pid)
            totals[identity.id] = group
        }

        previous = current
        previousIO = currentIO
        identities = seen
        return totals.values.sorted { $0.cpu > $1.cpu }
    }

    /// Un exécutable hors bundle .app était jeté sans un mot — dont le service
    /// de décodage vidéo matériel, qui pèse lourd pendant un montage. Il est
    /// regroupé sous le nom de son exécutable.
    private func identity(ofExecutable path: String) -> Identity {
        if let bundlePath = Self.enclosingBundle(path) { return identity(ofBundle: bundlePath) }
        let name = (path as NSString).lastPathComponent
        return (id: "exec:" + name, name: name, path: nil)
    }

    /// Bundle le plus ENGLOBANT du chemin d'un exécutable.
    ///
    /// Les panneaux d'extension d'Adobe sont des .app imbriquées dans celle de
    /// Premiere : retenir la première occurrence de « .app/ » les rattache à
    /// l'application parente, au lieu d'afficher « CEPHtmlEngine, 39 processus »
    /// comme s'il s'agissait d'un logiciel distinct.
    ///
    /// Déduire le bundle du chemin plutôt que d'interroger NSWorkspace rend
    /// cette lecture sûre depuis la file d'échantillonnage — AppKit ne garantit
    /// pas `runningApplications` hors du main thread.
    private static func enclosingBundle(_ executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[executablePath.startIndex..<range.lowerBound]) + ".app"
    }

    private func identity(ofBundle path: String) -> Identity {
        if let cached = bundleCache[path] { return cached }
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
        var identity: Identity = (id: path, name: name, path: path)
        if let info = ProtectedFolders.bundleInfo(path) {
            if let bundleId = info["CFBundleIdentifier"] as? String { identity.id = bundleId }
            if let display = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
               !display.isEmpty { identity.name = display }
        }
        bundleCache[path] = identity
        return identity
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, count)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 × MAXPATHLEN) n'est pas exposé à Swift.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(nulTerminated: buffer)
    }
}

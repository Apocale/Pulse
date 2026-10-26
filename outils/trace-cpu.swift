// Le temps CPU du Pulse installé, intervalle par intervalle : on y voit le
// relevé toutes les 5 s, le débit toutes les 2 s, et toute tâche périodique
// qui pèse. Lecture seule (`proc_pid_rusage`), rien d'autre : ni `sample`, ni
// profileur, qui demanderaient l'accès développeur — une fenêtre de mot de
// passe sur l'écran d'Isma.
//
//   swift outils/trace-cpu.swift              10 min, un trait toutes les 2 s
//   swift outils/trace-cpu.swift 300 5        5 min, toutes les 5 s
//   swift outils/trace-cpu.swift 60 2 1234    un autre processus (un --banc)
//
// Le Pulse installé est relancé à chaque fusion (outils/fusionne.sh) : la
// trace s'arrête alors, et ses premières minutes coûtent plus que le régime
// établi (premiers balayages). Relevé du 11/10, mêmes secondes : Pulse
// installé 8 à 9 ms de plus que le banc toutes les 2 s — l'icône de barre.
import AppKit
import Darwin

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
let duree = arguments.first ?? 600
let pas = arguments.dropFirst().first ?? 2
let cible = arguments.dropFirst(2).first.map { pid_t($0) }

var base = mach_timebase_info_data_t()
mach_timebase_info(&base)
let nanosecondesParUnite = Double(base.numer) / Double(base.denom)

func processus() -> pid_t? {
    if let cible { return kill(cible, 0) == 0 ? cible : nil }
    return NSRunningApplication.runningApplications(withBundleIdentifier: "com.isma.pulse").first?.processIdentifier
}

/// Temps CPU en secondes (les temps de rusage sont en unités mach : piège
/// du README), et mémoire.
func lecture(_ pid: pid_t) -> (cpu: Double, memoire: UInt64)? {
    var info = rusage_info_v6()
    let lu = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    } == 0
    guard lu else { return nil }
    return (Double(info.ri_user_time &+ info.ri_system_time) * nanosecondesParUnite / 1e9, info.ri_phys_footprint)
}

guard let pid = processus(), var avant = lecture(pid) else {
    print("processus introuvable")
    exit(1)
}
setvbuf(stdout, nil, _IOLBF, 0)
print("pid \(pid) · un trait toutes les \(pas) s pendant \(Int(duree)) s · une dièse = 0,1 % d'un cœur")
let debut = Date()
var instant = Date(), cumul = 0.0, couvert = 0.0
while Date().timeIntervalSince(debut) < duree {
    Thread.sleep(forTimeInterval: pas)
    guard processus() == pid, let apres = lecture(pid) else {
        print("le processus \(pid) a quitté (relancé par une fusion ?)")
        break
    }
    let dt = Date().timeIntervalSince(instant)
    let d = apres.cpu - avant.cpu
    cumul += d
    couvert += dt
    let pct = d / dt * 100
    print(String(format: "%6.0f s  %7.1f ms  %5.2f %%  %@", Date().timeIntervalSince(debut), d * 1000, pct,
                 String(repeating: "#", count: min(80, Int(pct * 10)))))
    avant = apres
    instant = Date()
}
print(String(format: "moyenne : %.2f %% d'un cœur sur %.0f s · mémoire %.0f Mo", cumul / max(couvert, 1) * 100,
             couvert, Double(avant.memoire) / 1_048_576))

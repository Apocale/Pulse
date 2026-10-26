import Foundation
import IOKit
import IOKit.pwr_mgt
import XPC
import notify
import PulseFanKit

// PulseHelper — le helper privilégié de Pulse (chantier 14).
//
// Lancé par launchd, en root, seulement si Isma l'a installé (voir
// docs/chantiers/14-ventilateurs.md). Il ne fait qu'une chose : poser sur les
// ventilateurs la consigne que Pulse lui envoie, bornée par le minimum et le
// maximum d'Apple, et rendre la main à macOS dès que quelque chose cloche —
// Pulse parti, battement manqué, veille, pression thermique forte, SMC muet,
// arrêt. Toute la logique est dans `FanController` (PulseFanKit), testée sans
// root contre un SMC simulé ; ce fichier ne fait que brancher le système.
//
// `PulseHelper --simule` : mêmes sécurités sur un SMC simulé, sans root, sur
// un écouteur anonyme ; pour regarder le journal tourner.

let simulated = CommandLine.arguments.contains("--simule")

// Sur accord seulement, en root : installer ou retirer le helper.
if CommandLine.arguments.contains("--installe") { exit(Installer.install()) }
if CommandLine.arguments.contains("--desinstalle") { exit(Installer.uninstall()) }
// Sans root, sans rien écrire : ce que ferait --installe.
if CommandLine.arguments.contains("--essai-installation") { exit(Installer.dryRun()) }

guard simulated || geteuid() == 0 else {
    FileHandle.standardError.write(Data("PulseHelper ne tourne que sous launchd, en root (ou avec --simule).\n".utf8))
    exit(64)
}

/// Horloge monotone, sommeil compris : une heure système qui saute ne
/// déclenche ni ne retarde le chien de garde.
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

let journal = HelperLog(path: simulated ? nil : HelperLog.path)
let queue = DispatchQueue(label: FanProtocol.label)

let hardware: FanHardware
if simulated {
    hardware = SimulatedFans()
} else if let smc = SMCFans() {
    hardware = smc
} else {
    journal.write("SMC inaccessible : rien n'est touché")
    exit(70)
}

let controller = FanController(hardware: hardware, now: now(), writesUsed: simulated ? 0 : WriteLedger.load()) {
    journal.write($0)
}
if !simulated { controller.onWrite = { WriteLedger.save($0) } }
journal.write("démarrage (pid \(getpid()), protocole \(FanProtocol.version), "
              + "\(controller.writesUsed) écriture(s) sur \(FanProtocol.writeBudget) depuis le démarrage du Mac)")

/// Qui peut parler au helper : un processus de la personne devant l'écran,
/// signé « com.isma.pulse » — et, si le helper porte une identité Apple
/// (Team ID), signé par Apple pour la même équipe. En ad hoc, l'identifiant
/// est la seule exigence qui survive aux recompilations, et un processus de
/// la même personne peut le copier : d'où la surface minimale — rien de ce
/// qu'un tel client peut demander ne sort des bornes d'Apple, et tout
/// retombe en automatique (revue de sécurité, docs/chantiers).
let clientRequirement = FanSigning.clientRequirement(team: FanSigning.ownTeamIdentifier())
journal.write("exigence envers le client : \(clientRequirement)")

func admit(_ peer: xpc_connection_t) -> Bool {
    let uid = xpc_connection_get_euid(peer)
    var console = stat()
    guard uid != 0, stat("/dev/console", &console) == 0, console.st_uid == uid else { return false }
    if simulated { return true }
    return xpc_connection_set_peer_code_signing_requirement(peer, clientRequirement) == 0
}

let listener: xpc_connection_t
if simulated {
    listener = xpc_connection_create(nil, queue)
} else {
    listener = xpc_connection_create_mach_service(FanProtocol.label, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
}
let server = FanXPCServer(listener: listener, controller: controller, queue: queue, clock: now, admit: admit)
server.log = { journal.write($0) }
server.onIdle = {
    journal.write("rien à faire depuis \(Int(FanProtocol.idleExit)) s : arrêt")
    exit(0)
}
// « Désinstaller » dans Pulse : la main déjà rendue par le contrôleur,
// fichiers effacés, puis launchd l'arrête.
server.onUninstall = {
    if simulated {
        journal.write("simulation : désinstallation demandée (rien à effacer)")
    } else {
        Installer.uninstallFromDaemon(journal: journal)
    }
}
server.start()

// Arrêt demandé (désinstallation, extinction) : la main à macOS d'abord.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
    source.setEventHandler {
        controller.stop(now: now())
        journal.write("arrêt (signal \(number))")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// Pression thermique publiée par macOS : forte, la main à macOS et 10 min
// de pause.
var pressureToken: Int32 = 0
func readPressure(_ token: Int32) {
    var state: UInt64 = 0
    guard notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) else { return }
    let level = Int(state)
    server.system { controller, time in controller.thermal(level, now: time) }
}
if notify_register_dispatch("com.apple.system.thermalpressurelevel", &pressureToken, queue, { readPressure($0) })
    == UInt32(NOTIFY_STATUS_OK) {
    readPressure(pressureToken)
}

// Veille : la main à macOS avant que le Mac ne dorme ; au réveil, 10 s
// d'automatique avant toute consigne.
var powerPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
var rootPort: io_connect_t = 0
rootPort = IORegisterForSystemPower(nil, &powerPort, { _, _, message, argument in
    switch message {
    case 0xE000_0270: // kIOMessageCanSystemSleep
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case 0xE000_0280: // kIOMessageSystemWillSleep
        queue.sync { controller.willSleep(now: now()) }
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case 0xE000_0300: // kIOMessageSystemHasPoweredOn
        server.system { controller, time in controller.didWake(now: time) }
    default:
        break
    }
}, &powerNotifier)
if let powerPort { IONotificationPortSetDispatchQueue(powerPort, DispatchQueue(label: FanProtocol.label + ".veille")) }

if simulated {
    // Un client du même processus, pour voir les sécurités agir : une
    // consigne, puis plus de battement — retour en automatique à 15 s.
    let client = FanXPCClient(endpoint: xpc_endpoint_create(listener))
    let first = client.sendAndWait(.hold([4_000, 9_999]))
    journal.write("simulation : consigne 4 000 / 9 999 → \(first.map { $0.fans.map { Int($0.target ?? 0) } } ?? [])")
    journal.write("simulation : plus de battement, attendre 15 s…")
}

dispatchMain()

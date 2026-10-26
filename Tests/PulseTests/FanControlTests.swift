import Foundation
import Testing
import XPC
@testable import Pulse
@testable import PulseFanKit

/// Le contrôle des ventilateurs (chantier 14), sans root et sans toucher au
/// SMC : la courbe, les sécurités du helper contre un SMC simulé aux bornes de
/// ce M2 Max, le protocole, et la connexion XPC de bout en bout sur un
/// écouteur anonyme.
@Suite struct FanCurveTests {

    @Test func laCourbeInterpoleEntreSesPoints() {
        let curve = FanCurve(points: [.init(40, 0), .init(60, 0.5), .init(80, 1)])
        #expect(curve.level(at: 20) == 0)        // plat sous le premier point
        #expect(curve.level(at: 50) == 0.25)
        #expect(curve.level(at: 60) == 0.5)
        #expect(curve.level(at: 70) == 0.75)
        #expect(curve.level(at: 95) == 1)        // plat au-dessus du dernier
        #expect(curve.level(at: .nan) == 1)      // illisible : le maximum, jamais le minimum
    }

    /// Plus chaud ne veut jamais dire moins de souffle, quels que soient les
    /// points qu'on a glissés.
    @Test func uneCourbeNeDescendJamaisQuandLaTemperatureMonte() {
        let wild = FanCurve(points: [.init(80, 0.2), .init(40, 0.6), .init(60, 0.1), .init(200, 3), .init(.nan, 0.5)])
        let clean = wild.sanitized
        #expect(clean.points.map(\.celsius) == [40, 60, 80, 105])
        #expect(clean.points.map(\.level) == [0.6, 0.6, 0.6, 1])
        for t in stride(from: 30.0, through: 105, by: 0.5) {
            #expect(clean.level(at: t + 0.5) >= clean.level(at: t))
        }
    }

    @Test func uneCourbeTropCourteRedevientCelleParDefaut() {
        #expect(FanCurve(points: [.init(50, 0.3)]).sanitized == .standard)
        #expect(FanCurve(points: []).sanitized == .standard)
        let many = FanCurve(points: (0..<12).map { .init(30 + Double($0) * 6, Double($0) / 11) })
        #expect(many.sanitized.points.count == 8)
        // Deux points à la même température : le plus fort l'emporte.
        let twins = FanCurve(points: [.init(50, 0.2), .init(50.2, 0.7), .init(80, 1)]).sanitized
        #expect(twins.points.count == 2)
        #expect(twins.points[0].level == 0.7)
    }

    /// Le niveau devient une consigne dans les bornes de CHAQUE ventilateur.
    @Test func leNiveauSAppliqueDansLesBornesDeChaqueVentilateur() {
        let fans = SimulatedFans.m2Max
        #expect(FanPlan.targets(level: 0, fans: fans) == [1_350, 1_522])
        #expect(FanPlan.targets(level: 1, fans: fans) == [5_349, 5_777])
        #expect(FanPlan.targets(level: 0.5, fans: fans) == [3_350, 3_650])
        #expect(FanPlan.targets(level: 7, fans: fans) == [5_349, 5_777])
        #expect(FanPlan.targets(level: -1, fans: fans) == [1_350, 1_522])
        #expect(FanPlan.targets(level: .nan, fans: fans) == [5_349, 5_777])
    }

    /// Une hausse passe tout de suite, une baisse au-delà de 3 °C seulement.
    @Test func lHysteresisRetientLesPetitesBaisses() {
        var follower = FanFollower(band: 3)
        #expect(follower.feed(60) == 60)
        #expect(follower.feed(64) == 64)     // hausse : tout de suite
        #expect(follower.feed(62) == 64)     // baisse de 2 °C : tenue
        #expect(follower.feed(61.5) == 64)
        #expect(follower.feed(58) == 61)     // baisse de 6 °C : suit, à 3 °C près
        #expect(follower.feed(59) == 61)
        #expect(follower.feed(70) == 70)
    }

    @Test func laSondeRetenue() {
        #expect(FanSensor.hottest.pick(cpu: 70, gpu: 82) == 82)
        #expect(FanSensor.hottest.pick(cpu: 70, gpu: nil) == 70)
        #expect(FanSensor.cpu.pick(cpu: nil, gpu: 82) == nil)
        #expect(FanSensor.gpu.pick(cpu: 70, gpu: 82) == 82)
        #expect(FanSensor.hottest.pick(cpu: nil, gpu: nil) == nil)
    }

    /// Règle dure n°2 : un réglage absent ou abîmé retombe sur sa valeur par
    /// défaut — et le mode sur l'AUTOMATIQUE, jamais sur un mode actif.
    @Test func lesReglagesAbimesRetombentEnAutomatique() throws {
        let decode = { (json: String) in try JSONDecoder().decode(FanSettings.self, from: Data(json.utf8)) }
        let empty = try decode("{}")
        let turbo = try decode(#"{"mode":"turbo","fixedLevel":"vite"}"#)
        let tooFast = try decode(#"{"fixedLevel":9}"#)
        #expect(empty == FanSettings())
        #expect(empty.mode == .automatic)
        #expect(turbo.mode == .automatic)
        #expect(turbo.fixedLevel == 0.5)
        #expect(tooFast.fixedLevel == 1)
        let curve = try decode(#"{"mode":"curve","curve":{"points":[{"celsius":50,"level":0.2},{"celsius":"chaud"},{"celsius":80,"level":0.9}]}}"#)
        #expect(curve.mode == .curve)
        #expect(curve.curve.points.map(\.celsius) == [50, 80])
        let roundTrip = try JSONDecoder().decode(FanSettings.self, from: JSONEncoder().encode(curve))
        #expect(roundTrip == curve)
    }
}

@Suite struct FanSafetyTests {
    private func make(_ fans: [FanReading] = SimulatedFans.m2Max) -> (FanController, SimulatedFans, Log) {
        let smc = SimulatedFans(fans: fans)
        let log = Log()
        let controller = FanController(hardware: smc, now: 0) { log.lines.append($0) }
        return (controller, smc, log)
    }

    final class Log { var lines: [String] = [] }

    /// Jamais sous le minimum ni au-dessus du maximum d'Apple, relus au SMC :
    /// la valeur du client n'est jamais crue.
    @Test func uneConsigneEstBorneeParLeMinimumEtLeMaximumDApple() {
        let (controller, smc, _) = make()
        let status = controller.handle(.hold([100, 99_999]), client: 1, now: 0)
        #expect(status.accepted)
        #expect(smc.fans.map(\.target) == [1_350, 5_777])
        #expect(smc.fans.allSatisfy { $0.manual })
        #expect(smc.violations == 0)
        #expect(controller.state == .manual(targets: [1_350, 5_777]))
    }

    /// Le mode imposé d'abord, la vitesse ensuite ; puis plus une écriture
    /// tant que la consigne ne change pas — un battement n'écrit rien.
    @Test func unBattementNEcritRien() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        #expect(smc.writes == ["F0Md=1", "F0Tg=3000", "F1Md=1", "F1Tg=3000"])
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 5)
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 10)
        #expect(smc.writes.count == 4)
        _ = controller.handle(.hold([3_500, 3_000]), client: 1, now: 15)
        #expect(smc.writes.last == "F0Tg=3500")
        #expect(smc.writes.count == 5)
    }

    @Test func unNombreDeVentilateursFauxEstRefuseSansRienEcrire() {
        let (controller, smc, _) = make()
        let status = controller.handle(.hold([3_000]), client: 1, now: 0)
        #expect(!status.accepted)
        #expect(status.refusal == .wrongCount)
        #expect(smc.writes.isEmpty)
    }

    @Test func sansBattementDepuis15sRetourEnAutomatique() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 100)
        controller.tick(now: 110)
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 110)   // battement
        controller.tick(now: 124.9)
        #expect(controller.isManual)
        controller.tick(now: 125.1)
        #expect(!controller.isManual)
        #expect(controller.fallback == .heartbeatLost)
        #expect(smc.fans.allSatisfy { !$0.manual })
        #expect(smc.writes.suffix(2) == ["F0Md=0", "F1Md=0"])
    }

    /// Pulse quitte ou plante : sa connexion se ferme, la main revient à
    /// macOS. La connexion d'un AUTRE client qui se ferme ne change rien.
    @Test func quandPulseQuitteRetourEnAutomatique() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 7, now: 0)
        controller.clientGone(8, now: 1)
        #expect(controller.isManual)
        controller.clientGone(7, now: 2)
        #expect(!controller.isManual)
        #expect(controller.fallback == .clientGone)
        #expect(smc.fans.allSatisfy { !$0.manual })
    }

    @Test func enVeilleRetourEnAutomatiquePuisDixSecondesDeGrace() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        controller.willSleep(now: 1)
        #expect(controller.fallback == .sleep)
        #expect(smc.fans.allSatisfy { !$0.manual })
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 2).refusal == .asleep)
        controller.didWake(now: 500)
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 505).refusal == .wakeGrace)
        #expect(smc.fans.allSatisfy { !$0.manual })
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 510.5).accepted)
    }

    /// macOS signale une pression forte : la main à macOS, 10 min de pause,
    /// et pas de reprise tant que la pression reste forte. Modérée — ce que
    /// fait un export ordinaire, relevé le 11/10 —, rien ne change.
    @Test func unePressionThermiqueForteRendLaMainPourDixMinutes() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([1_400, 1_600]), client: 1, now: 0)
        controller.thermal(1, now: 1)
        #expect(controller.isManual)
        controller.thermal(2, now: 2)
        #expect(!controller.isManual)
        #expect(controller.fallback == .thermal)
        #expect(smc.fans.allSatisfy { !$0.manual })
        controller.thermal(0, now: 300)
        let early = controller.handle(.hold([1_400, 1_600]), client: 1, now: 601)
        #expect(early.refusal == .thermalLock)
        #expect(early.lockRemaining == 1)
        #expect(controller.handle(.hold([1_400, 1_600]), client: 1, now: 602.5).accepted)
        // Toujours forte au bout de 10 min : toujours non.
        controller.thermal(3, now: 700)
        controller.thermal(2, now: 1_301)
        #expect(controller.handle(.hold([1_400, 1_600]), client: 1, now: 1_400).refusal == .thermalLock)
    }

    @Test func unSMCMuetOuQuiRefuseRendLaMain() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        smc.mute = true
        let status = controller.handle(.hold([3_000, 3_000]), client: 1, now: 5)
        #expect(status.refusal == .hardware)
        #expect(controller.fallback == .hardwareError)
        // Muet à la lecture, on écrit quand même l'automatique sur les deux.
        #expect(smc.writes.suffix(2) == ["F0Md=0", "F1Md=0"])

        let (other, failing, _) = make()
        failing.failWrites = true
        #expect(other.handle(.hold([3_000, 3_000]), client: 1, now: 0).refusal == .hardware)
        #expect(!other.isManual)
    }

    /// Des bornes absurdes (minimum nul, maximum sous le minimum) : aucune
    /// consigne.
    @Test func desBornesAbsurdesNeLaissentRienPasser() {
        var fans = SimulatedFans.m2Max
        fans[1].min = 0
        let (controller, smc, _) = make(fans)
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 0).refusal == .hardware)
        #expect(smc.writes.isEmpty)
    }

    /// Un helper qui démarre trouve un ventilateur resté imposé (le
    /// précédent a été tué au milieu d'une consigne) : il le rend à macOS.
    /// Rien d'imposé : il n'écrit rien.
    @Test func auDemarrageLeHelperRendCeQuiEtaitImpose() {
        var fans = SimulatedFans.m2Max
        fans[0].manual = true
        let (controller, smc, _) = make(fans)
        #expect(controller.fallback == .helperStart)
        #expect(smc.fans.allSatisfy { !$0.manual })
        let (_, clean, _) = make()
        #expect(clean.writes.isEmpty)
    }

    @Test func lArretRendLaMain() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        controller.stop(now: 1)
        #expect(controller.fallback == .helperStop)
        #expect(smc.fans.allSatisfy { !$0.manual })
    }

    /// Capteur muet côté Pulse : il demande l'automatique en le disant.
    @Test func capteurMuetDemandeLAutomatique() {
        let (controller, smc, log) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        _ = controller.handle(.automatic(.sensorLost), client: 1, now: 5)
        #expect(controller.fallback == .sensorLost)
        #expect(smc.fans.allSatisfy { !$0.manual })
        #expect(log.lines.last == "automatique : la température ne se lisait plus")
    }

    /// Le budget d'écritures du démarrage : la consigne qui le dépasserait
    /// est refusée et la main rendue — le retour en automatique, lui,
    /// s'écrit toujours. Le compte repris d'un helper précédent compte.
    @Test func leBudgetDEcrituresRendLaMainAvantQueLeSMCNeRefuse() {
        let smc = SimulatedFans()
        let controller = FanController(hardware: smc, now: 0, writesUsed: FanProtocol.writeBudget - 4)
        var saved: [Int] = []
        controller.onWrite = { saved.append($0) }
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 0).accepted)   // 4 écritures
        #expect(saved.last == FanProtocol.writeBudget)
        let over = controller.handle(.hold([3_600, 3_600]), client: 1, now: 5)
        #expect(over.refusal == .writeBudget)
        #expect(controller.fallback == .writeBudget)
        #expect(smc.fans.allSatisfy { !$0.manual })
        #expect(over.writesUsed == Int64(FanProtocol.writeBudget))
        // Un battement sans changement ne coûte rien, même budget épuisé :
        // mais il n'y a plus de consigne à tenir, il faudrait réécrire.
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 10).refusal == .writeBudget)
    }

    /// Une hausse passe tout de suite ; une baisse attend une minute après
    /// la précédente — la consigne plus forte reste en place.
    @Test func uneBaisseAttendUneMinuteApresLaPrecedente() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([4_000, 4_000]), client: 1, now: 0)
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 5)     // première baisse : passe
        #expect(smc.fans.map(\.target) == [3_000, 3_000])
        _ = controller.handle(.hold([2_000, 2_000]), client: 1, now: 30)    // trop tôt : tenue à 3 000
        #expect(smc.fans.map(\.target) == [3_000, 3_000])
        _ = controller.handle(.hold([5_000, 5_000]), client: 1, now: 35)    // hausse : tout de suite
        #expect(smc.fans.map(\.target) == [5_000, 5_000])
        _ = controller.handle(.hold([2_000, 2_000]), client: 1, now: 66)    // une minute après la baisse
        #expect(smc.fans.map(\.target) == [2_000, 2_000])
        #expect(smc.violations == 0)
    }

    /// « Désinstaller » : la main rendue avant que le démon n'efface ses
    /// fichiers.
    @Test func laDesinstallationRendDAbordLaMain() {
        let (controller, smc, _) = make()
        _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        let status = controller.handle(FanRequest(command: .uninstall), client: 1, now: 1)
        #expect(status.accepted)
        #expect(!controller.isManual)
        #expect(smc.fans.allSatisfy { !$0.manual })
    }

    /// Le SMC refuse `F0Md = 0` : le ventilateur reste imposé alors que
    /// l'état se dit « automatique ». Le chien de garde retente (1 s, puis
    /// 2, 4… une minute au plus) jusqu'à ce que le SMC relise 0, et le dit
    /// au journal une fois. Avant (17-audit-code) : un seul essai, plus
    /// rien ne tournait, ventilateur imposé jusqu'au redémarrage.
    @Test func unRetourRefuseParLeSMCSeRetenteJusquARendreLaMain() {
        let (controller, smc, log) = make()
        _ = controller.handle(.hold([1_400, 1_600]), client: 1, now: 0)
        smc.refusedRestores = 3          // F0 et F1 refusés, puis F0 encore une fois
        controller.clientGone(1, now: 10)
        #expect(!controller.isManual)
        #expect(controller.pendingRestore == [0, 1])
        #expect(controller.needsWatchdog)
        #expect(smc.fans.allSatisfy { $0.manual })
        controller.tick(now: 10.5)       // trop tôt : rien
        #expect(smc.writes.count == 6)
        controller.tick(now: 11)         // F0 refusé encore, F1 rendu
        #expect(controller.pendingRestore == [0])
        #expect(!smc.fans[1].manual)
        controller.tick(now: 12)         // prochain essai à 13 (2 s)
        #expect(smc.writes.count == 8)
        controller.tick(now: 13)
        #expect(controller.pendingRestore.isEmpty)
        #expect(!controller.needsWatchdog)
        #expect(smc.fans.allSatisfy { !$0.manual })
        #expect(controller.fallback == .clientGone)
        #expect(log.lines.last == "automatique rendu au nouvel essai : ventilateur 0")
        #expect(log.lines.filter { $0.contains("ÉCHEC") }.count == 1)
    }

    /// Un refus d'écrire sur un ventilateur que le SMC relit déjà rendu ne
    /// laisse rien à rattraper ; une nouvelle consigne efface ce qui restait.
    @Test func rienARattraperQuandLeSMCRelitAutomatique() {
        let (controller, smc, _) = make()
        smc.failWrites = true
        #expect(controller.handle(.hold([3_000, 3_000]), client: 1, now: 0).refusal == .hardware)
        #expect(controller.pendingRestore.isEmpty)
        #expect(!controller.needsWatchdog)

        let (other, refusing, _) = make()
        _ = other.handle(.hold([3_000, 3_000]), client: 1, now: 0)
        refusing.refusedRestores = 1
        _ = other.handle(.automatic(), client: 1, now: 5)
        #expect(other.pendingRestore == [0])
        #expect(other.handle(.hold([3_000, 3_000]), client: 1, now: 6).accepted)
        #expect(other.pendingRestore.isEmpty)
        #expect(other.isManual)
    }

    /// Un refus répété à chaque battement ne s'écrit qu'une fois au journal.
    @Test func unRefusRepeteNeSEcritQuUneFois() {
        let (controller, _, log) = make()
        controller.thermal(2, now: 0)
        for t in stride(from: 1.0, through: 60, by: 5) {
            _ = controller.handle(.hold([3_000, 3_000]), client: 1, now: t)
        }
        #expect(log.lines.filter { $0.hasPrefix("refus") }.count == 1)
    }
}

@Suite struct FanProtocolTests {
    private func decode(_ values: [String: Int64]) -> FanRequest? { FanRequest.decode { values[$0] } }

    @Test func unMessageMalFormeNeDecodeRien() {
        #expect(decode([:]) == nil)
        #expect(decode(["v": 2, "c": 1]) == nil)                     // autre version
        #expect(decode(["v": 1, "c": 9]) == nil)                     // commande inconnue
        #expect(decode(["v": 1, "c": 3, "n": 0]) == nil)             // aucune consigne
        #expect(decode(["v": 1, "c": 3, "n": 9]) == nil)             // trop de ventilateurs
        #expect(decode(["v": 1, "c": 3, "n": 2, "t0": 3000]) == nil) // consigne manquante
        #expect(decode(["v": 1, "c": 3, "n": 1, "t0": -5]) == nil)   // négative
        #expect(decode(["v": 1, "c": 1]) == .status)
    }

    /// Un client ne peut pas se prévaloir d'une raison du helper (veille,
    /// pression…) : seulement « demandé » ou « capteur muet ».
    @Test func unClientNeChoisitPasSaRaison() {
        #expect(decode(["v": 1, "c": 2, "r": 5])?.reason == .requested)
        #expect(decode(["v": 1, "c": 2, "r": 6])?.reason == .sensorLost)
        #expect(decode(["v": 1, "c": 2])?.reason == .requested)
    }

    @Test func allerRetour() {
        let hold = FanRequest.hold([1_350, 5_777.4])
        #expect(decode(hold.encode()) == .hold([1_350, 5_777]))
        let status = FanStatus(accepted: false, refusal: .thermalLock, manual: true, fallback: .sleep,
                               fallbackAge: 12, lockRemaining: 30, pressure: 1, helperPID: 42,
                               fans: SimulatedFans.m2Max)
        let values = status.encode()
        #expect(FanStatus.decode { values[$0] } == status)
    }

    /// Les octets écrits : le Float32 petit-boutiste qu'Apple Silicon attend,
    /// vérifié contre le lecteur (lecture seule) du chantier 04 et contre les
    /// octets de `F0Mx` relevés sur la machine.
    @Test func lesOctetsDUneConsigne() {
        #expect(FanBytes.float32LE(5_349) == [0, 40, 167, 69])
        #expect(SMCCode.decode(type: "flt ", bytes: FanBytes.float32LE(3_217)) == 3_217)
        #expect(FanBytes.decode(type: "flt ", bytes: FanBytes.float32LE(1_522)) == 1_522)
        #expect(FanBytes.fpe2(2_000) == [0x1F, 0x40])
        #expect(FanBytes.encode(1, type: "ui8 ", size: 1) == [1])
        #expect(FanBytes.encode(300, type: "ui8 ", size: 1) == nil)
        #expect(FanBytes.encode(3_000, type: "flt ", size: 2) == nil)   // taille qui ne colle pas
        #expect(FanBytes.encode(3_000, type: "ioft", size: 8) == nil)   // type inconnu
        #expect(FanBytes.encode(.infinity, type: "flt ", size: 4) == nil)
    }

    /// Le plist installé : le binaire hors du bundle, le service Mach, la
    /// relance sur plantage seulement. Lu par le vrai décodeur de plists.
    @Test func lePlistLaunchd() throws {
        let data = Data(FanProtocol.launchdPlist().utf8)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.isma.pulse.helper")
        #expect(plist["Program"] as? String == "/Library/PrivilegedHelperTools/com.isma.pulse.helper")
        #expect((plist["MachServices"] as? [String: Bool])?["com.isma.pulse.helper"] == true)
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(plist["RunAtLoad"] == nil)
        #expect(FanRequest.decode { FanRequest(command: .uninstall).encode()[$0] } == FanRequest(command: .uninstall))
    }

    /// L'installation ne copie en root qu'un binaire signé
    /// `com.isma.pulse.helper` : un autre exécutable — celui de Pulse, un
    /// outil du système — est refusé, un fichier absent aussi.
    @Test func lInstallationReconnaitLeHelperASaSignature() {
        #expect(FanSigning.identifier(ofFileAt: "/bin/ls") == "com.apple.ls")
        #expect(FanSigning.identifier(ofFileAt: "/nulle/part/PulseHelper") == nil)
        #expect(FanSigning.identifier(ofFileAt: "/bin/ls") != FanProtocol.label)
    }

    /// L'exigence envers le client suit la signature du helper : ad hoc,
    /// l'identifiant seul ; identité Apple, la même équipe en plus. Les deux
    /// se compilent pour de vrai (`SecRequirementCreateWithString`), et un
    /// Team ID bizarre ne peut rien injecter dans l'exigence.
    @Test func lExigenceEnversLeClientSuitLaSignatureDuHelper() {
        let adHoc = FanSigning.clientRequirement(team: nil)
        let team = FanSigning.clientRequirement(team: "AB12CD34EF")
        #expect(adHoc == #"identifier "com.isma.pulse""#)
        #expect(team == #"identifier "com.isma.pulse" and anchor apple generic and certificate leaf[subject.OU] = "AB12CD34EF""#)
        #expect(FanSigning.clientRequirement(team: #"X" or true or "#) == adHoc)
        for text in [adHoc, team] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        }
    }

    /// La courbe ne change de consigne qu'au pas de 5 %.
    @Test func leNiveauAuPasDeCinqPourCent() {
        #expect(FanPlan.quantized(0.62) == 0.6)
        #expect(FanPlan.quantized(0.63) == 0.65)
        #expect(FanPlan.quantized(-1) == 0)
        #expect(FanPlan.quantized(.nan) == 1)
    }

    /// L'app reste en lecture seule : le lecteur du 04 n'a toujours pas de
    /// commande d'écriture.
    @Test func lAppNEcritToujoursPasDansLeSMC() {
        #expect(SMCCommand(rawValue: 6) == nil)
    }
}

/// Le chemin XPC entier, dans le processus : écouteur anonyme, client par
/// point de terminaison, SMC simulé, horloge à la main.
@Suite(.serialized) struct FanXPCTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 1_000
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
    }

    private func serve() -> (FanXPCServer, SimulatedFans, Clock, xpc_endpoint_t, DispatchQueue) {
        let queue = DispatchQueue(label: "essai.helper")
        let smc = SimulatedFans()
        let clock = Clock()
        let listener = xpc_connection_create(nil, queue)
        let controller = FanController(hardware: smc, now: clock.now())
        let server = FanXPCServer(listener: listener, controller: controller, queue: queue, clock: clock.now)
        server.watchdogInterval = 0.05
        server.start()
        return (server, smc, clock, xpc_endpoint_create(listener), queue)
    }

    private func wait(_ queue: DispatchQueue, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if queue.sync(execute: condition) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    @Test func uneConsignePasseEtRevientBornee() {
        let (server, smc, _, endpoint, queue) = serve()
        defer { withExtendedLifetime(server) {} }
        let client = FanXPCClient(endpoint: endpoint)
        let status = client.sendAndWait(.hold([2_000, 60_000]))
        #expect(status?.accepted == true)
        #expect(status?.manual == true)
        #expect(status?.fans.map(\.target) == [2_000, 5_777])
        #expect(queue.sync { smc.fans.allSatisfy { $0.manual } })
        client.close()
    }

    @Test func clientFermeRetourEnAutomatique() {
        let (server, smc, _, endpoint, queue) = serve()
        let client = FanXPCClient(endpoint: endpoint)
        #expect(client.sendAndWait(.hold([3_000, 3_000]))?.accepted == true)
        client.close()
        #expect(wait(queue) { !server.controller.isManual })
        #expect(queue.sync { server.controller.fallback } == .clientGone)
        #expect(queue.sync { smc.fans.allSatisfy { !$0.manual } })
    }

    /// Pulse parti, un ventilateur que le SMC refuse de rendre : le helper
    /// ne sort pas faute de client tant qu'il reste imposé, le rattrape au
    /// prochain essai du chien de garde, puis seulement s'arrête.
    @Test func leHelperNeSortPasTantQuUnVentilateurResteImpose() {
        let (server, smc, clock, endpoint, queue) = serve()
        let idle = Flag()
        let client = FanXPCClient(endpoint: endpoint)
        #expect(client.sendAndWait(.hold([3_000, 3_000]))?.accepted == true)
        // Client connecté, consigne posée : la sortie à vide ne peut plus
        // partir d'avant la connexion.
        queue.sync {
            server.idleDelay = 0.1
            server.onIdle = { idle.set() }
            smc.refusedRestores = 1
        }
        client.close()
        #expect(wait(queue) { !server.controller.isManual })
        #expect(queue.sync { server.controller.pendingRestore } == [0])
        Thread.sleep(forTimeInterval: 0.4)          // horloge arrêtée : aucun essai, aucune sortie
        #expect(!idle.isSet)
        #expect(queue.sync { smc.fans[0].manual })
        clock.advance(2)
        #expect(wait(queue) { server.controller.pendingRestore.isEmpty })
        #expect(queue.sync { smc.fans.allSatisfy { !$0.manual } })
        #expect(wait(queue) { idle.isSet })
    }

    /// L'exigence de signature posée sur le client est appliquée pour de
    /// vrai : le processus des tests n'est pas « com.isma.pulse », sa
    /// consigne n'arrive jamais au contrôleur, rien n'est écrit, et le refus
    /// se lit au journal.
    @Test func unClientMalSigneNeToucheARien() {
        let queue = DispatchQueue(label: "essai.helper.signature")
        let smc = SimulatedFans()
        let listener = xpc_connection_create(nil, queue)
        let controller = FanController(hardware: smc, now: 0)
        let server = FanXPCServer(listener: listener, controller: controller, queue: queue, clock: { 0 }) { peer in
            xpc_connection_set_peer_code_signing_requirement(peer, FanSigning.clientRequirement(team: nil)) == 0
        }
        let lines = Lines()
        server.log = { lines.append($0) }
        server.start()
        defer { withExtendedLifetime(server) {} }
        let client = FanXPCClient(endpoint: xpc_endpoint_create(listener))
        #expect(client.sendAndWait(.hold([5_000, 5_000]), timeout: 1) == nil)
        #expect(queue.sync { smc.writes.isEmpty && !controller.isManual })
        #expect(wait(queue) { lines.all.contains { $0.hasPrefix("client refusé : signature") } })
        client.close()
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func leChienDeGardeAgitSansBattement() {
        let (server, smc, clock, endpoint, queue) = serve()
        let client = FanXPCClient(endpoint: endpoint)
        #expect(client.sendAndWait(.hold([3_000, 3_000]))?.accepted == true)
        clock.advance(10)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(queue.sync { server.controller.isManual })
        clock.advance(6)
        #expect(wait(queue) { !server.controller.isManual })
        #expect(queue.sync { server.controller.fallback } == .heartbeatLost)
        #expect(queue.sync { smc.fans.allSatisfy { !$0.manual } })
        client.close()
    }

    /// Un message aux valeurs d'un autre type (chaînes) : « mal formé »,
    /// rien n'est écrit.
    @Test func unMessageEtrangerEstRefuseSansRienToucher() {
        let (server, smc, _, endpoint, queue) = serve()
        defer { withExtendedLifetime(server) {} }
        let connection = xpc_connection_create_from_endpoint(endpoint)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "v", "1")
        xpc_dictionary_set_string(message, "c", "3")
        let reply = xpc_connection_send_message_with_reply_sync(connection, message)
        #expect(xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
        #expect(xpc_dictionary_get_int64(reply, FanProtocol.Key.accepted) == 0)
        #expect(xpc_dictionary_get_int64(reply, FanProtocol.Key.refusal) == FanRefusal.malformed.rawValue)
        #expect(queue.sync { smc.writes.isEmpty })
        xpc_connection_cancel(connection)
    }
}

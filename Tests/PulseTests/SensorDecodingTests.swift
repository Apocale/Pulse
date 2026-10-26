import Foundation
import Testing
@testable import Pulse

/// Le décodage des capteurs, sur des octets et des résidences relevés sur la
/// machine le 11/10 (M2 Max, macOS 26). Aucun appel au matériel : on vérifie
/// la traduction, pas le capteur.
@Suite struct SensorDecodingTests {

    // MARK: - SMC

    /// Les `flt ` d'Apple Silicon sont des Float32 petit-boutistes.
    @Test func unFlottantSMCSeLitEnPetitBoutiste() {
        #expect(SMCCode.decode(type: "flt ", bytes: [0, 40, 167, 69]) == 5349)          // F0Mx
        let tp01 = SMCCode.decode(type: "flt ", bytes: [165, 205, 170, 66]) ?? 0         // Tp01
        #expect(abs(tp01 - 85.4016) < 0.001)
    }

    /// Le piège vu le 11/10 : `.map(Double.init)` sur un UInt64 choisit
    /// `Double(bitPattern:)`. `FNum` rendait 1e-323 ventilateur, `#KEY` 1e-320
    /// clés — et la carte n'en montrait aucun.
    @Test func unEntierSMCNeSeLitPasCommeUnMotifDeBits() {
        #expect(SMCCode.decode(type: "ui8 ", bytes: [2]) == 2)                           // FNum
        #expect(SMCCode.decode(type: "ui32", bytes: [0, 0, 9, 106]) == 2410)             // #KEY
        #expect(SMCCode.decode(type: "ui16", bytes: [0, 7]) == 7)                        // F0Fc
        #expect(SMCCode.decode(type: "si8 ", bytes: [0xFE]) == -2)
        #expect(SMCCode.decode(type: "si16", bytes: [0xFF, 0xFE]) == -2)
    }

    /// Les virgules fixes des Mac Intel, gardées pour qu'un autre Mac ne lise
    /// pas n'importe quoi.
    @Test func lesVirgulesFixesIntel() {
        #expect(SMCCode.decode(type: "fpe2", bytes: [0x1F, 0x40]) == 2000)               // 8000 / 4 tr/min
        #expect(SMCCode.decode(type: "sp78", bytes: [0x3C, 0x80]) == 60.5)
        #expect(SMCCode.decode(type: "sp78", bytes: [0xFF, 0x00]) == -1)
    }

    /// Un type inconnu ou des octets manquants : pas de chiffre inventé.
    @Test func unTypeInconnuNeRendRien() {
        #expect(SMCCode.decode(type: "ioft", bytes: [0x66, 0x66, 0x22, 0, 0, 0, 0, 0]) == nil)
        #expect(SMCCode.decode(type: "flt ", bytes: [1, 2]) == nil)
        #expect(SMCCode.decode(type: "ui32", bytes: [1]) == nil)
    }

    @Test func lesCodesAQuatreLettres() {
        #expect(SMCCode.fourCC("F0Ac") == 0x4630_4163)
        #expect(SMCCode.string(0x4630_4163) == "F0Ac")
        #expect(SMCCode.string(SMCCode.fourCC("#KEY")) == "#KEY")
    }

    /// Le message de 80 octets : la clé en tête, la commande au 43e octet.
    @Test func leMessageSMCRespecteLaStructureC() {
        let message = SMCMessage.request(key: SMCCode.fourCC("F0Ac"), command: .readBytes, dataSize: 4, index: 0)
        #expect(message.count == 80)
        #expect(Array(message[0..<4]) == [0x63, 0x41, 0x30, 0x46])   // ordre de l'hôte
        #expect(SMCMessage.uint32(message, at: 0) == SMCCode.fourCC("F0Ac"))
        #expect(SMCMessage.uint32(message, at: 28) == 4)
        #expect(message[42] == 5)
        let byIndex = SMCMessage.request(key: 0, command: .keyFromIndex, index: 2409)
        #expect(byIndex[42] == 8)
        #expect(SMCMessage.uint32(byIndex, at: 44) == 2409)
    }

    /// Rien n'écrit dans le SMC : la commande d'écriture (6) n'existe pas
    /// dans le type, elle ne peut donc partir d'aucun appel.
    @Test func aucuneCommandeNEcrit() {
        #expect(SMCCommand.allCases.map(\.rawValue).sorted() == [5, 8, 9])
        #expect(SMCCommand(rawValue: 6) == nil)
    }

    // MARK: - IOReport

    @Test func uneEnergieDevientUnePuissance() {
        #expect(IOReportMath.watts(energy: 16_943, unit: "mJ", seconds: 1) == 16.943)            // CPU Energy
        let gpu = IOReportMath.watts(energy: 11_599_317_800, unit: "nJ", seconds: 1) ?? 0        // GPU Energy
        #expect(abs(gpu - 11.5993) < 0.0001)
        #expect(IOReportMath.watts(energy: 3_000, unit: "mJ", seconds: 1.5) == 2)
        #expect(IOReportMath.watts(energy: 1, unit: "kJ", seconds: 1) == nil)
        #expect(IOReportMath.watts(energy: 1, unit: "mJ", seconds: 0) == nil)
    }

    /// Grappe efficacité, résidences relevées sur 1 s le 11/10, table
    /// `voltage-states1-sram` du pmgr.
    @Test func laFrequenceEstPondereeParLeTempsActif() {
        let states: [(name: String, ticks: Int64)] = [
            ("DOWN", 0), ("IDLE", 6_173_079), ("V0P5", 99_657), ("V1P4", 18_932), ("V2P3", 38_090),
            ("V3P2", 25_234), ("V4P1", 59_800), ("V5P0", 17_769_683)]
        let table: [Double] = [912, 1284, 1752, 2004, 2256, 2424]
        let f = IOReportMath.frequency(states: states, table: table)
        #expect(abs((f?.mhz ?? 0) - 2411.87) < 0.01)
        #expect(abs((f?.active ?? 0) - 0.74475) < 0.0001)
    }

    /// La carte graphique déclare P1…P15 pour huit fréquences : les états de
    /// trop sont acceptés tant qu'ils restent vides.
    @Test func lesEtatsEnTropDeLaCarteGraphique() {
        var states: [(name: String, ticks: Int64)] = [("OFF", 4_833_328), ("P1", 486_125)]
        states += (2...7).map { ("P\($0)", Int64(0)) }
        states.append(("P8", 18_952_404))
        states += (9...15).map { ("P\($0)", Int64(0)) }
        let table: [Double] = [444, 612, 808, 968, 1110, 1236, 1338, 1398]
        let f = IOReportMath.frequency(states: states, table: table)
        #expect(abs((f?.mhz ?? 0) - 1374.14) < 0.01)
        #expect(abs((f?.active ?? 0) - 0.80087) < 0.0001)

        // Du temps dans un état sans fréquence connue : on ne devine pas.
        states[states.count - 1].ticks = 10
        #expect(IOReportMath.frequency(states: states, table: table) == nil)
    }

    @Test func uneTableTropLongueNeRendRien() {
        let states: [(name: String, ticks: Int64)] = [("IDLE", 10), ("V0P1", 5), ("V1P0", 5)]
        #expect(IOReportMath.frequency(states: states, table: [600, 900, 1200]) == nil)
        // Grappe entièrement au repos : fréquence nulle, pas d'invention.
        let idle: [(name: String, ticks: Int64)] = [("IDLE", 10), ("V0P1", 0), ("V1P0", 0)]
        #expect(IOReportMath.frequency(states: idle, table: [600, 900])?.mhz == 0)
    }

    @Test func deuxGrappesSeCombinentAuTempsActif() {
        let both = IOReportMath.combine([(mhz: 3696, active: 0.9), (mhz: 702, active: 0.1)])
        #expect(abs((both?.mhz ?? 0) - 3396.6) < 0.01)
        #expect(abs((both?.active ?? 0) - 0.5) < 0.0001)
        #expect(IOReportMath.combine([])  == nil)
    }

    /// Paires (Hz, mV) petit-boutistes → MHz.
    @Test func laTableDVFSSeLitEnMegahertz() {
        var data = Data()
        for (hz, mv) in [(UInt32(912_000_000), UInt32(590)), (1_284_000_000, 625)] {
            withUnsafeBytes(of: hz.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: mv.littleEndian) { data.append(contentsOf: $0) }
        }
        #expect(DVFSTables.megahertz(data) == [912, 1284])
        #expect(DVFSTables.megahertz(Data([1, 2, 3])) == [])
    }

    // MARK: - Relevé

    @Test func lesFamillesSontDesMoyennes() {
        var sample = SensorSample()
        sample.readings = [
            .init(group: .cpu, family: "Cœurs performance", name: "1", celsius: 80, source: "Tp01"),
            .init(group: .cpu, family: "Cœurs performance", name: "2", celsius: 90, source: "Tp05"),
            .init(group: .cpu, family: "Cœurs efficacité", name: "1", celsius: 70, source: "Tp1h"),
        ]
        let families = sample.families(in: .cpu)
        #expect(families.map(\.family) == ["Cœurs performance", "Cœurs efficacité"])
        #expect(families.first?.celsius == 85)
        #expect(sample.cpuTemperature == 80)
        #expect(sample.hottestCPU?.source == "Tp05")
        #expect(sample.menuBarText == "80°")
        #expect(sample.gpuTemperature == nil)
    }

    // MARK: - Catalogue

    /// La même clé ne mesure pas la même chose d'une génération à l'autre :
    /// `Tp09` est un cœur efficacité sur M1, un cœur performance sur M2. Avec
    /// le seul catalogue du M2, un M1 Pro rangeait ce cœur parmi les cœurs
    /// performance et n'avait pas de carte graphique (sondes en `Tg05`…).
    @Test func leCatalogueSuitLaGenerationDeLaPuce() {
        #expect(SensorCatalog.Chip(brand: "Apple M1 Pro") == .init(generation: 1, variant: "Pro"))
        #expect(SensorCatalog.Chip(brand: "Apple M2 Max") == .init(generation: 2, variant: "Max"))
        #expect(SensorCatalog.Chip(brand: "Apple M4") == .init(generation: 4))
        #expect(SensorCatalog.Chip(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz") == nil)
        #expect(SensorCatalog.Chip(brand: "") == nil)

        func family(_ key: String, on brand: String) -> String? {
            SensorCatalog.entries(for: SensorCatalog.Chip(brand: brand)).first { $0.key == key }?.family
        }
        #expect(family("Tp09", on: "Apple M1 Pro") == "Cœurs efficacité")
        #expect(family("Tp09", on: "Apple M2 Max") == "Cœurs performance")
        #expect(family("Tg05", on: "Apple M1 Pro") == "Carte graphique")
        #expect(family("Tg0f", on: "Apple M1 Pro") == nil)
        #expect(family("Tg0f", on: "Apple M2 Max") == "Carte graphique")
        #expect(family("Tg0G", on: "Apple M4") == "Carte graphique")
        #expect(family("Tg0G", on: "Apple M4 Max") == nil)
        #expect(SensorCatalog.entries(for: SensorCatalog.Chip(brand: "Apple M9 Pro")).isEmpty)
        #expect(SensorCatalog.entries(for: nil).isEmpty)

        for brand in ["Apple M1", "Apple M2", "Apple M3 Max", "Apple M4", "Apple M4 Pro"] {
            let keys = SensorCatalog.entries(for: SensorCatalog.Chip(brand: brand)).map(\.key)
            #expect(!keys.isEmpty && Set(keys).count == keys.count, "\(brand) : clés en double")
        }
    }

    /// Une grappe éteinte rend 4,6 à 6,7 °C (relevé du 26/10) : écarté, la
    /// dernière bonne valeur tient 30 s, puis la sonde se tait. La batterie,
    /// elle, peut être froide pour de vrai.
    @Test func uneSondeDeGrappeEteinteNeFaitPasChuterLaMoyenne() {
        var filter = DieTemperatureFilter()
        let core = SensorCatalog.Entry(key: "Tp01", group: .cpu, family: "Cœurs performance", name: "Cœur performance 1")
        let battery = SensorCatalog.Entry(key: "TB1T", group: .battery, family: "Batterie", name: "Batterie 1")
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(filter.accept(core, 71.5, now: t0) == 71.5)
        #expect(filter.accept(core, 5.2, now: t0.addingTimeInterval(1.5)) == 71.5)
        #expect(filter.accept(core, 6.7, now: t0.addingTimeInterval(29)) == 71.5)
        #expect(filter.accept(core, 4.6, now: t0.addingTimeInterval(31)) == nil)
        #expect(filter.accept(core, 64, now: t0.addingTimeInterval(32)) == 64)
        #expect(filter.accept(core, 0, now: t0.addingTimeInterval(33)) == nil)
        #expect(filter.accept(core, nil, now: t0.addingTimeInterval(34)) == nil)
        // Une sonde jamais lue correctement ne rend rien plutôt qu'un 5 °C.
        let gpu = SensorCatalog.Entry(key: "Tg0f", group: .gpu, family: "Carte graphique", name: "Carte graphique 1")
        #expect(filter.accept(gpu, 5.9, now: t0) == nil)
        #expect(filter.accept(battery, 12, now: t0) == 12)
    }

    /// Le dénominateur de l'anneau des ventilateurs est le maximum d'Apple.
    @Test func laPartDuMaximumDUnVentilateur() {
        let fan = SensorSample.Fan(index: 0, rpm: 4342, min: 1350, max: 5349, target: 4341, forced: false)
        #expect(abs(fan.fraction - 0.81174) < 0.0001)
        #expect(SensorSample.Fan(index: 1, rpm: 100, min: 0, max: 0, target: nil, forced: false).fraction == 0)
    }

    @Test func lesFormatsFrancais() {
        #expect(SensorFormat.celsius(76.4) == "76\u{00A0}°C")
        #expect(SensorFormat.rpm(4342) == "4\u{202F}342\u{00A0}tr/min")
        #expect(SensorFormat.rpm(980) == "980\u{00A0}tr/min")
        #expect(SensorFormat.watts(19.04) == "19\u{00A0}W")
        #expect(SensorFormat.watts(4.83) == "4,8\u{00A0}W")
        #expect(SensorFormat.megahertz(3696) == "3,70\u{00A0}GHz")
        #expect(SensorFormat.megahertz(771) == "771\u{00A0}MHz")
        #expect(SensorFormat.pressure(2) == "forte")
    }

    /// Le recoupement de la batterie dans `--probe` : `Temperature` en
    /// dixièmes de kelvin, `VirtualTemperature` en centièmes de degré —
    /// relevés au même instant le 11/10 (3 047 et 3 150), ils disent tous deux
    /// 31,5 °C. Lue en centièmes, la première affichait 30 °C (signalé par 06).
    @Test func lesDeuxTemperaturesDeLaBatterie() {
        let c = SensorProbe.batteryCelsius(temperature: 3047, virtual: 3150)
        #expect(abs((c.temperature ?? 0) - 31.55) < 0.001)
        #expect(abs((c.virtual ?? 0) - 31.50) < 0.001)
        #expect(SensorProbe.batteryCelsius(temperature: 3071, virtual: nil).temperature.map { ($0 * 10).rounded() / 10 } == 34.0)
        #expect(SensorProbe.batteryCelsius(temperature: 0, virtual: 0).temperature == nil)
    }

    /// Le budget panneau fermé tient à ceci : une carte masquée sans segment
    /// ne lit plus rien ; fermé, une lecture toutes les 30 s ; ouvert, 1,5 s.
    @Test @MainActor func laCadenceSuitLaCarteEtLeSegment() {
        #expect(SensorsModule.cadence(enabled: true, panelOpen: true, bar: false) == .open)
        #expect(SensorsModule.cadence(enabled: true, panelOpen: false, bar: false) == .closed)
        #expect(SensorsModule.cadence(enabled: false, panelOpen: true, bar: true) == .closed)
        #expect(SensorsModule.cadence(enabled: false, panelOpen: true, bar: false) == .stopped)
        #expect(SensorsModule.cadence(enabled: false, panelOpen: false, bar: false) == .stopped)
    }
}

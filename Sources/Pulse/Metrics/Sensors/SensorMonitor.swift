import Foundation
import IOKit
import notify

/// Les familles de capteurs, dans l'ordre d'affichage.
enum SensorGroup: String, CaseIterable {
    case cpu = "Processeur"
    case gpu = "Carte graphique"
    case memory = "Mémoire"
    case ssd = "SSD"
    case battery = "Batterie"
    case air = "Air"
    case other = "Autres"
}

/// Un relevé de tous les capteurs. Rien n'y est estimé : un capteur absent
/// reste absent.
struct SensorSample {
    /// Une température, avec la clé ou le capteur d'où elle vient.
    struct Reading {
        var group: SensorGroup
        /// Ce que montre une ligne de la carte : « Cœurs performance »…
        var family: String
        var name: String
        var celsius: Double
        var source: String
    }

    struct Fan {
        var index: Int
        var rpm: Double
        var min: Double
        var max: Double
        var target: Double?
        /// `F0Md` à 1 : vitesse imposée par un logiciel, plus par macOS.
        var forced: Bool
        /// Part de la vitesse maximale d'Apple : un dénominateur réel, lu au
        /// SMC (`F0Mx`).
        var fraction: Double { max > 0 ? Swift.max(0, Swift.min(1, rpm / max)) : 0 }
    }

    /// Puissances moyennes sur l'intervalle entre deux lectures, en watts.
    struct Power {
        var cpu: Double?
        var gpu: Double?
        var ane: Double?
        var dram: Double?
        var seconds: Double
    }

    /// Fréquence moyenne d'une grappe pendant son temps actif, et sa
    /// fréquence maximale — la dernière ligne de sa table DVFS.
    struct Clock {
        var mhz: Double
        var max: Double
        var active: Double
        var fraction: Double { max > 0 ? Swift.min(1, mhz / max) : 0 }
    }

    var readings: [Reading] = []
    var fans: [Fan] = []
    var power: Power?
    /// Puissance de la machine entière selon le SMC (`PSTR`).
    var systemPower: Double?
    var efficiency: Clock?
    var performance: Clock?
    var gpuClock: Clock?
    /// Niveau de pression thermique de macOS : 0 nominale … 4 veille forcée.
    var thermalPressure: Int?
    /// IOReport vient de poser sa référence : puissance et fréquences
    /// arrivent à la lecture suivante (0,6 s). « mesure… », pas « illisible ».
    var reportPending = false
    var date = Date()

    /// Moyenne d'un ensemble de lectures.
    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func readings(in group: SensorGroup) -> [Reading] { readings.filter { $0.group == group } }

    /// Une ligne par famille, dans l'ordre du catalogue : (famille, moyenne,
    /// nombre de capteurs).
    func families(in group: SensorGroup) -> [(family: String, celsius: Double, count: Int)] {
        var order: [String] = []
        var values: [String: [Double]] = [:]
        for r in readings(in: group) {
            if values[r.family] == nil { order.append(r.family) }
            values[r.family, default: []].append(r.celsius)
        }
        return order.compactMap { f in Self.mean(values[f] ?? []).map { (f, $0, values[f]?.count ?? 0) } }
    }

    /// La température du processeur : moyenne de tous ses cœurs. Plus stable
    /// que le cœur le plus chaud, qui saute d'un relevé à l'autre ; celui-ci
    /// reste dans `--probe`.
    var cpuTemperature: Double? { Self.mean(readings(in: .cpu).map(\.celsius)) }
    var gpuTemperature: Double? { Self.mean(readings(in: .gpu).map(\.celsius)) }
    var hottestCPU: Reading? { readings(in: .cpu).max { $0.celsius < $1.celsius } }

    /// Le segment de barre de menus optionnel : « 62° ».
    var menuBarText: String? { cpuTemperature.map { "\(Int($0.rounded()))°" } }
}

/// Quelle clé SMC est quel capteur.
///
/// Correspondance relevée dans Stats (github.com/exelban/stats,
/// Modules/Sensors/values.swift — Copyright (c) 2019 Serhiy Mytrovtsiy,
/// licence MIT), qui la tient de la communauté : Apple ne documente aucune de
/// ces clés. Seules les clés présentes sur ce Mac sont lues ; une clé absente
/// est simplement ignorée. Les noms sont les nôtres, en français.
///
/// Les clés des cœurs et de la carte graphique changent de sens d'une
/// génération de puce à l'autre : `Tp09` est un cœur EFFICACITÉ sur M1, un
/// cœur performance sur M2 et M4 ; `Tg0f`, la carte graphique du M2,
/// n'existe pas sur M1, dont la carte graphique est en `Tg05`… Qu'une clé
/// existe ne dit donc pas ce qu'elle mesure : le catalogue se choisit au nom
/// de la puce. Avec les seules clés du M2, un M1 Pro aurait montré un cœur
/// efficacité parmi les cœurs performance et aucune carte graphique.
enum SensorCatalog {
    struct Entry {
        var key: String
        var group: SensorGroup
        var family: String
        var name: String
    }

    /// La puce de ce Mac, lue dans son nom (`machdep.cpu.brand_string`) :
    /// « Apple M1 Pro » → génération 1, déclinaison « Pro ».
    struct Chip: Equatable {
        var generation: Int
        var variant: String

        init(generation: Int, variant: String = "") {
            self.generation = generation
            self.variant = variant
        }

        /// Nil pour un nom qui n'est pas celui d'une puce Apple (Intel).
        init?(brand: String) {
            let words = brand.split(separator: " ").map(String.init)
            guard let model = words.first(where: { $0.count >= 2 && $0.hasPrefix("M") && Int($0.dropFirst()) != nil }),
                  let generation = Int(model.dropFirst()) else { return nil }
            let variant = words.last.flatMap { ["Pro", "Max", "Ultra"].contains($0) ? $0 : nil } ?? ""
            self.init(generation: generation, variant: variant)
        }

        static let current: Chip? = sysctlString("machdep.cpu.brand_string").flatMap(Chip.init(brand:))
    }

    private static func cores(performance: [String], efficiency: [String], gpu: [String],
                              memory: [String] = []) -> [Entry] {
        performance.enumerated().map {
            Entry(key: $1, group: .cpu, family: "Cœurs performance", name: "Cœur performance \($0 + 1)")
        } + efficiency.enumerated().map {
            Entry(key: $1, group: .cpu, family: "Cœurs efficacité", name: "Cœur efficacité \($0 + 1)")
        } + gpu.enumerated().map {
            Entry(key: $1, group: .gpu, family: "Carte graphique", name: "Carte graphique \($0 + 1)")
        } + memory.enumerated().map {
            Entry(key: $1, group: .memory, family: "Mémoire", name: "Mémoire \($0 + 1)")
        }
    }

    /// Puces M1, M1 Pro, M1 Max et M1 Ultra.
    static let m1 = cores(performance: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                          efficiency: ["Tp09", "Tp0T"],
                          gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
                          memory: ["Tm02", "Tm06", "Tm08", "Tm09"])

    /// Puces M2, M2 Pro et M2 Max.
    static let m2 = cores(performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
                          efficiency: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
                          gpu: ["Tg0f", "Tg0j"])

    /// Puces M3, M3 Pro et M3 Max.
    static let m3 = cores(performance: ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                                        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                          efficiency: ["Te05", "Te0L", "Te0P", "Te0S"],
                          gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])

    /// Puces M4, M4 Pro et M4 Max : les deux premières sondes de la carte
    /// graphique ne sont pas les mêmes sur la puce de base.
    static func m4(variant: String) -> [Entry] {
        cores(performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
              efficiency: ["Te05", "Te0S", "Te09", "Te0H"],
              gpu: (variant.isEmpty ? ["Tg0G", "Tg0H"] : ["Tg1U", "Tg1k"])
                  + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
              memory: ["Tm0p", "Tm1p", "Tm2p"])
    }

    /// Cœurs, carte graphique et mémoire d'une puce. Une génération que Stats
    /// ne répertorie pas ici (M5…) n'en a aucun : rien d'affiché plutôt qu'un
    /// capteur deviné.
    static func entries(for chip: Chip?) -> [Entry] {
        switch chip?.generation {
        case 1: return m1
        case 2: return m2
        case 3: return m3
        case 4: return m4(variant: chip?.variant ?? "")
        default: return []
        }
    }

    /// Toutes les puces Apple Silicon.
    static let apple: [Entry] = [
        Entry(key: "TH0x", group: .ssd, family: "SSD", name: "SSD (mémoire flash)"),
        Entry(key: "TB1T", group: .battery, family: "Batterie", name: "Batterie 1"),
        Entry(key: "TB2T", group: .battery, family: "Batterie", name: "Batterie 2"),
        Entry(key: "TaLP", group: .air, family: "Flux d'air gauche", name: "Flux d'air gauche"),
        Entry(key: "TaRF", group: .air, family: "Flux d'air droit", name: "Flux d'air droit"),
        Entry(key: "TW0P", group: .other, family: "Wi-Fi", name: "Carte Wi-Fi"),
    ]

    static let all = entries(for: Chip.current) + apple

    /// Repli sans SMC : les familles que les noms HID désignent eux-mêmes.
    static func fromHID(_ sensors: [(name: String, celsius: Double)]) -> [SensorSample.Reading] {
        sensors.compactMap { sensor in
            let name = sensor.name
            if name.hasPrefix("PMU tdie") {
                return .init(group: .cpu, family: "Puce", name: name, celsius: sensor.celsius, source: "HID")
            }
            if name.hasPrefix("NAND") {
                return .init(group: .ssd, family: "SSD", name: name, celsius: sensor.celsius, source: "HID")
            }
            if name.hasPrefix("gas gauge battery") {
                return .init(group: .battery, family: "Batterie", name: name, celsius: sensor.celsius, source: "HID")
            }
            return nil
        }
    }
}

/// Une sonde de la puce (cœurs, carte graphique, mémoire) dont la grappe est
/// éteinte ne rend pas une température mais une valeur de repos : 4,6 à
/// 6,7 °C relevés le 26/10 sur ce M2 Max — les huit cœurs performance
/// ensemble sur 267 lectures de 841, à 10 par seconde. Moyennées avec les
/// autres, elles faisaient tomber « Processeur » à 24 °C dans la carte, la
/// barre de menus et l'historique, et la courbe des ventilateurs aurait
/// suivi. Une puce allumée n'est jamais plus froide que la pièce : sous
/// 15 °C, la lecture est écartée, et la dernière bonne valeur de la sonde la
/// remplace pendant 30 s ; au-delà, la sonde se tait. Batterie, SSD et air
/// gardent leur lecture : ils peuvent être froids pour de vrai.
struct DieTemperatureFilter {
    static let floor = 15.0
    static let hold: TimeInterval = 30
    private var lastGood: [String: (celsius: Double, at: Date)] = [:]

    mutating func accept(_ entry: SensorCatalog.Entry, _ raw: Double?, now: Date) -> Double? {
        guard let raw, raw > -40, raw < 150, raw != 0 else { return nil }
        guard [.cpu, .gpu, .memory].contains(entry.group) else { return raw }
        if raw >= Self.floor {
            lastGood[entry.key] = (raw, now)
            return raw
        }
        guard let last = lastGood[entry.key], now.timeIntervalSince(last.at) <= Self.hold else { return nil }
        return last.celsius
    }
}

/// Le lecteur de tous les capteurs. Un seul propriétaire — la file des
/// capteurs, ou `--probe` —, jamais deux threads à la fois.
final class SensorMonitor {
    let smc: SMCReader?
    /// Créé à la première lecture panneau OUVERT seulement : l'abonnement
    /// coûte 145 ms de CPU (`IOReportSampler`), à ne pas payer tant que la
    /// carte n'est pas regardée. Une mesure du Pulse installé sur 60 s juste
    /// après un lancement l'aurait comptée dans le budget panneau fermé.
    private var reportStorage: IOReportSampler??
    private var report: IOReportSampler? {
        if let created = reportStorage { return created }
        let made = IOReportSampler(groups: [("Energy Model", nil),
                                            ("CPU Stats", "CPU Complex Performance States"),
                                            ("GPU Stats", "GPU Performance States")])
        reportStorage = .some(made)
        return made
    }
    private lazy var tables = DVFSTables.read()
    /// Repli quand le SMC ne répond pas.
    private lazy var hid: HIDThermometer? = smc == nil ? HIDThermometer() : nil
    private var pressureToken: Int32 = -1
    private var dieFilter = DieTemperatureFilter()
    private var lastReport: (power: SensorSample.Power?, efficiency: SensorSample.Clock?,
                             performance: SensorSample.Clock?, gpuClock: SensorSample.Clock?, date: Date)?
    /// Clés du catalogue présentes sur ce Mac, triées une fois.
    private lazy var presentEntries: [SensorCatalog.Entry] = {
        guard let smc else { return [] }
        return SensorCatalog.all.filter { smc.value($0.key) != nil }
    }()

    init() {
        smc = SMCReader()
        var token: Int32 = 0
        if notify_register_check("com.apple.system.thermalpressurelevel", &token) == UInt32(NOTIFY_STATUS_OK) {
            pressureToken = token
        }
    }

    deinit { if pressureToken >= 0 { notify_cancel(pressureToken) } }

    /// `withReport` : lire aussi IOReport — puissance et fréquences, 80 % du
    /// coût d'une lecture (3,6 ms de CPU sur 4,4, mesuré le 11/10). Seule la
    /// carte ouverte les affiche : panneau fermé, l'historique et le segment
    /// de barre n'ont besoin que du SMC (0,8 ms).
    func sample(withReport: Bool = true) -> SensorSample {
        var sample = SensorSample()
        if let smc {
            let now = Date()
            sample.readings = presentEntries.compactMap { entry in
                guard let value = dieFilter.accept(entry, smc.value(entry.key), now: now) else { return nil }
                return .init(group: entry.group, family: entry.family, name: entry.name,
                             celsius: value, source: entry.key)
            }
            sample.fans = fans(smc)
            sample.systemPower = smc.value("PSTR")
        } else if let hid {
            sample.readings = SensorCatalog.fromHID(hid.read())
        }
        if !withReport {
            if case .some(let created?) = reportStorage { created.reset() }
            lastReport = nil
        } else if let (channels, seconds) = report?.sample() {
            apply(channels, seconds: seconds, to: &sample)
            lastReport = (sample.power, sample.efficiency, sample.performance, sample.gpuClock, Date())
        } else if let last = lastReport, Date().timeIntervalSince(last.date) < 60 {
            // Lecture trop proche de la précédente (moins de 0,5 s, voir
            // `IOReportSampler.sample`) : la dernière mesure reste la bonne,
            // avec sa propre durée, plutôt qu'une section qui disparaît.
            sample.power = last.power
            sample.efficiency = last.efficiency
            sample.performance = last.performance
            sample.gpuClock = last.gpuClock
        } else if report != nil {
            sample.reportPending = true
        }
        if pressureToken >= 0 {
            var state: UInt64 = 0
            if notify_get_state(pressureToken, &state) == UInt32(NOTIFY_STATUS_OK) { sample.thermalPressure = Int(state) }
        }
        return sample
    }

    private func fans(_ smc: SMCReader) -> [SensorSample.Fan] {
        guard let count = smc.value("FNum"), count > 0, count < 8 else { return [] }
        return (0..<Int(count)).compactMap { i in
            // Bornés : une valeur aberrante du SMC (3e38) planterait
            // l'affichage, qui l'arrondit en entier.
            guard let rpm = smc.value("F\(i)Ac"), rpm < 30_000,
                  let max = smc.value("F\(i)Mx"), max > 0, max <= 30_000 else { return nil }
            return .init(index: i, rpm: Swift.max(0, rpm), min: smc.value("F\(i)Mn") ?? 0, max: max,
                         target: smc.value("F\(i)Tg"), forced: (smc.value("F\(i)Md") ?? 0) == 1)
        }
    }

    /// Puissances et fréquences tirées des canaux IOReport. Les noms de
    /// canaux sont ceux de macmon, vérifiés sur la machine : « CPU Energy »
    /// (mJ), « GPU Energy » (nJ), « ANE… », « DRAM… » ; grappes « ECPU »,
    /// « PCPU », « PCPU1 » ; carte graphique « GPUPH ».
    private func apply(_ channels: [IOReportChannel], seconds: Double, to sample: inout SensorSample) {
        var power = SensorSample.Power(seconds: seconds)
        func add(_ value: Double?, to field: inout Double?) {
            guard let value else { return }
            field = (field ?? 0) + value
        }
        var efficiency: [(mhz: Double, active: Double)] = []
        var performance: [(mhz: Double, active: Double)] = []
        for channel in channels {
            switch channel.group {
            case "Energy Model":
                let watts = IOReportMath.watts(energy: channel.value, unit: channel.unit, seconds: seconds)
                if channel.name.hasSuffix("CPU Energy") { add(watts, to: &power.cpu) }
                else if channel.name == "GPU Energy" { add(watts, to: &power.gpu) }
                else if channel.name.hasPrefix("ANE") { add(watts, to: &power.ane) }
                else if channel.name.hasPrefix("DRAM") { add(watts, to: &power.dram) }
            case "CPU Stats":
                if channel.name.hasPrefix("ECPU"),
                   let f = IOReportMath.frequency(states: channel.states, table: tables.efficiency) {
                    efficiency.append(f)
                } else if channel.name.hasPrefix("PCPU"),
                          let f = IOReportMath.frequency(states: channel.states, table: tables.performance) {
                    performance.append(f)
                }
            case "GPU Stats" where channel.name == "GPUPH":
                if let f = IOReportMath.frequency(states: channel.states, table: tables.gpu), let top = tables.gpu.last {
                    sample.gpuClock = .init(mhz: f.mhz, max: top, active: f.active)
                }
            default:
                break
            }
        }
        sample.power = power
        if let f = IOReportMath.combine(efficiency), let top = tables.efficiency.last {
            sample.efficiency = .init(mhz: f.mhz, max: top, active: f.active)
        }
        if let f = IOReportMath.combine(performance), let top = tables.performance.last {
            sample.performance = .init(mhz: f.mhz, max: top, active: f.active)
        }
    }
}

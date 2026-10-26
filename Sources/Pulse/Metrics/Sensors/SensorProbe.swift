import Foundation
import IOKit

/// Section CAPTEURS de `--probe` : chaque chiffre de la carte, sa source, et
/// une source indépendante quand il en existe une.
enum SensorProbe {
    static func lines() -> [String] {
        var out: [String] = []
        func emit(_ text: String) { out.append(text) }

        // Deux lectures à 1 s d'écart : IOReport mesure un écart. Le coût est
        // celui de la SECONDE, une lecture ordinaire de l'app, en temps CPU
        // du thread (noyau compris) et non en temps d'horloge.
        // Création : le lecteur, puis l'abonnement IOReport, fait à la
        // première lecture panneau ouvert.
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let monitor = SensorMonitor()
        _ = monitor.sample()
        let setup = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        Thread.sleep(forTimeInterval: 1)
        var costs: [Double] = []
        var sample = SensorSample()
        for i in 0..<5 {
            if i > 0 { Thread.sleep(forTimeInterval: IOReportSampler.minimumInterval + 0.1) }
            let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let s = monitor.sample()
            costs.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e6)
            if i == 0 { sample = s }
        }
        let cost = costs.sorted()[costs.count / 2]
        // Panneau fermé : SMC seul, IOReport n'est pas lu (`SensorStore`).
        // Mesuré sur un lecteur à part, pour ne pas casser la référence
        // IOReport de celui-ci.
        let closedMonitor = SensorMonitor()
        _ = closedMonitor.sample(withReport: false)
        let closedCosts: [Double] = (0..<5).map { _ in
            let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = closedMonitor.sample(withReport: false)
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e6
        }
        let closedCost = closedCosts.sorted()[closedCosts.count / 2]

        let pressure = sample.thermalPressure.map { "\(SensorFormat.pressure($0)) (niveau \($0) sur 4)" } ?? "illisible"
        emit("pression thermique \(pressure) · ProcessInfo : \(SensorFormat.thermalState(ProcessInfo.processInfo.thermalState))")
        emit("SMC \(monitor.smc == nil ? "inaccessible" : "lu sans privilège, commandes de lecture seulement")")

        // Températures, groupe par groupe.
        let hid = HIDThermometer()?.read() ?? []
        let brand = sysctlString("machdep.cpu.brand_string") ?? "nom illisible"
        let chip = SensorCatalog.Chip.current
        emit("TEMPÉRATURES (SMC, clés relevées dans Stats pour \(chip.map { "les puces M\($0.generation)" } ?? "aucune puce") — \(brand))")
        if SensorCatalog.entries(for: chip).isEmpty {
            emit("  puce non répertoriée : cœurs et carte graphique non lus plutôt que devinés")
        }
        if sample.readings.isEmpty { emit("  aucune — ni SMC ni HID") }
        for group in SensorGroup.allCases {
            let readings = sample.readings(in: group)
            guard !readings.isEmpty else { continue }
            let families = sample.families(in: group)
                .map { "\($0.family) \(SensorFormat.celsius($0.celsius))\($0.count > 1 ? " (\($0.count))" : "")" }
            emit("  \(group.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0))\(families.joined(separator: " · "))")
            if group == .cpu || group == .gpu {
                let keys = readings.map { "\($0.source) \(SensorFormat.number($0.celsius, digits: 1))" }
                emit("    \(keys.joined(separator: " "))")
            }
        }
        if let hottest = sample.hottestCPU {
            emit("  cœur le plus chaud : \(hottest.name), \(SensorFormat.celsius(hottest.celsius)) (\(hottest.source))")
        }
        if sample.readings(in: .memory).isEmpty {
            emit("  mémoire : aucune clé identifiée sur cette puce — rien d'affiché plutôt qu'un capteur deviné")
        }

        // Recoupements.
        emit("RECOUPEMENTS")
        if let smc = monitor.smc {
            let t0 = Date()
            let keys = smc.allKeys()
            let scan = Date().timeIntervalSince(t0)
            func average(prefix: String) -> (Double, Int)? {
                let values = keys.filter { $0.hasPrefix(prefix) }.compactMap { smc.raw($0) }
                    .filter { $0.type == "flt " }.compactMap { SMCCode.decode(type: $0.type, bytes: $0.bytes) }
                    .filter { $0 > 0 && $0 < 150 }
                return SensorSample.mean(values).map { ($0, values.count) }
            }
            if let (all, n) = average(prefix: "Tp"), let mine = sample.cpuTemperature {
                emit("  processeur      \(SensorFormat.celsius(mine)) (\(sample.readings(in: .cpu).count) cœurs) · \(SensorFormat.celsius(all)) moyenne des \(n) clés Tp (méthode macmon) — écart \(SensorFormat.number(abs(mine - all), digits: 1)) °C")
            }
            if let (all, n) = average(prefix: "Tg"), let mine = sample.gpuTemperature {
                emit("  carte graphique \(SensorFormat.celsius(mine)) (\(sample.readings(in: .gpu).map(\.source).joined(separator: ", "))) · \(SensorFormat.celsius(all)) moyenne des \(n) clés Tg — écart \(SensorFormat.number(abs(mine - all), digits: 1)) °C")
            }
            let pmuHID = hid.filter { $0.name.hasPrefix("PMU tdie") }.map(\.celsius)
            if let viaHID = SensorSample.mean(pmuHID), let (viaSMC, n) = average(prefix: "TPD") {
                emit("  puce (PMU)      \(SensorFormat.celsius(viaHID)) HID « PMU tdie » (\(pmuHID.count)) · \(SensorFormat.celsius(viaSMC)) SMC TPD (\(n)) — écart \(SensorFormat.number(abs(viaHID - viaSMC), digits: 1)) °C")
            }
            emit("  (\(keys.count) clés SMC énumérées en \(SensorFormat.number(scan * 1000, digits: 0)) ms — une fois, pour ce relevé seulement)")
        }
        if let ssd = sample.families(in: .ssd).first {
            let nand = SensorSample.mean(hid.filter { $0.name.hasPrefix("NAND") }.map(\.celsius))
            emit("  SSD             \(SensorFormat.celsius(ssd.celsius)) SMC TH0x · \(nand.map { SensorFormat.celsius($0) } ?? "—") HID « NAND CH0 temp »")
        }
        if let battery = sample.families(in: .battery).first {
            let gauge = SensorSample.mean(hid.filter { $0.name.hasPrefix("gas gauge") }.map(\.celsius))
            let smart = smartBattery()
            var parts = ["\(SensorFormat.celsius(battery.celsius)) SMC TB1T/TB2T",
                         "\(gauge.map { SensorFormat.celsius($0) } ?? "—") HID « gas gauge battery »"]
            if let v = smart.virtual { parts.append("\(SensorFormat.celsius(v)) AppleSmartBattery VirtualTemperature") }
            if let t = smart.temperature { parts.append("\(SensorFormat.celsius(t)) Temperature (dixièmes de kelvin)") }
            emit("  batterie        " + parts.joined(separator: " · "))
        }

        // Ventilateurs.
        emit("VENTILATEURS (SMC, \(sample.fans.count))")
        if sample.fans.isEmpty { emit("  aucun lu") }
        for fan in sample.fans {
            let target = fan.target.map { ", consigne \(SensorFormat.rpm($0))" } ?? ""
            emit("  ventilateur \(fan.index + 1)  \(SensorFormat.rpm(fan.rpm)) — \(SensorFormat.percentOfMax(fan.fraction)) du maximum (min \(SensorFormat.rpm(fan.min)), max \(SensorFormat.rpm(fan.max))\(target)) · \(fan.forced ? "vitesse imposée" : "pilotés par macOS")")
        }
        emit("  pas de seconde source sans root : l'IORegistry ne publie pas la vitesse des ventilateurs sur Apple Silicon")

        // Puissance.
        if let p = sample.power {
            emit("PUISSANCE (IOReport, moyenne sur \(SensorFormat.number(p.seconds, digits: 2)) s)")
            emit("  processeur \(SensorFormat.watts(p.cpu)) · carte graphique \(SensorFormat.watts(p.gpu)) · moteur neuronal \(SensorFormat.watts(p.ane)) · mémoire vive \(SensorFormat.watts(p.dram))")
            let parts = [p.cpu, p.gpu, p.ane, p.dram].compactMap { $0 }.reduce(0, +)
            let adapter = smartBattery().systemPowerIn
            var line = "  machine entière \(SensorFormat.watts(sample.systemPower)) (SMC PSTR, instantané)"
            if let adapter { line += " · \(SensorFormat.watts(adapter)) entrée secteur (AppleSmartBattery SystemPowerIn)" }
            emit(line)
            emit("  les quatre blocs font \(SensorFormat.watts(parts))\(sample.systemPower.map { ", soit \(SensorFormat.percentOfMax(parts / max($0, 0.001))) de la machine entière" } ?? "")")
            emit("  carte graphique : canal « GPU Energy », celui de macmon ; le canal « GPU0 » lit davantage, sens non documenté, non retenu")
        } else {
            emit("PUISSANCE : IOReport inaccessible")
        }

        // Fréquences.
        emit("FRÉQUENCES (IOReport × table DVFS du pmgr, pendant le temps actif)")
        for (name, clock) in [("cœurs efficacité", sample.efficiency), ("cœurs performance", sample.performance),
                              ("carte graphique", sample.gpuClock)] {
            if let clock {
                emit("  \(name.padding(toLength: 18, withPad: " ", startingAt: 0))\(SensorFormat.megahertz(clock.mhz)) sur \(SensorFormat.megahertz(clock.max)) max · actif \(SensorFormat.percentOfMax(clock.active)) du temps")
            } else {
                emit("  \(name) : illisible (table DVFS et états IOReport ne concordent pas)")
            }
        }
        emit("  moteur neuronal : aucune table d'états dans IOReport (56 canaux ANE relevés, aucun de fréquence) — sa puissance seulement")
        emit("  pas de source indépendante sans root : powermetrics exige sudo")

        emit("COÛT  panneau ouvert, lecture complète (SMC + IOReport) : \(SensorFormat.number(cost, digits: 2)) ms de CPU (médiane de 5), toutes les 1,5 s : \(SensorFormat.number(cost / 1_500 * 100, digits: 3)) % d'un cœur")
        emit("      panneau fermé, SMC seul (historique, segment) : \(SensorFormat.number(closedCost, digits: 2)) ms, toutes les 30 s : \(SensorFormat.number(closedCost / 30_000 * 100, digits: 4)) % d'un cœur")
        emit("      carte masquée et segment éteint : aucune lecture · HID jamais lu par l'app (recoupement de --probe seulement) · abonnement IOReport \(SensorFormat.number(setup, digits: 1)) ms, une fois, à la première ouverture")
        emit("barre de menus (optionnelle, éteinte) : CPU \(sample.menuBarText ?? "—")")
        return out
    }

    /// La batterie vue par son contrôleur, source indépendante du SMC :
    /// puissance d'entrée en mW, et deux températures en DEUX unités —
    /// `Temperature` en dixièmes de kelvin, `VirtualTemperature` en centièmes
    /// de degré. Relevé par le chantier 06 (README) : lue en centièmes,
    /// `Temperature` donnait 30 °C quand toutes les sondes en lisaient 31 à 34.
    static func batteryCelsius(temperature: Double?, virtual: Double?) -> (temperature: Double?, virtual: Double?) {
        (temperature.flatMap { PowerReader.celsius(deciKelvin: $0) },
         virtual.map { $0 / 100 }.flatMap { (-30...90).contains($0) ? $0 : nil })
    }

    static func smartBattery() -> (temperature: Double?, virtual: Double?, systemPowerIn: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.doubleValue
        }
        let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        let powerIn = (telemetry?["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 }
        let celsius = batteryCelsius(temperature: number("Temperature"), virtual: number("VirtualTemperature"))
        return (celsius.temperature, celsius.virtual, powerIn.flatMap { $0 > 0 ? $0 : nil })
    }
}

/// Les formats des capteurs, en français : virgule décimale, espace
/// insécable avant l'unité.
enum SensorFormat {
    static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func celsius(_ value: Double) -> String { "\(Int(value.rounded()))\u{00A0}°C" }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(number(value, digits: value < 10 ? 1 : 0))\u{00A0}W"
    }

    static func megahertz(_ value: Double) -> String {
        value >= 1000 ? "\(number(value / 1000, digits: 2))\u{00A0}GHz" : "\(Int(value.rounded()))\u{00A0}MHz"
    }

    /// « 2 824 tr/min », espace fine insécable entre les milliers.
    static func rpm(_ value: Double) -> String { "\(thousands(Int(value.rounded())))\u{00A0}tr/min" }

    static func thousands(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append("\u{202F}") }
            out.append(c)
        }
        return out
    }

    static func percentOfMax(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))\u{00A0}%" }

    /// Les niveaux de `OSThermalPressureLevel` sur macOS
    /// (libkern/OSThermalNotification.h) : Nominal, Moderate, Heavy,
    /// Trapping, Sleeping.
    static func pressure(_ level: Int) -> String {
        switch level {
        case 0: return "nominale"
        case 1: return "modérée"
        case 2: return "forte"
        case 3: return "critique"
        case 4: return "maximale"
        default: return "inconnue"
        }
    }

    static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "passable (fair)"
        case .serious:  return "sérieux (serious)"
        case .critical: return "critique (critical)"
        @unknown default: return "inconnu"
        }
    }
}

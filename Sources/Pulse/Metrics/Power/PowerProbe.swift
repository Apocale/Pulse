import Foundation

/// La section ÉNERGIE de `--probe` : chaque chiffre de la carte, avec sa
/// source et, quand il en existe une, la seconde lecture qui le recoupe.
enum PowerProbe {
    static func lines() -> [String] {
        let raw = PowerMonitor.raw()
        var s = PowerReader.sample(raw)
        s.liveSystemWatts = PowerMonitor.liveSystemWatts(SMCReader())
        var out: [String] = []
        func emit(_ label: String, _ value: String) {
            out.append("  \(label.padding(toLength: 17, withPad: " ", startingAt: 0))\(value)")
        }

        guard s.hasBattery else {
            emit("batterie", "aucune")
            if let a = s.adapter { emit("alimentation", adapterText(a, input: s.adapterInputWatts)) }
            out += accessoryLines()
            return out
        }

        emit("batterie", "\(s.level.map(Fmt.percent) ?? "—") · \(s.state.label)")
        let percentRaw = raw.source.flatMap { PowerReader.number($0["Current Capacity"]) }
        if let charge = s.currentCharge, let full = s.fullChargeCapacity, full > 0 {
            emit("", "recoupé : \(PowerFmt.mAh(charge)) sur \(PowerFmt.mAh(full)) = \(Fmt.percent(Double(charge) / Double(full)))"
                 + (percentRaw.map { " · IOPowerSources \(Int($0)) %" } ?? ""))
        }

        let report = PowerMonitor.healthReport()
        if let macOS = report?.maximumCapacity {
            emit("santé", "\(macOS) % selon macOS (system_profiler, condition « \(report?.condition ?? "?") »)")
        } else {
            emit("santé", "macOS injoignable (system_profiler) — repli sur le calcul ci-dessous")
        }
        if let computed = s.computedHealth, let nominal = s.nominalCapacity, let design = s.designCapacity {
            emit("", "calculée : \(PowerFmt.mAh(nominal)) nominaux sur \(PowerFmt.mAh(design)) d'origine = \(Fmt.percent(computed))"
                 + " — powerd lisse la sienne dans le temps")
        }
        if let full = s.fullChargeCapacity, let design = s.designCapacity, design > 0 {
            emit("pleine charge", "\(PowerFmt.mAh(full)) sur \(PowerFmt.mAh(design)) (\(Fmt.percent(Double(full) / Double(design)))), dans les conditions du moment")
        }
        if let cycles = s.cycles {
            emit("cycles", "\(PowerFmt.count(cycles))" + (s.designCycles.map { " sur \(PowerFmt.count($0)) prévus" } ?? "")
                 + (report?.cycles.map { $0 == cycles ? " · system_profiler d'accord" : " · system_profiler dit \($0)" } ?? ""))
        }
        if let t = s.temperature {
            let rawT = PowerReader.int(raw.registry["Temperature"]).map { "Temperature \(PowerFmt.count($0)) en dixièmes de kelvin" } ?? ""
            let check = s.virtualTemperature.map { " · recoupée : VirtualTemperature \(PowerFmt.celsius($0))" } ?? ""
            emit("température", "\(PowerFmt.celsius(t)) (\(rawT))\(check)")
        } else {
            emit("température", "non publiée")
        }
        if let v = s.voltage {
            emit("tension", "\(PowerFmt.volts(v))"
                 + (s.amperage.map { " · courant \(PowerFmt.amps($0)) (moyenne de la jauge)" } ?? "")
                 + (s.instantAmperage.map { ", \(PowerFmt.amps($0)) à l'instant" } ?? ""))
        }
        if let live = s.liveSystemWatts {
            emit("consommation", "\(PowerFmt.watts(live)), SMC PSTR à l'instant — le chiffre de la carte, et celui de la carte Capteurs")
        }
        if let w = s.systemWatts {
            let source = s.state.onExternalPower
                ? "télémétrie de la jauge (PowerTelemetryData.SystemLoad), rafraîchie toutes les 40 à 60 s"
                : "tension × courant de la batterie"
            emit(s.liveSystemWatts == nil ? "consommation" : "", "\(PowerFmt.watts(w)), \(source)")
        } else if s.liveSystemWatts == nil {
            emit("consommation", "ni SMC ni jauge")
        }
        if let sum = s.loadSum, let count = s.loadCount, count > 0 {
            emit("", "compteur de la jauge : \(PowerFmt.watts(sum / count / 1000)) en moyenne sur \(PowerFmt.count(Int(count))) relevés — la journée de la carte en prend les écarts")
        }
        if let b = s.batteryWatts, abs(b) >= 0.05 {
            emit("batterie", b > 0 ? "reçoit \(PowerFmt.watts(b))" : "fournit \(PowerFmt.watts(-b))")
        }
        if let a = s.adapter { emit("chargeur", adapterText(a, input: s.adapterInputWatts)) }

        switch s.state {
        case .discharging:
            emit("temps restant", s.minutesToEmpty.map { "\(Fmt.duration(Double($0) * 60)) avant vide, selon macOS" } ?? "en calcul")
        case .charging:
            emit("temps restant", s.minutesToFull.map { "\(Fmt.duration(Double($0) * 60)) avant la pleine charge, selon macOS" } ?? "en calcul")
        default:
            emit("temps restant", "sans objet sur secteur")
        }

        let modes = [s.energyModeAC.map { "secteur : \($0.label)" }, s.energyModeBattery.map { "batterie : \($0.label)" }]
            .compactMap { $0 }.joined(separator: " · ")
        let lpm = raw.preferences.flatMap { prefs -> String? in
            let ac = (prefs["AC Power"] as? [String: Any]).flatMap { PowerReader.int($0["LowPowerMode"]) }
            return ac.map { "pmset powermode \($0) sur secteur" }
        }
        emit("mode d'énergie", (modes.isEmpty ? "illisible" : modes)
             + " · économie d'énergie \(s.lowPowerMode ? "ACTIVE" : "inactive") (ProcessInfo)"
             + (lpm.map { " · \($0)" } ?? ""))

        out += accessoryLines()
        return out
    }

    private static func adapterText(_ a: PowerAdapter, input: Double?) -> String {
        var parts: [String] = []
        if let w = a.watts { parts.append("\(w) W") }
        if let name = a.name { parts.append(name + (a.manufacturer.map { " (\($0))" } ?? "")) }
        if let v = a.voltage, let i = a.current { parts.append("négocié \(PowerFmt.number(v, digits: 1)) V · \(PowerFmt.amps(i))") }
        if let input { parts.append("fournit \(PowerFmt.watts(input)) en ce moment") }
        return parts.joined(separator: " · ")
    }

    private static func accessoryLines() -> [String] {
        guard PowerMonitor.accessoriesAvailable else {
            return ["  appareils        source indisponible (IOPSCopyPowerSourcesByType absente de cet IOKit)"]
        }
        let list = PowerMonitor.accessories()
        var out = ["  appareils        \(list.isEmpty ? "aucun appareil à batterie connu" : "\(list.count)") — powerd et IORegistry, sans autorisation Bluetooth"]
        for a in list {
            out.append("    \(a.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(PowerFmt.parts(a))  [\(a.source)]")
        }
        return out
    }
}

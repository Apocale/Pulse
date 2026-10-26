import Foundation

/// La lecture de la batterie, de l'alimentation et des accessoires, en
/// fonctions pures sur les dictionnaires que publient l'IORegistry et
/// `IOPowerSources`. Les appels système sont dans `PowerMonitor` ; tout ce qui
/// interprète une valeur est ici, testé sur les dictionnaires réels de ce Mac
/// (`PowerTests`).
///
/// Unités relevées le 11/10 sur ce MacBook Pro M2 Max, chacune recoupée :
/// - `CurrentCapacity` et `MaxCapacity` sont des POURCENTAGES sur Apple
///   Silicon (74 et 100) ; les mAh sont dans `AppleRawCurrentCapacity` et
///   `AppleRawMaxCapacity` (5 095 sur 6 906 : 73,8 %, le même 74 %).
/// - `Temperature` est en DIXIÈMES DE KELVIN, pas en centièmes de degré comme
///   on le lit partout : 3 073 donne 34,2 °C, quand les trois sondes SMC de la
///   batterie (TB0T, TB1T, TB2T) lisaient 33,8 · 32,6 · 33,8 °C et les six
///   capteurs HID « gas gauge battery » 33,0 à 34,2 °C. Lu en centièmes, il
///   donnerait 30,7 °C, sous toutes les sondes. `VirtualTemperature`, lui, est
///   en centièmes de degré : 3 409, soit 34,1 °C — il suit `Temperature` à
///   0,1 °C près sur trois relevés, un recoupement disponible à chaque lecture.
/// - `Voltage` en mV, `Amperage` en mA signé (en-tête du noyau,
///   IOPMPowerSource.h).
/// - `PowerTelemetryData.SystemLoad` en mW : 76,9 W quand la clé SMC `PSTR`
///   (puissance totale du système) lisait 77,5 W au même instant. La jauge ne
///   la rafraîchit qu'à son rythme : identique sur cinq relevés à 1 s.
enum PowerReader {
    /// Ce qu'on a lu, tel quel.
    struct Raw {
        /// Les propriétés de l'`AppleSmartBattery`.
        var registry: [String: Any] = [:]
        /// La description `IOPowerSources` de la batterie interne.
        var source: [String: Any]?
        /// `IOPSCopyExternalPowerAdapterDetails`.
        var adapter: [String: Any]?
        /// `IOPMCopyActivePMPreferences` : un profil par source.
        var preferences: [String: Any]?
        var lowPowerMode = false
    }

    static func sample(_ raw: Raw) -> PowerSample {
        var s = PowerSample()
        let r = raw.registry
        let ps = raw.source ?? [:]
        s.hasBattery = bool(r["BatteryInstalled"]) ?? bool(ps["Is Present"]) ?? false
        s.lowPowerMode = raw.lowPowerMode
        if let prefs = raw.preferences {
            s.energyModeAC = energyMode(prefs["AC Power"])
            s.energyModeBattery = energyMode(prefs["Battery Power"])
        }
        guard s.hasBattery else {
            if let adapter = raw.adapter { s.adapter = adapterDetails(adapter) }
            return s
        }

        // Le pourcentage du menu Batterie : IOPowerSources d'abord.
        if let cur = number(ps["Current Capacity"]), let max = number(ps["Max Capacity"]), max > 0 {
            s.level = min(1, cur / max)
        } else if let cur = number(r["CurrentCapacity"]), let max = number(r["MaxCapacity"]), max > 0 {
            s.level = min(1, cur / max)
        }

        let external = bool(r["ExternalConnected"]) ?? (ps["Power Source State"] as? String == "AC Power")
        let charging = bool(ps["Is Charging"]) ?? bool(r["IsCharging"]) ?? false
        let full = bool(r["FullyCharged"]) ?? bool(ps["Is Charged"]) ?? false
        s.state = state(external: external, charging: charging, full: full)

        s.cycles = int(r["CycleCount"])
        s.designCycles = int(r["DesignCycleCount9C"]) ?? int(ps["DesignCycleCount"])
        s.designCapacity = int(r["DesignCapacity"])
        s.nominalCapacity = int(r["NominalChargeCapacity"])
        // Sur Apple Silicon, `MaxCapacity` vaut 100 (des pour cent) : la
        // pleine charge en mAh est dans la clé « Raw ».
        s.fullChargeCapacity = int(r["AppleRawMaxCapacity"])
        s.currentCharge = int(r["AppleRawCurrentCapacity"])
        s.condition = ps["BatteryHealth"] as? String

        s.temperature = number(r["Temperature"]).flatMap(celsius(deciKelvin:))
        s.virtualTemperature = number(r["VirtualTemperature"]).map { $0 / 100 }

        s.voltage = number(r["Voltage"]).map { $0 / 1000 }
        s.amperage = signed(r["Amperage"]).map { Double($0) / 1000 }
        s.instantAmperage = signed(r["InstantAmperage"]).map { Double($0) / 1000 }

        let telemetry = r["PowerTelemetryData"] as? [String: Any] ?? [:]
        let load = number(telemetry["SystemLoad"]).map { $0 / 1000 }
        var input = number(telemetry["SystemPowerIn"]).map { $0 / 1000 }
        if input == nil || input == 0,
           let v = number(telemetry["SystemVoltageIn"]), let i = number(telemetry["SystemCurrentIn"]), v > 0, i > 0 {
            input = v * i / 1e6
        }
        s.loadSum = number(telemetry["AccumulatedSystemLoad"])
        s.loadCount = number(telemetry["SystemLoadAccumulatorCount"])
        if external {
            s.adapterInputWatts = input.flatMap { $0 > 0 ? $0 : nil }
            s.systemWatts = (load.flatMap { $0 > 0 ? $0 : nil }) ?? s.adapterInputWatts
        } else if let watts = s.batteryWatts, watts < 0 {
            // Sur batterie, la décharge mesurée par la jauge : documentée par
            // l'en-tête du noyau, là où la télémétrie n'a été vue que sur
            // secteur.
            s.systemWatts = -watts
        } else {
            s.systemWatts = load.flatMap { $0 > 0 ? $0 : nil }
        }

        switch s.state {
        case .discharging:
            s.minutesToEmpty = minutes(ps["Time to Empty"]) ?? minutes(r["AvgTimeToEmpty"])
        case .charging:
            s.minutesToFull = minutes(ps["Time to Full Charge"]) ?? minutes(r["AvgTimeToFull"])
        default:
            break
        }

        if external, let adapter = raw.adapter ?? r["AdapterDetails"] as? [String: Any] {
            s.adapter = adapterDetails(adapter)
        }
        return s
    }

    static func state(external: Bool, charging: Bool, full: Bool) -> PowerState {
        if !external { return .discharging }
        if charging { return .charging }
        return full ? .charged : .notCharging
    }

    /// Dixièmes de kelvin vers degrés Celsius, hors des bornes d'une batterie
    /// en état de marche : nil plutôt qu'un chiffre absurde.
    static func celsius(deciKelvin raw: Double) -> Double? {
        let c = raw / 10 - 273.15
        return (-30...90).contains(c) ? c : nil
    }

    /// Le réglage « Mode d'énergie » d'un profil. Sous macOS 26 il vit dans
    /// la clé historique `LowPowerMode` : 0 automatique, 1 économie, 2 haute
    /// performance. `HighPowerMode`, l'ancienne clé, reste à 0.
    static func energyMode(_ profile: Any?) -> EnergyMode? {
        guard let profile = profile as? [String: Any] else { return nil }
        if let value = int(profile["LowPowerMode"]), let mode = EnergyMode(rawValue: value), mode != .automatic {
            return mode
        }
        if int(profile["HighPowerMode"]) == 1 { return .highPower }
        return profile["LowPowerMode"] == nil && profile["HighPowerMode"] == nil ? nil : .automatic
    }

    static func adapterDetails(_ d: [String: Any]) -> PowerAdapter {
        PowerAdapter(name: d["Name"] as? String,
                     watts: int(d["Watts"]),
                     voltage: number(d["AdapterVoltage"]).map { $0 / 1000 },
                     current: number(d["Current"]).map { $0 / 1000 },
                     manufacturer: d["Manufacturer"] as? String)
    }

    /// Une durée en minutes publiée par la jauge ou par IOPowerSources :
    /// 65 535 et -1 veulent dire « inconnue », 0 « sans objet ».
    static func minutes(_ any: Any?) -> Int? {
        guard let m = int(any), m > 0, m < 65_535 else { return nil }
        return m
    }

    // MARK: - Accessoires

    /// Les accessoires de `IOPSCopyPowerSourcesByType` (ceux du widget
    /// Batteries de macOS) puis les appareils HID qui publient
    /// `BatteryPercent` dans l'IORegistry (souris, clavier, trackpad Apple),
    /// sans doublon de nom.
    ///
    /// Les AirPods arrivent en deux sources : les écouteurs (« Combined », avec
    /// gauche et droite) et le boîtier (« Case »), reliés par le même
    /// « Group Identifier ».
    static func accessories(sources: [[String: Any]], hid: [[String: Any]] = []) -> [PowerAccessory] {
        var order: [String] = []
        var byGroup: [String: PowerAccessory] = [:]

        for d in sources where (d["Type"] as? String) == "Accessory Source" {
            guard let rawName = d["Name"] as? String else { continue }
            let group = (d["Group Identifier"] as? String) ?? (d["Accessory Identifier"] as? String) ?? rawName
            let partId = (d["Part Identifier"] as? String) ?? ""

            var parts: [PowerAccessory.Part] = []
            if partId == "Combined", let combined = d["Combined Parts"] as? [[String: Any]], !combined.isEmpty {
                parts = combined.compactMap(part)
            } else if let p = part(d) {
                parts = [p]
            }
            guard !parts.isEmpty else { continue }

            // Le boîtier porte « Case » à la fin de son nom ; l'appareil, non.
            let isCase = parts.allSatisfy { $0.role == .case }
            let name = isCase ? strip(caseSuffix: rawName) : rawName

            if var existing = byGroup[group] {
                existing.parts += parts
                if !isCase { existing.name = name; existing.kind = kind(name: name, category: d["Accessory Category"] as? String) }
                byGroup[group] = existing
            } else {
                order.append(group)
                byGroup[group] = PowerAccessory(id: group, name: name,
                                                kind: kind(name: name, category: d["Accessory Category"] as? String),
                                                parts: parts, source: "IOPowerSources")
            }
        }

        var result = order.compactMap { byGroup[$0] }.map { accessory -> PowerAccessory in
            var a = accessory
            a.parts.sort { rank($0.role) < rank($1.role) }
            return a
        }

        let known = Set(result.map { $0.name.lowercased() })
        for d in hid {
            guard let name = d["Product"] as? String, let percent = number(d["BatteryPercent"]),
                  !known.contains(name.lowercased()) else { continue }
            let id = (d["DeviceAddress"] as? String) ?? (d["SerialNumber"] as? String) ?? name
            result.append(PowerAccessory(id: id, name: name, kind: kind(name: name, category: nil),
                                         parts: [.init(role: .single, level: min(1, percent / 100), charging: false)],
                                         source: "IORegistry"))
        }
        return result
    }

    private static func part(_ d: [String: Any]) -> PowerAccessory.Part? {
        guard let cur = number(d["Current Capacity"]) else { return nil }
        let max = number(d["Max Capacity"]) ?? 100
        guard max > 0 else { return nil }
        let role: PowerAccessory.Role
        switch (d["Part Identifier"] as? String) ?? "" {
        case "Left":  role = .left
        case "Right": role = .right
        case "Case":  role = .case
        default:      role = .single
        }
        return .init(role: role, level: min(1, cur / max), charging: bool(d["Is Charging"]) ?? false)
    }

    private static func rank(_ role: PowerAccessory.Role) -> Int {
        switch role {
        case .single: return 0
        case .left:   return 1
        case .right:  return 2
        case .case:   return 3
        }
    }

    private static func strip(caseSuffix name: String) -> String {
        for suffix in [" Case", " case", " Boîtier", " boîtier"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static func kind(name: String, category: String?) -> PowerAccessory.Kind {
        let n = name.lowercased()
        if n.contains("airpods max") { return .airpodsMax }
        if n.contains("airpods pro") { return .airpodsPro }
        if n.contains("airpods") { return .airpods }
        if n.contains("mouse") || n.contains("souris") { return .mouse }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("keyboard") || n.contains("clavier") { return .keyboard }
        switch category ?? "" {
        case "Headset", "Headphones", "Audio Battery Case": return .headphones
        case "Mouse": return .mouse
        case "Keyboard": return .keyboard
        case "Trackpad": return .trackpad
        default: return .other
        }
    }

    // MARK: - Santé selon macOS

    /// La sortie JSON de `system_profiler SPPowerDataType`.
    static func healthReport(json: Data, now: Date = Date()) -> BatteryHealthReport? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let battery = items.first(where: { $0["_name"] as? String == "spbattery_information" }),
              let health = battery["sppower_battery_health_info"] as? [String: Any] else { return nil }
        let capacity: Int?
        switch health["sppower_battery_health_maximum_capacity"] {
        case let text as String: capacity = Int(text.filter(\.isNumber))
        case let value as NSNumber: capacity = value.intValue
        default: capacity = nil
        }
        return BatteryHealthReport(maximumCapacity: capacity.flatMap { (1...100).contains($0) ? $0 : nil },
                                   condition: health["sppower_battery_health"] as? String,
                                   cycles: int(health["sppower_battery_cycle_count"]),
                                   readAt: now)
    }

    // MARK: - Nombres

    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let i as Int: return Double(i)
        case let d as Double: return d
        default: return nil
        }
    }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let i as Int: return i
        default: return nil
        }
    }

    /// Un courant négatif traverse l'IORegistry en entier 64 bits signé ;
    /// `ioreg` l'affiche en non signé (18 446 744 073 709 551 xxx). Les deux
    /// lectures donnent ici la même valeur négative.
    static func signed(_ any: Any?) -> Int64? {
        switch any {
        case let n as NSNumber: return n.int64Value
        case let i as Int: return Int64(i)
        case let u as UInt64: return Int64(bitPattern: u)
        default: return nil
        }
    }

    static func bool(_ any: Any?) -> Bool? {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }
}

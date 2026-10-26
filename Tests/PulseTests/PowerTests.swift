import Foundation
import AppKit
import Testing
@testable import Pulse

/// La lecture de la batterie, de l'alimentation et des accessoires
/// (`PowerReader`), sur les dictionnaires relevés le 11/10 sur ce MacBook Pro
/// M2 Max : sur secteur 140 W, 74 %, ne charge pas, pendant un montage.
@Suite struct PowerTests {
    /// L'AppleSmartBattery, réduite aux clés lues (valeurs réelles).
    nonisolated(unsafe) static let registry: [String: Any] = [
        "BatteryInstalled": true,
        "ExternalConnected": true,
        "IsCharging": false,
        "FullyCharged": false,
        "CurrentCapacity": 74,
        "MaxCapacity": 100,
        "AppleRawCurrentCapacity": 5095,
        "AppleRawMaxCapacity": 6906,
        "NominalChargeCapacity": 7150,
        "DesignCapacity": 8694,
        "CycleCount": 359,
        "DesignCycleCount9C": 1000,
        "Temperature": 3071,
        "VirtualTemperature": 3389,
        "Voltage": 11998,
        "Amperage": 0,
        "InstantAmperage": 0,
        "AvgTimeToEmpty": 65535,
        "AvgTimeToFull": 65535,
        "PowerTelemetryData": ["SystemLoad": 76922, "SystemPowerIn": 76922,
                               "SystemVoltageIn": 27642, "SystemCurrentIn": 2783, "BatteryPower": 0],
    ]

    /// La description IOPowerSources de la batterie interne.
    nonisolated(unsafe) static let source: [String: Any] = [
        "Type": "InternalBattery", "Is Present": true, "Is Charging": false, "Is Charged": false,
        "Current Capacity": 74, "Max Capacity": 100, "Power Source State": "AC Power",
        "BatteryHealth": "Good", "DesignCycleCount": 1000, "Time to Empty": 0, "Time to Full Charge": 0,
    ]

    nonisolated(unsafe) static let adapter: [String: Any] = [
        "Watts": 140, "Name": "140W USB-C Power Adapter", "Manufacturer": "Apple Inc.",
        "AdapterVoltage": 28000, "Current": 4990,
    ]

    /// Les profils de pmset : « powermode 2 » sur secteur.
    nonisolated(unsafe) static let preferences: [String: Any] = [
        "AC Power": ["LowPowerMode": 2, "HighPowerMode": 0],
        "Battery Power": ["LowPowerMode": 0, "HighPowerMode": 0],
    ]

    static func raw(registry: [String: Any] = registry, source: [String: Any]? = source) -> PowerReader.Raw {
        PowerReader.Raw(registry: registry, source: source, adapter: adapter, preferences: preferences, lowPowerMode: false)
    }

    @Test func laBatterieDeCeMac() {
        let s = PowerReader.sample(Self.raw())
        #expect(s.hasBattery)
        #expect(s.level == 0.74)
        #expect(s.state == .notCharging)
        #expect(s.cycles == 359 && s.designCycles == 1000)
        #expect(abs((s.computedHealth ?? 0) - 7150.0 / 8694) < 1e-9, "la santé se calcule sur la capacité nominale")
        #expect(s.health(macOS: 81) == 0.81, "la santé de macOS passe devant le calcul")
        #expect(s.systemWatts == 76.922)
        #expect(s.adapterInputWatts == 76.922)
        #expect(s.adapter?.watts == 140)
        #expect(s.minutesToEmpty == nil && s.minutesToFull == nil, "65 535 et 0 ne sont pas des durées")
        #expect(s.activeEnergyMode == .highPower)
    }

    /// Le piège : `Temperature` se lit partout en centièmes de degré. Sur ce
    /// Mac il est en dixièmes de kelvin — 30,7 °C lu en centièmes, sous les
    /// trois sondes SMC de la batterie (33,8 · 32,6 · 33,8 °C).
    @Test func laTemperatureEstEnDixiemesDeKelvin() {
        let s = PowerReader.sample(Self.raw())
        let t = s.temperature ?? 0
        #expect(abs(t - 33.95) < 0.01, "\(t) °C au lieu de 33,95")
        #expect((32.6...35).contains(t), "hors de la plage des sondes SMC")
        #expect(abs(t - (s.virtualTemperature ?? 0)) < 0.2, "VirtualTemperature, en centièmes, la suit à 0,1 °C près")
        #expect(PowerReader.celsius(deciKelvin: 0) == nil, "un zéro de la jauge n'est pas -273 °C")
    }

    /// Sur batterie : le courant arrive négatif, en entier 64 bits signé —
    /// `ioreg` l'affiche 18 446 744 073 709 549 271.
    @Test func surBatterieLaConsommationVientDuCourant() {
        var registry = Self.registry
        registry["ExternalConnected"] = false
        registry["Voltage"] = 11500
        registry["Amperage"] = NSNumber(value: Int64(-2345))
        registry["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -2400))
        var source = Self.source
        source["Power Source State"] = "Battery Power"
        source["Time to Empty"] = 192
        let s = PowerReader.sample(Self.raw(registry: registry, source: source))
        #expect(s.state == .discharging)
        #expect(abs((s.amperage ?? 0) + 2.345) < 1e-9)
        #expect(abs((s.instantAmperage ?? 0) + 2.4) < 1e-9, "le non signé de ioreg redevient négatif")
        #expect(abs((s.systemWatts ?? 0) - 11.5 * 2.345) < 1e-9)
        #expect(s.minutesToEmpty == 192)
        #expect(s.adapter == nil, "sur batterie, pas de chargeur")
        #expect(s.activeEnergyMode == .automatic)
    }

    /// La consommation affichée est celle du SMC, en direct, comme la carte
    /// Capteurs : côte à côte, la jauge (rafraîchie toutes les 40 à 60 s) et
    /// le SMC disaient 93 et 103 W pour la même machine.
    @Test func laConsommationAfficheeEstCelleDuSMC() {
        var s = PowerReader.sample(Self.raw())
        #expect(s.displayedWatts == 76.922, "sans SMC : la jauge")
        s.liveSystemWatts = 103
        #expect(s.displayedWatts == 103)
        #expect(s.systemWatts == 76.922, "la jauge reste lisible pour --probe")
    }

    /// Carte masquée dès le lancement : aucun échantillonneur n'est créé —
    /// avant, `stateDidChange` le créait pour l'arrêter aussitôt, après une
    /// lecture complète et un `system_profiler`.
    @Test func uneCarteMasqueeNeCreeRien() {
        #expect(!EnergyModule.needsSampler(enabled: false, exists: false))
        #expect(EnergyModule.needsSampler(enabled: false, exists: true), "un échantillonneur existant doit s'arrêter")
        #expect(EnergyModule.needsSampler(enabled: true, exists: false))
    }

    /// Ce que coûte un relevé réel — batterie, alimentation, SMC —, en temps
    /// processeur du fil : le budget panneau fermé en dépend (un relevé
    /// toutes les 5 min). Seuil large, en debug : un garde-fou contre une
    /// régression, la mesure est dans le journal du chantier.
    @Test func unReleveResteBonMarche() {
        func threadCPU() -> Double {
            var t = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
            return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        }
        let smc = SMCReader()
        _ = PowerMonitor.read(smc: smc)
        let n = 40
        let start = threadCPU()
        for _ in 0..<n { _ = PowerMonitor.read(smc: smc) }
        let perRead = (threadCPU() - start) / Double(n)
        print("Énergie : \(String(format: "%.3f", perRead * 1000)) ms de processeur par relevé, "
              + "soit \(String(format: "%.5f", perRead / PowerSampler.closedInterval * 100)) % d'un cœur panneau fermé")
        #expect(perRead < 0.02, "\(perRead * 1000) ms par relevé")
    }

    @Test func enChargeLeTempsJusquAuPlein() {
        var registry = Self.registry
        registry["IsCharging"] = true
        registry["Amperage"] = 3100
        var source = Self.source
        source["Is Charging"] = true
        source["Time to Full Charge"] = 65
        let s = PowerReader.sample(Self.raw(registry: registry, source: source))
        #expect(s.state == .charging)
        #expect(s.minutesToFull == 65)
        #expect((s.batteryWatts ?? 0) > 0, "en charge, la batterie reçoit")
    }

    /// En export sur un chargeur trop faible : sur secteur, la batterie
    /// complète. C'est la ligne que la carte doit dire avant qu'elle se vide.
    @Test func quandLeChargeurNeSuffitPas() {
        var registry = Self.registry
        registry["Amperage"] = -1000            // 12 V × 1 A tirés de la batterie
        let s = PowerReader.sample(Self.raw(registry: registry))
        #expect(s.state == .notCharging)
        #expect(EnergyCard.stateText(s) == "sur secteur, la batterie aide (12\u{00A0}W)")
        #expect(EnergyCard.stateText(PowerReader.sample(Self.raw())) == "sur secteur, ne charge pas")
        // Le filet relevé le 11/10 : −89 mA à 114 W sur un chargeur de 140 W.
        registry["Amperage"] = NSNumber(value: UInt64(18_446_744_073_709_551_527))
        let trickle = PowerReader.sample(Self.raw(registry: registry))
        #expect(abs((trickle.amperage ?? 0) + 0.089) < 1e-9, "le non signé de ioreg se relit -89 mA")
        #expect(EnergyCard.stateText(trickle) == "sur secteur, ne charge pas", "un filet n'est pas une aide")
    }

    /// Ce que la carte verse à l'historique du 02 : panneau fermé, 5 min
    /// d'écart, la MOYENNE du compteur de la jauge — un instant y serait un
    /// tirage au sort entre deux pics d'export ; à 5 s d'écart, la valeur
    /// affichée.
    @Test func ceQueLaCarteVerseALHistorique() {
        var a = PowerReader.sample(Self.raw())
        a.loadSum = 308_558_868; a.loadCount = 4422; a.liveSystemWatts = 95
        var b = a
        b.loadSum = 314_198_954; b.loadCount = 4477; b.liveSystemWatts = 120
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let closed = PowerSampler.historyValues(previous: (t0, a), current: b, now: t0.addingTimeInterval(300))
        #expect(closed.map { $0.0 } == [PowerSampler.chargeKey, PowerSampler.consumptionKey])
        #expect(closed.first?.1 == 0.74)
        #expect(abs((closed.last?.1 ?? 0) - 102.547) < 0.01, "moyenne du compteur : \(closed.last?.1 ?? 0)")
        let open = PowerSampler.historyValues(previous: (t0, a), current: b, now: t0.addingTimeInterval(5))
        #expect(open.last?.1 == 120, "panneau ouvert : la valeur affichée")
        #expect(PowerSampler.historyValues(previous: nil, current: b, now: t0).last?.1 == 120)
        let desktop = PowerReader.sample(PowerReader.Raw(registry: [:], source: nil, adapter: nil,
                                                         preferences: nil, lowPowerMode: false))
        #expect(PowerSampler.historyValues(previous: nil, current: desktop, now: t0).isEmpty)
    }

    /// La puissance moyenne entre deux lectures du compteur de la jauge,
    /// relevée le 11/10 : +5 640 086 mW sur 55 relevés, 102,5 W.
    @Test func laPuissanceMoyenneDuCompteur() {
        var a = PowerSample(), b = PowerSample()
        a.loadSum = 308_558_868; a.loadCount = 4422
        b.loadSum = 314_198_954; b.loadCount = 4477
        let watts = PowerSampler.averageWatts(from: a, to: b) ?? 0
        #expect(abs(watts - 102.547) < 0.01, "\(watts) W")
        #expect(PowerSampler.averageWatts(from: b, to: b) == nil, "compteur immobile")
        #expect(PowerSampler.averageWatts(from: b, to: a) == nil, "compteur reparti de zéro")
        #expect(PowerSampler.averageWatts(from: nil, to: b) == nil)
        let s = PowerReader.sample(Self.raw())
        #expect(s.loadSum == nil, "absent du dictionnaire d'exemple : nil, pas 0")
    }

    @Test func unMacDeBureauNaPasDeBatterie() {
        let s = PowerReader.sample(PowerReader.Raw(registry: [:], source: nil, adapter: nil,
                                                   preferences: nil, lowPowerMode: false))
        #expect(!s.hasBattery)
        #expect(s.level == nil && s.temperature == nil && s.computedHealth == nil)
    }

    /// `LowPowerMode` porte le mode d'énergie entier sous macOS 26 : 2 n'y
    /// veut pas dire « économie » — `ProcessInfo` la donnait inactive.
    @Test func leModeDEnergie() {
        #expect(PowerReader.energyMode(["LowPowerMode": 2, "HighPowerMode": 0]) == .highPower)
        #expect(PowerReader.energyMode(["LowPowerMode": 1]) == .lowPower)
        #expect(PowerReader.energyMode(["LowPowerMode": 0, "HighPowerMode": 0]) == .automatic)
        #expect(PowerReader.energyMode(["HighPowerMode": 1]) == .highPower, "l'ancienne clé")
        #expect(PowerReader.energyMode(["Display Sleep Timer": 10]) == nil)
        #expect(PowerReader.energyMode(nil) == nil)
    }

    @Test func lesDureesInconnues() {
        #expect(PowerReader.minutes(65535) == nil)
        #expect(PowerReader.minutes(-1) == nil, "IOPowerSources : en calcul")
        #expect(PowerReader.minutes(0) == nil)
        #expect(PowerReader.minutes(95) == 95)
    }

    // MARK: - Accessoires

    /// Les deux sources des AirPods, telles que `IOPSCopyPowerSourcesByType(4)`
    /// les rend : le boîtier, et les écouteurs avec leurs parties.
    nonisolated(unsafe) static let airpods: [[String: Any]] = [
        ["Type": "Accessory Source", "Name": "AirPods Pro #3 Case", "Accessory Category": "Audio Battery Case",
         "Group Identifier": "0D08930D", "Part Identifier": "Case", "Current Capacity": 50, "Max Capacity": 100,
         "Is Charging": false, "Transport Type": "Bluetooth LE", "Product ID": 8231],
        ["Type": "Accessory Source", "Name": "AirPods Pro #3", "Accessory Category": "Headset",
         "Group Identifier": "0D08930D", "Part Identifier": "Combined", "Current Capacity": 100, "Max Capacity": 100,
         "Is Charging": true, "Transport Type": "Bluetooth LE", "Product ID": 8231,
         "Combined Parts": [
            ["Part Identifier": "Left", "Current Capacity": 100, "Max Capacity": 100, "Is Charging": true],
            ["Part Identifier": "Right", "Current Capacity": 100, "Max Capacity": 100, "Is Charging": true],
         ]],
        ["Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 74],
    ]

    @Test func lesAirPodsDeviennentUnSeulAppareil() {
        let list = PowerReader.accessories(sources: Self.airpods)
        #expect(list.count == 1, "\(list.map(\.name))")
        let a = list.first
        #expect(a?.name == "AirPods Pro #3")
        #expect(a?.kind == .airpodsPro)
        #expect(a?.parts.map(\.role) == [.left, .right, .case])
        #expect(a?.parts.last?.level == 0.5)
        #expect(a?.lowestWorn == 1)
        #expect(a.map(PowerFmt.parts) == "100\u{00A0}% en charge · boîtier 50\u{00A0}%")
    }

    @Test func lesAppareilsHIDSansDoublon() {
        let hid: [[String: Any]] = [["Product": "Magic Mouse", "BatteryPercent": 42],
                                    ["Product": "AirPods Pro #3", "BatteryPercent": 99]]
        let list = PowerReader.accessories(sources: Self.airpods, hid: hid)
        #expect(list.map(\.name) == ["AirPods Pro #3", "Magic Mouse"])
        #expect(list.last?.kind == .mouse)
        #expect(list.last?.parts.first?.level == 0.42)
        #expect(list.last?.source == "IORegistry")
    }

    @Test func gaucheEtDroiteDifferentes() {
        let a = PowerAccessory(id: "x", name: "AirPods", kind: .airpods,
                               parts: [.init(role: .left, level: 0.8, charging: false),
                                       .init(role: .right, level: 0.35, charging: false)],
                               source: "IOPowerSources")
        #expect(PowerFmt.parts(a) == "gauche 80\u{00A0}% · droite 35\u{00A0}%")
        #expect(a.lowestWorn == 0.35)
    }

    // MARK: - Santé selon macOS

    @Test func laSanteDeSystemProfiler() {
        let json = Data("""
        {"SPPowerDataType":[{"_name":"spbattery_information",
          "sppower_battery_health_info":{"sppower_battery_cycle_count":359,
            "sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"81 %"}}]}
        """.utf8)
        let report = PowerReader.healthReport(json: json)
        #expect(report?.maximumCapacity == 81)
        #expect(report?.condition == "Good")
        #expect(report?.cycles == 359)
        #expect(PowerReader.healthReport(json: Data("{}".utf8)) == nil)
    }

    // MARK: - Symboles

    @Test func chaqueSymboleExiste() {
        let kinds: [PowerAccessory.Kind] = [.airpods, .airpodsPro, .airpodsMax, .headphones, .mouse, .keyboard, .trackpad, .other]
        for name in kinds.map(\.symbol) + EnergyCard.allSymbols {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "symbole absent : \(name)")
        }
    }
}

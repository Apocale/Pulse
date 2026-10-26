import Foundation

/// Un relevé complet et figé : tout ce que le `Sampler` publie, en valeurs
/// fixes. Les tests de rendu en nourrissent un sampler (`sampler()`) et
/// comparent les cartes à des images de référence : rien n'y dépend de
/// l'heure, de la machine ou de l'humeur des capteurs.
///
/// `typique` raconte une journée de montage ordinaire et chargée — Premiere
/// et Media Encoder qui exportent, le swap qui monte, Ssd 2 qui se remplit —
/// pour que chaque élément des cartes du socle ait quelque chose à dessiner :
/// anneau d'alerte, échéance, export, incident, partage iPhone.
struct Releve {
    var memory = MemorySample()
    var cpu = CPUSample()
    var gpu: Double?
    var volumes: [VolumeSample] = []
    var series: [SeriesPoint] = []
    var forecasts: [String: FillForecast] = [:]
    var apps: [AppUsage] = []
    var focusTotal: TimeInterval = 0
    var session: EditingSession?
    var incidents: [Incident] = []
    var processes: [ProcessGroup] = []
    var export: ExportActivity?
    var verdict: Verdict = .pending
    var network = NetworkSample()
    var networkTrail: [NetworkSample] = []
    /// Le cumul internet des derniers jours, du plus ancien au plus récent.
    var networkDays: [(day: Date, usage: [NetworkTracker.Usage])] = []
    /// « Allumé depuis » : l'heure de démarrage est fixée à cet écart du
    /// moment du rendu.
    var allumeDepuis: TimeInterval = 3 * 86_400 + 4 * 3600 + 30
    /// « Aujourd'hui » pour ce qui se compte jusqu'à lui : le forfait du mois.
    var maintenant = Date(timeIntervalSince1970: Releve.origine)

    // Les cartes qui mesurent elles-mêmes, figées elles aussi.
    var energie = PowerSample()
    var accessoires: [PowerAccessory] = []
    var santeBatterie: BatteryHealthReport?
    var capteurs = SensorSample()
    var wifi: SignalWiFi?
    var adresses: AdressesLocales?
    var passerelle = Latence(source: "ping")
    var internet = Latence(source: "trafic en cours")
    var debitParApp: [SuiviSockets.DebitApp] = []
    /// La carte Médias (08) : moteurs, exports du jour, cache, sorties en
    /// cours — et la semaine d'exports, à la place du journal d'AME et
    /// d'exports.json (19-suivis).
    var medias = MediaState()
    var exports: [ExportRecord] = []
    /// Les réglages des cartes : le forfait iPhone du réseau, entre autres.
    var reglages = PulseSettings()

    /// Un sampler qui publie ce relevé, persistance coupée d'abord : sa
    /// création relit l'historique, et rien ne doit pouvoir y écrire. Les
    /// modules qui mesurent eux-mêmes — énergie, capteurs, réseau — sont
    /// figés du même geste : plus rien ne les relance.
    @MainActor
    func sampler() -> Sampler {
        Persistence.enabled = false
        SystemClock.bootDate = Date().addingTimeInterval(-allumeDepuis)
        EnergyModule.installer(PowerSampler(figé: energie, accessories: accessoires, health: santeBatterie))
        SensorStore.shared.figer(capteurs)
        MoniteurReseau.shared.figer(wifi: wifi, adresses: adresses, passerelle: passerelle,
                                    internet: internet, apps: debitParApp)
        return Sampler(figé: self)
    }

    // MARK: - La journée type

    /// Un instant fixe, le 11/10/2026 à 14 h 00 : toutes les dates du relevé
    /// en partent, aucune ne dépend de l'heure du test.
    static let origine: Double = 1_791_727_200

    static let gio: UInt64 = 1 << 30
    static let go: UInt64 = 1_000_000_000

    static var typique: Releve {
        var r = Releve()
        let gio = Self.gio, go = Self.go
        let t0 = origine

        r.memory = MemorySample(total: 32 * gio, app: 14 * gio, wired: 9 * gio / 2,
                                compressed: 16 * gio / 5, cached: 6 * gio,
                                swapUsed: 21 * gio / 10, swapTotal: 3 * gio,
                                pressureLevel: 2, pressure: 0.58)

        // Quatre cœurs d'efficacité, puis huit de performance, dans l'ordre
        // du noyau.
        let e = [0.62, 0.55, 0.48, 0.71], p = [0.83, 0.12, 0.95, 0.40, 0.05, 0.67, 0.30, 0.22]
        r.cpu = CPUSample(total: 0.46, user: 0.36, system: 0.10, perCore: e + p,
                          performance: p.reduce(0, +) / Double(p.count),
                          efficiency: e.reduce(0, +) / Double(e.count),
                          load: [7.42, 6.18, 5.90])
        r.gpu = 0.68

        func volume(_ name: String, _ path: String, total: UInt64, free: UInt64,
                    interne: Bool, uuid: String) -> VolumeSample {
            VolumeSample(name: name, path: path, total: total, available: free, isInternal: interne,
                         uuid: uuid, availableStrict: free)
        }
        r.volumes = [volume("Macintosh HD", "/", total: 994 * go, free: 402 * go, interne: true, uuid: "FIXE-MAC"),
                     volume("Ssd 2", "/Volumes/Ssd 2", total: 2_000 * go, free: 312 * go, interne: false, uuid: "FIXE-SSD2"),
                     volume("Extreme Pro", "/Volumes/Extreme Pro", total: 2_000 * go, free: 719 * go,
                            interne: false, uuid: "FIXE-EXTREME"),
                     volume("SSD 1", "/Volumes/SSD 1", total: 1_000 * go, free: 677 * go,
                            interne: false, uuid: "FIXE-SSD1")]
        // Des échéances au-delà de la semaine : « plein vers lundi » changerait
        // de jour avec le calendrier.
        r.forecasts = ["FIXE-SSD2": FillForecast(bytesPerDay: -26e9, daysUntilFull: 12, ruptures: 1,
                                                 calmSeconds: 70 * 3600),
                       "FIXE-EXTREME": FillForecast(bytesPerDay: -1.2e9, daysUntilFull: nil, ruptures: 0,
                                                    calmSeconds: 72 * 3600),
                       "FIXE-MAC": FillForecast(bytesPerDay: 5.3e9, daysUntilFull: nil, ruptures: 0,
                                                calmSeconds: 72 * 3600)]

        // Une heure de série, un point toutes les 10 s : le processeur ondule,
        // le swap monte de 1 à 2,1 Gio (« +1,1 Go en 1 h »).
        r.series = (0...360).map { i in
            let x = Double(i)
            return SeriesPoint(t: t0 - 3600 + x * 10,
                               ram: 0.62 + 0.08 * sin(x / 30),
                               swap: Double(gio) * (1 + 1.1 * x / 360),
                               cpu: min(1, max(0, 0.35 + 0.25 * sin(x / 17) + 0.1 * sin(x / 3))),
                               gpu: min(1, max(0, 0.5 + 0.3 * sin(x / 23))))
        }

        r.apps = [AppUsage(bundleId: "com.adobe.PremierePro.26", name: "Adobe Premiere Pro 2026", focus: 3 * 3600 + 12 * 60),
                  AppUsage(bundleId: "com.vivaldi.Vivaldi", name: "Vivaldi", focus: 65 * 60),
                  AppUsage(bundleId: "com.adobe.ame.application.26", name: "Adobe Media Encoder 2026", focus: 25 * 60),
                  AppUsage(bundleId: "com.apple.finder", name: "Finder", focus: 10 * 60)]
        r.focusTotal = r.apps.reduce(0) { $0 + $1.focus }

        // Une session close : sa durée ne dépend pas de l'heure du rendu.
        var session = EditingSession(bundleId: "com.adobe.PremierePro.26", name: "Adobe Premiere Pro 2026",
                                     start: t0 - 2 * 3600 - 13 * 60)
        session.end = t0
        r.session = session
        r.incidents = [Incident(app: "Adobe Premiere Pro 2026", bundleId: "com.adobe.PremierePro.26",
                                kind: .crash, date: Date(timeIntervalSince1970: t0 - 26 * 3600))]
        r.export = ExportActivity(app: "Adobe Media Encoder 2026",
                                  began: Date(timeIntervalSince1970: t0 - 4 * 60),
                                  lastActive: Date(timeIntervalSince1970: t0))

        // Triés par processeur, comme les rend `ProcessMonitor`. Les icônes :
        // celles d'apps du système, identiques sur tout Mac, ou l'icône
        // générique des exécutables.
        r.processes = [
            ProcessGroup(bundleId: "com.adobe.PremierePro.26", name: "Adobe Premiere Pro 2026",
                         cpu: 186.4, footprint: 46 * gio / 5, processCount: 14),
            ProcessGroup(bundleId: "com.adobe.ame.application.26", name: "Adobe Media Encoder 2026",
                         cpu: 142.0, footprint: 21 * gio / 10, processCount: 3),
            ProcessGroup(bundleId: "com.apple.Safari", name: "Safari", cpu: 23.1, footprint: 8 * gio / 5,
                         processCount: 9, bundlePath: "/Applications/Safari.app"),
            ProcessGroup(bundleId: "exec:com.apple.WebKit.WebContent", name: "com.apple.WebKit.WebContent",
                         cpu: 8.2, footprint: 11 * gio / 10, processCount: 6),
            ProcessGroup(bundleId: "com.apple.finder", name: "Finder", cpu: 1.9, footprint: 3 * gio / 20,
                         processCount: 1, bundlePath: "/System/Library/CoreServices/Finder.app"),
        ]

        r.verdict = Verdict(rule: 6, ruleName: "pression mémoire élevée", level: .warning, symbol: "memorychip",
                            phrase: "La mémoire commence à manquer",
                            evidence: "pression élevée · 2,1 Go de swap",
                            also: ["swap en hausse"])

        r.network = NetworkSample(connected: true, kind: .hotspot, label: NetworkKind.hotspot.label,
                                  rxRate: 2_400_000, txRate: 310_000)
        r.networkTrail = (0..<Sampler.networkTrailLength).map { i in
            let x = Double(i)
            return NetworkSample(connected: true, kind: .hotspot, label: NetworkKind.hotspot.label,
                                 rxRate: max(0, 1_500_000 + 1_200_000 * sin(x / 7)),
                                 txRate: max(0, 200_000 + 150_000 * sin(x / 5 + 1)))
        }
        // Le cycle du forfait depuis le 1er octobre : du partage iPhone
        // certains jours, la box les autres. Les deux derniers jours font
        // « Aujourd'hui » et « Hier » dans la carte.
        let jour = 86_400.0
        let partage: [UInt64] = [0, 0, 2_100_000_000, 450_000_000, 0, 1_700_000_000, 0, 900_000_000, 0]
        r.networkDays = partage.enumerated().map { i, octets in
            (Date(timeIntervalSince1970: t0 - Double(10 - i) * jour),
             [NetworkTracker.Usage(label: "Wi-Fi", kind: .wifi, rx: 40 * go, tx: 2 * go)]
                + (octets > 0 ? [NetworkTracker.Usage(label: NetworkKind.hotspot.label, kind: .hotspot,
                                                      rx: octets * 9 / 10, tx: octets / 10)] : []))
        } + [
            (Date(timeIntervalSince1970: t0 - jour),
             [NetworkTracker.Usage(label: "Wi-Fi", kind: .wifi, rx: 341 * go, tx: 15 * go),
              NetworkTracker.Usage(label: NetworkKind.hotspot.label, kind: .hotspot, rx: 3 * go, tx: go / 2)]),
            (Date(timeIntervalSince1970: t0),
             [NetworkTracker.Usage(label: "Wi-Fi", kind: .wifi, rx: 7 * go, tx: 4 * go / 5),
              NetworkTracker.Usage(label: NetworkKind.hotspot.label, kind: .hotspot, rx: 1_200_000_000,
                                   tx: 180_000_000)]),
        ]
        var reseau = ReglagesReseau()
        reseau.forfaitGo = 20
        reseau.jourRenouvellement = 1
        r.reglages.modules[ReglagesReseau.module] = ModuleSettings(options: reseau.options())

        // Partage iPhone en Wi-Fi : le signal, la passerelle, un peu d'envoi.
        r.wifi = SignalWiFi(rssi: -58, bruit: -92, debitLiaison: 573, canal: 149, bande: "5 GHz",
                            largeurMHz: 80, norme: "802.11ax")
        r.adresses = AdressesLocales(interface: "en0", ipv4: "172.20.10.4", ipv6: nil,
                                     passerelle: "172.20.10.1", dns: ["172.20.10.1"])
        r.passerelle = Latence(ms: 4.2, perdus: 0, essais: 6, source: "ping", connexions: 0, aRepondu: true)
        r.internet = Latence(ms: 38.5, perdus: 0, essais: 6, source: "trafic en cours", connexions: 7, aRepondu: true)
        r.debitParApp = [
            SuiviSockets.DebitApp(id: "com.getdropbox.dropbox", nom: "Dropbox", chemin: nil,
                                  recu: 12_000, envoye: 1_850_000),
            SuiviSockets.DebitApp(id: "com.apple.Safari", nom: "Safari", chemin: "/Applications/Safari.app",
                                  recu: 640_000, envoye: 22_000),
            SuiviSockets.DebitApp(id: "com.adobe.PremierePro.26", nom: "Adobe Premiere Pro 2026", chemin: nil,
                                  recu: 85_000, envoye: 4_000),
        ]

        // Sur secteur, en plein export : le chargeur de 140 W ne charge plus.
        var batterie = PowerSample()
        batterie.hasBattery = true
        batterie.level = 0.74
        batterie.state = .notCharging
        batterie.cycles = 359
        batterie.designCycles = 1000
        batterie.designCapacity = 8579
        batterie.nominalCapacity = 7120
        batterie.fullChargeCapacity = 6950
        batterie.currentCharge = 5140
        batterie.condition = "Normal"
        batterie.temperature = 31.5
        batterie.voltage = 12.62
        batterie.amperage = 0
        batterie.systemWatts = 102
        batterie.liveSystemWatts = 98.4
        batterie.adapterInputWatts = 112
        batterie.adapter = PowerAdapter(name: "Adaptateur secteur USB-C 140 W", watts: 140, voltage: 28,
                                        current: 5, manufacturer: "Apple Inc.")
        batterie.energyModeAC = .highPower
        batterie.energyModeBattery = .automatic
        r.energie = batterie
        r.santeBatterie = BatteryHealthReport(maximumCapacity: 81, condition: "Normal", cycles: 359,
                                              readAt: Date(timeIntervalSince1970: t0))
        r.accessoires = [PowerAccessory(id: "airpods", name: "AirPods Pro", kind: .airpodsPro,
                                        parts: [.init(role: .left, level: 1.0, charging: false),
                                                .init(role: .right, level: 0.95, charging: false),
                                                .init(role: .case, level: 0.5, charging: true)],
                                        source: "IOPowerSources")]

        // La puce sous un export : chaude, ventilateurs au tiers.
        var puce = SensorSample()
        func lecture(_ groupe: SensorGroup, _ famille: String, _ nom: String, _ degres: Double) -> SensorSample.Reading {
            SensorSample.Reading(group: groupe, family: famille, name: nom, celsius: degres, source: "SMC")
        }
        puce.readings = [71, 69, 74, 68, 66, 72, 70, 67].enumerated().map {
            lecture(.cpu, "Cœurs performance", "Cœur performance \($0 + 1)", $1)
        } + [58, 57, 59, 56].enumerated().map {
            lecture(.cpu, "Cœurs efficacité", "Cœur efficacité \($0 + 1)", $1)
        } + [lecture(.gpu, "Carte graphique", "Carte graphique 1", 62),
             lecture(.gpu, "Carte graphique", "Carte graphique 2", 64),
             lecture(.ssd, "SSD", "SSD (mémoire flash)", 41),
             lecture(.battery, "Batterie", "Batterie 1", 31.5),
             lecture(.air, "Flux d'air gauche", "Flux d'air gauche", 34),
             lecture(.air, "Flux d'air droit", "Flux d'air droit", 36)]
        puce.fans = [SensorSample.Fan(index: 0, rpm: 2650, min: 1200, max: 5700, target: nil, forced: false),
                     SensorSample.Fan(index: 1, rpm: 2700, min: 1200, max: 6000, target: nil, forced: false)]
        puce.power = SensorSample.Power(cpu: 18.4, gpu: 9.2, ane: 0, dram: 1.6, seconds: 1.5)
        puce.systemPower = 64
        puce.efficiency = SensorSample.Clock(mhz: 1650, max: 2424, active: 0.55)
        puce.performance = SensorSample.Clock(mhz: 3120, max: 3696, active: 0.62)
        puce.gpuClock = SensorSample.Clock(mhz: 1020, max: 1398, active: 0.48)
        puce.thermalPressure = 1
        puce.date = Date(timeIntervalSince1970: t0)
        r.capteurs = puce

        // Médias (08, figé par le 19) : une semaine d'exports type — la file
        // d'AME depuis Premiere, des 4K de quelques minutes, un échec —, le
        // GPU au même chiffre que la carte Processeur (une seule lecture,
        // README), l'export en cours et le fichier qu'il écrit.
        func export(_ nom: String, finA heures: Double, dure minutes: Double, octets: UInt64?,
                    issue: ExportRecord.Outcome = .success) -> ExportRecord {
            let fin = t0 - heures * 3600
            return ExportRecord(id: "fixe-\(Int(fin))", app: "Media Encoder", end: fin, duration: minutes * 60,
                                output: "/Volumes/Ssd 2/Exports/\(nom)", outcome: issue, bytes: octets,
                                source: AMEJournal.source)
        }
        // Des noms neutres : ce relevé est compilé dans l'app que reçoivent
        // d'autres personnes, et le rendu de la carte Médias illustre sa page.
        r.exports = [export("Interview 6.mp4", finA: 0.8, dure: 8.15, octets: 4_200_000_000),
                     export("Teaser.mp4", finA: 3.6, dure: 3.2, octets: 612_000_000),
                     export("Interview 5.mp4", finA: 22, dure: 7.9, octets: 4_050_000_000),
                     export("Interview 5 v1.mp4", finA: 23.5, dure: 1.1, octets: nil, issue: .failure),
                     export("Podcast 02.mov", finA: 47, dure: 14.5, octets: 21_400_000_000),
                     export("Podcast 01.mov", finA: 50, dure: 13.8, octets: 20_100_000_000,
                            issue: .warning),
                     export("Reel 9x16.mp4", finA: 98, dure: 2.4, octets: 380_000_000),
                     export("Interview 4.mp4", finA: 121, dure: 7.6, octets: 3_900_000_000)]
        let aujourdhui = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: t0)).timeIntervalSince1970
        r.medias.exportsToday = r.exports.filter { $0.end >= aujourdhui }.sorted { $0.end > $1.end }
        r.medias.lastExport = r.exports.max { $0.end < $1.end }
        r.medias.engines = MediaSample(gpuUtilization: r.gpu, gpuPower: 9.2, gpuFrequency: 1020,
                                       gpuMaxFrequency: 1398, gpuMemory: 27 * gio / 5, encoderPower: 0.42,
                                       scalerPower: 0.05, neuralPower: 0,
                                       gpuApps: [GPUAppUsage(bundleId: "com.adobe.ame.application.26",
                                                             name: "Adobe Media Encoder 2026", share: 0.41),
                                                 GPUAppUsage(bundleId: "com.adobe.PremierePro.26",
                                                             name: "Adobe Premiere Pro 2026", share: 0.22)],
                                       interval: 1.5)
        let cache = URL(fileURLWithPath: "/Users/Shared/Adobe/Common", isDirectory: true)
        r.medias.cache = MediaCache.Measure(location: .init(files: cache.appendingPathComponent("Media Cache Files"),
                                                            database: cache.appendingPathComponent("Media Cache"),
                                                            fromPreferences: true),
                                            bytes: 109 * go, staleBytes: 90 * go, fileCount: 63_510,
                                            measuredAt: Date(timeIntervalSince1970: t0 - 600), seconds: 1.7)
        r.medias.writing = [WrittenFile(path: "/Volumes/Ssd 2/Exports/Interview 7.mp4", app: "Media Encoder",
                                        bytes: 1_840_000_000, rate: 31_000_000)]
        return r
    }
}

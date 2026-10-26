import Foundation
import SwiftUI
import Carbon.HIToolbox
import Testing
@testable import Pulse

/// Les pièges du README qui n'avaient pas de test (chantier 17). Chacun est
/// un bug qui a existé ; chaque test a été vu échouer en réintroduisant le
/// défaut décrit.
@Suite struct PiegesTests {

    // MARK: - « Apple mélange les conventions d'unités »

    /// Stockage en base 1000, mémoire en base 1024 — pas l'une pour tout.
    @Test func lesDeuxBasesDUnites() {
        #expect(Fmt.bytes(500_000_000_000.0) == "500\u{00A0}Go")
        #expect(Fmt.memory(500_000_000_000.0) == "466\u{00A0}Go")
        #expect(Fmt.memory(Double(128) * 1_073_741_824) == "128\u{00A0}Go")
        #expect(Fmt.bytes(Double(128) * 1_073_741_824) == "137\u{00A0}Go")
    }

    // MARK: - « Le CPU de Premiere ne dit pas s'il exporte »

    static func groupes(premiere: Double, encodeur: Double) -> [ProcessGroup] {
        [ProcessGroup(bundleId: "com.adobe.PremierePro.26", name: "Premiere Pro", cpu: premiere,
                      footprint: 0, processCount: 1),
         ProcessGroup(bundleId: "com.adobe.ame.26", name: "Adobe Media Encoder", cpu: encodeur,
                      footprint: 0, processCount: 1)]
    }

    /// Les bornes mesurées le 25 août : Premiere à 286 % au repos ne fait
    /// pas un export ; Media Encoder à 102 %, deux relevés de suite, si ; un
    /// pic isolé, non.
    @Test func leProcesseurDePremiereNeDitPasLExport() {
        let detector = ExportDetector()
        let t0 = Date(timeIntervalSince1970: 1_791_720_000)
        #expect(detector.observe(Self.groupes(premiere: 286, encodeur: 31), now: t0) == nil)
        #expect(detector.observe(Self.groupes(premiere: 286, encodeur: 31), now: t0 + 3) == nil)
        #expect(detector.observe(Self.groupes(premiere: 0, encodeur: 102), now: t0 + 6) == nil, "un pic isolé")
        let export = detector.observe(Self.groupes(premiere: 0, encodeur: 102), now: t0 + 9)
        #expect(export?.app == "Adobe Media Encoder")
        #expect(export?.duration == 3)
    }

    // MARK: - « La position d'une icône ne prouve pas qu'elle se voit »
    // et « les icônes de la barre de menus sont des fenêtres de Control Center »

    /// Relevé du 11/10 : Pulse à x = 1347 sur 125 pt, dans une fenêtre de
    /// Control Center à x = 1340 sur 139 pt. Sans fenêtre affichée qui le
    /// contient, le cadre annoncé ne prouve rien ; une fenêtre bien plus
    /// large n'est pas la sienne.
    @Test func uneIconeNeSeVoitQueDansUneFenetreAffichee() {
        let notch = CGRect(x: 1138, y: 0, width: 918, height: 37)
        let item = CGRect(x: 1347, y: 0, width: 125, height: 37)
        let sienne = MenuBarRoom.Window(frame: CGRect(x: 1340, y: 0, width: 139, height: 37), owner: "Control Center")
        #expect(MenuBarRoom.place(of: item, in: [sienne], rightOfNotch: notch) == .visible)
        #expect(MenuBarRoom.place(of: item, in: [], rightOfNotch: notch) == .notDrawn)
        let large = MenuBarRoom.Window(frame: CGRect(x: 1300, y: 0, width: 300, height: 37), owner: "Control Center")
        #expect(MenuBarRoom.place(of: item, in: [large], rightOfNotch: notch) == .notDrawn)
        let gauche = CGRect(x: 900, y: 0, width: 125, height: 37)
        let derriere = MenuBarRoom.Window(frame: CGRect(x: 893, y: 0, width: 139, height: 37), owner: "Control Center")
        #expect(MenuBarRoom.place(of: gauche, in: [derriere], rightOfNotch: notch) == .behindNotch)
        #expect(MenuBarRoom.place(of: nil, in: [sienne], rightOfNotch: notch) == .absent)
    }

    /// Un second écran posé au-dessus a sa propre barre, aux Y négatifs : ses
    /// icônes ne prennent pas la place de celles du Mac (26/10 : « 918
    /// points, dont 1 715 pris par 29 icônes »).
    @Test func lesIconesDUnAutreEcranNeComptentPas() {
        let notch = CGRect(x: 1138, y: 0, width: 918, height: 37)
        let ici = [MenuBarRoom.Window(frame: CGRect(x: 1340, y: 0, width: 139, height: 37), owner: "Control Center"),
                   MenuBarRoom.Window(frame: CGRect(x: 1479, y: 0, width: 577, height: 37), owner: "Control Center")]
        let audessus = [MenuBarRoom.Window(frame: CGRect(x: 893, y: -1440, width: 139, height: 24), owner: "Control Center"),
                        MenuBarRoom.Window(frame: CGRect(x: 1200, y: -1440, width: 120, height: 24), owner: "Control Center"),
                        MenuBarRoom.Window(frame: CGRect(x: 2400, y: -1440, width: 900, height: 24), owner: "Control Center")]
        let place = MenuBarRoom.room(ici + audessus, rightOfNotch: notch)
        #expect(place.count == 2 && place.used == 716 && place.free == 202)
        // Une icône de l'autre écran, à gauche de l'encoche en X, n'est pas « derrière l'encoche ».
        let la = CGRect(x: 900, y: -1440, width: 125, height: 24)
        #expect(MenuBarRoom.place(of: la, in: audessus, rightOfNotch: notch) == .visible)
        // Un écran posé à GAUCHE, aligné en haut : même rangée, X négatifs.
        let mac = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let agauche = MenuBarRoom.Window(frame: CGRect(x: -700, y: 0, width: 139, height: 24), owner: "Control Center")
        let icone = CGRect(x: -693, y: 0, width: 125, height: 24)
        #expect(MenuBarRoom.place(of: icone, in: [agauche], rightOfNotch: notch, screen: mac) == .visible)
        let gauche = CGRect(x: 900, y: 0, width: 125, height: 37)
        let derriere = MenuBarRoom.Window(frame: CGRect(x: 893, y: 0, width: 139, height: 37), owner: "Control Center")
        #expect(MenuBarRoom.place(of: gauche, in: [derriere], rightOfNotch: notch, screen: mac) == .behindNotch)
    }

    // MARK: - « Une prévision sans échéance ne veut pas dire que le volume se vide »

    @Test func unePrevisionSansEcheanceNeDitPasQueLeVolumeSeVide() {
        let lent = FillForecast(bytesPerDay: -3_000_000_000, daysUntilFull: nil, ruptures: 0, calmSeconds: 86_400)
        #expect(lent.trendText == "se remplit lentement")
        let vide = FillForecast(bytesPerDay: 3_000_000_000, daysUntilFull: nil, ruptures: 0, calmSeconds: 86_400)
        #expect(vide.trendText.hasPrefix("se vide de 3"))
        let plein = FillForecast(bytesPerDay: -50_000_000_000, daysUntilFull: 9, ruptures: 0, calmSeconds: 86_400)
        #expect(plein.trendText == "plein dans ~9 jours")
        #expect(FillForecast(bytesPerDay: 0, daysUntilFull: nil, ruptures: 0, calmSeconds: 0).trendText == "stable")
    }

    // MARK: - « Le mouvement est un ressort, jamais une durée fixe »

    @Test func leMouvementEstUnRessortCritique() {
        guard !Motion.reduceMotion else { return }   // « Réduire les animations » coché : nil, exact
        #expect(Motion.value == .spring(response: 0.4, dampingFraction: 1.0))
    }

    // MARK: - « Un ForEach aux identités en double répète un élément »

    /// Le 08/10, quatre Wi-Fi le même jour, tous « Wi-Fi » : l'historique
    /// rend UNE entrée par sorte de réseau, les octets additionnés.
    @Test func quatreWiFiNeFontQuUneEntree() throws {
        let folder = AuditCodeTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reseau.json")
        try Data("""
        {"version": 1, "days": {"2026-10-08": {
          "routeur-a": {"label": "Wi-Fi", "kind": "wifi", "rx": 100, "tx": 1},
          "routeur-b": {"label": "Wi-Fi", "kind": "wifi", "rx": 200, "tx": 2},
          "routeur-c": {"label": "Wi-Fi", "kind": "wifi", "rx": 300, "tx": 3},
          "routeur-d": {"label": "Wi-Fi", "kind": "wifi", "rx": 400, "tx": 4},
          "partage-iphone": {"label": "iPhone", "kind": "hotspot", "rx": 50, "tx": 5}}}}
        """.utf8).write(to: url)
        let jour = try #require(NetworkTracker(url: url).history(days: 1, from: AuditCodeTests.networkDay("2026-10-08")).first)
        #expect(jour.usage.count == 2)
        #expect(Set(jour.usage.map(\.kind)).count == jour.usage.count, "deux entrées de la même sorte")
        #expect(jour.usage.first { $0.kind == .wifi }?.rx == 1_000)
    }

    // MARK: - « Une image disque se lit pleine à 100 % »

    @Test func uneImageEnLectureSeuleNeCompteJamais() {
        #expect(!DiskMonitor.counts(path: "/Volumes/FilmCraft 0.4.0", readOnly: true))
        #expect(DiskMonitor.counts(path: "/Volumes/Ssd 2", readOnly: false))
        #expect(DiskMonitor.counts(path: "/", readOnly: false))
        #expect(DiskMonitor.counts(path: "/", readOnly: true), "la racine, quoi qu'en dise la clé")
        #expect(!DiskMonitor.counts(path: "/System/Volumes/Data", readOnly: false))
    }

    // MARK: - « Le premier ping réveille la radio Wi-Fi »

    @Test func leSecondEchoMesureLaLiaison() {
        #expect(Ping.plusCourt(70, 3.4) == 3.4)
        #expect(Ping.plusCourt(nil, 5) == 5)
        #expect(Ping.plusCourt(nil, nil) == nil)
    }

    // MARK: - « Premiere traîne soixante processus qui n'exportent rien »

    @Test func lesMoteursWebDesExtensionsSontEcartes() {
        let cep = "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app/Contents/Frameworks/CEPHtmlEngine.framework/Helpers/CEPHtmlEngine Helper.app/Contents/MacOS/CEPHtmlEngine Helper"
        #expect(MediaTracker.ignore(path: cep))
        #expect(!MediaTracker.ignore(path: "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app/Contents/MacOS/Adobe Premiere Pro 2026"))
    }

    // MARK: - « Le journal SMART se lit sans root, mais pas à travers tous les boîtiers »

    @Test func unBoitierMuetDitNonPublieeSansInventer() {
        let boitier = PhysicalDisk(id: 1, bsdName: "disk10", model: "ASMT ASM246X", interconnect: "USB",
                                   isInternal: false, isRemovable: false, smartCapable: false, size: 2_000_000_000_000)
        let line = DiskLine(disk: boitier, volumes: [], read: nil, write: nil, health: nil)
        #expect(DiskProbe.healthText(line).hasPrefix("non publiée"))
        var capable = boitier
        capable.smartCapable = true
        #expect(DiskProbe.healthText(DiskLine(disk: capable, volumes: [], read: nil, write: nil)).hasPrefix("journal SMART illisible"))
    }
}

/// « Un seuil de 10 s pile donne un point toutes les 15 s » : des relevés
/// qui arrivent un peu en avance — la gigue de la minuterie — donnent
/// toujours un point par 10 s, pas un par 15.
@Suite(.serialized) struct PiegeDixSecondesTests {
    @Test func desRelevesEnAvanceDonnentToujoursUnPointParDixSecondes() throws {
        let folder = AuditCodeTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let noon = 1_791_720_000.0
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let recorder = SeriesRecorder(url: url, legacyURL: nil, persistent: { true })
        for i in 0..<24 {
            recorder.record("cpu.total", 0.5, now: noon + Double(i) * 5 - Double(i) * 0.01)
        }
        recorder.flush(timeout: 5, now: noon + 130)
        let db = SeriesDatabase(url: url, readOnly: true)
        let raw = db.buckets(key: "cpu.total", from: Int64(noon) - 10, to: Int64(noon) + 200, bucket: 1, now: Int64(noon) + 200)
        #expect(raw.count == 12, "\(raw.count) points pour 2 min")
    }
}

/// Pièges qui se vérifient sur la vraie machine, sans rien ouvrir.
@Suite(.serialized) struct PiegesMachineTests {
    /// « `pti_total_user` n'est pas en nanosecondes » : des unités de temps
    /// mach (41,67 ns sur ce M2 Max). Le processus des tests tourne 0,6 s
    /// sans s'arrêter : son groupe doit lire au moins 40 % d'un cœur — lu
    /// en nanosecondes, il en lirait 2.
    @Test func leTempsProcesseurEstEnUnitesMach() {
        let monitor = ProcessMonitor()
        _ = monitor.sample()
        let end = Date().addingTimeInterval(0.6)
        var spin = 0.0
        while Date() < end { spin += sin(spin) }
        let groups = monitor.sample()
        // Le processus des tests vit souvent dans le bundle d'Xcode : son
        // groupe est celui du bundle qui contient l'exécutable.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let mine = groups.first { group in group.bundlePath.map { exe.hasPrefix($0 + "/") } ?? false }
            ?? groups.first { $0.name == (exe as NSString).lastPathComponent }
        #expect(mine != nil, "groupe du processus des tests introuvable (\(exe))")
        #expect((mine?.cpu ?? 0) >= 40, "\(mine?.cpu ?? 0) % d'un cœur pour 0,6 s de calcul continu")
        #expect(spin.isFinite)
    }

    /// « Les batteries Bluetooth se lisent sans le Bluetooth » : aucun
    /// fichier de Pulse n'utilise IOBluetooth ni CoreBluetooth — leur premier
    /// appel fait surgir la demande d'autorisation de macOS. (Que leurs
    /// classes soient chargées ne prouve rien : d'autres cadres du système
    /// les chargent sans rien demander.)
    @Test func pulseNeTouchePasAuBluetooth() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for interdit in ["import CoreBluetooth", "import IOBluetooth", "CBCentralManager(", "IOBluetoothDevice."] {
                #expect(!text.contains(interdit), "\(file.lastPathComponent) : \(interdit)")
            }
        }
    }

    /// Une app lancée depuis Téléchargements, le Bureau ou un disque externe :
    /// lire son Info.plist ferait demander à macOS l'accès au dossier
    /// (26/10). Pulse ne le lit pas ; /Applications se lit comme avant.
    @Test func lesDossiersProtegesNeSontJamaisLus() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for chemin in ["\(home)/Downloads/Outil.app", "\(home)/Desktop/Outil.app", "\(home)/Documents/Outil.app",
                       "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Outil.app", "/Volumes/Ssd 2/Outil.app"] {
            #expect(ProtectedFolders.contains(chemin), "\(chemin)")
            #expect(ProtectedFolders.bundleInfo(chemin) == nil)
        }
        #expect(!ProtectedFolders.contains("/Applications/Safari.app"))
        #expect(!ProtectedFolders.contains("\(home)/Applications/Outil.app"))
        #expect(ProtectedFolders.bundleInfo("/System/Applications/Calculator.app")?["CFBundleIdentifier"] as? String
                == "com.apple.calculator")
    }

    /// Seuls les volumes locaux comptent, lus dans la table du noyau sans
    /// rien attendre d'un partage réseau (26/10) : la racine en est, jamais
    /// un volume système masqué.
    @Test func seulsLesVolumesLocauxComptent() {
        let locaux = DiskMonitor.localVolumes()
        #expect(locaux.contains { $0.url.path == "/" })
        #expect(locaux.allSatisfy { $0.url.path == "/" || $0.url.path.hasPrefix("/Volumes/") })
        #expect(!DiskMonitor.isTimeMachine(bsdName: locaux.first { $0.url.path == "/" }?.bsd ?? ""))
        #expect(!DiskMonitor.isTimeMachine(bsdName: ""))
        #expect(DiskMonitor.volumes(important: false).contains { $0.path == "/" })
    }
}

extension ForecastTests {
    /// « Le seuil de débit se règle par le bas » : 30 Mo/s d'export pendant
    /// 12 h (2,6 To par jour) sont un travail, pas une copie. À 400 Go par
    /// jour, le seuil d'avant écartait chacun de ces intervalles.
    @Test func unExportDeDouzeHeuresNEstPasUneCopie() {
        let pts = Self.points(hours: 12) { h in (1_500 - h * 108) * Self.go }
        let forecast = HistoryStore.forecast(points: pts, capacity: Self.ssd, free: UInt64(204 * Self.go))
        #expect(forecast?.ruptures == 0)
        #expect(forecast?.daysUntilFull != nil)
    }
}

/// « `RegisterEventHotKey` attend une position de touche, pas un
/// caractère » : sur l'ABC-AZERTY de cette machine, le M est à la place du
/// point-virgule du QWERTY (41) ; `kVK_ANSI_M` (46) y donne une virgule. Le
/// test d'origine envoyait 46 et passait quand même.
@Suite struct PiegeClavierTests {
    static func layout(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    @MainActor @Test func leRaccourciSuitLaDispositionDuClavier() throws {
        let azerty = try #require(Self.layout("com.apple.keylayout.ABC-AZERTY"))
        let qwerty = try #require(Self.layout("com.apple.keylayout.ABC"))
        #expect(AppDelegate.keyCode(for: "m", layout: azerty) == UInt32(kVK_ANSI_Semicolon))
        #expect(AppDelegate.keyCode(for: "m", layout: qwerty) == UInt32(kVK_ANSI_M))
    }
}

/// Les incidents, sur des dossiers fabriqués comme ceux de la machine.
@Suite struct PiegesIncidentsTests {
    static func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// « Adobe ne produit aucun `.ips` » : les plantages sont dans la base
    /// Crashpad, datés par un attribut étendu — la version fait partie du
    /// chemin, jamais codée en dur.
    @Test func lesPlantagesDAdobeSeLisentDansCrashpad() throws {
        let root = AuditCodeTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.path + "/Premiere Pro/26.0/SentryIO-db"
        try Self.write("minidump", base + "/pending/a.dmp")
        try Self.write("minidump", base + "/completed/b.dmp")
        try Self.write("minidump", base + "/completed/vieux.dmp")
        try Self.write("autre", base + "/completed/notes.txt")
        for (file, seconds) in [("pending/a.dmp", "1791720000"), ("completed/b.dmp", "1791723600"),
                                ("completed/vieux.dmp", "1700000000")] {
            #expect(setxattr(base + "/" + file, "org.chromium.crashpad.database.creation_time",
                             seconds, seconds.utf8.count, 0, 0) == 0)
        }
        let crashes = IncidentLog.crashes(since: Date(timeIntervalSince1970: 1_791_000_000), in: root.path)
        #expect(crashes.count == 2)
        #expect(crashes.allSatisfy { $0.kind == .crash && $0.app == "Premiere Pro" })
        #expect(Set(crashes.map(\.date.timeIntervalSince1970)) == [1_791_720_000, 1_791_723_600])
    }

    /// « Les diagnostics disk writes et cpu usage sont du bruit » : seuls les
    /// JetsamEvent comptent, et seulement leurs victimes au motif inquiétant.
    @Test func seulsLesProcessusTuesFauteDeMemoireComptent() throws {
        let folder = AuditCodeTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = """
        {"bug_type":"298","timestamp":"2026-10-10 12:00:00.00 +0200"}
        {"processes":[{"name":"Adobe Premiere Pro 2026","reason":"vm-pageshortage"},{"name":"spotlightknowledged.updater","reason":"per-process-limit"},{"name":"Finder"}]}
        """
        try Self.write(body, folder.path + "/JetsamEvent-2026-10-10-120000.ips")
        // Lus comme des JetsamEvent, ces deux-là compteraient chacun une
        // victime : c'est le filtre sur le nom qui les écarte.
        try Self.write("{\"bug_type\":\"45\"}\n{\"processes\":[{\"name\":\"Adobe Premiere Pro 2026\",\"reason\":\"disk-writes\"}]}",
                       folder.path + "/Adobe Premiere Pro 2026_2026-10-10-110000.disk_writes_resource.diag")
        try Self.write("{\"bug_type\":\"22\"}\n{\"processes\":[{\"name\":\"Adobe Premiere Pro 2026\",\"reason\":\"cpu\"}]}",
                       folder.path + "/Adobe Premiere Pro 2026_2026-10-10-100000.cpu_resource.diag")
        let events = IncidentLog.jetsamEvents(since: Date(timeIntervalSince1970: 1_790_000_000), in: folder.path)
        #expect(events.map(\.app) == ["Adobe Premiere Pro 2026"])
        #expect(events.first?.kind == .jetsam)
    }
}

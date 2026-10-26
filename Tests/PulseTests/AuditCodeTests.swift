import Foundation
import Testing
@testable import Pulse

/// Une valeur écrite sur une autre file et lue ici, sous verrou : ce que
/// Swift 6 exige d'un rappel `@Sendable` (17-audit-code).
final class Verrouille<Valeur>: @unchecked Sendable {
    private let verrou = NSLock()
    private var valeur: Valeur
    init(_ valeur: Valeur) { self.valeur = valeur }
    var lue: Valeur { verrou.lock(); defer { verrou.unlock() }; return valeur }
    func pose(_ nouvelle: Valeur) { verrou.lock(); valeur = nouvelle; verrou.unlock() }
}

/// Les défauts trouvés par la revue du code (chantier 17), chacun vu échouer
/// sans sa correction. Sur des fichiers jetables : jamais les vraies données.
@Suite struct AuditCodeTests {
    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-audit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: - history.json, élément par élément (règle n°2)

    /// Une session sans début, un enregistrement d'app qui n'est pas un
    /// objet, un point de série abîmé : chacun tombe SEUL. Avant, chaque
    /// tableau échouait en bloc sous son `try?`, et la sauvegarde suivante
    /// écrasait 90 jours de temps par app ou de sessions.
    @Test func unEnregistrementAbimeNEmportePasSonTableau() throws {
        let json = """
        {"version": 1,
         "apps": {"2026-10-10": {"com.adobe.PremierePro.26": {"name": "Premiere Pro", "focus": 3600},
                                 "com.apple.finder": {"name": "Finder"},
                                 "bizarre": 42}},
         "sessions": [{"bundleId": "com.adobe.PremierePro.26", "name": "Premiere Pro", "start": 1791700000, "end": 1791710000},
                      {"bundleId": "com.adobe.PremierePro.26", "name": "sans début"},
                      {"bundleId": "com.adobe.AfterEffects", "start": 1791715000}],
         "series": [{"t": 1791720000, "ram": 0.5, "swap": 0, "cpu": 0.2, "gpu": 0.1},
                    {"t": 1791720010, "ram": "beaucoup"},
                    "rien"],
         "volumes": {"UUID-SSD": [{"t": 1791720000, "free": 9e11}, 7]}}
        """
        let file = try JSONDecoder().decode(HistoryStore.File.self, from: Data(json.utf8))
        let day = try #require(file.apps["2026-10-10"])
        #expect(day.count == 2)
        #expect(day["com.adobe.PremierePro.26"]?.focus == 3600)
        #expect(day["com.apple.finder"]?.focus == 0, "un champ ajouté plus tard manque aux anciens jours")
        #expect(file.sessions.map(\.name) == ["Premiere Pro", "com.adobe.AfterEffects"])
        #expect(file.series.count == 2)
        #expect(file.series.first?.cpu == 0.2)
        #expect(file.volumes["UUID-SSD"]?.count == 1)
    }

    // MARK: - reseau.json

    static func networkDay(_ text: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    /// Une valeur d'une autre forme, un jour ou un réseau : sautée seule.
    /// Avant, la lecture d'un bloc rendait TOUT vide, et le premier relevé
    /// réécrivait le fichier deux secondes après le lancement.
    @Test func unReseauAbimeNEffacePasLeForfait() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reseau.json")
        try Data("""
        {"version": 1, "days": {
          "2026-10-07": {"partage-iphone": {"label": "iPhone", "kind": "hotspot", "rx": 1000, "tx": 200}, "abime": 3},
          "2026-10-08": 7,
          "2026-10-09": {"starlink": {"kind": "starlink", "rx": 500, "tx": 50}}}}
        """.utf8).write(to: url)
        let tracker = NetworkTracker(url: url)
        let days = tracker.history(days: 3, from: Self.networkDay("2026-10-09"))
        #expect(days.count == 3)
        #expect(days[0].usage.map(\.kind) == [.hotspot])
        #expect(days[0].usage.first?.rx == 1000)
        #expect(days[1].usage.isEmpty)
        #expect(days[2].usage.first?.kind == .starlink)
        #expect(Self.contents(folder) == ["reseau.json"], "un fichier lisible ne se met pas de côté")
    }

    /// Pas du JSON, ou des jours d'une autre forme : mis de côté, jamais
    /// écrasé.
    @Test func unReseauIllisibleEstMisDeCote() throws {
        for text in ["{\"days\": {\"2026-10-07\": ", "{\"days\": [1, 2, 3]}"] {
            let folder = Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("reseau.json")
            try Data(text.utf8).write(to: url)
            _ = NetworkTracker(url: url)
            #expect(Self.contents(folder) == ["reseau.illisible.json"], "\(text)")
            #expect(try String(contentsOf: folder.appendingPathComponent("reseau.illisible.json"), encoding: .utf8) == text)
        }
    }

    // MARK: - exports.json

    /// Une liste d'une autre forme, ou un fichier qui n'est pas du JSON : mis
    /// de côté. Avant, chargé vide, puis écrasé à la première sauvegarde par
    /// la seule fin du journal d'AME. Une liste absente reste un fichier vide
    /// lisible.
    @Test func desExportsIllisiblesSontMisDeCote() throws {
        for (text, aside) in [("{\"version\": 1, \"exports\": 5}", true), ("pas du json", true),
                              ("{\"version\": 1}", false)] {
            let folder = Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("exports.json")
            try Data(text.utf8).write(to: url)
            let history = ExportHistory(journal: nil, file: url)
            #expect(history.count == 0)
            #expect(Self.contents(folder) == [aside ? "exports.illisible.json" : "exports.json"], "\(text)")
        }
    }

    // MARK: - Mise de côté

    /// Un second fichier illisible ne supprime plus la copie du premier.
    @Test func uneSecondeMiseDeCoteGardeLaPremiere() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("reglages.json")
        let now = Date(timeIntervalSince1970: 1_791_720_000)
        try Data("premier".utf8).write(to: url)
        let first = try #require(Persistence.setAside(url, now: now))
        try Data("second".utf8).write(to: url)
        let second = try #require(Persistence.setAside(url, now: now))
        try Data("troisième".utf8).write(to: url)
        let third = try #require(Persistence.setAside(url, now: now))
        #expect(first.lastPathComponent == "reglages.illisible.json")
        #expect(second.lastPathComponent.hasPrefix("reglages.illisible-"))
        #expect(second.lastPathComponent.hasSuffix(".json"))
        #expect(third != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "premier")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(try String(contentsOf: third, encoding: .utf8) == "troisième")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Accessibilité (restes du 16)

    /// Une alerte qui ARRIVE dans la barre, panneau fermé, est annoncée à
    /// VoiceOver une fois ; pas au lancement, pas à chaque relevé, pas pour
    /// un avertissement.
    @Test func uneAlerteQuiArriveEstAnnonceeUneFois() {
        let alerte = MenuBarAlert(symbol: MenuBarAlert.alertSymbol, spoken: "alerte : Ssd 2 plein vers jeudi")
        let attention = MenuBarAlert(symbol: MenuBarAlert.warningSymbol, spoken: "attention : le swap monte")
        #expect(MenuBarController.announcement(wasAlerting: nil, alert: alerte) == nil, "lancement")
        #expect(MenuBarController.announcement(wasAlerting: false, alert: alerte)
                == "Pulse — alerte : Ssd 2 plein vers jeudi")
        #expect(MenuBarController.announcement(wasAlerting: true, alert: alerte) == nil, "déjà dite")
        #expect(MenuBarController.announcement(wasAlerting: false, alert: attention) == nil)
        #expect(MenuBarController.announcement(wasAlerting: false, alert: nil) == nil)
    }

    /// Plus aucun conteneur `.ignore` : il sort en AXUnknown, que VoiceOver
    /// ne lit pas (piège du README) — les deux derniers étaient dans la
    /// barre de menus (09) et les ventilateurs (14).
    @Test func aucunConteneurIgnoreNeResteMuet() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("accessibilityElement(children: .ignore)"), "\(file.lastPathComponent)")
        }
    }

    // MARK: - Sorties sur Internet

    /// IP publique et sonde 1.1.1.1 : cochées, elles ne partent QUE de
    /// l'app installée. `swift test` tourne dans un `.xctest`, comme
    /// `--banc --ecrit` hors de l'app : jamais. Avant, la garde était la
    /// persistance, que `--banc --ecrit` rallume (`./verifie.sh`).
    @Test func rienNeSortSurInternetHorsDeLApp() {
        #expect(!Extras.appReelle)
        #expect(!MoniteurReseau.sortiePermise(true))
        #expect(!MoniteurReseau.sortiePermise(false))
    }
}

/// La base des séries tenue par un autre processus au-delà de 2 s n'est
/// plus mise de côté : seule une base ABÎMÉE l'est.
@Suite(.serialized) struct AuditBaseTests {
    @Test func uneBaseTenueAilleursNEstPasMiseDeCote() throws {
        let folder = AuditCodeTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(SeriesDatabase.fileName)
        let noon = Date(timeIntervalSince1970: 1_791_720_000)
        do {
            let created = SeriesDatabase(url: url, readOnly: false, now: noon)
            #expect(created.state == .ready)
            try created.insert([.init(key: "cpu.total", t: 1_791_720_000, v: 0.5)], now: noon)
            created.close()
        }
        // Un autre écrivain tient la base, verrou exclusif.
        let holder = try SQLiteConnection(path: url.path, readOnly: false)
        try holder.exec("BEGIN EXCLUSIVE")
        let blocked = SeriesDatabase(url: url, readOnly: false, now: noon)
        if case .unavailable = blocked.state {} else {
            Issue.record("état attendu : momentanément illisible, lu : \(blocked.state)")
        }
        #expect(blocked.setAside.isEmpty)
        #expect(AuditCodeTests.contents(folder).filter { $0.contains("illisible") }.isEmpty,
                "une base saine a été renommée")
        blocked.close()
        try holder.exec("COMMIT")

        let reopened = SeriesDatabase(url: url, readOnly: false, now: noon)
        #expect(reopened.state == .ready)
        #expect(reopened.stats(for: "cpu.total")?.rows[.raw] == 1, "le point d'avant est perdu")
        reopened.close()
    }
}

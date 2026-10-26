import AppKit
import Foundation
import Testing
@testable import Pulse

/// La barre de menus (chantier 09) : réglages tolérants, composition,
/// largeur figée, alerte. Sans `Sampler` : la composition se rejoue sur des
/// relevés écrits à la main (`MenuBarComposer.Reading`), rien n'est lu ni
/// écrit chez Isma.
@MainActor
@Suite struct MenuBarTests {
    static func decode(_ json: String) throws -> PulseSettings {
        try JSONDecoder().decode(PulseSettings.self, from: Data(json.utf8))
    }

    static func verdict(_ level: VerdictLevel) -> Verdict {
        Verdict(rule: level == .alert ? 4 : level == .warning ? 6 : 12, ruleName: "essai", level: level,
                symbol: "checkmark.circle", phrase: "Ssd 2 plein vers jeudi", evidence: "", also: [])
    }

    /// Un relevé : mémoire, disque, débit, processeur, aux valeurs données.
    static func reading(_ settings: PulseSettings, memory: Double = 0.63, disk: Double = 0.85,
                        rates: (String, String)? = ("6,0k", "7,5k"), cpu: Double = 0.44,
                        level: VerdictLevel = .muted) -> MenuBarComposer.Reading {
        let values: [String: MenuBarSegment?] = [
            "memoire": MenuBarSegment(label: "MÉM", value: Fmt.percent(memory), spoken: "mémoire", fraction: memory),
            "disques": MenuBarSegment(label: "SSD 2", value: Fmt.occupancy(disk), spoken: "disque", fraction: disk),
            "reseau": rates.map { MenuBarSegment(label: "↑" + $0.0, value: "↓" + $0.1, spoken: "débit") },
            "processeur": MenuBarSegment(label: "CPU", value: Fmt.percent(cpu), spoken: "processeur", fraction: cpu),
            "energie": MenuBarSegment(label: "BAT", value: "74 %", spoken: "batterie", fraction: 0.74),
            "capteurs": MenuBarSegment(label: "CPU", value: "62°", spoken: "processeur 62 degrés"),
            "horloges": MenuBarSegment(label: "SARAH", value: "14:05", spoken: "Sarah, 14 h 05"),   // 18-extras
            "calendrier": MenuBarSegment(label: "AGENDA", value: "25 min", spoken: "Appel client, dans 25 min"),   // 18-extras
            "meteo": MenuBarSegment(label: "MÉTÉO", value: "18°", spoken: "Plutôt dégagé, 18 degrés"),   // 18-extras
        ]
        let segments = MenuBarCatalog.items(settings).filter(\.shown).map { (item: $0, segment: values[$0.id] ?? nil) }
        // Trois relevés de débit, pour le graphe en miroir.
        let trail = [(5_000.0, 20_000.0), (60_000.0, 900_000.0), (8_000.0, 30_000.0)].map {
            NetworkSample(connected: true, rxRate: $0.1, txRate: $0.0)
        }
        return MenuBarComposer.Reading(segments: segments, verdict: verdict(level), trail: trail,
                                       diskLabels: ["MACIN.", "SSD 2", "EXTRE."])
    }

    // MARK: Réglages

    /// Un fichier d'avant ce chantier n'a pas la clé : la barre garde son
    /// allure (mémoire, disque, débit), le reste éteint.
    @Test func reglagesDAvant() throws {
        let settings = try Self.decode(#"{"version": 1, "layout": {"columns": 2}}"#)
        #expect(settings.menuBar == MenuBarSettings())
        let items = MenuBarCatalog.items(settings)
        #expect(items.filter(\.shown).map(\.id) == ["memoire", "disques", "reseau"])
        #expect(items.allSatisfy { $0.style == .text })
        #expect(Set(items.map(\.id)) == Set(MenuBarCatalog.entries.map(\.id)))
    }

    /// Règle dure n°2 : un mode inconnu, un style illisible, un élément sans
    /// identifiant ne coûtent que leur propre valeur.
    @Test func reglagesTolerants() throws {
        let settings = try Self.decode(#"""
        {"menuBar": {"mode": "spirale", "alert": 3,
                     "items": [{"id": "processeur", "shown": true, "style": "anneau"},
                               {"shown": true},
                               {"id": "disques", "shown": "oui", "style": "hologramme"},
                               {"id": "inconnu", "shown": true, "style": "texte"}]}}
        """#)
        #expect(settings.menuBar.mode == .combined)
        #expect(settings.menuBar.alert == .alerts)
        let items = MenuBarCatalog.items(settings)
        #expect(items.first == MenuBarSettings.Item(id: "processeur", shown: true, style: .ring))
        #expect(items[1] == MenuBarSettings.Item(id: "disques", shown: false, style: .text))
        #expect(!items.contains { $0.id == "inconnu" })
    }

    @Test func allerRetour() throws {
        var settings = PulseSettings()
        settings.menuBar.mode = .separate
        settings.menuBar.alert = .warnings
        MenuBarCatalog.setStyle(.graph, id: "memoire", in: &settings)
        MenuBarCatalog.setShown(true, id: "energie", in: &settings)
        let data = try SettingsStore.encode(settings)
        #expect(try JSONDecoder().decode(PulseSettings.self, from: data) == settings)
    }

    /// Règle dure n°7 : ni jauge ni anneau sans total réel — un réglage écrit
    /// à la main retombe sur le texte.
    @Test func stylesSansDenominateur() throws {
        let settings = try Self.decode(#"""
        {"menuBar": {"items": [{"id": "reseau", "shown": true, "style": "jauge"},
                               {"id": "capteurs", "shown": true, "style": "anneau"}]}}
        """#)
        let items = MenuBarCatalog.items(settings)
        #expect(items.first { $0.id == "reseau" }?.style == .text)
        #expect(items.first { $0.id == "capteurs" }?.style == .text)
        #expect(MenuBarCatalog.entry("reseau")?.styles == [.text, .graph])
        #expect(MenuBarCatalog.entry("capteurs")?.styles == [.text])
        var copy = settings
        MenuBarCatalog.setStyle(.ring, id: "reseau", in: &copy)
        #expect(MenuBarCatalog.items(copy).first { $0.id == "reseau" }?.style == .text)
    }

    /// Capteurs tient son interrupteur lui-même : la page de la barre et la
    /// page Capteurs écrivent la même valeur, celle dont dépend la cadence
    /// de lecture.
    @Test func interrupteurDuModule() {
        var settings = PulseSettings()
        #expect(MenuBarCatalog.items(settings).first { $0.id == "capteurs" }?.shown == false)
        MenuBarCatalog.setShown(true, id: "capteurs", in: &settings)
        #expect(settings.module("capteurs").options[SensorsModule.barOption] == .bool(true))
        #expect(MenuBarCatalog.items(settings).first { $0.id == "capteurs" }?.shown == true)
        // Un « shown » écrit dans la liste de la barre ne prime pas.
        settings.menuBar.items = [MenuBarSettings.Item(id: "capteurs", shown: false, style: .text)]
        #expect(MenuBarCatalog.items(settings).first { $0.id == "capteurs" }?.shown == true)
    }

    @Test func ordre() {
        var settings = PulseSettings()
        let before = MenuBarCatalog.items(settings).map(\.id)
        let cpu = before.firstIndex(of: "processeur")!
        MenuBarCatalog.move(fromOffsets: IndexSet(integer: cpu), toOffset: 0, in: &settings)
        MenuBarCatalog.setShown(true, id: "processeur", in: &settings)
        let contents = MenuBarComposer.contents(Self.reading(settings), settings: settings, history: nil)
        #expect(contents.count == 1)
        #expect(contents[0].pieces.map(\.id) == ["processeur", "memoire", "disques", "reseau"])
    }

    // MARK: Largeur figée

    /// La largeur ne dépend jamais des valeurs : « 0 % » et « 100 % », un
    /// débit nul ou à 888 Mo/s, hors ligne ou non, donnent la même image.
    @Test func largeurFigee() {
        var settings = PulseSettings()
        MenuBarCatalog.setShown(true, id: "processeur", in: &settings)
        let calm = MenuBarComposer.contents(Self.reading(settings, memory: 0.05, disk: 0.1, rates: ("\u{2007}\u{2007}0k", "\u{2007}\u{2007}0k"), cpu: 0.01),
                                            settings: settings, history: nil)[0]
        let busy = MenuBarComposer.contents(Self.reading(settings, memory: 1, disk: 1, rates: ("888M", "888M"), cpu: 1, level: .alert),
                                            settings: settings, history: nil)[0]
        let offline = MenuBarComposer.contents(Self.reading(settings, rates: nil), settings: settings, history: nil)[0]
        #expect(busy.alert != nil && calm.alert == nil)
        let width = MenuBarDrawing.size(calm).width
        #expect(MenuBarDrawing.size(busy).width == width)
        #expect(MenuBarDrawing.size(offline).width == width)
        #expect(MenuBarDrawing.size(calm.widest).width == width)
        #expect(MenuBarDrawing.size(calm).height == 22)
    }

    /// La place du symbole est réservée tant que l'alerte est permise, et
    /// rendue à la barre quand elle ne l'est plus.
    @Test func placeDeLAlerte() {
        var settings = PulseSettings()
        let with = MenuBarComposer.contents(Self.reading(settings), settings: settings, history: nil)[0]
        settings.menuBar.alert = .never
        let without = MenuBarComposer.contents(Self.reading(settings, level: .alert), settings: settings, history: nil)[0]
        #expect(without.alert == nil)
        #expect(MenuBarDrawing.size(with).width - MenuBarDrawing.size(without).width
                == MenuBarDrawing.alertWidth + MenuBarDrawing.alertGap)
    }

    /// Chaque style a sa largeur, constante elle aussi.
    @Test func stylesFiges() {
        for style in MenuBarSettings.Style.allCases {
            var settings = PulseSettings()
            for entry in MenuBarCatalog.entries where entry.styles.contains(style) {
                MenuBarCatalog.setShown(true, id: entry.id, in: &settings)
                MenuBarCatalog.setStyle(style, id: entry.id, in: &settings)
            }
            let low = MenuBarComposer.contents(Self.reading(settings, memory: 0, disk: 0, cpu: 0), settings: settings, history: nil)[0]
            let high = MenuBarComposer.contents(Self.reading(settings, memory: 1, disk: 1, cpu: 1), settings: settings, history: nil)[0]
            #expect(MenuBarDrawing.size(low).width == MenuBarDrawing.size(high).width, "style \(style)")
        }
    }

    // MARK: Composition

    @Test func unElementParSegment() {
        var settings = PulseSettings()
        settings.menuBar.mode = .separate
        let contents = MenuBarComposer.contents(Self.reading(settings, level: .alert), settings: settings, history: nil)
        #expect(contents.map { $0.pieces.map(\.id) } == [["memoire"], ["disques"], ["reseau"]])
        #expect(contents.map(\.reservesAlert) == [true, false, false])
        #expect(contents[0].alert?.symbol == MenuBarAlert.alertSymbol)
        #expect(contents.dropFirst().allSatisfy { $0.alert == nil })
    }

    /// Sans aucun segment, l'élément garde une icône où cliquer.
    @Test func rienAffiche() {
        var settings = PulseSettings()
        for entry in MenuBarCatalog.entries { MenuBarCatalog.setShown(false, id: entry.id, in: &settings) }
        let contents = MenuBarComposer.contents(Self.reading(settings), settings: settings, history: nil)
        #expect(contents.count == 1 && contents[0].pieces.isEmpty)
        #expect(MenuBarDrawing.size(contents[0]).width > 10)
    }

    /// Le symbole suit le niveau du verdict et le réglage : plein pour une
    /// alerte, contour pour un avertissement s'il est demandé, rien sinon.
    @Test func symboleDuVerdict() {
        #expect(MenuBarComposer.alertMark(Self.verdict(.alert), .alerts)?.symbol == MenuBarAlert.alertSymbol)
        #expect(MenuBarComposer.alertMark(Self.verdict(.alert), .warnings)?.symbol == MenuBarAlert.alertSymbol)
        #expect(MenuBarComposer.alertMark(Self.verdict(.warning), .alerts) == nil)
        #expect(MenuBarComposer.alertMark(Self.verdict(.warning), .warnings)?.symbol == MenuBarAlert.warningSymbol)
        #expect(MenuBarComposer.alertMark(Self.verdict(.alert), .never) == nil)
        #expect(MenuBarComposer.alertMark(Self.verdict(.muted), .warnings) == nil)
        #expect(MenuBarComposer.alertMark(Self.verdict(.alert), .alerts)?.spoken == "alerte : Ssd 2 plein vers jeudi")
    }

    /// Le mini-graphe : un point par relevé, douze gardés, le dernier à
    /// droite.
    @Test func historique() {
        let history = MenuBarHistory()
        let start = Date()
        for step in 0..<20 {
            history.record(["memoire": Double(step) / 20], now: start.addingTimeInterval(Double(step) * 5))
        }
        // Un second appel dans la même seconde ne compte pas.
        history.record(["memoire": 1], now: start.addingTimeInterval(19 * 5 + 1))
        #expect(history.values["memoire"]?.count == MenuBarHistory.length)
        #expect(history.values["memoire"]?.last == 19.0 / 20)
    }

    /// Le débit affiché ne bouge que d'au moins 30 % ou d'une unité : les
    /// écarts du repos (« 6,0k », « 7,5k », « 6,8k ») ne redessinent rien,
    /// un envoi de rushes passe aussitôt.
    @Test func debitFiltre() {
        let filter = MenuBarRateFilter()
        #expect(filter.filter(up: 6_000, down: 7_500) == (6_000, 7_500))
        #expect(filter.filter(up: 7_400, down: 6_800) == (6_000, 7_500))     // +23 %, −9 %
        #expect(filter.filter(up: 8_100, down: 7_500) == (6_000, 7_500))     // +2,1 ko/s : bruit
        #expect(filter.filter(up: 9_500, down: 7_500) == (9_500, 7_500))     // +3,5 ko/s : affiché
        #expect(filter.filter(up: 9_500, down: 2_400_000) == (9_500, 2_400_000))
        #expect(filter.filter(up: 9_500, down: 2_100_000) == (9_500, 2_400_000))  // −12 %
        #expect(filter.filter(up: 9_500, down: 980_000) == (9_500, 980_000))      // M → k
        #expect(filter.filter(up: 40_000, down: 980_000) == (40_000, 980_000))    // ×4
        #expect(filter.filter(up: 48_000, down: 980_000) == (40_000, 980_000))    // +20 %
        // Sous 1 ko/s, tout est « 0k » : rien ne bouge.
        let idle = MenuBarRateFilter()
        _ = idle.filter(up: 200, down: 900)
        #expect(idle.filter(up: 700, down: 100) == (200, 900))
        // Le texte affiché et l'infobulle suivent le chiffre gardé.
        var settings = PulseSettings()
        settings.menuBar.alert = .never
        var reading = Self.reading(settings)
        reading.rates = (6_000, 7_500)
        let shown = MenuBarRateFilter()
        let first = MenuBarComposer.contents(reading, settings: settings, history: nil, rates: shown)
        reading.rates = (7_000, 7_000)
        let second = MenuBarComposer.contents(reading, settings: settings, history: nil, rates: shown)
        #expect(first == second)
        #expect(second[0].pieces.last?.label == "↑6,0k")
    }

    /// En texte, la part n'est pas dessinée : un relevé qui garde « 63 % »
    /// ne change rien à l'image, donc rien n'est redessiné.
    @Test func rienARedessiner() {
        let settings = PulseSettings()
        let a = MenuBarComposer.contents(Self.reading(settings, memory: 0.6301), settings: settings, history: nil)
        let b = MenuBarComposer.contents(Self.reading(settings, memory: 0.6342), settings: settings, history: nil)
        #expect(a == b)
    }

    // MARK: Dessin

    /// L'image n'est pas transparente (piège du README : un élément peut
    /// réserver sa place et ne rien montrer), et sa taille en points est
    /// celle de la composition.
    @Test func imageDessinee() throws {
        let settings = PulseSettings()
        let content = MenuBarComposer.contents(Self.reading(settings, level: .alert), settings: settings, history: nil)[0]
        let image = MenuBarDrawing.image(content, scale: 2)
        #expect(image.isTemplate)
        #expect(image.size == MenuBarDrawing.size(content))
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == Int(image.size.width * 2))
        #expect(Self.opaquePixels(rep) > 500)
    }

    /// Chaque style dessine quelque chose, segment par segment.
    @Test func chaqueStyleDessine() throws {
        for style in MenuBarSettings.Style.allCases {
            for entry in MenuBarCatalog.entries where entry.styles.contains(style) {
                var settings = PulseSettings()
                settings.menuBar.alert = .never
                for other in MenuBarCatalog.entries { MenuBarCatalog.setShown(other.id == entry.id, id: other.id, in: &settings) }
                MenuBarCatalog.setStyle(style, id: entry.id, in: &settings)
                let content = MenuBarComposer.contents(Self.reading(settings), settings: settings, history: nil)[0]
                #expect(content.pieces.map(\.id) == [entry.id])
                let rep = try #require(MenuBarDrawing.image(content, scale: 2).representations.first as? NSBitmapImageRep)
                #expect(Self.opaquePixels(rep) > 20, "\(entry.id) en \(style)")
            }
        }
    }

    static func opaquePixels(_ rep: NSBitmapImageRep) -> Int {
        var opaque = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 } }
        return opaque
    }
}

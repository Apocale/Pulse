import AppKit
import Foundation
import Testing
@testable import Pulse

/// La persistance des réglages (`reglages.json`) : règle dure n°2, un champ
/// absent ou illisible ne coûte jamais le reste.
@MainActor
@Suite struct SettingsTests {
    /// Un dossier jetable par test : jamais l'Application Support d'Isma.
    static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-reglages-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func decode(_ json: String) throws -> PulseSettings {
        try JSONDecoder().decode(PulseSettings.self, from: Data(json.utf8))
    }

    static var sample: PulseSettings {
        var s = PulseSettings()
        s.layout.columns = 3
        s.layout.order = ["memoire", "processeur", "reseau"]
        s.modules["processeur"] = ModuleSettings(enabled: true, column: 2, compact: true, appCount: 6,
                                                 tints: ["utilisateur": "system:indigo"],
                                                 options: ["anneaux": .bool(false), "seuil": .int(80), "vue": .text("barres")])
        s.modules["reseau"] = ModuleSettings(enabled: false)
        s.display.rateUnit = .bits
        s.refresh.openInterval = 2
        s.refresh.closedInterval = 10
        return s
    }

    @Test func allerRetour() throws {
        let data = try SettingsStore.encode(Self.sample)
        #expect(try JSONDecoder().decode(PulseSettings.self, from: data) == Self.sample)
    }

    /// Le fichier d'une version plus ancienne, sans les champs ajoutés
    /// depuis : tout ce qui manque prend sa valeur par défaut.
    @Test func clesAbsentesValeursParDefaut() throws {
        #expect(try Self.decode("{}") == PulseSettings())
        let partial = try Self.decode(#"{"layout": {"columns": 1}, "modules": {"memoire": {"compact": true}}}"#)
        #expect(partial.layout.columns == 1)
        #expect(partial.layout.order == [])
        #expect(partial.module("memoire") == ModuleSettings(compact: true))
        #expect(partial.module("memoire").enabled == nil)
        #expect(partial.display == DisplaySettings())
        #expect(partial.refresh == RefreshSettings())
    }

    /// Un champ au mauvais type retombe SEUL sur sa valeur par défaut ; une
    /// clé inconnue — écrite par une version plus récente — est ignorée.
    @Test func champIllisibleSeul() throws {
        let s = try Self.decode(#"""
        {"layout": {"columns": "trois", "order": ["memoire", 42, "reseau"]},
         "display": {"rateUnit": "baud"},
         "refresh": {"openInterval": "vite", "closedInterval": 10},
         "futur": {"quelque": "chose"},
         "modules": {"memoire": {"enabled": "oui", "appCount": 6, "tints": {"apps": 3, "systeme": "alert"}}}}
        """#)
        #expect(s.layout.columns == 2)
        #expect(s.layout.order == ["memoire", "reseau"])
        #expect(s.display.rateUnit == .bytes)
        #expect(s.refresh.openInterval == 1.5)
        #expect(s.refresh.closedInterval == 10)
        #expect(s.module("memoire").enabled == nil)
        #expect(s.module("memoire").appCount == 6)
        #expect(s.module("memoire").tints == ["systeme": "alert"])
    }

    /// Un module abîmé n'emporte pas les autres.
    @Test func unModuleAbimeNEmportePasLesAutres() throws {
        let s = try Self.decode(#"{"modules": {"memoire": "n'importe quoi", "reseau": {"enabled": false}}}"#)
        #expect(s.modules["memoire"] == nil)
        #expect(s.module("reseau").enabled == false)
    }

    /// Le magasin : écrit, relu à l'identique par une nouvelle instance.
    @Test func ecritPuisRelu() throws {
        let url = Self.scratch().appendingPathComponent("reglages.json")
        let store = SettingsStore(url: url, writes: true)
        #expect(store.settings == PulseSettings())
        store.settings = Self.sample
        store.save()
        #expect(SettingsStore(url: url, writes: true).settings == Self.sample)
    }

    /// Illisible malgré la tolérance — pas même du JSON — : mis de côté,
    /// jamais effacé ; l'app repart des réglages par défaut.
    @Test func fichierIllisibleMisDeCote() throws {
        let dir = Self.scratch()
        let url = dir.appendingPathComponent("reglages.json")
        try Data("pas du json".utf8).write(to: url)
        let store = SettingsStore(url: url, writes: true)
        #expect(store.settings == PulseSettings())
        let backup = dir.appendingPathComponent("reglages.illisible.json")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "pas du json")
    }

    /// Export puis import : les mêmes réglages. Un import de n'importe quoi
    /// est refusé et ne touche à rien.
    @Test func exportEtImport() throws {
        let dir = Self.scratch()
        let store = SettingsStore(url: dir.appendingPathComponent("reglages.json"), writes: true)
        store.settings = Self.sample
        let exported = dir.appendingPathComponent("export.json")
        try store.export(to: exported)

        let other = SettingsStore(url: dir.appendingPathComponent("autre.json"), writes: true)
        try other.importSettings(from: exported)
        #expect(other.settings == Self.sample)

        let garbage = dir.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: garbage)
        #expect(throws: (any Error).self) { try other.importSettings(from: garbage) }
        #expect(other.settings == Self.sample)
    }

    /// Panneau fermé, jamais sous 5 s : le budget de moins de 1 % d'un cœur
    /// en dépend. Une valeur éditée à la main retombe sur le choix proche.
    @Test func cadenceBornee() {
        var refresh = RefreshSettings()
        refresh.closedInterval = 0.5
        refresh.openInterval = 0.01
        #expect(refresh.sanitized.closedInterval == 5)
        #expect(refresh.sanitized.openInterval == 1)
        refresh.closedInterval = .nan
        #expect(refresh.sanitized.closedInterval == 5)
        refresh.openInterval = 2.4
        #expect(refresh.sanitized.openInterval == 2)
    }
}

/// Les unités réglables : le débit en octets reste au caractère près ce
/// qu'il était, en bits il se lit comme un forfait.
@Suite struct RateUnitTests {
    @Test func enOctetsRienNeChange() {
        for value in [0.0, 950, 36_200, 2_400_000, 1.2e9] {
            #expect(Fmt.rate(value, .bytes) == "\(Fmt.bytes(value))/s")
        }
    }

    @Test func enBits() {
        #expect(Fmt.rate(125_000, .bits) == "1,0\u{00A0}Mbit/s")
        #expect(Fmt.rate(11_837, .bits) == "94,7\u{00A0}kbit/s")
        #expect(Fmt.rate(30e6, .bits) == "240\u{00A0}Mbit/s")
        #expect(Fmt.rate(50, .bits) == "400\u{00A0}bit/s")
    }

    @Test func cadenceLisible() {
        #expect(Fmt.decimalSeconds(1.5) == "1,5\u{00A0}s")
        #expect(Fmt.decimalSeconds(5) == "5\u{00A0}s")
    }
}

/// Les teintes réglables : refusées sous 3:1 sur le fond des cartes, dans
/// l'une ou l'autre apparence (règle dure n°4).
@MainActor
@Suite struct TintTests {
    /// Les cinq rôles de `Palette` passent, avec les ratios que mesure
    /// `outils/contraste.swift` sur le rendu (11/10).
    @Test func lesRolesDePalettePassent() throws {
        for role in PaletteRole.allCases {
            let choice = TintChoice(raw: role.rawValue)
            let ratios = try #require(choice.ratios)
            #expect(choice.passes, "\(role) : \(ratios)")
        }
        // À 0,05 près : l'outil lit le fond sur le rendu, au 1/255 près.
        let blue = try #require(TintChoice(raw: "data").ratios)
        #expect(abs(blue.dark - 3.55) < 0.05 && abs(blue.light - 3.39) < 0.05, "bleu : \(blue)")
    }

    /// Le jaune système est illisible sur fond clair : refusé.
    @Test func leJauneEstRefuse() throws {
        let yellow = TintChoice(raw: "system:yellow")
        let ratios = try #require(yellow.ratios)
        #expect(ratios.light < 3)
        #expect(!yellow.passes)
        #expect(yellow.color == nil)
        #expect(!TintChoice(raw: "#FFFF00").passes)
    }

    @Test func inconnueRefusee() {
        #expect(TintChoice(raw: "system:licorne").nsColor == nil)
        #expect(!TintChoice(raw: "#12").passes)
        #expect(!TintChoice(raw: "").passes)
    }
}

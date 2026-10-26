import Foundation
import Testing
@testable import Pulse

/// Chantier 05 : « qu'est-ce qui remplit Ssd 2 ? », sur des arrivées
/// fabriquées comme celles que rend l'index Spotlight.
@Suite struct RemplissageTests {
    static let go = 1e9
    static let now = Date(timeIntervalSince1970: 1_791_700_000)

    static func arrival(_ path: String, _ gigabytes: Double, hoursAgo: Double) -> FillReport.Arrival {
        .init(relativePath: path, bytes: gigabytes * go, added: now.addingTimeInterval(-hoursAgo * 3600))
    }

    /// Le relevé du 11/10 sur Ssd 2, en miniature : les rushes du client A
    /// arrivés hier, ceux du client B en début de semaine.
    @Test func lesDossiersSeClassentParOctetsArrives() {
        let report = FillReport.build(volumeKey: "UUID", volumeName: "Ssd 2", arrivals: [
            Self.arrival("Client A/01 Rushes - Client A/Tournage 22-09-26/A001.MXF", 20, hoursAgo: 3),
            Self.arrival("Client A/01 Rushes - Client A/Tournage 22-09-26/A002.MXF", 9, hoursAgo: 5),
            Self.arrival("Client A/01 Rushes - Client A/Tournage 14-09-26/B001.MXF", 356, hoursAgo: 60),
            Self.arrival("Client B/01 Rushes - Client B/P__B0752.MOV", 349, hoursAgo: 100),
            Self.arrival("Client A/04 Assets - Client A/logo.png", 0.1, hoursAgo: 20),
            Self.arrival("vieux.mov", 50, hoursAgo: 24 * 8),          // hors fenêtre
            Self.arrival("notes.txt", 0.001, hoursAgo: 1),             // à la racine
        ], now: Self.now)
        #expect(report.week.map(\.path) == ["Client A/01 Rushes - Client A",
                                             "Client B/01 Rushes - Client B",
                                             "Client A/04 Assets - Client A", "(racine)"])
        #expect(report.day.first?.path == "Client A/01 Rushes - Client A")
        #expect(abs(report.day.first!.bytes - 29 * Self.go) < 1)
        #expect(abs(report.weekBytes - (29 + 356 + 349 + 0.1 + 0.001) * Self.go) < 1)
        #expect(report.dayFiles == 4)
        #expect(report.weekFiles == 6)
    }

    /// « Client A › 01 Rushes » : le client répété en suffixe s'efface.
    @Test func leLibelleRetireLeClientRepete() {
        #expect(FillFolder(path: "Client A/01 Rushes - Client A", bytes: 0, files: 0).label == "Client A › 01 Rushes")
        #expect(FillFolder(path: "SND/2026-07 Juillet - SND", bytes: 0, files: 0).label == "SND › 2026-07 Juillet")
        #expect(FillFolder(path: "Client C/03 Exports", bytes: 0, files: 0).label == "Client C › 03 Exports")
        #expect(FillFolder(path: "Journal Isma", bytes: 0, files: 0).label == "Journal Isma")
    }

    @Test func unFichierSeRangeSurDeuxNiveaux() {
        #expect(FillReport.folderKey("a.mov") == "(racine)")
        #expect(FillReport.folderKey("Client/a.mov") == "Client")
        #expect(FillReport.folderKey("Client/01 Rushes/Jour 1/a.mov") == "Client/01 Rushes")
    }

    /// Le bilan se relit d'un disques.json écrit par une autre version (règle
    /// dure n°2) : champs manquants, champ inconnu.
    @Test func unBilanSeRelitMalgreUnSchemaDifferent() throws {
        let json = #"{"volumeKey":"K","volumeName":"Ssd 2","weekBytes":8.1e11,"week":[{"path":"A/B","bytes":3e11}],"inconnu":1}"#
        let r = try JSONDecoder().decode(FillReport.self, from: Data(json.utf8))
        #expect(r.weekBytes == 8.1e11)
        #expect(r.day.isEmpty)
        #expect(r.week.first?.files == 0)
    }
}

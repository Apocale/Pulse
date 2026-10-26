import Foundation
import Testing
@testable import Pulse

/// Le chantier 08 : journal d'AME, historique des exports, fréquences du GPU.
@Suite struct MediaTests {
    /// Un exports.json jetable, jamais celui de l'app.
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pulse-exports-\(UUID().uuidString).json")
    }

    /// Un extrait réel du journal d'AME (11/10), rejoué tel quel : un export
    /// réussi, un avec avertissement suivi de ses polices manquantes, un
    /// échec, et les lignes de file qui ne sont pas des exports.
    static let journal = """

    Log File Created: 03/25/2026 11:39:00 PM
    -----------------------------------------


    10/11/2026 01:57:36 AM : Queue Started


     - Source File: /var/folders/t3/hwbqh4n11g96ymmyb_l9pt6r0000gn/T/Client A 6_11.prproj
     - Output File: /Volumes/Ssd 2/Client A/03 Exports - Client A/11:10/2.mp4
     - Preset Used: Match Source - Adaptive Low Bitrate
     - Video: 1080x1920 (1,0), 30 fps, Progressive, Rec. 709, 203 (75% HLG, 58% PQ), Hardware Encoding, 00:03:14:17
     - Audio: AAC, 128 kbps, 48 kHz, Stereo
     - Bitrate: VBR, 1 pass, Target 5.70 Mbps
     - Encoding Time: 00:00:12
    10/11/2026 01:57:51 AM : File Successfully Encoded


    10/11/2026 01:57:51 AM : Queue Stopped


     - Source File: /var/folders/t3/hwbqh4n11g96ymmyb_l9pt6r0000gn/T/Pod Client B 2.prproj
     - Output File: /Volumes/SSD 1/Client B/Sept/Interview 5/Export/Interview 5.mp4
     - Preset Used:
     - Encoding Time: 00:08:09
    10/11/2026 03:54:14 AM : File Encoded with warning
    -------------------------------------

    Missing Font: "Halagar ExtraBold"

     - Source File: /var/folders/t3/hwbqh4n11g96ymmyb_l9pt6r0000gn/T/SND Sept_5.prproj
     - Output File: /Volumes/SSD 1/Client B/Sept/Foot 2/2_2.mp4
     - Encoding Time: 00:01:20
    10/02/2026 05:13:09 PM : Encoding Failed
    """

    @Test func leJournalDAMEDonneLesExportsEtLeurIssue() throws {
        let records = AMEJournal.parse(Self.journal)
        #expect(records.count == 3, "les lignes de file ne sont pas des exports")
        #expect(records.map(\.outcome) == [.success, .warning, .failure])
        #expect(records[1].output == "/Volumes/SSD 1/Client B/Sept/Interview 5/Export/Interview 5.mp4")
        #expect(records[1].duration == 489)
        #expect(records[0].duration == 12)

        // Heure locale, comme l'écrit AME.
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 11
        parts.hour = 3; parts.minute = 54; parts.second = 14
        let expected = try #require(Calendar.current.date(from: parts))
        #expect(records[1].end == expected.timeIntervalSince1970)
    }

    /// Le journal est en UTF-16 avec sa marque d'ordre des octets.
    @Test func leJournalSeLitEnUTF16() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-ame-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try #require(Self.journal.data(using: .utf16LittleEndian))
        try (Data([0xFF, 0xFE]) + data).write(to: url)
        let text = try #require(AMEJournal.read(url))
        #expect(AMEJournal.parse(text).count == 3)
    }

    /// Relire le même journal ne double rien : les identifiants sont stables.
    @Test func relireLeJournalNeDoubleRien() {
        let now = Date(timeIntervalSince1970: 1_791_700_000)   // 11/10/2026
        let history = ExportHistory(journal: nil, file: Self.scratch())
        let records = AMEJournal.parse(Self.journal)
        #expect(history.ingest(records, now: now))
        #expect(!history.ingest(records, now: now))
        #expect(history.count == 3)
    }

    /// Règle dure n°2 : un enregistrement écrit avant l'ajout d'un champ se
    /// relit, et un enregistrement illisible n'emporte pas les autres.
    @Test func unChampAbsentNEffacePasLHistorique() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-exports-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date().timeIntervalSince1970
        let json = """
        {"version":1,"exports":[
          {"id":"ancien","app":"Media Encoder","end":\(now - 3600),"duration":60},
          "illisible",
          {"id":"complet","app":"Premiere Pro","end":\(now - 60),"duration":30,"output":"/tmp/a.mp4",
           "outcome":"warning","bytes":1000,"source":"vu par Pulse","champFutur":true}
        ]}
        """
        try Data(json.utf8).write(to: url)
        let history = ExportHistory(journal: nil, file: url)
        let records = history.exports(since: Date(timeIntervalSince1970: now - 86_400))
        #expect(records.map(\.id) == ["complet", "ancien"])
        #expect(records.last?.outcome == .success)
        #expect(records.first?.bytes == 1000)
    }

    /// Un export vu en direct que le journal décrit ensuite n'est compté
    /// qu'une fois : le journal l'emporte.
    @Test func lExportVuEnDirectCedeLaPlaceAuJournal() {
        let history = ExportHistory(journal: nil, file: Self.scratch())
        let began = Date().addingTimeInterval(-600)
        let live = ExportActivity(app: "Adobe Media Encoder 2026", began: began, lastActive: began.addingTimeInterval(489))
        history.update(live: live)
        history.update(live: nil)
        #expect(history.count == 1)
        let fromJournal = ExportRecord(id: "ame-x", app: "Media Encoder", end: began.addingTimeInterval(492).timeIntervalSince1970,
                                       duration: 489, output: "/tmp/x.mp4", outcome: .success, bytes: nil,
                                       source: AMEJournal.source)
        history.ingest([fromJournal])
        #expect(history.exports(since: began.addingTimeInterval(-60)).map(\.id) == ["ame-x"])
    }

    /// AME ajoute à la fin de son journal : seule la fin est relue, et un
    /// export ajouté est compté une fois, sans doubler les anciens.
    @Test func leJournalSeRelitParLaFin() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-ame-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(Self.journal.data(using: .utf16LittleEndian))
        try (Data([0xFF, 0xFE]) + first).write(to: url)
        let history = ExportHistory(journal: url, file: Self.scratch())
        let now = Date(timeIntervalSince1970: 1_791_700_000)   // 11/10/2026, 07 h
        history.update(live: nil, now: now)
        #expect(history.count == 3)

        let more = """

         - Source File: /var/folders/t3/T/Client C.prproj
         - Output File: /Volumes/Ssd 2/Client C/Vid 11.mp4
         - Encoding Time: 00:00:31
        10/11/2026 05:30:00 AM : File Successfully Encoded

        """
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: try #require(more.data(using: .utf16LittleEndian)))
        try handle.close()
        history.update(live: nil, now: now)
        #expect(history.count == 4)
        #expect(history.exports(since: Date(timeIntervalSince1970: 0)).first?.output == "/Volumes/Ssd 2/Client C/Vid 11.mp4")

        // Une tranche qui commence sur un octet impair se recale.
        let tail = try #require(AMEJournal.read(url, from: 3))
        #expect(AMEJournal.parse(tail).count == 4)
    }

    /// Le journal d'AME vit dans ~/Documents : le chercher fait demander à
    /// macOS l'accès au dossier Documents. Sur un Mac neuf, carte Médias
    /// masquée, ouvrir le panneau ne le cherche pas (26/10) ; la carte
    /// affichée, la règle « Export terminé » ou un historique déjà nourri
    /// par le journal le font chercher, une seule fois.
    @Test func leJournalDAMENEstChercheQueSurDemande() {
        final class Compteur { var recherches = 0 }

        let neuf = Compteur()
        let history = ExportHistory(file: Self.scratch(), lookup: { neuf.recherches += 1; return nil })
        history.update(live: nil, journalWanted: false)
        history.update(live: nil, journalWanted: false)
        #expect(neuf.recherches == 0)
        history.update(live: nil, journalWanted: true)
        history.update(live: nil, journalWanted: true)
        #expect(neuf.recherches == 1)

        let regle = Compteur()
        ExportHistory(file: Self.scratch(), lookup: { regle.recherches += 1; return nil }).relireJournal()
        #expect(regle.recherches == 1)

        let nourri = Compteur()
        let ancien = ExportHistory(file: Self.scratch(), lookup: { nourri.recherches += 1; return nil })
        ancien.ingest(AMEJournal.parse(Self.journal), now: Date(timeIntervalSince1970: 1_791_700_000))
        ancien.update(live: nil, journalWanted: false)
        #expect(nourri.recherches == 1)
    }

    /// Panneau fermé : le module ne fait rien, carte affichée ou non — pas
    /// même le `stat` du journal. Mille relevés en moins de 5 ms au total,
    /// quand un seul relevé ouvert, carte affichée, en coûte quatre.
    @Test func panneauFermeAucunTravail() {
        let tracker = MediaTracker(history: ExportHistory(journal: nil, file: Self.scratch()))
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1000 {
            #expect(tracker.tick(groups: [], export: nil, open: false) == nil)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        #expect(elapsed < 5, "mille relevés panneau fermé en \(elapsed) ms")
    }

    /// Panneau ouvert, carte Médias masquée, dépliant des exports fermé :
    /// l'historique seul, ni IOReport ni clients du GPU.
    @Test func sansCarteNiDepliantPasDeMoteurs() {
        let tracker = MediaTracker(history: ExportHistory(journal: nil, file: Self.scratch()))
        MediaTracker.setShown(false)
        defer { MediaTracker.setShown(true) }
        _ = tracker.tick(groups: [], export: nil, open: true)
        let state = tracker.tick(groups: [], export: nil, open: true)
        #expect(state != nil)
        #expect(state?.engines == nil)
        #expect(state?.cache == nil)
    }

    @Test func leCreateurDUnClientGPUDonneSonPID() {
        #expect(GPUClients.pid(fromCreator: "pid 451, WindowServer") == 451)
        #expect(GPUClients.pid(fromCreator: "WindowServer") == nil)
    }
}

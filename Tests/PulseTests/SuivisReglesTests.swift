import Foundation
import Testing
@testable import Pulse

/// 19-suivis : la règle « Copie de rushes terminée » (le chantier 05 publie
/// ses épisodes clos panneau fermé, pour elle seule), et « Export terminé »
/// qui nomme le fichier produit et son issue (journal d'AME du chantier 08).
/// Rien n'est envoyé : le moteur et le surveillant rendent des textes.
@MainActor
@Suite struct SuivisReglesTests {
    static let t0 = Date(timeIntervalSince1970: 1_791_720_000)

    static func export(_ nom: String, fin: Double, dure: Double = 300, issue: ExportRecord.Outcome = .success,
                       octets: UInt64? = 4_200_000_000, source: String = AMEJournal.source) -> ExportRecord {
        ExportRecord(id: "essai-\(nom)-\(Int(fin))", app: "Media Encoder", end: t0.timeIntervalSince1970 + fin,
                     duration: dure, output: "/Volumes/Ssd 2/Exports/\(nom)", outcome: issue, bytes: octets,
                     source: source)
    }

    static func copie(_ genre: Ingestion.Kind, debut: Double, octets: Double = 128e9) -> Ingestion {
        Ingestion(kind: genre, target: "Ssd 2", targetKey: "UUID-SSD2", source: genre == .copy ? "SSD 1" : nil,
                  app: nil, start: t0.addingTimeInterval(debut), lastActive: t0.addingTimeInterval(debut + 840),
                  bytes: octets)
    }

    // MARK: - Export terminé : le fichier et son issue

    @Test func unExportDitSonFichierEtSonIssue() {
        let repli = "Media Encoder · 8 min"
        #expect(LectureRegles.texteExport([Self.export("Interview 6.mp4", fin: 0)], repli: repli)
                == "Interview 6.mp4 · réussi · \(Fmt.bytes(UInt64(4_200_000_000)))")
        #expect(LectureRegles.texteExport([Self.export("Interview 6.mp4", fin: 0, issue: .failure)], repli: repli)
                == "Interview 6.mp4 · échec")
        #expect(LectureRegles.texteExport([Self.export("Interview 6.mp4", fin: 0, issue: .warning, octets: nil)],
                                          repli: repli) == "Interview 6.mp4 · réussi avec avertissement")
        // Une file : le compte, et les échecs nommés d'abord.
        let file = [Self.export("A.mp4", fin: 0), Self.export("B.mp4", fin: 60, issue: .failure),
                    Self.export("C.mp4", fin: 120)]
        #expect(LectureRegles.texteExport(file, repli: repli) == "3 fichiers · 1 échec : B.mp4")
        #expect(LectureRegles.texteExport([Self.export("A.mp4", fin: 0), Self.export("B.mp4", fin: 60),
                                           Self.export("C.mp4", fin: 120)], repli: repli)
                == "3 fichiers · tous réussis · A.mp4, B.mp4 et 1 autre")
        // Rien au journal (export vu par la charge seule) : l'app et la durée.
        #expect(LectureRegles.texteExport([], repli: repli) == repli)
    }

    @Test func lesFichiersSontCeuxDeLExport() {
        let journal = [Self.export("avant.mp4", fin: -3600),               // l'export précédent
                       Self.export("pendant.mp4", fin: 240),
                       Self.export("vu.mp4", fin: 250, source: ExportHistory.liveSource),
                       Self.export("apres.mp4", fin: 3600)]
        let fichiers = LectureRegles.fichiersExport(journal, debut: Self.t0, fin: Self.t0.addingTimeInterval(270))
        #expect(fichiers.map { ($0.output! as NSString).lastPathComponent } == ["pendant.mp4"])
    }

    @Test func lExportAttendLeJournalPuisSeDit() {
        let surveillant = SurveillantRegles(store: SurveillantReglesTests.store(),
                                            notificateur: SurveillantReglesTests.Carnet(), journalise: false)
        let fin = Self.t0.addingTimeInterval(300)
        surveillant.attendreExport(Evenement(sujet: "Adobe Media Encoder 2026", date: fin,
                                             texte: "Media Encoder · 5 min", debut: Self.t0))
        // Ni réponse ni délai écoulé : rien encore.
        #expect(surveillant.exportsPrets(date: fin.addingTimeInterval(5)) == nil)
        surveillant.journalRelu([Self.export("Interview 6.mp4", fin: 290)])
        #expect(surveillant.exportsPrets(date: fin.addingTimeInterval(5))?.map(\.texte)
                == ["Interview 6.mp4 · réussi · \(Fmt.bytes(UInt64(4_200_000_000)))"])
        // Dit une seule fois.
        #expect(surveillant.exportsPrets(date: fin.addingTimeInterval(10)) == nil)
    }

    @Test func sansReponseDuJournalLExportSeDitQuandMeme() {
        let surveillant = SurveillantRegles(store: SurveillantReglesTests.store(),
                                            notificateur: SurveillantReglesTests.Carnet(), journalise: false)
        let fin = Self.t0.addingTimeInterval(300)
        surveillant.attendreExport(Evenement(sujet: "Adobe Media Encoder 2026", date: fin,
                                             texte: "Media Encoder · 5 min", debut: Self.t0))
        #expect(surveillant.exportsPrets(date: fin.addingTimeInterval(19)) == nil)
        #expect(surveillant.exportsPrets(date: fin.addingTimeInterval(SurveillantRegles.attenteJournal))?.map(\.texte)
                == ["Media Encoder · 5 min"])
    }

    // MARK: - Copie de rushes terminée

    @Test func uneCopieTermineeSeDitUneFoisEtPasLesAutresEcritures() {
        var detecteur = DetecteurEvenements()
        let ancienne = Self.copie(.card, debut: -7200)
        // Premier relevé : la référence. La copie d'avant l'allumage se tait.
        #expect(detecteur.observer(export: nil, incidents: [], copies: [ancienne], date: Self.t0).isEmpty)
        let carte = Self.copie(.card, debut: 0)
        let telechargement = Self.copie(.download, debut: 60)
        let export = Self.copie(.export, debut: 120)
        let entre = Self.copie(.copy, debut: 180)
        let dits = detecteur.observer(export: nil, incidents: [], copies: [ancienne, carte, telechargement, export, entre],
                                      date: Self.t0.addingTimeInterval(1200))
        #expect(dits["disques.copieTerminee"]?.map(\.texte)
                == ["Copie de carte vers Ssd 2 · \(Fmt.bytes(UInt64(128e9))) en 14 min",
                    "Copie depuis SSD 1 vers Ssd 2 · \(Fmt.bytes(UInt64(128e9))) en 14 min"])
        // Relue au relevé suivant, la même liste ne redit rien.
        #expect(detecteur.observer(export: nil, incidents: [], copies: [ancienne, carte, entre],
                                   date: Self.t0.addingTimeInterval(1205)).isEmpty)
    }

    @Test func lesCopiesNeQuittentLaFileQuePourUneRegleAllumee() {
        let sampler = Releve.typique.sampler()
        let store = SurveillantReglesTests.store()
        let surveillant = SurveillantRegles(store: store, notificateur: SurveillantReglesTests.Carnet(),
                                            journalise: false)
        surveillant.demarrer(sampler)
        // Préréglages, tous éteints : coût nul, rien ne part de la file.
        #expect(Prereglages.tous.first { $0.id == "copie-terminee" }?.active == false)
        #expect(DiskActivity.ecouteCopies == false)
        store.modifier("copie-terminee") { $0.active = true }
        #expect(DiskActivity.ecouteCopies == true)
        #expect(surveillant.ecoute)
        store.modifier("copie-terminee") { $0.active = false }
        #expect(DiskActivity.ecouteCopies == false)
        #expect(!surveillant.ecoute)
    }
}

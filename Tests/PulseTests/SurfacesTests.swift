import Foundation
import Testing
@testable import Pulse

/// Chantier 13 : l'état partagé des widgets et des Raccourcis, les réponses
/// des actions, la disposition du tableau de bord.
@MainActor
@Suite struct SurfacesTests {
    static func volume(_ name: String, interne: Bool, total: UInt64, free: UInt64, uuid: String) -> VolumeSample {
        VolumeSample(name: name, path: interne ? "/" : "/Volumes/\(name)", total: total, available: free,
                     isInternal: interne, uuid: uuid, availableStrict: free)
    }

    static let volumes = [
        volume("Macintosh HD", interne: true, total: 1_000_000_000_000, free: 399_000_000_000, uuid: "INTERNE"),
        volume("Extreme Pro", interne: false, total: 2_000_000_000_000, free: 719_000_000_000, uuid: "EXTREME"),
        volume("Ssd 2", interne: false, total: 2_000_000_000_000, free: 304_000_000_000, uuid: "SSD2"),
    ]

    static func verdict(_ level: VerdictLevel, rule: Int = 9, phrase: String = "Ssd 2 plein vers jeudi") -> Verdict {
        Verdict(rule: rule, ruleName: "test", level: level, symbol: "externaldrive", phrase: phrase,
                evidence: "304 Go libres", also: [])
    }

    static func etat(verdict given: Verdict? = nil) -> EtatPartage {
        let verdict = given ?? Self.verdict(.warning)
        var memory = MemorySample()
        memory.total = 32 * 1_073_741_824
        memory.app = 10 * 1_073_741_824
        memory.wired = 6 * 1_073_741_824
        memory.compressed = 4 * 1_073_741_824
        return EtatBuilder.build(memory: memory, volumes: volumes, forecasts: [:], verdict: verdict, forfait: nil)
    }

    // MARK: - Disque de rushes

    @Test func leDisqueDeRushesEstLExterneLePlusRempli() {
        // Ssd 2 porte 1,70 To, Extreme Pro 1,28 To : Ssd 2, quel que soit l'ordre.
        #expect(EtatBuilder.rushes(Self.volumes)?.historyKey == "SSD2")
        #expect(EtatBuilder.rushes(Self.volumes.reversed())?.historyKey == "SSD2")
        // Aucun externe : pas de disque de rushes, le widget montre l'interne.
        let seul = [Self.volumes[0]]
        #expect(EtatBuilder.rushes(seul) == nil)
        var etat = Self.etat()
        etat.disques = etat.disques.filter(\.interne)
        etat.rushes = nil
        #expect(etat.disqueDeRushes?.nom == "Macintosh HD")
    }

    @Test func lesChiffresSontCeuxDuPanneau() {
        let etat = Self.etat()
        let ssd = etat.disques.first { $0.id == "SSD2" }
        #expect(ssd?.libre == Fmt.bytes(UInt64(304_000_000_000)))
        #expect(ssd?.occupationTexte == Fmt.occupancy(0.848))
        // « sur 32 Go », comme la carte Mémoire, pas « 32,0 Go ».
        #expect(etat.memoire.totale == Fmt.memory(UInt64(32 * 1_073_741_824), digits: 0))
        #expect(etat.memoire.utilisee == Fmt.memory(UInt64(20 * 1_073_741_824)))
    }

    // MARK: - Pulse est-il calme ?

    @Test func calmeSeulementSansAvertissementNiAlerte() {
        #expect(Reponses.calme(Self.etat(verdict: Self.verdict(.warning))).calme == false)
        #expect(Reponses.calme(Self.etat(verdict: Self.verdict(.alert))).calme == false)
        #expect(Reponses.calme(Self.etat(verdict: Self.verdict(.muted, rule: 12, phrase: "La machine suit"))).calme == true)
        #expect(Reponses.calme(Self.etat(verdict: Self.verdict(.data, rule: 11, phrase: "Export en cours"))).calme == true)
        // Avant le premier relevé : jamais un feu vert.
        #expect(Reponses.calme(Self.etat(verdict: .pending)).calme == false)
        #expect(Reponses.calme(Self.etat(verdict: Self.verdict(.warning))).phrase
                == "Non : Ssd 2 plein vers jeudi (304 Go libres).")
    }

    // MARK: - Combien reste-t-il sur … ?

    @Test func leDisqueSeCherchePasSonNomSansCasseNiAccent() {
        let etat = Self.etat()
        #expect(Reponses.disque(etat, nom: "ssd 2").disque?.id == "SSD2")
        #expect(Reponses.disque(etat, nom: "  EXTRÊME PRO ").disque?.id == "EXTREME")
        // Sans nom : le disque de rushes.
        #expect(Reponses.disque(etat, nom: nil).disque?.id == "SSD2")
        #expect(Reponses.disque(etat, nom: "").disque?.id == "SSD2")
        let absent = Reponses.disque(etat, nom: "Lexar")
        #expect(absent.disque == nil)
        #expect(absent.phrase.hasPrefix("Lexar n'est pas branché."))
        #expect(absent.phrase.contains("Ssd 2"))
    }

    @Test func consommationIPhoneSansCumul() {
        #expect(Reponses.iphone(Self.etat()).octets == 0)
        var etat = Self.etat()
        var forfait = ForfaitPartage()
        forfait.aujourdhui = "216 ko"
        forfait.aujourdhuiOctets = 216_000
        forfait.cycle = "5,8 Go"
        etat.forfait = forfait
        let reponse = Reponses.iphone(etat)
        #expect(reponse.octets == 216_000)
        #expect(reponse.phrase == "216 ko aujourd'hui par le partage iPhone, 5,8 Go depuis le début du cycle. Ce Mac seulement.")
    }

    // MARK: - Le fichier des widgets (règle dure n°2)

    @Test func lAllerRetourGardeTout() throws {
        let etat = Self.etat()
        let relu = try EtatPartage.decoder.decode(EtatPartage.self, from: etat.encoded())
        #expect(relu.sameValues(as: etat))
        #expect(abs(relu.date.timeIntervalSince(etat.date)) < 1)
    }

    @Test func unChampAbsentOuAbimeNeCouteRienDAutre() throws {
        // Un fichier d'une version future : un champ inconnu, un disque
        // illisible, la mémoire absente. Le reste se lit.
        let json = """
        {"version": 7, "date": "2026-10-11T06:00:00Z", "futur": [1, 2],
         "verdict": {"niveau": "warning", "phrase": "Ssd 2 plein vers jeudi", "calme": false},
         "disques": [{"id": "SSD2", "nom": "Ssd 2", "libre": "304 Go", "occupation": "abîmé"},
                     42,
                     {"id": "INTERNE", "nom": "Macintosh HD", "interne": true}],
         "rushes": "SSD2"}
        """
        let etat = try EtatPartage.decoder.decode(EtatPartage.self, from: Data(json.utf8))
        #expect(etat.version == 7)
        #expect(etat.verdict.phrase == "Ssd 2 plein vers jeudi")
        #expect(etat.disques.map(\.id) == ["SSD2", "INTERNE"])
        #expect(etat.disques.first?.occupation == 0)
        #expect(etat.disqueDeRushes?.libre == "304 Go")
        #expect(etat.memoire.utilisee == "—")
        #expect(etat.forfait == nil)
    }

    @Test func lEcritureEstCoupeeSousSnapshot() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-etat-\(UUID().uuidString).json")
        // Le drapeau passé tel quel : basculer `Persistence.enabled` en plein
        // `swift test` parallèle troublerait les autres suites.
        #expect(SharedStateWriter.shared.write(Self.etat(), to: url, enabled: false) == false)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(SharedStateWriter.shared.write(Self.etat(), to: url, enabled: true) == true)
        #expect(EtatPartage.read(from: url)?.disqueDeRushes?.id == "SSD2")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Tableau de bord et surfaces

    @Test func autantDeColonnesQueLaLargeurEnLoge() {
        #expect(Masonry.columnCount(width: 1560, columnWidth: 296, spacing: 12) == 5)
        #expect(Masonry.columnCount(width: 296, columnWidth: 296, spacing: 12) == 1)
        #expect(Masonry.columnCount(width: 100, columnWidth: 296, spacing: 12) == 1)
        #expect(Masonry.columnCount(width: 604, columnWidth: 296, spacing: 12) == 2)
    }

    @Test func uneSurfaceVisibleNeSeCompteQuUneFois() {
        #expect(Surfaces.anyVisible == false)
        Surfaces.set("essai", visible: true)
        Surfaces.set("essai", visible: true)
        #expect(Surfaces.anyVisible == true)
        Surfaces.set("essai", visible: false)
        #expect(Surfaces.anyVisible == false)
    }

    /// 19-suivis : la fenêtre Réglages cachée (derrière Premiere, réduite,
    /// autre espace) gardait la cadence du panneau ouvert tant qu'elle
    /// n'était pas fermée — 2,8 à 3,1 % d'un cœur au banc. Elle relit sa
    /// visibilité sur la fenêtre elle-même : jamais posée à l'écran ici, elle
    /// est hors de vue, la cadence retombe et son contenu est vidé, sa page
    /// gardée pour le retour. Rien n'est jamais affiché : ni `show`, ni
    /// `orderFront`.
    @Test func laFenetreReglagesCacheeRepasseALaCadenceFermee() {
        let sampler = Releve.typique.sampler()
        let reglages = SettingsWindow()
        reglages.sampler = sampler
        var annonces: [Bool] = []
        reglages.visibilityDidChange = { annonces.append($0) }
        let fenetre = reglages.makeWindow(sampler: sampler, page: .module("memoire"))
        #expect(reglages.isLive)
        #expect(Surfaces.isSeen(fenetre) == false)
        // Comme `show` : annoncée sous les yeux d'Isma.
        reglages.announce(true)
        #expect(annonces == [true])
        // Le premier changement d'occlusion, sur une fenêtre qui ne se voit pas.
        reglages.visibilityChanged()
        #expect(annonces == [true, false])
        #expect(reglages.isSeen == false)
        #expect(reglages.isLive == false)
        #expect(reglages.page == .module("memoire"))
        // Rien de plus tant qu'elle reste cachée : une annonce par bascule.
        reglages.visibilityChanged()
        #expect(annonces == [true, false])
        reglages.close()
        #expect(annonces == [true, false])
    }

    @Test func leWidgetDitLAgeDeSesChiffres() {
        let now = Date()
        #expect(PulseWidgetView.age(of: now, now: now) == "relevé à l'instant")
        #expect(PulseWidgetView.age(of: now.addingTimeInterval(-300), now: now) == "relevé il y a 5 min")
        #expect(PulseWidgetView.age(of: now.addingTimeInterval(-7200), now: now).hasSuffix("Pulse tourne-t-il ?"))
    }
}

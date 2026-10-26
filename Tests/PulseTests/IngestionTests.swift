import Foundation
import Testing
@testable import Pulse

/// Chantier 05 : les écritures massives nommées, sur des relevés fabriqués
/// toutes les 5 s comme panneau fermé.
@Suite struct IngestionTests {
    typealias App = IngestionInput.App
    static let mo = 1_000_000.0
    static let ssd2: UInt32 = 16_777_254
    static let interne: UInt32 = 16_777_233
    static let t0 = Date(timeIntervalSince1970: 1_791_700_000)

    static func disk(_ id: UInt64, _ name: String, read: Double = 0, write: Double = 0,
                     inside: Bool = false, removable: Bool = false, devices: Set<UInt32> = []) -> IngestionInput.Disk {
        IngestionInput.Disk(id: id, name: name, volumeKey: "UUID-\(name)", isInternal: inside,
                            isRemovable: removable, read: read, write: write, devices: devices)
    }

    static func input(at seconds: Double, _ disks: [IngestionInput.Disk], rx: Double = 0,
                      apps: [App] = []) -> IngestionInput {
        IngestionInput(now: t0.addingTimeInterval(seconds), interval: 5, disks: disks,
                       networkRx: rx, apps: apps, exporting: false)
    }

    /// Une carte SD lue à 200 Mo/s pendant que Ssd 2 écrit autant : copie de
    /// carte, nommée avec sa source et l'application qui tient les fichiers.
    @Test func uneCopieDeCarteSeNommeAvecSaSource() {
        var detector = IngestionDetector()
        var last: [Ingestion] = []
        let finder: [App] = [App(name: "Finder", read: 200 * Self.mo, write: 200 * Self.mo, devices: [Self.ssd2])]
        for step in 1...12 {
            last = detector.observe(Self.input(at: Double(step) * 5, [
                Self.disk(1, "Ssd 2", write: 200 * Self.mo, devices: [Self.ssd2]),
                Self.disk(2, "EOS_DIGITAL", read: 200 * Self.mo, removable: true),
            ], apps: finder)).active
        }
        #expect(last.count == 1)
        #expect(last.first?.kind == .card)
        #expect(last.first?.source == "carte EOS_DIGITAL")
        #expect(last.first?.app == "Finder")
        #expect(last.first?.label == "Copie de carte")
        #expect(abs((last.first?.bytes ?? 0) - 12_000 * Self.mo) < 1)
        #expect(last.first?.start == Self.t0)
    }

    /// Le réseau reçoit ce que le disque écrit : téléchargement, même si une
    /// pause de 45 s s'intercale ; une minute de calme le clôt.
    @Test func unTelechargementSurviveAUnePauseEtSeClotApresUneMinute() {
        var detector = IngestionDetector()
        let vivaldi: [App] = [App(name: "Vivaldi", write: 40 * Self.mo, devices: [Self.ssd2])]
        let busy = Self.disk(1, "Ssd 2", write: 40 * Self.mo, devices: [Self.ssd2])
        let calm = Self.disk(1, "Ssd 2", devices: [Self.ssd2])
        for step in 1...6 {
            _ = detector.observe(Self.input(at: Double(step) * 5, [busy], rx: 41 * Self.mo, apps: vivaldi))
        }
        for step in 7...15 {      // 45 s de pause : l'épisode tient
            #expect(detector.observe(Self.input(at: Double(step) * 5, [calm])).finished.isEmpty)
        }
        for step in 16...20 {
            _ = detector.observe(Self.input(at: Double(step) * 5, [busy], rx: 41 * Self.mo, apps: vivaldi))
        }
        var finished: [Ingestion] = []
        for step in 21...40 where finished.isEmpty {
            finished = detector.observe(Self.input(at: Double(step) * 5, [calm])).finished
        }
        #expect(finished.count == 1)
        #expect(finished.first?.kind == .download)
        #expect(finished.first?.app == "Vivaldi")
        #expect(abs((finished.first?.bytes ?? 0) - 11 * 200 * Self.mo) < 1)
        #expect(finished.first?.active == false)
    }

    /// Sous 1 Go, rien : un cache, un enregistrement automatique.
    @Test func unePetiteEcritureNeSAfficheJamais() {
        var detector = IngestionDetector()
        var shown = 0
        for step in 1...30 {
            let write = step <= 10 ? 15 * Self.mo : 0           // 750 Mo en 50 s
            let r = detector.observe(Self.input(at: Double(step) * 5, [Self.disk(1, "Ssd 2", write: write)]))
            shown += r.active.count + r.finished.count
        }
        #expect(shown == 0)
    }

    /// Le disque interne n'ouvre jamais d'épisode : swap et services y
    /// écrivent sans application visible.
    @Test func leDisqueInterneEstEcarte() {
        var detector = IngestionDetector()
        var shown = 0
        for step in 1...40 {
            let r = detector.observe(Self.input(at: Double(step) * 5,
                                                [Self.disk(0, "Macintosh HD", write: 300 * Self.mo, inside: true)]))
            shown += r.active.count + r.finished.count
        }
        #expect(shown == 0)
    }

    /// Débranché en pleine copie : l'épisode se clôt aussitôt, avec ce qui a
    /// été écrit, sans écrivain inventé.
    @Test func unDisqueDebrancheCloLEpisode() {
        var detector = IngestionDetector()
        for step in 1...4 {
            _ = detector.observe(Self.input(at: Double(step) * 5, [Self.disk(1, "Ssd 2", write: 100 * Self.mo)]))
        }
        let r = detector.observe(Self.input(at: 25, []))
        #expect(r.finished.count == 1)
        #expect(r.finished.first?.bytes == 2_000 * Self.mo)
        #expect(r.finished.first?.app == nil)
    }

    /// Le cas du 11/10 : Ssd 2 écrit 5,8 Mo/s de proxies ffmpeg ; Xcode écrit
    /// 3,1 Mo/s sur l'interne, ffmpeg 2,5 Mo/s. Au débit, Xcode semblait le
    /// plus proche ; au fichier ouvert, c'est ffmpeg.
    @Test func lEcrivainEstCeluiQuiTientUnFichierSurLeDisque() {
        let input = Self.input(at: 5, [Self.disk(1, "Ssd 2", read: 32 * Self.mo, write: 5.8 * Self.mo, devices: [Self.ssd2])],
                               apps: [App(name: "Xcode", write: 3.1 * Self.mo, devices: [Self.interne]),
                                      App(name: "ffmpeg", read: 29.4 * Self.mo, write: 2.5 * Self.mo, devices: [Self.interne, Self.ssd2])])
        #expect(IngestionDetector.writer(for: input.disks[0], in: input) == "ffmpeg")
        #expect(IngestionDetector.classify(input.disks[0], in: input).kind == .write)
    }

    /// Le relevé du 11/10 encore : pendant que Ssd 2 recevait 3,1 Mo/s de
    /// proxies, le disque interne lisait 109 Mo/s pour d'autres. L'ancienne
    /// règle annonçait « Copie depuis Macintosh HD ». ffmpeg lit dix fois ce
    /// qu'il écrit : un transcodage, pas une copie. Une vraie copie depuis
    /// l'interne (le Finder lit ce qu'il écrit) reste une copie.
    @Test func unTranscodageNEstPasUneCopieDepuisLInterne() {
        let proxies = Self.input(at: 5, [
            Self.disk(0, "Macintosh HD", read: 109 * Self.mo, write: 7.7 * Self.mo, inside: true),
            Self.disk(1, "Ssd 2", read: 34.8 * Self.mo, write: 3.1 * Self.mo, devices: [Self.ssd2]),
        ], apps: [App(name: "ffmpeg", read: 29.4 * Self.mo, write: 3.1 * Self.mo, devices: [Self.ssd2])])
        #expect(IngestionDetector.classify(proxies.disks[1], in: proxies).kind == .write)

        let copie = Self.input(at: 5, [
            Self.disk(0, "Macintosh HD", read: 150 * Self.mo, write: 2 * Self.mo, inside: true),
            Self.disk(1, "Ssd 2", write: 140 * Self.mo, devices: [Self.ssd2]),
        ], apps: [App(name: "Finder", read: 150 * Self.mo, write: 140 * Self.mo, devices: [Self.ssd2])])
        #expect(IngestionDetector.classify(copie.disks[1], in: copie).kind == .copy)
        #expect(IngestionDetector.classify(copie.disks[1], in: copie).source == "Macintosh HD")
    }

    /// Un journal écrit par une autre version, avec un champ inconnu et des
    /// champs manquants, se relit sans rien perdre (règle dure n°2).
    @Test func unEpisodeSeRelitMalgreUnSchemaDifferent() throws {
        let json = #"{"kind":"download","target":"Ssd 2","start":0,"lastActive":3600,"bytes":5e10,"nouveau":true}"#
        let e = try JSONDecoder().decode(Ingestion.self, from: Data(json.utf8))
        #expect(e.kind == .download)
        #expect(e.bytes == 5e10)
        #expect(e.app == nil)
        #expect(e.duration == 3600)
    }
}

/// Chantier 05 : la page SMART NVMe, décodée sur un relevé reconstitué.
@Suite struct SanteDisqueTests {
    /// Le SSD interne le 11/10 : 33 °C, usure 3 %, réserve 100 % (seuil 99 %).
    @Test func laPageSMARTSeDecode() {
        var page = [UInt8](repeating: 0, count: 512)
        page[1] = UInt8((273 + 33) & 0xFF); page[2] = UInt8((273 + 33) >> 8)
        page[3] = 100; page[4] = 99; page[5] = 3
        func put(_ value: UInt64, at offset: Int) {
            for i in 0..<8 { page[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        }
        put(140_222_000, at: 48)     // unités de 512 000 octets
        put(638, at: 112)
        put(1_802, at: 128)
        put(53, at: 144)
        let h = DiskHealth.parse(page)
        #expect(h?.temperature == 33)
        #expect(h?.percentUsed == 3)
        #expect(h?.status == .good)
        #expect(h?.dataWritten == Double(140_222_000) * 512_000)   // 71,8 To
        #expect(h?.powerOnHours == 1_802)
        #expect(h?.unsafeShutdowns == 53)
    }

    /// Le contrôleur lève lui-même l'alerte : défaillant, sans seuil maison.
    /// Une réserve sous le seuil : à surveiller.
    @Test func unAvertissementCritiqueDitDefaillant() {
        var page = [UInt8](repeating: 0, count: 512)
        page[0] = 0x04; page[3] = 100; page[4] = 10
        #expect(DiskHealth.parse(page)?.status == .failing)
        page[0] = 0; page[3] = 8
        #expect(DiskHealth.parse(page)?.status == .watch)
    }
}

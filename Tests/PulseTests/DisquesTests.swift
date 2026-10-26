import Foundation
import Testing
@testable import Pulse

/// Chantier 05 : débits des disques physiques, sur des compteurs fabriqués
/// comme ceux que publient les pilotes de stockage.
@Suite struct DebitsDisquesTests {
    static let mo = 1_000_000.0

    static func disk(_ id: UInt64, _ bsd: String, inside: Bool = false, removable: Bool = false) -> PhysicalDisk {
        PhysicalDisk(id: id, bsdName: bsd, model: "Modèle \(bsd)", interconnect: inside ? "Apple Fabric" : "USB",
                     isInternal: inside, isRemovable: removable, smartCapable: false, size: 2_000_000_000_000)
    }

    static func volume(_ name: String, _ path: String, inside: Bool = false) -> VolumeSample {
        VolumeSample(name: name, path: path, total: 2_000_000_000_000, available: 500_000_000_000,
                     isInternal: inside, uuid: "UUID-\(name)", availableStrict: 500_000_000_000)
    }

    @Test func lePremierReleveNeDonneAucunDebit() {
        var meter = DiskRateMeter()
        let rates = meter.update(now: 100, readings: [1: DiskCounters(read: 5_000, written: 9_000)])
        #expect(rates.isEmpty)
    }

    @Test func leDebitEstLEcartDivisePeLIntervalle() {
        var meter = DiskRateMeter()
        _ = meter.update(now: 100, readings: [1: DiskCounters(read: 0, written: 0)])
        let rates = meter.update(now: 105, readings: [1: DiskCounters(read: UInt64(50 * Self.mo), written: UInt64(500 * Self.mo))])
        #expect(rates[1]?.read == 10 * Self.mo)
        #expect(rates[1]?.write == 100 * Self.mo)
        #expect(rates[1]?.written == 500 * Self.mo)
        #expect(rates[1]?.interval == 5)
    }

    /// Un compteur qui recule ne donne ni débit négatif ni pic absurde : rien,
    /// puis le relevé suivant repart de la nouvelle base.
    @Test func unCompteurQuiReculeNeDonneRien() {
        var meter = DiskRateMeter()
        _ = meter.update(now: 100, readings: [1: DiskCounters(read: 9_000_000, written: 9_000_000)])
        let reset = meter.update(now: 105, readings: [1: DiskCounters(read: 1_000, written: 1_000)])
        #expect(reset[1] == nil)
        let next = meter.update(now: 110, readings: [1: DiskCounters(read: 1_000 + 5_000_000, written: 1_000)])
        #expect(next[1]?.read == 1_000_000)
        #expect(next[1]?.write == 0)
    }

    /// Débranché puis rebranché sous le même identifiant (ce que l'IORegistry
    /// ne fait pas, mais rien ne l'interdit) : on repart de zéro, sans
    /// compter comme écrit tout ce qui l'a été pendant l'absence.
    @Test func unDisqueRebrancheRepartDeZero() {
        var meter = DiskRateMeter()
        _ = meter.update(now: 100, readings: [1: DiskCounters(read: 0, written: 0), 2: DiskCounters(read: 0, written: 0)])
        _ = meter.update(now: 105, readings: [1: DiskCounters(read: 10, written: 10)])
        let back = meter.update(now: 110, readings: [1: DiskCounters(read: 20, written: 20),
                                                      2: DiskCounters(read: 900_000_000, written: 900_000_000)])
        #expect(back[2] == nil)
        #expect(back[1]?.read == 2)
    }

    /// L'interne d'abord, puis les externes dans l'ordre de leurs volumes ;
    /// un disque sans volume n'apparaît que s'il travaille.
    @Test func lesLignesSuiventLOrdreDesVolumes() {
        let disks = [Self.disk(10, "disk10"), Self.disk(0, "disk0", inside: true),
                     Self.disk(6, "disk6"), Self.disk(4, "disk4", removable: true), Self.disk(5, "disk5")]
        let volumes = [Self.volume("Macintosh HD", "/", inside: true),
                       Self.volume("SSD 1", "/Volumes/SSD 1"), Self.volume("Ssd 2", "/Volumes/Ssd 2")]
        let map: [String: UInt64] = ["/": 0, "/Volumes/SSD 1": 6, "/Volumes/Ssd 2": 10]
        let rates: [UInt64: DiskRateMeter.Rate] = [
            4: .init(read: 80 * Self.mo, write: 0, written: 0, interval: 5),   // une carte qu'on lit, non montée
            5: .init(read: 0, write: 0, written: 0, interval: 5),              // branché, démonté, au repos
        ]
        let lines = DiskActivity.lines(disks: disks, volumes: volumes, map: map, rates: rates)
        #expect(lines.map(\.disk.bsdName) == ["disk0", "disk6", "disk10", "disk4"])
        #expect(lines.last?.name == "Modèle disk4")
        #expect(lines[2].name == "Ssd 2")
    }
}

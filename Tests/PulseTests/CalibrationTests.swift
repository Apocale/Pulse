import Foundation
import Testing
@testable import Pulse

/// Les seuils calibrés du verdict et le bilan qui sert à les calibrer
/// (chantier 12). Chaque test a été vu échouer sans sa correction : le seuil
/// de 30 jours, le décompte qui prenait chaque relance pour un changement.
@Suite struct CalibrationTests {
    static let gio: UInt64 = 1 << 30
    static let now = Date(timeIntervalSince1970: 1_791_500_000)

    /// Un disque interne qui « sera plein dans `days` jours », mémoire calme.
    static func input(days: Double) -> VerdictInput {
        var input = VerdictInput()
        input.memory = MemorySample(total: 32 * gio, app: 12 * gio, wired: 5 * gio, compressed: 4 * gio,
                                    cached: 0, swapUsed: 0, swapTotal: 0, pressureLevel: 1)
        let free: UInt64 = 400_000_000_000
        input.volumes = [VolumeSample(name: "Macintosh HD", path: "/", total: 995_000_000_000,
                                      available: free, isInternal: true, uuid: "MAC", availableStrict: free)]
        input.forecasts = ["MAC": FillForecast(bytesPerDay: -Double(free) / days, daysUntilFull: days,
                                               ruptures: 0, calmSeconds: 72 * 3600)]
        input.volumeAges = ["MAC": 60]
        return input
    }

    /// Rejeu du 11/10 : entre 14 et 30 jours, l'échéance du disque interne
    /// avait disparu 24 h plus tard dans 72 % des cas. « Macintosh HD plein
    /// dans ~20 jours » n'est plus un avertissement ; à 10 jours, si.
    @Test func laRegle9ParleSousQuatorzeJours() {
        #expect(VerdictEngine.instant(Self.input(days: 20), now: Self.now).verdict.rule == 12)
        #expect(VerdictEngine.instant(Self.input(days: 10), now: Self.now).verdict.rule == 9)
        #expect(VerdictEngine.instant(Self.input(days: 5), now: Self.now).verdict.rule == 4)
    }

    /// La série qui manquait à la règle 10 : l'app hors montage la plus
    /// chargée, jamais Premiere ni l'encodeur, même plus chargés qu'elle.
    @Test func laSerieDeLaRegle10IgnoreLeMontage() {
        func group(_ id: String, _ cpu: Double) -> ProcessGroup {
            ProcessGroup(bundleId: id, name: id, cpu: cpu, footprint: 0, processCount: 1)
        }
        let groups = [group("com.adobe.PremierePro.26", 300), group("com.adobe.ame.application.26", 220),
                      group("com.vivaldi.Vivaldi", 150), group("com.apple.Notes", 4)]
        #expect(CalibrationSeries.busiest(groups) == 150)
        #expect(CalibrationSeries.busiest([group("com.adobe.PremierePro.26", 300)]) == 0)
    }

    static func entry(_ t: Double, rule: Int? = nil, event: String? = nil) -> VerdictJournal.Entry {
        VerdictJournal.Entry(t: t, rule: rule, name: "", event: event)
    }

    /// Le matin du 11/10 : vingt relances après fusion, toutes sur « Ssd 2
    /// plein vers … ». Le bilan y voyait vingt changements.
    @Test func uneRelanceNEstPasUnChangement() {
        let entries = [
            Self.entry(0, event: "start"), Self.entry(0, rule: 4),
            Self.entry(60, event: "stop"), Self.entry(62, event: "start"), Self.entry(62, rule: 4),
            Self.entry(120, event: "stop"), Self.entry(122, event: "start"), Self.entry(122, rule: 4),
            Self.entry(400, rule: 7),
            Self.entry(500, event: "stop"), Self.entry(502, event: "start"), Self.entry(502, rule: 7),
            Self.entry(900, rule: 12),
        ]
        let counted = VerdictJournal.changes(entries)
        #expect(counted.changes == 2, "4 → 7, puis 7 → 12 : \(counted.changes)")
        #expect(counted.restarts == 3)
    }
}

import Foundation
import Testing
@testable import Pulse

/// Le délai de tenue du verdict (`VerdictEngine.holdDelay`), rejoué sur le
/// moteur réel, relevé toutes les 5 s comme panneau fermé.
///
/// Situation de départ, celle du 09/10 : « Ssd 2 plein dans ~8 jours » (règle
/// 9, avertissement), mémoire au calme.
@Suite struct VerdictHoldTests {
    static let gio: UInt64 = 1 << 30
    static let start = Date(timeIntervalSince1970: 1_791_500_000)

    /// Un relevé : pression mémoire, plantage éventuel, export éventuel,
    /// disque qui se remplit ou non.
    static func input(pressure: Int32 = 1, crashAt: Date? = nil,
                      exporting: Bool = false, diskFilling: Bool = true) -> VerdictInput {
        var input = VerdictInput()
        input.memory = MemorySample(total: 32 * gio, app: 12 * gio, wired: 5 * gio,
                                    compressed: 4 * gio, cached: 0, swapUsed: 0,
                                    swapTotal: 0, pressureLevel: pressure)
        let ssd = VolumeSample(name: "Ssd 2", path: "/Volumes/Ssd 2", total: 2_000 * 1_000_000_000,
                               available: 676 * 1_000_000_000, isInternal: false,
                               uuid: "SSD2", availableStrict: 676 * 1_000_000_000)
        input.volumes = [ssd]
        if diskFilling {
            input.forecasts = ["SSD2": FillForecast(bytesPerDay: -88.3e9, daysUntilFull: 7.7,
                                                    ruptures: 0, calmSeconds: 72 * 3600)]
        }
        input.volumeAges = ["SSD2": 60]
        if let crashAt {
            input.incidents = [Incident(app: "Adobe Premiere Pro 2026", bundleId: nil,
                                        kind: .crash, date: crashAt)]
        }
        if exporting {
            input.export = ExportActivity(app: "Adobe Media Encoder 2026",
                                          began: start, lastActive: start)
        }
        return input
    }

    /// Fait tourner le moteur de `from` à `to` secondes, relevé toutes les 5 s.
    static func run(_ engine: VerdictEngine, from: Int, to: Int,
                    _ make: (Int) -> VerdictInput) -> [(t: Int, verdict: Verdict)] {
        stride(from: from, through: to, by: 5).map { t in
            (t, engine.evaluate(make(t), now: start.addingTimeInterval(Double(t))))
        }
    }

    @Test func pressionQuiClignoteNeChangePasLeVerdict() {
        let engine = VerdictEngine()
        // Pression élevée 30 s sur 60, dix minutes durant : le cas du journal,
        // 195 épisodes de 30 s en médiane.
        let shown = Self.run(engine, from: 0, to: 600) { t in
            Self.input(pressure: (t / 30) % 2 == 1 ? 2 : 1)
        }
        let rules = Set(shown.map(\.verdict.rule))
        #expect(rules == [9], "le verdict a changé : \(rules)")
        // La pression n'est pas tue pour autant : elle passe en « et aussi ».
        #expect(shown.contains { $0.verdict.also.contains("pression élevée") })
    }

    @Test func uneAlerteNAttendPas() {
        let engine = VerdictEngine()
        let crash = Self.start.addingTimeInterval(100)
        let shown = Self.run(engine, from: 0, to: 140) { t in
            Self.input(crashAt: t >= 100 ? crash : nil)
        }
        // Entrée de règle à 3 s, relevé toutes les 5 s : affichée au plus tard à 105 s.
        let first = shown.first { $0.verdict.rule == 5 }
        #expect(first != nil)
        #expect((first?.t ?? .max) <= 105)
    }

    @Test func leCalmeQuiSeDegradePasseToutDeSuite() {
        let engine = VerdictEngine()
        let shown = Self.run(engine, from: 0, to: 80) { t in
            Self.input(pressure: t >= 50 ? 2 : 1, diskFilling: false)
        }
        #expect(shown.first?.verdict.rule == 12)
        let first = shown.first { $0.verdict.rule == 6 }
        #expect((first?.t ?? .max) <= 60, "« La machine suit » est resté affiché sur une pression élevée")
    }

    @Test func unVerdictRetombeResteCinqMinutesEtSeDate() {
        let engine = VerdictEngine()
        // Pression élevée dès le premier relevé, retombée à 60 s.
        let shown = Self.run(engine, from: 0, to: 420) { t in
            Self.input(pressure: t < 60 ? 2 : 1)
        }
        func at(_ t: Int) -> Verdict { shown.first { $0.t == t }!.verdict }
        #expect(at(0).rule == 6)
        // Tenu, et ses chiffres sont datés plutôt que présentés comme actuels.
        #expect(at(200).rule == 6)
        #expect(at(200).evidence.contains("relevé il y a"))
        // La règle 9 gagne depuis 70 s (sortie à 10 s) : affichée 300 s plus tard.
        #expect(at(365).rule == 6)
        #expect(at(380).rule == 9)
    }

    @Test func unExportFiniSEffaceAussitot() {
        let engine = VerdictEngine()
        let shown = Self.run(engine, from: 0, to: 130) { t in
            Self.input(exporting: t < 100, diskFilling: false)
        }
        func at(_ t: Int) -> Verdict { shown.first { $0.t == t }!.verdict }
        #expect(at(50).rule == 11)
        #expect(at(105).rule == 12, "« Export en cours » est resté affiché après la fin")
    }
}

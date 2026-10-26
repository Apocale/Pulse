import Foundation
import Testing
@testable import Pulse

/// Le conseil de chaque règle (`Metrics/Advice/`), à partir du verdict que
/// rend le VRAI barème sur un relevé fabriqué : le conseil part toujours de
/// l'objet que la phrase nomme.
///
/// Chaque test a été vu échouer sans la règle qu'il protège (journal du
/// chantier : `docs/chantiers/12-verdict.md`).
@Suite struct AdviceTests {
    static let gio: UInt64 = 1 << 30
    static let go: UInt64 = 1_000_000_000
    static let now = Date(timeIntervalSince1970: 1_791_500_000)

    // MARK: - Fabrique

    static func memory(pressure: Int32 = 1, swap: UInt64 = 0) -> MemorySample {
        MemorySample(total: 32 * gio, app: 14 * gio, wired: 6 * gio, compressed: 5 * gio, cached: 0,
                     swapUsed: swap, swapTotal: swap, pressureLevel: pressure)
    }

    static func app(_ name: String, _ id: String, gio footprint: Double, cpu: Double = 5,
                    path: String? = "default") -> ProcessGroup {
        ProcessGroup(bundleId: id, name: name, cpu: cpu, footprint: UInt64(footprint * Double(gio)),
                     processCount: 3,
                     bundlePath: path == "default" ? "/Applications/\(name).app" : path)
    }

    static let premiere = app("Adobe Premiere Pro 2026", "com.adobe.PremierePro.26", gio: 21)
    static let vivaldi = app("Vivaldi", "com.vivaldi.Vivaldi", gio: 6)
    static let claude = app("Claude", "com.anthropic.claudefordesktop", gio: 5)

    /// Un volume de `total` Go dont `free` Go sont libres.
    static func volume(_ name: String, total: UInt64, free: UInt64, interne: Bool = false) -> VolumeSample {
        VolumeSample(name: name, path: interne ? "/" : "/Volumes/\(name)", total: total * go,
                     available: free * go, isInternal: interne, uuid: name.uppercased(),
                     availableStrict: free * go)
    }

    static let macintosh = volume("Macintosh HD", total: 995, free: 600, interne: true)
    static let extreme = volume("Extreme Pro", total: 2_000, free: 719)

    static func verdict(_ input: VerdictInput) -> Verdict {
        VerdictEngine.instant(input, now: now).verdict
    }

    // MARK: - Mémoire

    @Test func laMemoireNommeLaPlusGrosseAppHorsMontage() throws {
        var input = VerdictInput()
        input.memory = Self.memory(pressure: 2, swap: 5 * Self.gio)
        input.processes = [Self.premiere, Self.claude, Self.vivaldi]
        let shown = Self.verdict(input)
        #expect(shown.rule == 6)
        let advice = try #require(Advisor.advice(for: shown, input, now: Self.now))
        // Premiere tient plus, mais c'est l'outil de travail : on ne
        // conseille pas de le fermer.
        #expect(advice.text == "Fermer Vivaldi libère 6,0\u{00A0}Go")
        #expect(advice.action == .activityMonitor)
    }

    @Test func rienAFermerSousUnGo() throws {
        var input = VerdictInput()
        input.memory = Self.memory(pressure: 2)
        input.processes = [Self.premiere, Self.app("Notes", "com.apple.Notes", gio: 0.4)]
        let advice = try #require(Advisor.advice(for: Self.verdict(input), input, now: Self.now))
        #expect(advice.text == "Seul Premiere Pro pèse : 21,0\u{00A0}Go")
    }

    @Test func niAgentSystemeNiServiceSansBundle() throws {
        var input = VerdictInput()
        input.memory = Self.memory(pressure: 2)
        input.processes = [
            Self.app("Spotlight", "com.apple.Spotlight", gio: 3,
                     path: "/System/Library/CoreServices/Spotlight.app"),
            Self.app("VTDecoderXPCService", "exec:VTDecoderXPCService", gio: 4, path: nil),
            Self.app("Vivaldi", "com.vivaldi.Vivaldi", gio: 2),
        ]
        let advice = try #require(Advisor.advice(for: Self.verdict(input), input, now: Self.now))
        #expect(advice.text == "Fermer Vivaldi libère 2,0\u{00A0}Go")
    }

    // MARK: - Disques pleins (règles 3 et 8)

    @Test func unDisquePleinSeVideVersUnExterneJamaisVersLInterne() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        // Ssd 2 à 92 % : 1 840 Go occupés sur 2 000. Sous 90 % : 1 800.
        let ssd = Self.volume("Ssd 2", total: 2_000, free: 160)
        // L'interne a plus de place que l'Extreme Pro : il ne doit pas
        // être proposé pour autant.
        input.volumes = [Self.volume("Macintosh HD", total: 995, free: 900, interne: true), ssd, Self.extreme]
        let shown = Self.verdict(input)
        #expect(shown.rule == 8)
        let advice = try #require(Advisor.advice(for: shown, input, now: Self.now))
        #expect(advice.text == "Déplacer 41\u{00A0}Go vers Extreme Pro (719\u{00A0}Go libres)")
        #expect(advice.action == .finder(path: "/Volumes/Ssd 2", name: "Ssd 2"))
    }

    @Test func leDisqueInterneOuvreLesReglagesDeStockage() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        input.volumes = [Self.volume("Macintosh HD", total: 995, free: 30, interne: true)]
        let shown = Self.verdict(input)
        #expect(shown.rule == 3)
        let advice = try #require(Advisor.advice(for: shown, input, now: Self.now))
        // 965 Go occupés, plafond 895,5 : 69,5 à retirer, arrondis à 70.
        #expect(advice.text == "Libérer 70\u{00A0}Go le ramène sous 90\u{00A0}%")
        #expect(advice.action == .storageSettings)
    }

    @Test func liberer_ramene_vraiment_sous_le_seuil() {
        for free in stride(from: UInt64(1), through: 199, by: 7) {
            let volume = Self.volume("Ssd 2", total: 2_000, free: free)
            let toFree = Advisor.bytesToFree(volume)
            let after = Double(volume.used - toFree) / Double(volume.total)
            #expect(after < VerdictEngine.volumeWarningFraction, "\(free) Go libres : \(toFree) ne suffit pas")
        }
    }

    // MARK: - Disques qui se remplissent (règles 4 et 9)

    @Test func unDisqueQuiSeRemplitDonneLesJoursDeLAutre() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        let ssd = Self.volume("Ssd 2", total: 2_000, free: 307)
        input.volumes = [Self.macintosh, ssd, Self.extreme]
        input.forecasts = ["SSD 2": FillForecast(bytesPerDay: -90.1e9, daysUntilFull: 3.4, ruptures: 0,
                                                 calmSeconds: 86_400, window: 86_400)]
        let shown = Self.verdict(input)
        #expect(shown.rule == 4)
        let advice = try #require(Advisor.advice(for: shown, input, now: Self.now))
        // 719 ÷ 90,1 = 7,98 jours.
        #expect(advice.text == "Extreme Pro a 719\u{00A0}Go libres, ~8 jours à ce rythme")
        #expect(advice.detail.contains("90,1\u{00A0}Go par jour"))
        #expect(advice.action == .finder(path: "/Volumes/Ssd 2", name: "Ssd 2"))
    }

    /// L'idée du chantier 05 : le verdict dit POURQUOI le disque se remplit.
    /// Une copie en cours sur un AUTRE disque ne doit pas être nommée.
    @Test func uneCopieEnCoursDitPourquoiLeDisqueSeRemplit() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        let ssd = Self.volume("Ssd 2", total: 2_000, free: 307)
        input.volumes = [Self.macintosh, ssd, Self.extreme]
        input.forecasts = ["SSD 2": FillForecast(bytesPerDay: -90.1e9, daysUntilFull: 3.4, ruptures: 0,
                                                 calmSeconds: 86_400, window: 86_400)]
        let start = Self.now.addingTimeInterval(-300)
        let ailleurs = Ingestion(kind: .download, target: "Extreme Pro", targetKey: "EXTREME PRO", source: nil,
                                 app: "Vivaldi", start: start, lastActive: Self.now, bytes: 9e9, rate: 30e6,
                                 active: true)
        let carte = Ingestion(kind: .card, target: "Ssd 2", targetKey: "SSD 2", source: "EOS_DIGITAL",
                              app: "ffmpeg", start: start, lastActive: Self.now, bytes: 1.3e9, rate: 4.3e6,
                              active: true)
        let shown = Self.verdict(input)
        #expect(shown.rule == 4)
        let advice = try #require(Advisor.advice(for: shown, input, ingestions: [ailleurs, carte], now: Self.now))
        #expect(advice.text == "Copie de carte en cours (ffmpeg, 1,3\u{00A0}Go)")
        // Le geste n'est pas perdu : il passe dans le détail.
        #expect(advice.detail.contains("Extreme Pro a 719\u{00A0}Go libres, ~8 jours à ce rythme"))
        #expect(advice.action == .finder(path: "/Volumes/Ssd 2", name: "Ssd 2"))
        // Close, elle ne dit plus rien du moment.
        var finie = carte
        finie.active = false
        let calm = try #require(Advisor.advice(for: shown, input, ingestions: [finie], now: Self.now))
        #expect(calm.text.hasPrefix("Extreme Pro a 719"))
    }

    @Test func sansAutreDisqueLibererUneSemaine() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        let ssd = Self.volume("Ssd 2", total: 2_000, free: 307)
        input.volumes = [Self.macintosh, ssd]
        input.forecasts = ["SSD 2": FillForecast(bytesPerDay: -90e9, daysUntilFull: 3.4, ruptures: 0,
                                                 calmSeconds: 86_400)]
        let advice = try #require(Advisor.advice(for: Self.verdict(input), input, now: Self.now))
        #expect(advice.text == "Libérer 630\u{00A0}Go donne une semaine de plus")
    }

    // MARK: - Plantage, processeur, calme

    @Test func unPlantageDitLaMemoireDuMoment() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        let crash = Self.now.addingTimeInterval(-600)
        input.incidents = [Incident(app: "Adobe Premiere Pro 2026", bundleId: nil, kind: .crash, date: crash)]
        let t = crash.timeIntervalSince1970
        // Trois points de la série de l'heure ; celui de t - 5 est le bon.
        input.series = [SeriesPoint(t: t - 125, ram: 0.80, swap: 2 * Double(Self.gio), cpu: 0.5, gpu: 0.4),
                        SeriesPoint(t: t - 5, ram: 0.97, swap: 7 * Double(Self.gio), cpu: 0.9, gpu: 0.8),
                        SeriesPoint(t: t + 115, ram: 0.60, swap: 7 * Double(Self.gio), cpu: 0.1, gpu: 0.1)]
        let shown = Self.verdict(input)
        #expect(shown.rule == 5)
        let advice = try #require(Advisor.advice(for: shown, input, now: Self.now))
        #expect(advice.text == "Au plantage : mémoire à 97\u{00A0}%, swap 7,0\u{00A0}Go")
    }

    @Test func leProcesseurRendDesCoeursAuMontage() throws {
        var input = VerdictInput()
        input.memory = Self.memory()
        input.cpu.total = 0.95
        input.processes = [Self.app("Vivaldi", "com.vivaldi.Vivaldi", gio: 2, cpu: 250),
                           Self.app("Adobe Premiere Pro 2026", "com.adobe.PremierePro.26", gio: 21, cpu: 180)]
        let shown = Self.verdict(input)
        #expect(shown.rule == 10)
        #expect(shown.object == .app(bundleId: "com.vivaldi.Vivaldi"))
        let advice = try #require(Advisor.advice(for: shown, input, now: Self.now))
        #expect(advice.text == "Fermer Vivaldi rend 2,5 cœurs à Premiere Pro")
    }

    @Test func leCalmeNeConseillePasDeGeste() {
        var input = VerdictInput()
        input.memory = Self.memory()
        input.volumes = [Self.macintosh, Self.extreme]
        input.processes = [Self.premiere, Self.vivaldi]
        let shown = Self.verdict(input)
        #expect(shown.rule == 12)
        #expect(Advisor.advice(for: shown, input, now: Self.now) == nil)
    }

    @Test func coeursAuSingulierSousDeux() {
        #expect(Advisor.cores(100) == "1 cœur")
        #expect(Advisor.cores(150) == "1,5 cœur")
        #expect(Advisor.cores(250) == "2,5 cœurs")
        #expect(Advisor.cores(304) == "3 cœurs")
    }
}

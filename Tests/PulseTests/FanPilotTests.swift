import Foundation
import Testing
@testable import Pulse
@testable import PulseFanKit

/// Le pilote côté Pulse (chantier 14) : ce qu'il décide à chaque battement,
/// sans helper ni SMC — et qu'en automatique il ne fait rien.
@Suite struct FanPilotTests {
    private let fans = SimulatedFans.m2Max

    @Test func enAutomatiqueOnRendLaMain() {
        var follower = FanFollower(), misses = 0
        let decision = FanEngine.decide(settings: FanSettings(), fans: fans, cpu: 70, gpu: 60,
                                        follower: &follower, misses: &misses)
        #expect(decision == .release(.requested, ""))
    }

    @Test func vitesseFixeDansLesBornesDeChaqueVentilateur() {
        var settings = FanSettings()
        settings.mode = .fixed
        settings.fixedLevel = 0.5
        var follower = FanFollower(), misses = 0
        let decision = FanEngine.decide(settings: settings, fans: fans, cpu: nil, gpu: nil,
                                        follower: &follower, misses: &misses)
        #expect(decision == .hold(targets: [3_350, 3_650], level: 0.5, temperature: nil))
    }

    /// La courbe d'origine : à 75 °C, 60 % de la plage de chaque ventilateur ;
    /// au-dessus de 90 °C, le maximum.
    @Test func laCourbeSuitLaPlusChaudeDesDeux() {
        var settings = FanSettings()
        settings.mode = .curve
        var follower = FanFollower(), misses = 0
        guard case .hold(let targets, let level, let temperature) =
                FanEngine.decide(settings: settings, fans: fans, cpu: 75, gpu: 60, follower: &follower, misses: &misses)
        else { Issue.record("pas de consigne"); return }
        #expect(targets == [3_749, 4_075])
        #expect(abs(level - 0.6) < 1e-9)
        #expect(temperature == 75)
        // 2 °C de moins : l'hystérésis tient la consigne.
        guard case .hold(let held, _, _) =
                FanEngine.decide(settings: settings, fans: fans, cpu: 73, gpu: 60, follower: &follower, misses: &misses)
        else { Issue.record("pas de consigne"); return }
        #expect(held == [3_749, 4_075])
        var hot = FanFollower()
        #expect(FanEngine.decide(settings: settings, fans: fans, cpu: 70, gpu: 96, follower: &hot, misses: &misses)
                == .hold(targets: [5_349, 5_777], level: 1, temperature: 96))
    }

    /// Trois lectures de suite sans température : la main à macOS.
    @Test func sansTemperatureTroisFoisOnRendLaMain() {
        var settings = FanSettings()
        settings.mode = .curve
        var follower = FanFollower(), misses = 0
        for _ in 0..<2 {
            let decision = FanEngine.decide(settings: settings, fans: fans, cpu: nil, gpu: nil,
                                            follower: &follower, misses: &misses)
            #expect(decision == .wait("Température manquée."))
        }
        let third = FanEngine.decide(settings: settings, fans: fans, cpu: nil, gpu: nil,
                                     follower: &follower, misses: &misses)
        #expect(third == .release(.sensorLost, "La température ne se lit plus : macOS reprend la main."))
        // Une lecture revenue remet le compte à zéro.
        _ = FanEngine.decide(settings: settings, fans: fans, cpu: 60, gpu: nil, follower: &follower, misses: &misses)
        #expect(misses == 0)
    }

    @Test func sansVentilateursLisiblesOnRendLaMain() {
        var settings = FanSettings()
        settings.mode = .fixed
        var follower = FanFollower(), misses = 0
        var absurd = fans
        absurd[0].max = 0
        _ = FanEngine.decide(settings: settings, fans: [], cpu: 60, gpu: 60, follower: &follower, misses: &misses)
        _ = FanEngine.decide(settings: settings, fans: absurd, cpu: 60, gpu: 60, follower: &follower, misses: &misses)
        let third = FanEngine.decide(settings: settings, fans: [], cpu: 60, gpu: 60, follower: &follower, misses: &misses)
        #expect(third == .release(.sensorLost, "Les ventilateurs ne se lisent plus : macOS reprend la main."))
    }

    /// Le défaut, sans fichier : automatique — rien d'actif tant qu'Isma
    /// n'a rien choisi. Et `--snapshot` (persistance coupée) n'écrit rien.
    @Test func parDefautRienNEstActifEtRienNEstEcrit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-ventilateurs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FanSettingsStore(url: folder.appendingPathComponent("ventilateurs.json"), writes: false)
        #expect(store.load().mode == .automatic)
        var settings = FanSettings()
        settings.mode = .fixed
        store.save(settings)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        let writing = FanSettingsStore(url: store.url, writes: true)
        writing.save(settings)
        #expect(writing.load().mode == .fixed)
    }
}

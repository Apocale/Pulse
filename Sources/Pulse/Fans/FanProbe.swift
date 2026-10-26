import Foundation
import PulseFanKit

/// Section VENTILATEURS de `--probe` : chaque chiffre de la page
/// Ventilateurs, et l'état du helper. Lecture seule : le SMC est lu par le
/// lecteur du chantier 04, le helper n'est interrogé (« état », qui n'écrit
/// rien) que s'il est installé.
@MainActor
enum FanProbe {
    static func lines() -> [String] {
        var out: [String] = []
        func line(_ label: String, _ text: String) {
            out.append(label.padding(toLength: 17, withPad: " ", startingAt: 0) + text)
        }

        let state = FanHelperService.state
        line("helper", state.probeText)
        line("embarqué", FanHelperService.bundledDescription)

        let store = FanSettingsStore()
        let exists = FileManager.default.fileExists(atPath: store.url.path)
        let settings = store.load()
        line("mode", settings.mode.label.lowercased()
             + (exists ? " (ventilateurs.json)" : " (défaut : ventilateurs.json absent)"))

        let monitor = SensorMonitor()
        let sample = monitor.sample(withReport: false)
        let fans = sample.fans.map {
            FanReading(index: $0.index, actual: $0.rpm, min: $0.min, max: $0.max, target: $0.target, manual: $0.forced)
        }
        if fans.isEmpty { line("ventilateurs", "illisibles au SMC") }
        for fan in fans {
            line("ventilateur \(fan.index + 1)",
                 "\(FanSettingsPage.rpm(fan.actual)) tr/min · min \(FanSettingsPage.rpm(fan.min)) · max \(FanSettingsPage.rpm(fan.max))"
                 + (fan.target.map { " · consigne \(FanSettingsPage.rpm($0))" } ?? "")
                 + (fan.manual ? " · IMPOSÉE (F\(fan.index)Md = 1)" : " · macOS (F\(fan.index)Md = 0)"))
        }

        let fixed = FanPlan.targets(level: settings.fixedLevel, fans: fans)
        line("vitesse fixe", "\(Int((settings.fixedLevel * 100).rounded())) % de la plage → "
             + fixed.map { FanSettingsPage.rpm($0) }.joined(separator: " et ") + " tr/min")
        line("courbe", settings.curve.sanitized.points
             .map { "\(Int($0.celsius.rounded())) °C → \(FanSettingsPage.levelText($0.level))" }
             .joined(separator: " · ") + " (suit : \(settings.sensor.label.lowercased()))")
        let cpu = sample.cpuTemperature, gpu = sample.gpuTemperature
        if let celsius = settings.sensor.pick(cpu: cpu, gpu: gpu) {
            // Ce que le pilote enverrait : le niveau au pas de 5 %.
            let level = FanPlan.quantized(settings.curve.level(at: celsius))
            line("maintenant", "processeur \(cpu.map { "\(Int($0.rounded())) °C" } ?? "—"), carte graphique \(gpu.map { "\(Int($0.rounded())) °C" } ?? "—")"
                 + " → \(Int(celsius.rounded())) °C suivis → \(FanSettingsPage.levelText(level))"
                 + " → " + FanPlan.targets(level: level, fans: fans).map { FanSettingsPage.rpm($0) }.joined(separator: " et ")
                 + " tr/min" + (settings.mode == .curve ? "" : " (si la courbe était choisie)"))
        } else {
            line("maintenant", "température suivie illisible")
        }

        if state == .installed {
            let status = FanXPCClient().sendAndWait(.status, timeout: 2)
            if let status {
                line("helper (XPC)", (status.manual ? "consigne imposée" : "automatique")
                     + " · dernier retour : \(status.fallback.phrase)"
                     + (status.fallbackAge.map { " il y a \($0) s" } ?? "")
                     + " · pression thermique \(status.pressure.map(String.init) ?? "?")"
                     + (status.lockRemaining > 0 ? " · pause \(status.lockRemaining) s" : "")
                     + " · \(status.writesUsed) écriture(s) sur \(FanProtocol.writeBudget) depuis le démarrage"
                     + " · pid \(status.helperPID)")
                if let upToDate = FanHelperService.upToDate {
                    line("version", upToDate ? "le helper installé est celui de ce Pulse"
                                             : "le helper installé diffère de celui de ce Pulse : « Mettre à jour… »")
                }
            } else {
                line("helper (XPC)", "installé mais muet")
            }
        } else {
            line("helper (XPC)", "aucune demande : helper non installé")
        }

        let journal = HelperJournal.tail(5)
        if journal.isEmpty {
            line("journal", "vide (\(HelperJournal.path) absent : le helper n'a jamais tourné)")
        } else {
            line("journal", HelperJournal.path)
            for entry in journal { out.append("  " + entry) }
        }
        return out
    }
}

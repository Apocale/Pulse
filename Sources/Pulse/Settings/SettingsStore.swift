import Foundation
import Combine

/// Les réglages d'Isma, lus au lancement et écrits à chaque changement dans
/// `~/Library/Application Support/Pulse/reglages.json`.
///
/// Fichier à part, comme `reseau.json` et `verdicts.jsonl` : un réglage
/// abîmé ne doit jamais pouvoir coûter l'historique. Illisible malgré le
/// décodage tolérant, il est mis de côté en `reglages.illisible.json`, jamais
/// écrasé — même règle que `history.json`.
///
/// `Persistence.enabled` faux (`--snapshot`, `--probe`, `--banc`) : lu, jamais
/// écrit.
@MainActor
final class SettingsStore: ObservableObject {
    /// Les réglages de l'app, partagés par le panneau, la fenêtre Réglages et
    /// le sampler.
    static let shared = SettingsStore()

    @Published var settings: PulseSettings {
        didSet { if settings != oldValue { scheduleSave() } }
    }

    let url: URL
    /// Faux sous `--snapshot` (`Persistence`) : lu, jamais écrit. Figé à la
    /// création, pour qu'un test ne dépende pas de l'état global.
    let writes: Bool
    private var pendingSave: DispatchWorkItem?

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("reglages.json")
    }

    init(url: URL = SettingsStore.defaultURL, writes: Bool? = nil) {
        self.url = url
        let writes = writes ?? Persistence.enabled
        self.writes = writes
        settings = Self.load(from: url, setAside: writes)
    }

    /// Lecture tolérante. Absent : réglages par défaut. Illisible — pas même
    /// un objet JSON — : mis de côté, puis réglages par défaut.
    static func load(from url: URL, setAside: Bool) -> PulseSettings {
        guard let data = try? Data(contentsOf: url) else { return PulseSettings() }
        if let decoded = try? JSONDecoder().decode(PulseSettings.self, from: data) { return decoded }
        if setAside { Persistence.setAside(url) }
        return PulseSettings()
    }

    static func encode(_ settings: PulseSettings) throws -> Data {
        let encoder = JSONEncoder()
        // Lisible à l'œil : c'est aussi le format de l'export.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    /// Écrit au tour de boucle suivant, une fois pour une rafale de
    /// changements (un glisser-déposer en produit plusieurs).
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// À la sortie de l'app : écrit ce qui attendait encore, rien d'autre.
    func flush() {
        if pendingSave != nil { save() }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard writes, let data = try? Self.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Export : le fichier même, lisible, à garder ou à copier sur un autre Mac.
    func export(to destination: URL) throws {
        try Self.encode(settings).write(to: destination, options: .atomic)
    }

    /// Import tolérant : chaque champ lisible est repris, le reste garde sa
    /// valeur par défaut. Un fichier qui n'est pas un objet JSON est refusé
    /// et les réglages en place restent intacts.
    func importSettings(from source: URL) throws {
        let data = try Data(contentsOf: source)
        settings = try JSONDecoder().decode(PulseSettings.self, from: data)
    }
}

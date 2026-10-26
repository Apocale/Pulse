import Foundation

/// Le journal des disques : `disques.json`, à part de history.json — un
/// fichier abîmé ici ne peut rien coûter d'autre.
///
/// Deux choses y vivent. Les écritures massives : un épisode entre quand il
/// se clôt, et pendant qu'il dure toutes les minutes, marqué « en cours » —
/// c'est ce qui permet à `--probe`, un autre processus, de montrer le même
/// chiffre que la carte ; 30 jours. Et le dernier bilan « ce qui remplit »
/// de chaque volume, pour que la carte l'ait dès le lancement et que
/// `--probe` le montre.
///
/// Touché depuis la file d'échantillonnage (épisodes) et depuis la file des
/// requêtes Spotlight (bilans) : d'où le verrou.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : tout son état passe par son verrou.
final class DiskJournal: @unchecked Sendable {
    private struct File: Codable {
        var version: Int = 1
        var episodes: [Ingestion] = []
        var fill: [FillReport] = []

        init() {}

        /// Règle dure n°2 : chaque champ en `decodeIfPresent`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
            episodes = (try? c.decodeIfPresent([Ingestion].self, forKey: .episodes)) ?? []
            fill = (try? c.decodeIfPresent([FillReport].self, forKey: .fill)) ?? []
        }
    }

    static let window: TimeInterval = 30 * 86_400
    /// Écriture au plus une fois par minute tant qu'un épisode dure.
    static let saveInterval: TimeInterval = 60

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("disques.json")
    }

    private let lock = NSLock()
    private var file = File()
    private var lastSave: Date = .distantPast

    init() {
        file = Self.load(setAside: true) ?? File()
        file.episodes = Self.normalize(file.episodes, now: Date())
    }

    /// Les épisodes connus, du plus ancien au plus récent. Un épisode resté
    /// « en cours » dans le fichier alors que plus personne ne le suit — Pulse
    /// quitté en pleine copie — est rendu clos à sa dernière activité connue.
    /// `--probe` lit et n'écrit jamais.
    static func read(now: Date = Date()) -> [Ingestion] {
        normalize(load(setAside: false)?.episodes ?? [], now: now)
    }

    /// Les derniers bilans « ce qui remplit », un par volume.
    static func readFill() -> [FillReport] {
        load(setAside: false)?.fill ?? []
    }

    /// `setAside` : l'app seule met de côté un fichier illisible.
    private static func load(setAside: Bool) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let decoded = try? JSONDecoder().decode(File.self, from: data) { return decoded }
        // Illisible malgré le décodage tolérant : mis de côté, jamais écrasé.
        if setAside, Persistence.enabled { Persistence.setAside(url) }
        return nil
    }

    private static func normalize(_ episodes: [Ingestion], now: Date) -> [Ingestion] {
        episodes
            .filter { now.timeIntervalSince($0.lastActive) <= window }
            .map { episode in
                var e = episode
                if e.active, now.timeIntervalSince(e.lastActive) > IngestionDetector.grace * 2 {
                    e.active = false
                    e.rate = 0
                }
                return e
            }
            .sorted { $0.start < $1.start }
    }

    /// Les épisodes clos, les plus récents d'abord.
    var finished: [Ingestion] {
        lock.lock(); defer { lock.unlock() }
        return file.episodes.filter { !$0.active }.sorted { $0.start > $1.start }
    }

    /// Les derniers bilans « ce qui remplit », par clé de volume.
    var fill: [String: FillReport] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(file.fill.map { ($0.volumeKey, $0) }, uniquingKeysWith: { a, b in a.at > b.at ? a : b })
    }

    /// Un relevé du détecteur. Écrit sur disque quand un épisode se clôt, et
    /// au plus une fois par minute tant qu'un autre dure.
    func record(active: [Ingestion], finished: [Ingestion], now: Date = Date()) {
        guard !active.isEmpty || !finished.isEmpty else { return }
        lock.lock()
        for episode in finished + active {
            if let i = file.episodes.firstIndex(where: { $0.id == episode.id }) {
                file.episodes[i] = episode
            } else {
                file.episodes.append(episode)
            }
        }
        file.episodes.removeAll { now.timeIntervalSince($0.lastActive) > Self.window }
        let due = !finished.isEmpty || now.timeIntervalSince(lastSave) >= Self.saveInterval
        lock.unlock()
        if due { save(now: now) }
    }

    /// Un nouveau bilan pour un volume : il remplace le précédent.
    func record(fill report: FillReport) {
        lock.lock()
        file.fill.removeAll { $0.volumeKey == report.volumeKey }
        file.fill.append(report)
        // Un volume qu'on ne voit plus depuis 30 jours n'a plus rien à dire.
        file.fill.removeAll { report.at.timeIntervalSince($0.at) > Self.window }
        lock.unlock()
        save(now: report.at)
    }

    /// L'encodage sous verrou, l'écriture en dehors.
    private func save(now: Date) {
        guard Persistence.enabled else { return }
        lock.lock()
        lastSave = now
        let data = try? JSONEncoder().encode(file)
        lock.unlock()
        guard let data else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

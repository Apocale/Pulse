import Foundation

/// Une écriture massive sur un disque externe, nommée : ce qui fait dire
/// « Ssd 2 plein vers mardi » cesse d'être une alarme anonyme quand on lit
/// « Téléchargement → Ssd 2 · 45 Go depuis 14 h 02 ».
struct Ingestion: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// Un disque amovible (carte SD, appareil photo) lit pendant que la
        /// cible écrit : une ingestion de rushes au sens propre.
        case card
        /// Un autre disque lit pendant que la cible écrit.
        case copy
        /// Le réseau reçoit pendant que la cible écrit.
        case download
        /// Un encodeur exporte (Media Encoder, Compressor).
        case export
        /// Rien de tout cela : une application écrit, nommée si on la voit.
        case write
    }

    var kind: Kind
    /// Le volume écrit, « Ssd 2 ».
    var target: String
    /// Sa clé d'historique (UUID), pour le relier à la prévision.
    var targetKey: String?
    /// « carte EOS_DIGITAL », « SSD 1 » : pour une copie seulement.
    var source: String?
    /// L'application qui a écrit le plus pendant l'épisode, si elle pèse au
    /// moins un quart des octets ; sinon un processus d'un autre compte
    /// (illisible sans root), et on ne l'invente pas.
    var app: String?
    var start: Date
    var lastActive: Date
    /// Octets écrits sur le disque cible pendant l'épisode.
    var bytes: Double
    /// Débit d'écriture du dernier relevé, 0 une fois l'épisode clos.
    var rate: Double = 0
    var active: Bool = false

    var id: String { "\(targetKey ?? target)-\(Int(start.timeIntervalSince1970))" }
    var duration: TimeInterval { lastActive.timeIntervalSince(start) }

    /// « Copie de carte », « Téléchargement »…
    var label: String {
        switch kind {
        case .card:     return "Copie de carte"
        case .copy:     return source.map { "Copie depuis \($0)" } ?? "Copie"
        case .download: return "Téléchargement"
        case .export:   return "Export"
        case .write:    return "Écriture"
        }
    }

    init(kind: Kind, target: String, targetKey: String?, source: String?, app: String?,
         start: Date, lastActive: Date, bytes: Double, rate: Double = 0, active: Bool = false) {
        self.kind = kind; self.target = target; self.targetKey = targetKey; self.source = source
        self.app = app; self.start = start; self.lastActive = lastActive; self.bytes = bytes
        self.rate = rate; self.active = active
    }

    /// Décodage écrit à la main (règle dure n°2) : un champ ajouté plus tard
    /// ne doit jamais coûter le journal des épisodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .write
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? "?"
        targetKey = try? c.decodeIfPresent(String.self, forKey: .targetKey)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        start = (try? c.decodeIfPresent(Date.self, forKey: .start)) ?? .distantPast
        lastActive = (try? c.decodeIfPresent(Date.self, forKey: .lastActive)) ?? start
        bytes = (try? c.decodeIfPresent(Double.self, forKey: .bytes)) ?? 0
        rate = (try? c.decodeIfPresent(Double.self, forKey: .rate)) ?? 0
        active = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
    }
}

/// Ce que le détecteur voit à chaque relevé.
struct IngestionInput {
    struct Disk {
        var id: UInt64
        var name: String
        var volumeKey: String?
        var isInternal: Bool
        var isRemovable: Bool
        var read: Double      // octets par seconde
        var write: Double
        /// Périphériques (`st_dev`) des volumes de ce disque.
        var devices: Set<UInt32> = []
    }
    var now: Date
    /// Durée couverte par les débits, en secondes.
    var interval: Double
    var disks: [Disk]
    /// Réception réseau, octets par seconde.
    var networkRx: Double
    /// Une application qui écrit.
    struct App {
        var name: String
        var read: Double = 0
        var write: Double
        var encoder: Bool = false
        /// Où elle tient des fichiers ouverts en écriture : lu seulement
        /// quand un disque externe écrit assez pour ouvrir un épisode.
        var devices: Set<UInt32>? = nil
    }
    var apps: [App]
    /// Un export reconnu par `ExportDetector`.
    var exporting: Bool
}

/// Repère les écritures massives sur les disques EXTERNES et les nomme.
///
/// Le disque interne est écarté exprès : le swap et les services du système
/// y écrivent sans cesse — 15,7 Mo/s relevés le 11/10 sans aucune application
/// visible —, et ces écrivains appartiennent à un autre compte, illisible sans
/// root. Chaque épisode y serait anonyme ; et le swap ne remplit pas le disque.
///
/// Un épisode s'ouvre au premier relevé où la cible écrit à 2 Mo/s ou plus,
/// et se ferme après une minute sous ce débit. Il n'est montré qu'au-delà de
/// 1 Go écrits : un enregistrement automatique, un cache de vignettes ne sont
/// pas des ingestions. Sa nature se décide à chaque relevé, pondérée par les
/// octets écrits : un téléchargement qui marque une pause reste un
/// téléchargement.
struct IngestionDetector {
    /// Débit d'écriture qui ouvre ou prolonge un épisode : 2 Mo/s. Bien
    /// au-dessous d'un export (≈ 30 Mo/s) et d'une ingestion de carte (200 à
    /// 400 Mo/s), au-dessus des écritures de fond d'un disque de rushes.
    static let activeRate = 2_000_000.0
    /// Pause tolérée avant de clore : une copie Finder marque des temps morts
    /// entre deux gros fichiers.
    static let grace: TimeInterval = 60
    /// Seuil d'affichage.
    static let massive = 1_000_000_000.0
    /// Une source (disque qui lit, réseau qui reçoit) doit couvrir au moins
    /// la moitié de l'écriture pour qu'on la désigne.
    static let sourceShare = 0.5
    /// Une application doit porter au moins un quart des octets pour être
    /// nommée.
    static let appShare = 0.25

    private struct Open {
        var target: String
        var targetKey: String?
        var start: Date
        var lastActive: Date
        var bytes: Double = 0
        var rate: Double = 0
        var votes: [Ingestion.Kind: Double] = [:]
        var sources: [String: Double] = [:]
        /// Octets de l'épisode attribués à chaque application.
        var apps: [String: Double] = [:]
    }

    private var open: [UInt64: Open] = [:]

    /// Un relevé. Rend les épisodes en cours (au-delà du seuil d'affichage)
    /// et ceux qui viennent de se clore.
    mutating func observe(_ input: IngestionInput) -> (active: [Ingestion], finished: [Ingestion]) {
        var finished: [Ingestion] = []
        let present = Set(input.disks.map(\.id))
        // Un disque débranché en pleine copie : l'épisode s'arrête là.
        for (id, episode) in open where !present.contains(id) {
            if let done = Self.publish(episode, active: false) { finished.append(done) }
            open[id] = nil
        }

        for disk in input.disks where !disk.isInternal {
            guard disk.write >= Self.activeRate else {
                if let episode = open[disk.id], input.now.timeIntervalSince(episode.lastActive) > Self.grace {
                    if let done = Self.publish(episode, active: false) { finished.append(done) }
                    open[disk.id] = nil
                } else if var episode = open[disk.id] {
                    episode.rate = disk.write
                    open[disk.id] = episode
                }
                continue
            }
            var episode = open[disk.id] ?? Open(target: disk.name, targetKey: disk.volumeKey,
                                                start: input.now.addingTimeInterval(-input.interval),
                                                lastActive: input.now)
            let written = disk.write * input.interval
            episode.bytes += written
            episode.rate = disk.write
            episode.lastActive = input.now

            let (kind, source) = Self.classify(disk, in: input)
            episode.votes[kind, default: 0] += written
            if let source { episode.sources[source, default: 0] += written }
            if let writer = Self.writer(for: disk, in: input) {
                episode.apps[writer, default: 0] += written
            }
            open[disk.id] = episode
        }

        let active = open.values.compactMap { Self.publish($0, active: true) }
            .sorted { $0.start < $1.start }
        return (active, finished)
    }

    /// La nature d'une écriture sur UN relevé, et sa source.
    ///
    /// Une copie lit autant qu'elle écrit : la source est le disque dont la
    /// lecture tient entre la moitié et le triple de l'écriture. Le disque
    /// interne lit sans cesse pour d'autres (109 Mo/s relevés le 11/10, pendant
    /// que Ssd 2 recevait 3,1 Mo/s de proxies ffmpeg — « Copie depuis
    /// Macintosh HD » à tort) : il n'est désigné que si l'écrivain lui-même lit
    /// autant qu'il écrit, ce que ne fait pas un transcodage. Une carte, elle,
    /// ne lit que pour être copiée. Puis le réseau, s'il reçoit ce que le
    /// disque écrit ; puis un encodeur au travail.
    static func classify(_ disk: IngestionInput.Disk, in input: IngestionInput) -> (kind: Ingestion.Kind, source: String?) {
        let writer = writerApp(for: disk, in: input)
        let copier = writer.map { $0.read >= $0.write * 0.5 && $0.read <= $0.write * 2 } ?? false
        func matches(_ rate: Double, floor: Double) -> Bool {
            rate >= max(floor, disk.write * sourceShare) && rate <= max(disk.write * 3, floor * 3)
        }
        let reader = input.disks
            .filter { $0.id != disk.id && matches($0.read, floor: 5_000_000) && (!$0.isInternal || copier) }
            .min { abs(log($0.read / disk.write)) < abs(log($1.read / disk.write)) }
        if let reader {
            return reader.isRemovable ? (.card, "carte \(reader.name)") : (.copy, reader.name)
        }
        if matches(input.networkRx, floor: 1_000_000) { return (.download, nil) }
        if input.exporting || (input.apps.max { $0.write < $1.write }?.encoder ?? false) { return (.export, nil) }
        return (.write, nil)
    }

    /// L'écrivain : parmi les applications qui tiennent un fichier ouvert en
    /// écriture sur un volume de ce disque, celle qui écrit le plus. Aucune :
    /// un processus d'un autre compte, ou une app qui referme ses fichiers
    /// entre deux écritures — on ne le devine pas au débit, qui a désigné
    /// Xcode pour des proxies ffmpeg (voir `WrittenDevices`).
    static func writer(for disk: IngestionInput.Disk, in input: IngestionInput) -> String? {
        writerApp(for: disk, in: input)?.name
    }

    private static func writerApp(for disk: IngestionInput.Disk, in input: IngestionInput) -> IngestionInput.App? {
        guard disk.write > 0, !disk.devices.isEmpty else { return nil }
        return input.apps
            .filter { !($0.devices ?? []).isDisjoint(with: disk.devices) }
            .max { $0.write < $1.write }
    }

    /// L'épisode tel qu'on le montre, ou `nil` sous le seuil d'affichage.
    private static func publish(_ episode: Open, active: Bool) -> Ingestion? {
        guard episode.bytes >= massive else { return nil }
        let kind = episode.votes.max { $0.value < $1.value }?.key ?? .write
        let source = (kind == .card || kind == .copy)
            ? episode.sources.max { $0.value < $1.value }?.key : nil
        let top = episode.apps.max { $0.value < $1.value }
        let app = top.flatMap { $0.value >= episode.bytes * appShare ? $0.key : nil }
        return Ingestion(kind: kind, target: episode.target, targetKey: episode.targetKey,
                         source: source, app: app, start: episode.start, lastActive: episode.lastActive,
                         bytes: episode.bytes, rate: active ? episode.rate : 0, active: active)
    }
}

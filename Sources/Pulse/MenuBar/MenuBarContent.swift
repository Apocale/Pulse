import Foundation

/// Un segment prêt à dessiner : ses valeurs du moment, son style, et les
/// chaînes les plus larges sur lesquelles sa colonne se fige.
struct MenuBarPiece: Equatable {
    var id: String
    var style: MenuBarSettings.Style
    /// Le débit : ↑ sur ↓, sans étiquette.
    var stacked = false
    /// « MÉM » ; débit : « ↑8,7k ». Vide : la mesure manque (hors ligne),
    /// la colonne reste réservée et vide — un « 0k » se lirait comme une
    /// mesure.
    var label: String
    /// « 72 % » ; débit : « ↓16k ».
    var value: String
    /// Part d'un total réel, de 0 à 1 (jauge, anneau, graphe).
    var fraction: Double?
    /// Graphe : du plus ancien au plus récent, de 0 à 1.
    var history: [Double] = []
    /// Débit en graphe : la réception, dessinée sous l'axe.
    var historyDown: [Double] = []
    var widestLabel: String
    var widestValue: String
    /// Ce que l'infobulle et VoiceOver disent du segment.
    var spoken: String

    var isEmpty: Bool { label.isEmpty && value.isEmpty }
}

/// Le symbole du verdict dans la barre : un triangle plein pour une alerte,
/// en contour pour un avertissement — la forme dit le niveau, jamais la
/// couleur, qu'une image template n'a de toute façon pas.
struct MenuBarAlert: Equatable {
    static let alertSymbol = "exclamationmark.triangle.fill"
    static let warningSymbol = "exclamationmark.triangle"
    /// Une règle d'Isma en cours (chantier 11) : une cloche.
    static let ruleSymbol = "bell.fill"

    var symbol: String
    var spoken: String
}

/// Tout ce qu'un élément de barre de menus dessine.
struct MenuBarContent: Equatable {
    /// La place du symbole est réservée même sans alerte : la largeur ne
    /// bouge pas quand l'alerte arrive — sinon l'icône la plus à gauche
    /// passerait sous l'encoche au moment précis où il y a quelque chose à
    /// voir.
    var reservesAlert: Bool
    var alert: MenuBarAlert?
    var pieces: [MenuBarPiece]

    /// La phrase de l'infobulle et de VoiceOver : une image template n'expose
    /// rien d'elle-même.
    var spoken: String {
        var parts = pieces.map(\.spoken).filter { !$0.isEmpty }
        if let alert { parts.insert(alert.spoken, at: 0) }
        return "Pulse — " + (parts.isEmpty ? "ouvrir le panneau" : parts.joined(separator: " · "))
    }

    /// La même composition avec les valeurs les plus larges : c'est sur elle
    /// que la largeur de l'élément se fige.
    var widest: MenuBarContent {
        var copy = self
        if reservesAlert { copy.alert = MenuBarAlert(symbol: MenuBarAlert.alertSymbol, spoken: "") }
        copy.pieces = pieces.map { piece in
            var p = piece
            p.label = piece.stacked ? "↑" + piece.widestValue : piece.widestLabel
            p.value = piece.stacked ? "↓" + piece.widestValue : piece.widestValue
            p.fraction = piece.fraction.map { _ in 1 }
            return p
        }
        return copy
    }
}

/// Les derniers relevés de chaque segment, pour le mini-graphe : un point par
/// relevé du `Sampler` (toutes les 5 s panneau fermé), douze gardés — une
/// minute. En mémoire seulement : rien à garder d'un lancement à l'autre.
@MainActor
final class MenuBarHistory {
    static let length = 12
    private(set) var values: [String: [Double]] = [:]
    private var last: Date = .distantPast

    /// Au lancement, les douze derniers points de la série d'une heure du
    /// `Sampler` (un toutes les 10 s) : le graphe de la mémoire et du
    /// processeur n'attend pas une minute pour se dessiner.
    func seed(from sampler: Sampler) {
        let recent = sampler.series.suffix(Self.length)
        guard !recent.isEmpty else { return }
        if values["memoire"] == nil { values["memoire"] = recent.map { min(1, max(0, $0.ram)) } }
        if values["processeur"] == nil { values["processeur"] = recent.map { min(1, max(0, $0.cpu)) } }
    }

    /// Ajoute les parts du moment, une fois par relevé au plus : le libellé
    /// se refait jusqu'à une fois par seconde, le relevé toutes les 5 s.
    func record(_ fractions: [String: Double], now: Date = Date(), every: TimeInterval = 4.5) {
        guard now.timeIntervalSince(last) >= every else { return }
        last = now
        for (id, value) in fractions {
            values[id] = Array((values[id, default: []] + [min(1, max(0, value))]).suffix(Self.length))
        }
    }
}

/// Le débit affiché ne change que s'il change VRAIMENT : d'au moins 30 % —
/// et d'au moins 3 ko/s, sous 10 ko/s ce n'est que le bruit du repos — ou
/// d'une unité (k → M), sinon la barre garde le chiffre affiché.
///
/// L'icône est le premier poste du budget de Pulse : mesuré le 11/10 par le
/// chantier 03, 0,75 % d'un cœur pour le Pulse installé contre 0,30 % au banc
/// sans icône — environ 0,45 point pour une trentaine d'affichages par minute,
/// presque tous dus au débit, qui change à chaque relevé de 2 s (« 6,0k »,
/// « 7,5k », « 6,8k »…). Au repos ces écarts ne disent rien ; une vraie
/// montée (un envoi de rushes) passe aussitôt.
///
/// Relevé sur le Pulse installé le 11/10 (description d'accessibilité lue
/// deux minutes) : 15 images par minute avec la seule bande de 30 % — les
/// « 1,0k », « 2,6k », « 3,6k » du repos en faisaient encore la moitié.
///
/// Le chiffre gardé n'est jamais faux de plus de 30 % ou de 3 ko/s, et
/// l'infobulle dit le même que l'image. `--probe` imprime le relevé brut.
@MainActor
final class MenuBarRateFilter {
    static let band = 0.30
    /// Sous ce débit, la bande se compte sur lui : 3 ko/s.
    static let floor = 10_000.0
    private(set) var shown: (up: Double, down: Double)?

    func filter(up: Double, down: Double) -> (up: Double, down: Double) {
        guard let shown else {
            self.shown = (up, down)
            return (up, down)
        }
        let next = (up: Self.keep(shown.up, up) ? shown.up : up,
                    down: Self.keep(shown.down, down) ? shown.down : down)
        self.shown = next
        return next
    }

    /// Garder l'affiché : même texte, ou un écart de moins de 30 % (de
    /// moins de 3 ko/s sous 10 ko/s) qui ne change pas d'unité.
    static func keep(_ shown: Double, _ new: Double) -> Bool {
        let a = Fmt.compactRate(shown), b = Fmt.compactRate(new)
        if a == b { return true }
        if a.last != b.last { return false }
        return abs(new - shown) < band * max(shown, floor)
    }
}

/// Compose la barre à partir des valeurs des modules et des réglages d'Isma.
@MainActor
enum MenuBarComposer {
    static let alertSymbol = MenuBarAlert.alertSymbol
    static let warningSymbol = MenuBarAlert.warningSymbol

    /// Ce que la barre lit du `Sampler`, pris à un instant : le reste de la
    /// composition est un calcul pur, rejoué tel quel par `swift test`.
    struct Reading {
        /// Les segments affichés, dans l'ordre réglé, avec la valeur que leur
        /// module fournit (nil : la mesure manque, hors ligne par exemple).
        var segments: [(item: MenuBarSettings.Item, segment: MenuBarSegment?)]
        var verdict: Verdict
        var trail: [NetworkSample] = []
        /// Le débit brut du dernier relevé, nil hors ligne.
        var rates: (up: Double, down: Double)? = nil
        /// Les étiquettes des volumes montés.
        var diskLabels: [String] = []
        /// Règles (chantier 11) : `nil`, aucune règle allumée ne demande la
        /// cloche ; `false`, la place lui est réservée ; `true`, un épisode
        /// est en cours. Et ce que la cloche dit.
        var regles: Bool? = nil
        var reglesDit: String? = nil
    }

    /// Le relevé du moment : chaque module affiché fournit sa valeur.
    static func reading(_ sampler: Sampler, settings: PulseSettings) -> Reading {
        let segments = MenuBarCatalog.items(settings).filter(\.shown).compactMap { item -> (item: MenuBarSettings.Item, segment: MenuBarSegment?)? in
            guard let module = ModuleRegistry.module(item.id) else { return nil }
            return (item, module.menuBarSegment(sampler))
        }
        let net = sampler.network
        return Reading(segments: segments, verdict: sampler.verdict, trail: sampler.networkTrail,
                       rates: net.connected ? (net.txRate, net.rxRate) : nil,
                       diskLabels: sampler.volumes.map { MenuBarLabel.diskLabel($0.name) },
                       regles: SurveillantRegles.alerteBarre, reglesDit: SurveillantRegles.shared.texteBarre)
    }

    /// Les éléments de la barre : un seul en mode combiné, un par segment
    /// affiché sinon — le premier porte alors la place du symbole d'alerte.
    /// `rates` : le filtre du débit de l'app (`MenuBarRateFilter`) ; nil pour
    /// un relevé ponctuel (`--probe`, `--snapshot`), qui montre le brut.
    static func contents(_ sampler: Sampler, settings: PulseSettings, history: MenuBarHistory?,
                         rates: MenuBarRateFilter? = nil) -> [MenuBarContent] {
        contents(reading(sampler, settings: settings), settings: settings, history: history, rates: rates)
    }

    static func contents(_ reading: Reading, settings: PulseSettings, history: MenuBarHistory?,
                         rates: MenuBarRateFilter? = nil) -> [MenuBarContent] {
        // La cloche d'une règle passe devant le triangle du verdict : Isma
        // a demandé lui-même à être prévenu de CELA, le verdict reste dans
        // le panneau. Elle a sa place dès qu'une règle allumée la demande,
        // même si le symbole du verdict est réglé sur « jamais ».
        let reserves = settings.menuBar.alert != .never || reading.regles != nil
        let verdict = alertMark(reading.verdict, settings.menuBar.alert)
        let alert = reading.regles == true
            ? MenuBarAlert(symbol: MenuBarAlert.ruleSymbol,
                           spoken: [reading.reglesDit, verdict?.spoken].compactMap { $0 }.joined(separator: " · "))
            : verdict
        let pieces = Self.pieces(reading, history: history, rates: rates)
        switch settings.menuBar.mode {
        case .combined:
            return [MenuBarContent(reservesAlert: reserves, alert: alert, pieces: pieces)]
        case .separate:
            guard !pieces.isEmpty else {
                return [MenuBarContent(reservesAlert: reserves, alert: alert, pieces: [])]
            }
            return pieces.enumerated().map { index, piece in
                MenuBarContent(reservesAlert: index == 0 && reserves,
                               alert: index == 0 ? alert : nil, pieces: [piece])
            }
        }
    }

    /// Le symbole du verdict affiché, selon le réglage. Le verdict est
    /// celui du panneau (hystérésis, maintien de 5 min) : la barre ne peut
    /// pas dire autre chose que lui.
    static func alertMark(_ verdict: Verdict, _ setting: MenuBarSettings.Alert) -> MenuBarAlert? {
        switch (verdict.level, setting) {
        case (.alert, .alerts), (.alert, .warnings):
            return MenuBarAlert(symbol: alertSymbol, spoken: "alerte : \(verdict.phrase)")
        case (.warning, .warnings):
            return MenuBarAlert(symbol: warningSymbol, spoken: "attention : \(verdict.phrase)")
        default:
            return nil
        }
    }

    /// Les segments affichés, dans l'ordre réglé, avec leurs valeurs.
    static func pieces(_ reading: Reading, history: MenuBarHistory?, rates: MenuBarRateFilter? = nil) -> [MenuBarPiece] {
        // D'abord le relevé du moment dans l'historique, puis le dessin : le
        // dernier trait du graphe est la dernière mesure, sans doublon.
        var fractions: [String: Double] = [:]
        for (item, segment) in reading.segments {
            if let fraction = segment?.fraction { fractions[item.id] = fraction }
        }
        history?.record(fractions)

        var out: [MenuBarPiece] = []
        for (item, segment) in reading.segments {
            guard let entry = MenuBarCatalog.entry(item.id) else { continue }
            // La part n'entre dans l'image qu'en jauge, anneau ou graphe, au
            // pour cent près — ce que 48 pixels de jauge peuvent montrer. En
            // texte elle n'est pas dessinée : la garder ferait redessiner la
            // barre à chaque relevé pour un « 63 % » inchangé.
            let drawn = item.style == .text ? nil : segment?.fraction.map { ($0 * 100).rounded() / 100 }
            var piece = MenuBarPiece(id: item.id, style: item.style, stacked: entry.stacked,
                                     label: segment?.label ?? "", value: segment?.value ?? "",
                                     fraction: drawn,
                                     widestLabel: widestLabel(item.id, current: segment?.label, reading.diskLabels),
                                     widestValue: entry.widestValue,
                                     spoken: segment?.spoken ?? missing(entry))
            if entry.stacked, item.style == .text, segment != nil, let raw = reading.rates, let rates {
                let kept = rates.filter(up: raw.up, down: raw.down)
                piece.label = "↑" + Fmt.compactRate(kept.up)
                piece.value = "↓" + Fmt.compactRate(kept.down)
                piece.spoken = "reçu \(Fmt.bytes(kept.down))/s · envoyé \(Fmt.bytes(kept.up))/s"
            }
            if item.style == .graph {
                if entry.stacked {
                    let trail = reading.trail.suffix(MenuBarHistory.length)
                    let peak = max(10_000, trail.map(\.txRate).max() ?? 0, trail.map(\.rxRate).max() ?? 0)
                    piece.history = trail.map { $0.txRate / peak }
                    piece.historyDown = trail.map { $0.rxRate / peak }
                } else {
                    piece.history = (history?.values[item.id] ?? segment?.fraction.map { [$0] } ?? [])
                        .map { ($0 * 100).rounded() / 100 }
                }
            }
            out.append(piece)
        }
        return out
    }

    /// Ce que dit un segment sans valeur : le débit hors ligne, une batterie
    /// absente.
    private static func missing(_ entry: MenuBarCatalog.Entry) -> String {
        entry.stacked ? "hors ligne" : "\(entry.name.lowercased()) indisponible"
    }

    /// L'étiquette la plus large que le segment peut prendre. Le disque : la
    /// plus large parmi les volumes MONTÉS, pas un nom théorique de six
    /// signes — sur le pire cas « MACINT », l'icône faisait 137 pt et
    /// s'arrêtait à 25 pt de l'encoche (11/10).
    private static func widestLabel(_ id: String, current: String?, _ diskLabels: [String]) -> String {
        var candidates = [current ?? ""]
        if id == "disques" { candidates += diskLabels }
        return candidates.max { MenuBarDrawing.labelWidth($0) < MenuBarDrawing.labelWidth($1) } ?? ""
    }
}

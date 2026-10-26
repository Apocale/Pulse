import Foundation

// Les réglages de Pulse, tels qu'ils sont persistés dans `reglages.json`.
//
// Règle dure n°2 : chaque champ se lit en `decodeIfPresent`, et une valeur
// illisible retombe sur sa valeur par défaut au lieu de faire échouer tout le
// fichier. Le décodeur synthétisé lève `keyNotFound` sur une clé absente,
// même quand la propriété a une valeur par défaut : un champ ajouté naïvement
// effacerait tous les réglages d'Isma au premier lancement de la version
// suivante. D'où un `init(from:)` écrit à la main sur chaque type.

/// Tous les réglages.
struct PulseSettings: Codable, Equatable {
    /// Version du schéma, pour une migration future ; jamais exigée.
    var version = 1
    var layout = LayoutSettings()
    /// Réglages par module, indexés par l'identifiant du module.
    var modules: [String: ModuleSettings] = [:]
    var display = DisplaySettings()
    var refresh = RefreshSettings()
    /// La barre de menus (chantier 09) : `MenuBar/MenuBarSettings.swift`.
    var menuBar = MenuBarSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerant(Int.self, .version) ?? 1
        layout = c.tolerant(LayoutSettings.self, .layout) ?? LayoutSettings()
        // Un module abîmé n'emporte pas les autres.
        modules = (c.tolerant([String: Lossy<ModuleSettings>].self, .modules) ?? [:])
            .compactMapValues(\.value)
        display = c.tolerant(DisplaySettings.self, .display) ?? DisplaySettings()
        refresh = c.tolerant(RefreshSettings.self, .refresh) ?? RefreshSettings()
        menuBar = c.tolerant(MenuBarSettings.self, .menuBar) ?? MenuBarSettings()
    }

    /// Les réglages d'un module, ou ceux par défaut s'il n'en a pas encore.
    func module(_ id: String) -> ModuleSettings { modules[id] ?? ModuleSettings() }
}

/// La disposition du panneau.
struct LayoutSettings: Codable, Equatable {
    static let columnRange = 1...3

    /// Nombre de colonnes : 1, 2 ou 3.
    var columns = 2
    /// Ordre des cartes, tous modules confondus, de haut en bas dans chaque
    /// colonne. Un module absent de la liste — ajouté depuis — prend la
    /// place que lui donne le registre.
    var order: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = c.tolerant(Int.self, .columns) ?? 2
        order = (c.tolerant([Lossy<String>].self, .order) ?? []).compactMap(\.value)
    }
}

/// Les réglages d'un module. Nil partout où le module décide par défaut :
/// une valeur n'est écrite que si Isma l'a choisie.
struct ModuleSettings: Codable, Equatable {
    static let defaultAppCount = 4
    static let appCountRange = 0...10

    /// Carte affichée ? Nil : `enabledByDefault` du module.
    var enabled: Bool?
    /// Colonne, à partir de 0. Nil : `defaultColumn` du module.
    var column: Int?
    /// Carte compacte : le titre et le dessin principal, sans les listes.
    var compact = false
    /// Nombre d'applications listées. Nil : 4.
    var appCount: Int?
    /// Teinte choisie par série (identifiant de série → `TintChoice.raw`).
    var tints: [String: String] = [:]
    /// Réglages propres au module (identifiant d'option → valeur).
    var options: [String: OptionValue] = [:]

    init(enabled: Bool? = nil, column: Int? = nil, compact: Bool = false, appCount: Int? = nil,
         tints: [String: String] = [:], options: [String: OptionValue] = [:]) {
        self.enabled = enabled
        self.column = column
        self.compact = compact
        self.appCount = appCount
        self.tints = tints
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.tolerant(Bool.self, .enabled)
        column = c.tolerant(Int.self, .column)
        compact = c.tolerant(Bool.self, .compact) ?? false
        // Borné comme le pas à pas des Réglages : un -1 tapé à la main
        // faisait planter le panneau à chaque ouverture (`prefix(-1)`).
        appCount = c.tolerant(Int.self, .appCount).map {
            min(max($0, Self.appCountRange.lowerBound), Self.appCountRange.upperBound)
        }
        tints = (c.tolerant([String: Lossy<String>].self, .tints) ?? [:]).compactMapValues(\.value)
        options = (c.tolerant([String: Lossy<OptionValue>].self, .options) ?? [:]).compactMapValues(\.value)
    }
}

/// Unités d'affichage. La BASE des unités ne se règle pas : stockage en base
/// 1000, mémoire en base 1024, comme Apple (règle dure n°3). Seul le débit
/// peut se lire en bits, comme chez les opérateurs.
struct DisplaySettings: Codable, Equatable {
    enum RateUnit: String, Codable, CaseIterable {
        /// « 2,4 Mo/s », comme le Moniteur d'activité.
        case bytes
        /// « 19,2 Mbit/s », comme un test de débit ou un forfait.
        case bits
    }

    var rateUnit = RateUnit.bytes
    /// Le thème du panneau (chantier 10). Absent ou inconnu : Système.
    var theme = PulseTheme.systeme

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateUnit = c.tolerant(String.self, .rateUnit).flatMap(RateUnit.init(rawValue:)) ?? .bytes
        theme = c.tolerant(String.self, .theme).flatMap(PulseTheme.init(rawValue:)) ?? .systeme
    }
}

/// Cadence du relevé. Panneau fermé, jamais sous 5 s : c'est le budget de
/// moins de 1 % d'un cœur qui en dépend (mesuré le 09/10 à 5 s).
struct RefreshSettings: Codable, Equatable {
    static let openChoices: [Double] = [1, 1.5, 2, 3]
    static let closedChoices: [Double] = [5, 10]

    /// Panneau ouvert, en secondes.
    var openInterval = 1.5
    /// Panneau fermé, en secondes.
    var closedInterval: Double = 5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openInterval = c.tolerant(Double.self, .openInterval) ?? 1.5
        closedInterval = c.tolerant(Double.self, .closedInterval) ?? 5
    }

    /// Les valeurs hors des choix proposés — un fichier édité à la main —
    /// retombent sur le choix le plus proche, jamais sous le plancher.
    var sanitized: RefreshSettings {
        var copy = self
        copy.openInterval = Self.nearest(openInterval, in: Self.openChoices)
        copy.closedInterval = Self.nearest(closedInterval, in: Self.closedChoices)
        return copy
    }

    private static func nearest(_ value: Double, in choices: [Double]) -> Double {
        guard value.isFinite else { return choices[0] }
        return choices.min { abs($0 - value) < abs($1 - value) } ?? choices[0]
    }
}

/// La valeur d'un réglage propre à un module.
enum OptionValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int.self) { self = .int(value) }
        else { self = .text(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .int(let value):  try c.encode(value)
        case .text(let value): try c.encode(value)
        }
    }

    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var int: Int? { if case .int(let value) = self { return value }; return nil }
    var text: String? { if case .text(let value) = self { return value }; return nil }
}

/// Une valeur qui se décode ou s'efface sans faire échouer son conteneur.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// Clé absente ou valeur illisible : nil, jamais une erreur.
    func tolerant<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

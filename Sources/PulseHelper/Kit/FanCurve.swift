import Foundation

/// Ce que Pulse fait des ventilateurs. `automatic` : rien du tout — macOS
/// décide, aucune minuterie, aucune connexion au helper.
public enum FanMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case fixed
    case curve

    public var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .fixed:     return "Vitesse fixe"
        case .curve:     return "Courbe"
        }
    }
}

/// La température qui pilote la courbe.
public enum FanSensor: String, Codable, CaseIterable, Sendable {
    /// Moyenne des cœurs du processeur.
    case cpu
    /// Moyenne des capteurs de la carte graphique.
    case gpu
    /// La plus haute des deux : un export charge l'une ou l'autre.
    case hottest

    public var label: String {
        switch self {
        case .cpu:     return "Processeur"
        case .gpu:     return "Carte graphique"
        case .hottest: return "La plus chaude des deux"
        }
    }

    /// La température retenue, nil si la source manque.
    public func pick(cpu: Double?, gpu: Double?) -> Double? {
        switch self {
        case .cpu: return cpu
        case .gpu: return gpu
        case .hottest:
            switch (cpu, gpu) {
            case let (c?, g?): return max(c, g)
            case let (c?, nil): return c
            case let (nil, g?): return g
            default: return nil
            }
        }
    }
}

/// Une courbe température → vitesse. La vitesse est un NIVEAU entre le
/// minimum (0) et le maximum (1) d'Apple, appliqué à chaque ventilateur
/// dans ses propres bornes : les deux ventilateurs de ce Mac n'ont pas les
/// mêmes (1 350–5 349 et 1 522–5 777 tr/min). Une consigne ne peut donc pas
/// sortir des bornes d'Apple, par construction — et le helper borne encore.
public struct FanCurve: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var celsius: Double
        /// 0 = minimum d'Apple, 1 = maximum.
        public var level: Double

        public init(_ celsius: Double, _ level: Double) {
            self.celsius = celsius
            self.level = level
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            celsius = try c.decode(Double.self, forKey: .celsius)
            level = try c.decode(Double.self, forKey: .level)
        }
    }

    public static let celsiusRange: ClosedRange<Double> = 30...105
    public static let pointRange = 2...8

    public var points: [Point]

    public init(points: [Point]) { self.points = points }

    /// Au repos le minimum, puis de plus en plus fort à partir de 55 °C,
    /// le maximum à 90 °C. Plus prudente que silencieuse.
    public static let standard = FanCurve(points: [.init(45, 0), .init(60, 0.25), .init(75, 0.6), .init(90, 1)])

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Un point illisible est sauté, pas toute la courbe.
        let raw = (try? c.decode([FanLossy<Point>].self, forKey: .points)) ?? []
        points = raw.compactMap(\.value)
    }

    /// La courbe rendue sûre : points triés, dans les bornes, deux à huit,
    /// et un niveau qui ne baisse JAMAIS quand la température monte — plus
    /// chaud ne veut jamais dire moins de souffle. Moins de deux points
    /// lisibles : la courbe par défaut.
    public var sanitized: FanCurve {
        var clean = points
            .filter { $0.celsius.isFinite && $0.level.isFinite }
            .map { Point(Swift.min(Swift.max($0.celsius, Self.celsiusRange.lowerBound), Self.celsiusRange.upperBound),
                         Swift.min(Swift.max($0.level, 0), 1)) }
            .sorted { $0.celsius < $1.celsius }
        // Deux points à la même température : le plus fort l'emporte.
        var merged: [Point] = []
        for point in clean {
            if let last = merged.last, abs(last.celsius - point.celsius) < 0.5 {
                merged[merged.count - 1].level = Swift.max(last.level, point.level)
            } else {
                merged.append(point)
            }
        }
        clean = Array(merged.prefix(Self.pointRange.upperBound))
        guard clean.count >= Self.pointRange.lowerBound else { return .standard }
        var floor = 0.0
        for i in clean.indices {
            floor = Swift.max(floor, clean[i].level)
            clean[i].level = floor
        }
        return FanCurve(points: clean)
    }

    /// Le niveau pour une température : interpolation linéaire entre deux
    /// points, plat au-delà des extrémités.
    public func level(at celsius: Double) -> Double {
        let curve = sanitized.points
        guard let first = curve.first, let last = curve.last else { return 1 }
        guard celsius.isFinite else { return 1 }
        if celsius <= first.celsius { return first.level }
        if celsius >= last.celsius { return last.level }
        for (a, b) in zip(curve, curve.dropFirst()) where celsius <= b.celsius {
            let span = b.celsius - a.celsius
            return span > 0 ? a.level + (b.level - a.level) * (celsius - a.celsius) / span : b.level
        }
        return last.level
    }
}

/// Suit la température avec une hystérésis : une hausse passe tout de suite,
/// une baisse seulement au-delà de `band` degrés. Sans elle, un processeur
/// qui oscille de 2 °C autour d'un point ferait monter et descendre les
/// ventilateurs toutes les 5 s.
public struct FanFollower: Equatable, Sendable {
    public var band: Double
    public private(set) var held: Double?

    public init(band: Double = 3) { self.band = band }

    public mutating func feed(_ celsius: Double) -> Double {
        guard let current = held else {
            held = celsius
            return celsius
        }
        if celsius > current {
            held = celsius
        } else if celsius < current - band {
            held = celsius + band
        }
        return held ?? celsius
    }

    public mutating func reset() { held = nil }
}

/// Du niveau (0…1) aux consignes de chaque ventilateur, dans ses bornes.
public enum FanPlan {
    /// Un niveau ramené au pas de 5 % : la courbe ne change de consigne
    /// qu'en franchissant un pas, pas à chaque dixième de degré — chaque
    /// changement coûte des écritures au SMC (`FanProtocol.writeBudget`).
    public static func quantized(_ level: Double) -> Double {
        guard level.isFinite else { return 1 }
        return (min(max(level, 0), 1) * 20).rounded() / 20
    }

    public static func targets(level: Double, fans: [FanReading]) -> [Double] {
        let level = level.isFinite ? min(max(level, 0), 1) : 1
        return fans.map { ($0.min + ($0.max - $0.min) * level).rounded() }
    }
}

/// Les réglages des ventilateurs, persistés à part (`ventilateurs.json`).
/// Par défaut : automatique, rien d'actif. Chaque champ se lit en
/// `decodeIfPresent` (règle dure n°2) : un champ abîmé retombe sur sa
/// valeur par défaut — et le mode, sur l'automatique.
public struct FanSettings: Codable, Equatable, Sendable {
    public var mode: FanMode = .automatic
    /// Niveau de la vitesse fixe, 0 = minimum d'Apple, 1 = maximum.
    public var fixedLevel: Double = 0.5
    public var curve: FanCurve = .standard
    public var sensor: FanSensor = .hottest

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = ((try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil).flatMap(FanMode.init(rawValue:)) ?? .automatic
        let level = ((try? c.decodeIfPresent(Double.self, forKey: .fixedLevel)) ?? nil) ?? 0.5
        fixedLevel = level.isFinite ? min(max(level, 0), 1) : 0.5
        curve = ((try? c.decodeIfPresent(FanCurve.self, forKey: .curve)) ?? nil)?.sanitized ?? .standard
        sensor = ((try? c.decodeIfPresent(String.self, forKey: .sensor)) ?? nil).flatMap(FanSensor.init(rawValue:)) ?? .hottest
    }
}

/// Une valeur qui se décode ou s'efface sans emporter son tableau.
struct FanLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

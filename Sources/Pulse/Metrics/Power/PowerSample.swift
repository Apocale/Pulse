import Foundation

/// La batterie, l'alimentation et le mode d'énergie à un instant.
///
/// Chaque champ est optionnel : un Mac de bureau n'a pas de batterie, un
/// chargeur tiers ne décrit pas toujours sa puissance, et la jauge ne publie
/// la consommation qu'une fois sa télémétrie prête. Une valeur absente
/// s'affiche « — », jamais 0.
struct PowerSample: Equatable, Sendable {
    var hasBattery = false

    /// Charge, de 0 à 1. Celle du menu Batterie de macOS : `IOPowerSources`
    /// d'abord, l'AppleSmartBattery à défaut.
    var level: Double?
    var state: PowerState = .unknown

    var cycles: Int?
    /// Cycles prévus par Apple pour cette batterie (1 000 sur ce Mac).
    var designCycles: Int?

    /// Capacités en mAh : d'origine, nominale (celle dont macOS tire la
    /// santé), pleine charge dans les conditions du moment, charge présente.
    var designCapacity: Int?
    var nominalCapacity: Int?
    var fullChargeCapacity: Int?
    var currentCharge: Int?

    /// « Good » chez Apple : la condition que donnent les Réglages.
    var condition: String?

    /// En degrés Celsius. Voir `PowerReader.celsius` pour l'unité d'origine.
    var temperature: Double?
    /// Recoupement : `VirtualTemperature`, en centièmes de degré.
    var virtualTemperature: Double?

    /// Tension en volts, courant en ampères — positif en charge, négatif en
    /// décharge. `amperage` est la moyenne de la jauge, `instantAmperage` le
    /// relevé brut.
    var voltage: Double?
    var amperage: Double?
    var instantAmperage: Double?

    /// Ce que tire la machine entière, en watts, selon la jauge
    /// (`PowerTelemetryData`) : rafraîchi par elle toutes les 40 à 60 s.
    var systemWatts: Double?
    /// La même grandeur au SMC (`PSTR`), à l'instant de la lecture : celle de
    /// la carte Capteurs. Hors des fonctions pures : lue par `PowerMonitor`.
    var liveSystemWatts: Double?

    /// La consommation affichée : le SMC, en direct, d'abord — sans quoi la
    /// carte Énergie et la carte Capteurs affichaient côte à côte 93 et
    /// 103 W pour la même machine (rendu du 11/10) —, la jauge à défaut.
    var displayedWatts: Double? { liveSystemWatts ?? systemWatts }
    /// Ce qu'entre le chargeur dans la machine, en watts.
    var adapterInputWatts: Double?
    /// Le compteur de la jauge : la charge du système cumulée (mW) et le
    /// nombre de relevés qu'elle somme, un par seconde environ. Deux lectures
    /// donnent la puissance MOYENNE entre elles, là où `systemWatts` n'est
    /// qu'un instant.
    var loadSum: Double?
    var loadCount: Double?

    /// En minutes, seulement quand macOS en annonce un : vide sur batterie,
    /// pleine charge en charge.
    var minutesToEmpty: Int?
    var minutesToFull: Int?

    var adapter: PowerAdapter?

    /// Économie d'énergie active à l'instant (`ProcessInfo`).
    var lowPowerMode = false
    /// Le mode d'énergie réglé pour chaque source.
    var energyModeAC: EnergyMode?
    var energyModeBattery: EnergyMode?

    /// Santé en fraction : celle de macOS quand on la connaît, sinon la
    /// capacité nominale sur la capacité d'origine.
    func health(macOS: Int?) -> Double? {
        if let macOS { return Double(macOS) / 100 }
        return computedHealth
    }

    /// Capacité nominale sur capacité d'origine : la formule de macOS, sans
    /// le lissage de powerd (voir `BatteryHealthReport`).
    var computedHealth: Double? {
        guard let design = designCapacity, design > 0 else { return nil }
        guard let nominal = nominalCapacity ?? fullChargeCapacity, nominal > 0 else { return nil }
        return Double(nominal) / Double(design)
    }

    /// La batterie en watts, signée : positive quand elle se charge, négative
    /// quand elle alimente la machine.
    var batteryWatts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    /// Le mode d'énergie de la source qui alimente la machine en ce moment.
    var activeEnergyMode: EnergyMode? {
        state.onExternalPower ? energyModeAC : energyModeBattery
    }
}

enum PowerState: String, Equatable, Sendable {
    case charging
    case charged
    /// Sur secteur, sans charger : charge optimisée, limite, ou chaleur.
    case notCharging
    case discharging
    case unknown

    var onExternalPower: Bool { self == .charging || self == .charged || self == .notCharging }

    var label: String {
        switch self {
        case .charging:    return "en charge"
        case .charged:     return "chargée"
        case .notCharging: return "sur secteur, ne charge pas"
        case .discharging: return "sur batterie"
        case .unknown:     return "état inconnu"
        }
    }
}

/// Le chargeur branché, tel qu'il se décrit.
struct PowerAdapter: Equatable, Sendable {
    var name: String?
    var watts: Int?
    /// Tension et courant négociés, en volts et ampères.
    var voltage: Double?
    var current: Double?
    var manufacturer: String?
}

/// Le réglage « Mode d'énergie » de macOS. La valeur vit sous la clé
/// historique `LowPowerMode` : 2 n'y veut pas dire « économie » mais haute
/// performance — vérifié le 11/10, `ProcessInfo` donne l'économie inactive.
enum EnergyMode: Int, Equatable, Sendable {
    case automatic = 0
    case lowPower = 1
    case highPower = 2

    var label: String {
        switch self {
        case .automatic: return "automatique"
        case .lowPower:  return "économie d'énergie"
        case .highPower: return "haute performance"
        }
    }
}

/// Un appareil à batterie que macOS connaît : AirPods, souris, clavier,
/// trackpad, casque. Plusieurs parties pour les AirPods (gauche, droite,
/// boîtier).
struct PowerAccessory: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: Kind
    var parts: [Part]
    /// D'où vient la mesure : « IOPowerSources » ou « IORegistry ».
    var source: String

    struct Part: Equatable, Sendable {
        var role: Role
        var level: Double
        var charging: Bool
    }

    enum Role: String, Equatable, Sendable {
        case single, left, right, `case`

        var label: String {
            switch self {
            case .single: return ""
            case .left:   return "gauche"
            case .right:  return "droite"
            case .case:   return "boîtier"
            }
        }
    }

    enum Kind: String, Equatable, Sendable {
        case airpods, airpodsPro, airpodsMax, headphones, mouse, keyboard, trackpad, other

        /// Un symbole SF qui existe sur macOS 14 : vérifié par
        /// `NSImage(systemSymbolName:)` dans les tests.
        var symbol: String {
            switch self {
            case .airpods:    return "airpods"
            case .airpodsPro: return "airpodspro"
            case .airpodsMax: return "airpodsmax"
            case .headphones: return "headphones"
            case .mouse:      return "magicmouse"
            case .keyboard:   return "keyboard"
            case .trackpad:   return "hand.point.up.left"
            case .other:      return "battery.75percent"
            }
        }
    }

    /// La charge la plus basse des parties portées (le boîtier à part) :
    /// c'est elle qui coupera le son la première.
    var lowestWorn: Double? {
        let worn = parts.filter { $0.role != .case }
        return (worn.isEmpty ? parts : worn).map(\.level).min()
    }
}

/// La santé telle que macOS l'affiche dans Réglages Système, lue dans
/// `system_profiler` : powerd la lisse sur la durée, et la fonction qui la
/// donne directement est réservée aux binaires d'Apple.
struct BatteryHealthReport: Equatable, Sendable {
    /// « Capacité maximale », en pour cent.
    var maximumCapacity: Int?
    /// « Good », traduit « normale » par les Réglages.
    var condition: String?
    var cycles: Int?
    var readAt: Date
}

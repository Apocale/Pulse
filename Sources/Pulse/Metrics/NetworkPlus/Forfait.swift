import Foundation

/// Où en est le forfait iPhone, sur le cycle en cours.
///
/// Ce qui est compté : les octets échangés par CE Mac à travers le partage de
/// connexion, reçus et envoyés — l'opérateur compte les deux sens. Ni
/// l'iPhone lui-même ni un autre appareil branché dessus n'y sont : le
/// chiffre est un plancher de ce que l'opérateur décomptera, jamais un
/// plafond. Base 1000, comme les opérateurs.
struct EtatForfait: Equatable {
    struct Jour: Equatable {
        var jour: Date
        var octets: UInt64
    }

    /// Premier jour du cycle, à minuit.
    var debut: Date
    /// Premier jour du cycle SUIVANT, à minuit : le forfait repart de zéro.
    var fin: Date
    /// Ce Mac, à travers le partage iPhone, depuis `debut`.
    var consomme: UInt64
    /// Le forfait en octets ; `nil` s'il n'est pas réglé.
    var quota: UInt64?
    /// Chaque jour du cycle jusqu'à aujourd'hui compris, même vide.
    var parJour: [Jour]
    /// Moyenne par jour OBSERVÉ du cycle, en octets. `nil` avant
    /// `Forfait.joursAvantRythme` jours : un seul jour chargé ne fait pas un
    /// rythme.
    var rythme: Double?
    /// Le premier jour du cycle où Pulse a compté quelque chose, tous réseaux
    /// confondus. Avant lui, Pulse ne comptait pas encore : diviser par les
    /// jours du cycle sous-estimerait le rythme. Relevé le 11/10 : cumul
    /// commencé le 07/10, cycle le 01/10 — 566 Mo par jour au lieu de 1,3 Go.
    var observeDepuis: Date?
    /// À ce rythme, le jour où le forfait serait épuisé — seulement s'il
    /// tombe avant la fin du cycle.
    var epuiseVers: Date?

    var fraction: Double? { quota.map { $0 > 0 ? Double(consomme) / Double($0) : 0 } }
    var reste: UInt64? { quota.map { $0 > consomme ? $0 - consomme : 0 } }

    var niveau: NiveauForfait {
        guard let fraction else { return .nonRegle }
        if fraction >= Forfait.seuilDepasse { return .depasse }
        if fraction >= Forfait.seuilProche { return .proche }
        return .normal
    }

    /// Le budget d'une journée pour finir le cycle pile au forfait.
    var budgetParJour: Double? {
        guard let quota else { return nil }
        let jours = max(1, fin.timeIntervalSince(debut) / 86_400)
        return Double(quota) / jours.rounded()
    }
}

/// Les deux seuils que le chantier 11 (règles et notifications) branche sur
/// ses préréglages « forfait iPhone à 80 % puis 100 % ».
enum NiveauForfait: String, Equatable {
    case nonRegle
    case normal
    /// 80 % du forfait atteints.
    case proche
    /// Forfait épuisé.
    case depasse

    var libelle: String {
        switch self {
        case .nonRegle: return "forfait non réglé"
        case .normal:   return "sous 80 %"
        case .proche:   return "80 % atteints"
        case .depasse:  return "forfait épuisé"
        }
    }
}

enum Forfait {
    static let seuilProche = 0.8
    static let seuilDepasse = 1.0
    /// Sous trois jours de cycle, pas de rythme ni d'échéance.
    static let joursAvantRythme = 3.0

    /// Le cycle qui contient `date` : il commence le `jour` du mois — ou le
    /// dernier jour d'un mois trop court — et finit au même jour du mois
    /// suivant.
    static func cycle(contenant date: Date, jour: Int,
                      calendrier: Calendar = .current) -> (debut: Date, fin: Date) {
        let jour = min(31, max(1, jour))
        let aujourdHui = calendrier.startOfDay(for: date)
        let mois = calendrier.dateComponents([.year, .month], from: aujourdHui)
        func renouvellement(_ decalage: Int) -> Date {
            let premier = calendrier.date(from: mois).flatMap {
                calendrier.date(byAdding: .month, value: decalage, to: $0)
            } ?? aujourdHui
            let longueur = calendrier.range(of: .day, in: .month, for: premier)?.count ?? 28
            return calendrier.date(byAdding: .day, value: min(jour, longueur) - 1, to: premier) ?? premier
        }
        let ceMois = renouvellement(0)
        return aujourdHui >= ceMois ? (ceMois, renouvellement(1)) : (renouvellement(-1), ceMois)
    }

    /// Combien de jours d'historique il faut lire pour couvrir le cycle.
    static func joursALire(maintenant: Date = Date(), jour: Int, calendrier: Calendar = .current) -> Int {
        let debut = cycle(contenant: maintenant, jour: jour, calendrier: calendrier).debut
        let jours = calendrier.dateComponents([.day], from: debut, to: calendrier.startOfDay(for: maintenant)).day ?? 0
        return max(1, jours + 1)
    }

    /// L'état du forfait, tiré du cumul journalier par réseau (`reseau.json`).
    ///
    /// `historique` : les jours de `NetworkTracker.history`, du plus ancien au
    /// plus récent ; seuls ceux du cycle comptent, et seul le partage iPhone.
    static func etat(historique: [(day: Date, usage: [NetworkTracker.Usage])],
                     reglages: ReglagesReseau,
                     maintenant: Date = Date(),
                     calendrier: Calendar = .current) -> EtatForfait {
        let (debut, fin) = cycle(contenant: maintenant, jour: reglages.jourRenouvellement, calendrier: calendrier)
        var parDate: [Date: UInt64] = [:]
        var observeDepuis: Date?
        for (day, usage) in historique {
            let jour = calendrier.startOfDay(for: day)
            guard jour >= debut, jour < fin else { continue }
            if !usage.isEmpty { observeDepuis = min(observeDepuis ?? jour, jour) }
            parDate[jour, default: 0] += usage.filter { $0.kind == .hotspot }.reduce(0) { $0 + $1.rx + $1.tx }
        }
        var parJour: [EtatForfait.Jour] = []
        var jour = debut
        let aujourdHui = calendrier.startOfDay(for: maintenant)
        while jour <= aujourdHui {
            parJour.append(.init(jour: jour, octets: parDate[jour] ?? 0))
            guard let suivant = calendrier.date(byAdding: .day, value: 1, to: jour) else { break }
            jour = suivant
        }
        let consomme = parJour.reduce(0) { $0 + $1.octets }
        let quota = reglages.forfaitGo.map { UInt64(($0 * 1e9).rounded()) }

        var etat = EtatForfait(debut: debut, fin: fin, consomme: consomme, quota: quota, parJour: parJour,
                               observeDepuis: observeDepuis)
        let ecoules = maintenant.timeIntervalSince(observeDepuis ?? maintenant) / 86_400
        if ecoules >= joursAvantRythme {
            let rythme = Double(consomme) / ecoules
            etat.rythme = rythme
            if let quota, consomme < quota, rythme > 0 {
                let vers = maintenant.addingTimeInterval(Double(quota - consomme) / rythme * 86_400)
                if vers < fin { etat.epuiseVers = vers }
            }
        }
        return etat
    }
}

extension Sampler {
    /// Le forfait du moment, pour la carte et pour le chantier 11. Lu à la
    /// demande : un cumul de trente jours ne se recalcule pas à chaque relevé.
    @MainActor
    var forfait: EtatForfait { forfait(ReglagesReseau.actuels) }

    /// Le même, sur des réglages donnés (ceux de la carte), jusqu'à
    /// « aujourd'hui » — l'heure d'un relevé figé s'il y en a un (banc
    /// d'essai : sans elle, l'image de la carte changerait chaque jour).
    func forfait(_ reglages: ReglagesReseau) -> EtatForfait {
        let maintenant = maintenantFige ?? Date()
        let jours = Forfait.joursALire(maintenant: maintenant, jour: reglages.jourRenouvellement)
        return Forfait.etat(historique: networkHistory(days: jours), reglages: reglages, maintenant: maintenant)
    }
}

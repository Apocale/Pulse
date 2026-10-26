import Foundation

/// Ce qu'une règle peut surveiller : une mesure qu'un module expose déjà.
///
/// Aucune mesure n'est relevée pour les règles : chacune se lit sur le relevé
/// que le `Sampler` publie de toute façon, à sa cadence — 5 s panneau fermé,
/// les disques toutes les 2 min, les incidents toutes les 2 min. C'est ce qui
/// garde les règles à coût nul (voir `SurveillantRegles`).
struct MesureRegle: Identifiable, Equatable {
    enum Unite: Equatable {
        /// Octets, base 1000 : `Fmt.bytes` (règle dure n°3).
        case stockage
        /// Octets, base 1024 : `Fmt.memory`.
        case memoire
        /// Part de 1, affichée en pour cent.
        case part
        case jours
        /// Vrai ou faux.
        case etat
        /// Un fait daté, sans valeur.
        case evenement
    }

    var id: String
    /// Le module qui l'expose (`ModuleRegistry`), pour ranger l'éditeur.
    var module: String
    var nom: String
    var unite: Unite
    /// Une valeur par disque, suivie séparément.
    var parSujet = false
    /// Ce qui suit la valeur dans la phrase (« libres » : « 48 Go libres »).
    var suffixe = ""
    /// D'où sort le chiffre, et à quel rythme il change.
    var source: String

    /// Les comparaisons qui ont un sens pour cette mesure.
    var comparaisons: [Comparaison] {
        switch unite {
        case .etat: return [.vrai]
        case .evenement: return [.survient]
        default: return [.sous, .atteint]
        }
    }

    /// Une valeur dans l'unité de la mesure, pour la phrase et `--probe`.
    func texte(_ valeur: Double) -> String {
        switch unite {
        case .stockage: return Fmt.bytes(valeur)
        case .memoire: return Fmt.memory(valeur)
        // L'occupation d'un disque arrondie VERS LE BAS, comme l'anneau, la
        // barre de menus et les widgets : « 95 % » à 94,6 % se lisait comme
        // une règle « ≥ 95 % » qui aurait dû partir (17-audit-code).
        case .part: return id == "disques.occupation" ? Fmt.occupancy(valeur) : Fmt.percent(valeur)
        case .jours: return valeur < 1 ? "moins d'un jour" : Fmt.days(valeur)
        case .etat: return valeur >= 0.5 ? "oui" : "non"
        case .evenement: return ""
        }
    }
}

enum CatalogueMesures {
    static let toutes: [MesureRegle] = [
        MesureRegle(id: "disques.libre", module: "disques", nom: "Espace libre d'un disque",
                    unite: .stockage, parSujet: true, suffixe: "libres",
                    source: "espace libre affiché par le Finder, purgeable compris ; disques relus toutes les 2 min panneau fermé"),
        MesureRegle(id: "disques.occupation", module: "disques", nom: "Occupation d'un disque",
                    unite: .part, parSujet: true, suffixe: "occupé",
                    source: "part utilisée, purgeable exclu, comme la barre du panneau"),
        MesureRegle(id: "disques.pleinDans", module: "disques", nom: "Disque plein dans",
                    unite: .jours, parSujet: true,
                    source: "prévision de remplissage du panneau, recalculée chaque minute ; absente sous 6 h d'observation calme"),
        MesureRegle(id: "disques.copieTerminee", module: "disques", nom: "Une copie de rushes se termine",
                    unite: .evenement,
                    source: "fin d'une écriture massive (1 Go au moins) sur un disque externe pendant qu'une carte ou un autre disque lit, constatée 60 s après la dernière écriture (IngestionDetector) ; panneau fermé compris. Téléchargements et exports exclus"),
        MesureRegle(id: "memoire.utilisee", module: "memoire", nom: "Mémoire utilisée",
                    unite: .part, source: "app + wired + compressée, comme le Moniteur d'activité"),
        MesureRegle(id: "memoire.pression", module: "memoire", nom: "Pression mémoire",
                    unite: .part, source: "kern.memorystatus_level, comme l'outil memory_pressure"),
        MesureRegle(id: "memoire.swap", module: "memoire", nom: "Swap utilisé",
                    unite: .memoire, source: "vm.swapusage"),
        MesureRegle(id: "memoire.swapHausse", module: "memoire", nom: "Hausse du swap sur une heure",
                    unite: .memoire,
                    source: "swap du moment moins celui d'il y a une heure (série de 10 s) ; rien sous 5 min d'historique — le calcul de la règle 7 du verdict"),
        MesureRegle(id: "memoire.processusTue", module: "memoire", nom: "macOS tue un processus faute de mémoire",
                    unite: .evenement, source: "rapports JetsamEvent, relus toutes les 2 min"),
        MesureRegle(id: "processeur.total", module: "processeur", nom: "Processeur, toute la machine",
                    unite: .part, source: "host_processor_info, tous les cœurs"),
        MesureRegle(id: "reseau.horsLigne", module: "reseau", nom: "Aucun réseau",
                    unite: .etat,
                    source: "pas d'interface principale (Wi-Fi coupé, partage iPhone perdu) ; relevé toutes les 2 s. Une box connectée mais sans Internet ne se voit pas d'ici"),
        MesureRegle(id: "reseau.forfait", module: "reseau", nom: "Forfait iPhone consommé",
                    unite: .part,
                    source: "ce Mac à travers le partage iPhone, sur le cycle réglé dans la carte Réseau ; absente tant que le forfait n'est pas réglé"),
        MesureRegle(id: "montage.exportTermine", module: "montage", nom: "Un export se termine",
                    unite: .evenement,
                    source: "fin de la charge de Media Encoder, constatée 30 s après (ExportDetector) ; le fichier produit et son issue (réussi, avertissement, échec) lus dans le journal d'AME, un relevé plus tard ; l'export lancé sans Media Encoder n'est pas vu"),
        MesureRegle(id: "montage.plantage", module: "montage", nom: "Une app Adobe plante",
                    unite: .evenement, source: "base Crashpad d'Adobe, relue toutes les 2 min"),
    ]

    static func mesure(_ id: String) -> MesureRegle? { toutes.first { $0.id == id } }
}

/// Une valeur du relevé, pour un sujet (un disque) ou pour tout le Mac.
struct Echantillon: Equatable {
    /// Clé stable du sujet (l'UUID d'un volume) ; vide sans sujet.
    var sujet = ""
    /// Son nom du moment (« Ssd 2 »).
    var nom = ""
    var valeur: Double
    /// Suivi par une règle qui ne nomme pas de sujet : chaque disque
    /// EXTERNE, pas le disque interne — « disque de rushes presque plein »
    /// ne parle pas de Macintosh HD.
    var suiviParDefaut = true
}

/// Un fait daté (un export terminé, un plantage).
struct Evenement: Equatable {
    /// Ce qui l'a produit (« Premiere Pro »).
    var sujet = ""
    var date: Date
    /// La phrase qui le dit (« Media Encoder · 12 min »).
    var texte: String
    /// Le début de ce qui vient de finir (un export) : de quoi retrouver ses
    /// fichiers dans le journal d'AME (19-suivis).
    var debut: Date? = nil
}

/// Ce que le moteur lit à un instant : les valeurs des mesures suivies, les
/// événements survenus depuis le relevé précédent.
struct ReleveRegles {
    var date: Date
    /// Mesure → valeurs du moment. Absente : la mesure n'existe pas en ce
    /// moment (forfait non réglé, aucun disque externe), ce qui n'est ni vrai
    /// ni faux.
    var valeurs: [String: [Echantillon]] = [:]
    /// Mesure → événements depuis le relevé précédent.
    var evenements: [String: [Evenement]] = [:]
    /// Une app de montage est au premier plan.
    var enMontage = false
}

import Foundation

/// La barre de menus telle qu'Isma la règle (chantier 09), persistée dans
/// `reglages.json` sous la clé `menuBar`.
///
/// Règle dure n°2 : chaque champ se lit en `decodeIfPresent`, et une valeur
/// illisible retombe seule sur sa valeur par défaut. Un fichier écrit avant ce
/// chantier n'a pas la clé : la barre y garde son allure d'avant — mémoire,
/// disque le plus serré, débit — plus la place du symbole d'alerte.
struct MenuBarSettings: Codable, Equatable {
    /// Un seul élément combiné, ou un élément par module.
    enum Mode: String, Codable, CaseIterable {
        /// Le mode qu'iStat recommande sur un portable : à droite de
        /// l'encoche il n'y a que 918 pt, et chaque élément ajoute ses marges.
        case combined = "combine"
        case separate = "separe"
    }

    /// Le dessin d'un segment. Tous gardent la même grammaire : une petite
    /// étiquette en haut, la mesure dessous.
    enum Style: String, Codable, CaseIterable {
        /// « CPU » sur « 44 % ».
        case text = "texte"
        /// Les derniers relevés en barres.
        case graph = "graphe"
        /// Une jauge horizontale : seulement sur un total réel (règle n°7).
        case gauge = "jauge"
        /// Un anneau : seulement sur un total réel (règle n°7).
        case ring = "anneau"

        var label: String {
            switch self {
            case .text:  return "Texte"
            case .graph: return "Mini-graphe"
            case .gauge: return "Jauge"
            case .ring:  return "Anneau"
            }
        }
    }

    /// Quand le symbole du verdict apparaît dans la barre.
    enum Alert: String, Codable, CaseIterable {
        /// Les alertes seulement (disque à 95 %, plein sous 7 jours, mémoire
        /// saturée, plantage Adobe, processus tué).
        case alerts = "alertes"
        /// Les alertes, et les avertissements en contour.
        case warnings = "avertissements"
        /// Jamais : la place du symbole est rendue à la barre.
        case never = "jamais"

        var label: String {
            switch self {
            case .alerts:   return "Les alertes"
            case .warnings: return "Les alertes et les avertissements"
            case .never:    return "Jamais"
            }
        }
    }

    /// Un segment : le module qui le fournit, s'il s'affiche, et comment.
    struct Item: Codable, Equatable {
        var id: String
        var shown: Bool
        var style: Style

        init(id: String, shown: Bool, style: Style) {
            self.id = id
            self.shown = shown
            self.style = style
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Sans identifiant, l'élément ne désigne rien : il s'efface seul
            // (`Lossy`), sans emporter les autres.
            id = try c.decode(String.self, forKey: .id)
            shown = c.tolerant(Bool.self, .shown) ?? false
            style = c.tolerant(String.self, .style).flatMap(Style.init(rawValue:)) ?? .text
        }
    }

    var mode = Mode.combined
    /// Les segments dans l'ordre de la barre, de gauche à droite. Un module
    /// absent de la liste — ajouté depuis — prend la place et l'état que lui
    /// donne le catalogue (`MenuBarCatalog`).
    var items: [Item] = []
    var alert = Alert.alerts

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.tolerant(String.self, .mode).flatMap(Mode.init(rawValue:)) ?? .combined
        items = (c.tolerant([Lossy<Item>].self, .items) ?? []).compactMap(\.value)
        alert = c.tolerant(String.self, .alert).flatMap(Alert.init(rawValue:)) ?? .alerts
    }
}

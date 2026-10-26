import SwiftUI

/// Ce que la barre de menus sait dessiner, module par module.
///
/// Les VALEURS viennent des modules (`PulseModule.menuBarSegment`) ; le
/// catalogue dit seulement comment chacune peut se dessiner, sa place au
/// premier lancement et sa valeur la plus large — celle sur laquelle la
/// largeur se fige.
@MainActor
enum MenuBarCatalog {
    struct Entry: Equatable {
        /// L'identifiant du module qui fournit les valeurs.
        var id: String
        /// Le nom dans la page de Réglages.
        var name: String
        var shownByDefault: Bool
        /// Le débit : deux lignes empilées, ↑ ce qui part, ↓ ce qui arrive,
        /// sans étiquette — l'allure d'avant, celle d'iStat.
        var stacked = false
        /// La valeur la plus large possible, en signes de la police de la
        /// barre : la largeur se fige sur elle, jamais sur le relevé.
        var widestValue: String
        /// Une part d'un total réel : la jauge et l'anneau sont permis. Sans
        /// dénominateur réel — une température, un débit —, ils ne le sont
        /// pas (règle dure n°7).
        var hasFraction: Bool
        /// Le module tient lui-même l'interrupteur de son segment, et sa
        /// cadence en dépend : Capteurs, « Température du processeur dans la
        /// barre de menus ». Une seule source de vérité, lue et écrite là.
        var ownToggle: String? = nil
        /// Ce que le segment coûte en plus, s'il coûte quelque chose.
        var note: String = ""

        /// Les styles permis, dans l'ordre des Réglages.
        var styles: [MenuBarSettings.Style] {
            if stacked { return [.text, .graph] }
            if !hasFraction { return [.text] }
            return MenuBarSettings.Style.allCases
        }
    }

    /// Dans l'ordre par défaut de la barre, de gauche à droite : l'allure
    /// d'avant ce chantier (mémoire, disque le plus serré, débit), puis ce
    /// qui s'allume dans les Réglages.
    static let entries: [Entry] = [
        Entry(id: "memoire", name: "Mémoire", shownByDefault: true,
              widestValue: "100 %", hasFraction: true),
        Entry(id: "disques", name: "Disque le plus serré", shownByDefault: true,
              widestValue: "100 %", hasFraction: true),
        Entry(id: "reseau", name: "Débit internet", shownByDefault: true, stacked: true,
              widestValue: "888M", hasFraction: false),
        Entry(id: "processeur", name: "Processeur", shownByDefault: false,
              widestValue: "100 %", hasFraction: true),
        // macOS affiche déjà la batterie dans la barre : éteinte par défaut,
        // la place à droite de l'encoche est comptée.
        Entry(id: "energie", name: "Batterie", shownByDefault: false,
              widestValue: "100 %", hasFraction: true,
              note: "relue toutes les 5 min panneau fermé"),
        Entry(id: "capteurs", name: "Température du processeur", shownByDefault: false,
              widestValue: "100°", hasFraction: false, ownToggle: SensorsModule.barOption,
              note: "allumée, les capteurs sont relus toutes les 30 s panneau fermé (0,014 % d'un cœur)"),
        // 18-extras : éteints par défaut, comme leurs cartes.
        Entry(id: "horloges", name: "Heure de la première personne", shownByDefault: false,
              widestValue: "88:88", hasFraction: false),
        Entry(id: "calendrier", name: "Prochain événement du jour", shownByDefault: false,
              widestValue: "en cours", hasFraction: false,
              note: "carte Calendrier activée : relu toutes les 5 min"),
        Entry(id: "meteo", name: "Température dehors", shownByDefault: false,
              widestValue: "\u{2212}88°", hasFraction: false,
              note: "carte Météo activée : une requête à Open-Meteo par heure panneau fermé, sur Internet"),
    ]

    static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    /// Les segments réglés, dans l'ordre de la barre : ceux du fichier
    /// d'abord, dans leur ordre, puis ceux du catalogue qu'il ne connaît pas
    /// encore, à leur place par défaut. Un module disparu du registre est
    /// ignoré ; un style refusé (anneau sur une température) retombe sur
    /// le texte.
    static func items(_ settings: PulseSettings) -> [MenuBarSettings.Item] {
        let known = entries.filter { ModuleRegistry.module($0.id) != nil }
        var out: [MenuBarSettings.Item] = []
        for saved in settings.menuBar.items {
            guard let entry = known.first(where: { $0.id == saved.id }),
                  !out.contains(where: { $0.id == saved.id }) else { continue }
            out.append(resolve(saved, entry, settings))
        }
        for entry in known where !out.contains(where: { $0.id == entry.id }) {
            out.append(resolve(MenuBarSettings.Item(id: entry.id, shown: entry.shownByDefault, style: .text),
                               entry, settings))
        }
        return out
    }

    private static func resolve(_ item: MenuBarSettings.Item, _ entry: Entry,
                                _ settings: PulseSettings) -> MenuBarSettings.Item {
        var item = item
        if !entry.styles.contains(item.style) { item.style = .text }
        if let toggle = entry.ownToggle {
            item.shown = settings.module(entry.id).options[toggle]?.bool ?? false
        }
        return item
    }

    /// Affiche ou masque un segment, là où vit son interrupteur.
    static func setShown(_ shown: Bool, id: String, in settings: inout PulseSettings) {
        if let toggle = entry(id)?.ownToggle {
            settings.modules[id, default: ModuleSettings()].options[toggle] = .bool(shown)
            return
        }
        var items = Self.items(settings)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].shown = shown
        settings.menuBar.items = items
    }

    static func setStyle(_ style: MenuBarSettings.Style, id: String, in settings: inout PulseSettings) {
        var items = Self.items(settings)
        guard let index = items.firstIndex(where: { $0.id == id }),
              entry(id)?.styles.contains(style) == true else { return }
        items[index].style = style
        settings.menuBar.items = items
    }

    static func move(fromOffsets: IndexSet, toOffset: Int, in settings: inout PulseSettings) {
        var items = Self.items(settings)
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        settings.menuBar.items = items
    }
}

/// L'étiquette d'un disque dans la barre : son nom en capitales s'il tient en
/// six signes (« SSD 2 »), sinon son premier mot coupé. Partagée avec la
/// carte des disques.
enum MenuBarLabel {
    static func diskLabel(_ name: String) -> String {
        let upper = name.uppercased()
        if upper.count <= 6 { return upper }
        let first = upper.split(separator: " ").first.map(String.init) ?? upper
        return first.count <= 6 ? first : String(first.prefix(5)) + "."
    }
}

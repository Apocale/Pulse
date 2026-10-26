import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Une page de la fenêtre Réglages : la page générale, ou celle d'un module.
enum SettingsPage: Hashable {
    case general
    /// La barre de menus (chantier 09, `MenuBar/MenuBarSettingsPage.swift`).
    case menuBar
    case module(String)
    case regles             // 11-regles : règles et alertes
    case fans               // 14-ventilateurs : contrôle sur accord
}

/// La fenêtre Réglages, façon iStat Menus : une barre latérale avec une
/// ligne par carte — leur ordre est celui du panneau, et se règle au
/// glisser-déposer —, une page générale (disposition, cadence, unités,
/// sauvegarde), et une page par module avec l'aperçu en direct de sa carte.
///
/// Tout s'écrit à la volée dans `reglages.json` (`SettingsStore`) et
/// s'applique au panneau, à la cadence et aux modules sans redémarrage.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let sampler: Sampler
    @State var page: SettingsPage? = .general
    /// La page choisie, remontée à la fenêtre : cachée, elle vide son
    /// contenu, et le rouvre sur cette page (`SettingsWindow`).
    var pageDidChange: ((SettingsPage) -> Void)? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("Général", systemImage: "gearshape")
                    .tag(SettingsPage.general)
                Label("Barre de menus", systemImage: "menubar.rectangle")
                    .tag(SettingsPage.menuBar)
                Label("Règles et alertes", systemImage: "bell")
                    .tag(SettingsPage.regles)
                Label("Ventilateurs", systemImage: "fan")           // 14-ventilateurs
                    .tag(SettingsPage.fans)
                Section("Cartes du panneau") {
                    ForEach(Layout.order(store.settings), id: \.self) { id in
                        sidebarRow(id).tag(SettingsPage.module(id))
                    }
                    .onMove { from, to in
                        var order = Layout.order(store.settings)
                        order.move(fromOffsets: from, toOffset: to)
                        store.settings.layout.order = order
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch page {
            case .menuBar?:
                MenuBarSettingsPage(store: store, sampler: sampler)
            case .regles?:
                PageRegles(sampler: sampler)
            case .fans?:
                FanSettingsPage(pilot: .shared, sensors: .shared)   // 14-ventilateurs
            case .module(let id)?:
                if let module = ModuleRegistry.module(id) {
                    ModuleSettingsPage(module: module, store: store, sampler: sampler)
                        .id(id)
                }
            default:
                GeneralSettingsPage(store: store, sampler: sampler)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: page) { _, new in pageDidChange?(new ?? .general) }
    }

    /// Une carte dans la barre latérale : son symbole, son nom, et « masquée »
    /// quand elle n'est pas dans le panneau — l'état se lit sans couleur.
    @ViewBuilder
    private func sidebarRow(_ id: String) -> some View {
        if let module = ModuleRegistry.module(id) {
            let shown = Layout.isEnabled(module, in: store.settings)
            HStack {
                // Seul le nom s'efface : atténué à 60 % lui aussi, le mot
                // « masquée » tombait sous les 4,5:1 du texte (chantier 16).
                Label(module.name, systemImage: module.symbol)
                    .opacity(shown ? 1 : 0.6)
                Spacer()
                if !shown {
                    Text("masquée").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(shown ? "affichée" : "masquée")
            // L'ordre se règle aussi sans glisser (chantier 16).
            .accessibilityActions {
                let order = Layout.order(store.settings)
                let position = order.firstIndex(of: id) ?? 0
                if position > 0 {
                    Button("Monter") { reorder(id, to: position - 1) }
                }
                if position + 1 < order.count {
                    Button("Descendre") { reorder(id, to: position + 2) }
                }
            }
        }
    }

    /// Déplace la carte `id` à la position `offset` de l'ordre global, comme
    /// le glisser-déposer de la barre latérale (`onMove`).
    private func reorder(_ id: String, to offset: Int) {
        var order = Layout.order(store.settings)
        guard let from = order.firstIndex(of: id) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: min(max(offset, 0), order.count))
        store.settings.layout.order = order
    }
}

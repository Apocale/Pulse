import SwiftUI

/// La page « Barre de menus » de la fenêtre Réglages : un élément ou un par
/// segment, quels segments, dans quel ordre, dans quel style, le symbole
/// d'alerte, et la place que tout cela prend — avec l'aperçu des vraies
/// images, sur barre sombre et claire.
///
/// Tout s'écrit à la volée dans `reglages.json` et s'applique à la barre
/// sans redémarrage (`AppDelegate.apply` → `MenuBarController.refresh`).
struct MenuBarSettingsPage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var sampler: Sampler
    @State private var history = MenuBarHistory()

    private var items: [MenuBarSettings.Item] { MenuBarCatalog.items(store.settings) }

    var body: some View {
        Form {
            Section {
                preview
                roomLine
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Barre de menus", systemImage: "menubar.rectangle").font(.title3.weight(.semibold))
                    Text("Ce que Pulse montre en haut de l'écran, sans ouvrir le panneau. Aperçu avec les mesures du moment.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }

            Section {
                Picker("Dans la barre", selection: mode) {
                    Text("Un seul élément").tag(MenuBarSettings.Mode.combined)
                    Text("Un élément par segment").tag(MenuBarSettings.Mode.separate)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Un seul élément prend le moins de place : chaque élément ajoute ses marges, et à droite de l'encoche il n'y a que 918 points. Séparés, les éléments se rangent ensuite en ⌘-glissant dans la barre.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index, count: items.count)
                }
            } header: {
                Text("Segments, de gauche à droite")
            } footer: {
                Text("La jauge et l'anneau demandent un total réel : ni la température ni le débit n'en ont. Le mini-graphe montre la dernière minute.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                Picker("Symbole du verdict", selection: alert) {
                    ForEach(MenuBarSettings.Alert.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Alerte")
            } footer: {
                Text("Un triangle plein pour une alerte, en contour pour un avertissement : la forme dit le niveau, pas la couleur. Sa place est gardée même sans alerte, pour que la barre ne bouge pas quand elle arrive.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

        }
        .formStyle(.grouped)
        .navigationTitle("Barre de menus")
    }

    // MARK: Lignes

    @ViewBuilder
    private func row(_ item: MenuBarSettings.Item, index: Int, count: Int) -> some View {
        if let entry = MenuBarCatalog.entry(item.id) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Toggle(entry.name, isOn: shown(item.id))
                    Spacer()
                    if entry.styles.count > 1 {
                        Picker("Style", selection: style(item.id)) {
                            ForEach(entry.styles, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!item.shown)
                    }
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .accessibilityLabel("Monter \(entry.name)")
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == count - 1)
                        .accessibilityLabel("Descendre \(entry.name)")
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Les images mêmes que la barre recevra, recolorées comme macOS le fait
    /// d'une image template, sur barre sombre puis claire.
    private var preview: some View {
        let contents = MenuBarComposer.contents(sampler, settings: store.settings, history: history)
        let widths = contents.map { Int(MenuBarDrawing.size($0).width) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach([true, false], id: \.self) { dark in
                HStack(spacing: 14) {
                    ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                        let size = MenuBarDrawing.size(content)
                        Image(nsImage: MenuBarDrawing.image(content, scale: 2))
                            .renderingMode(.template)
                            .frame(width: size.width, height: size.height)
                            .foregroundStyle(dark ? Color.white : Color.black)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(dark ? Color.black : Color(white: 0.93), in: RoundedRectangle(cornerRadius: 4))
                // `.combine` et non `.ignore` : un conteneur ignoré sort en
                // AXUnknown, que VoiceOver ne lit pas (piège du README ; 16).
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Aperçu sur barre \(dark ? "sombre" : "claire") : \(contents.map(\.spoken).joined(separator: " ; "))")
            }
            Text(widths.count == 1
                 ? "Image de \(widths[0]) points de large, figée : elle ne bouge pas avec les mesures."
                 : "\(widths.count) éléments de \(widths.map(String.init).joined(separator: " + ")) points, chacun figé, plus leurs marges.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// La place à droite de l'encoche, lue sur les fenêtres de la barre.
    @ViewBuilder
    private var roomLine: some View {
        if let area = MenuBarRoom.rightOfNotch() {
            let room = MenuBarRoom.room(MenuBarRoom.shownWindows(), rightOfNotch: area)
            Label {
                Text("À droite de l'encoche : \(Int(room.area)) points, dont \(Int(room.used)) pris par \(room.count) icônes ; \(Int(room.free)) libres.")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: room.free < 20 ? "exclamationmark.triangle" : "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    // MARK: Liaisons

    private var mode: Binding<MenuBarSettings.Mode> {
        Binding(get: { store.settings.menuBar.mode }, set: { store.settings.menuBar.mode = $0 })
    }

    private var alert: Binding<MenuBarSettings.Alert> {
        Binding(get: { store.settings.menuBar.alert }, set: { store.settings.menuBar.alert = $0 })
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { MenuBarCatalog.items(store.settings).first { $0.id == id }?.shown ?? false },
                set: { value in
                    var settings = store.settings
                    MenuBarCatalog.setShown(value, id: id, in: &settings)
                    store.settings = settings
                })
    }

    private func style(_ id: String) -> Binding<MenuBarSettings.Style> {
        Binding(get: { MenuBarCatalog.items(store.settings).first { $0.id == id }?.style ?? .text },
                set: { value in
                    var settings = store.settings
                    MenuBarCatalog.setStyle(value, id: id, in: &settings)
                    store.settings = settings
                })
    }

    private func move(_ index: Int, by offset: Int) {
        var settings = store.settings
        let target = index + offset
        guard target >= 0, target < MenuBarCatalog.items(settings).count else { return }
        MenuBarCatalog.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target,
                            in: &settings)
        store.settings = settings
    }
}

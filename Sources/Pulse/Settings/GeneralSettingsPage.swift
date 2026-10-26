import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Page générale

struct GeneralSettingsPage: View {
    @ObservedObject var store: SettingsStore
    let sampler: Sampler
    @State private var notice: String?
    /// Hauteur du panneau avec ces réglages, et celle que l'écran offre.
    @State private var fit: PanelMeasure.Fit?
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginNotice: String?

    var body: some View {
        Form {
            // Pulse s'inscrit seul au premier lancement (`registerLoginItemOnce`) ;
            // ici, de quoi le retirer sans passer par Réglages Système (26/10).
            Section {
                Toggle("Ouvrir Pulse à l'ouverture de session", isOn: launchAtLogin)
                if let loginNotice {
                    Text(loginNotice).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Démarrage")
            } footer: {
                Text("Pulse surveille mieux s'il tourne en continu : la prévision des disques demande six heures de relevés suivis. Le même réglage vit dans Réglages Système › Général › Ouverture.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                Picker("Colonnes", selection: columns) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                LayoutMap(store: store)
                if let fit {
                    heightLine(fit)
                }
            } header: {
                Text("Disposition du panneau")
            } footer: {
                Text("Glissez une carte d'une colonne à l'autre, ou au-dessus d'une autre carte. L'ordre se règle aussi en glissant les cartes dans la barre latérale.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                Picker("Panneau ouvert", selection: openInterval) {
                    ForEach(RefreshSettings.openChoices, id: \.self) { Text("toutes les \(Fmt.decimalSeconds($0))").tag($0) }
                }
                Picker("Panneau fermé", selection: closedInterval) {
                    ForEach(RefreshSettings.closedChoices, id: \.self) { Text("toutes les \(Fmt.decimalSeconds($0))").tag($0) }
                }
            } header: {
                Text("Mise à jour")
            } footer: {
                Text("Panneau fermé, jamais plus souvent que toutes les 5 s : c'est ce qui garde Pulse sous 1 % d'un cœur. Le débit de la barre de menus garde son rythme de 2 s.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                Picker("Thème", selection: theme) {
                    ForEach(PulseTheme.allCases) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Apparence")
            } footer: {
                Text("Le thème change les fonds, jamais les couleurs des graphiques : elles restent lisibles sur chacun. Le cadre du panneau est en verre ; « Réduire la transparence » de macOS le rend opaque.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                Picker("Débit", selection: rateUnit) {
                    Text("en octets (Mo/s)").tag(DisplaySettings.RateUnit.bytes)
                    Text("en bits (Mbit/s)").tag(DisplaySettings.RateUnit.bits)
                }
            } header: {
                Text("Unités")
            } footer: {
                Text("Stockage en base 1000 et mémoire en base 1024, comme macOS : ces deux-là ne se règlent pas.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section {
                HStack {
                    Button("Exporter…") { exportSettings() }
                    Button("Importer…") { importSettings() }
                    Spacer()
                    Button("Réglages d'origine…") { resetSettings() }
                }
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Sauvegarde")
            } footer: {
                Text("Les réglages vivent dans \(store.url.path(percentEncoded: false)). Un réglage illisible retombe seul sur sa valeur d'origine.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Général")
        // Remesuré à chaque changement de réglage, pas à chaque relevé.
        .task(id: store.settings) { fit = PanelMeasure.fit(sampler: sampler, settings: store.settings) }
    }

    /// Trop haut pour l'écran, le panneau prend de lui-même une colonne de
    /// plus (`PanelFit`) : le dire ici, chiffres à l'appui.
    @ViewBuilder
    private func heightLine(_ fit: PanelMeasure.Fit) -> some View {
        let adapted = fit.natural.height > fit.screen
        Label {
            // Des mots plutôt que « pt », les milliers séparés comme
            // partout ailleurs dans Pulse (« 3 487 ») ; chantier 16.
            Text(adapted
                 ? "Trop haut pour l'écran (\(SensorFormat.thousands(Int(fit.natural.height))) points sur \(SensorFormat.thousands(Int(fit.screen)))) : le panneau passe de lui-même à \(fit.columns) colonnes. Vos réglages ne changent pas."
                 : "Le panneau tient dans l'écran : \(SensorFormat.thousands(Int(fit.natural.height))) points de haut sur \(SensorFormat.thousands(Int(fit.screen))).")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: adapted ? "rectangle.split.3x1" : "checkmark.circle")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Liaisons

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginItem },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginNotice = nil
                    } catch {
                        loginNotice = "macOS a refusé : \(error.localizedDescription)"
                    }
                    let status = SMAppService.mainApp.status
                    loginItem = status == .enabled
                    if on, status == .requiresApproval {
                        loginNotice = "À autoriser dans Réglages Système › Général › Ouverture."
                    }
                })
    }

    private var columns: Binding<Int> {
        Binding(get: { Layout.columnCount(store.settings) },
                set: { count in
                    var settings = store.settings
                    Layout.setColumns(count, in: &settings)
                    store.settings = settings
                })
    }

    private var openInterval: Binding<Double> {
        Binding(get: { store.settings.refresh.sanitized.openInterval },
                set: { store.settings.refresh.openInterval = $0 })
    }

    private var closedInterval: Binding<Double> {
        Binding(get: { store.settings.refresh.sanitized.closedInterval },
                set: { store.settings.refresh.closedInterval = $0 })
    }

    private var theme: Binding<PulseTheme> {
        Binding(get: { store.settings.display.theme },
                set: { store.settings.display.theme = $0 })
    }

    private var rateUnit: Binding<DisplaySettings.RateUnit> {
        Binding(get: { store.settings.display.rateUnit },
                set: { store.settings.display.rateUnit = $0 })
    }

    // MARK: Sauvegarde

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Réglages Pulse.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(to: url)
            notice = "Exportés dans \(url.lastPathComponent)."
        } catch {
            notice = "Export impossible : \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importSettings(from: url)
            notice = "Importés depuis \(url.lastPathComponent)."
        } catch {
            notice = "Ce fichier n'est pas un fichier de réglages de Pulse : rien n'a changé."
        }
    }

    private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Revenir aux réglages d'origine ?"
        alert.informativeText = "Cartes, ordre, colonnes, couleurs, cadence et unités reprennent leur valeur d'origine. Exportez d'abord pour pouvoir revenir en arrière."
        alert.addButton(withTitle: "Rétablir")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.settings = PulseSettings()
        notice = "Réglages d'origine rétablis."
    }
}

/// Le plan du panneau : une colonne par colonne, une étiquette par carte
/// affichée. On y glisse les cartes d'une colonne à l'autre.
struct LayoutMap: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let columns = Layout.columns(store.settings)
        let hidden = Layout.order(store.settings).filter { id in
            ModuleRegistry.module(id).map { !Layout.isEnabled($0, in: store.settings) } ?? false
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, ids in
                    VStack(spacing: 6) {
                        ForEach(ids, id: \.self) { id in
                            chip(id)
                                .dropDestination(for: String.self) { items, _ in
                                    drop(items, column: index, before: id)
                                }
                                // Le glisser-déposer n'existe ni au clavier ni
                                // pour VoiceOver : les mêmes gestes en actions
                                // (HIG Accessibility, « Offer alternatives to
                                // gestures » ; chantier 16).
                                .accessibilityActions {
                                    let position = ids.firstIndex(of: id) ?? 0
                                    if position > 0 {
                                        Button("Monter") { _ = drop([id], column: index, before: ids[position - 1]) }
                                    }
                                    if position + 1 < ids.count {
                                        Button("Descendre") {
                                            _ = drop([id], column: index, before: position + 2 < ids.count ? ids[position + 2] : nil)
                                        }
                                    }
                                    if index > 0 {
                                        Button("Colonne de gauche") { _ = drop([id], column: index - 1, before: nil) }
                                    }
                                    if index + 1 < columns.count {
                                        Button("Colonne de droite") { _ = drop([id], column: index + 1, before: nil) }
                                    }
                                }
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, column: index, before: nil)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Colonne \(index + 1)")
                }
            }
            if !hidden.isEmpty {
                Text("Masquées : " + hidden.compactMap { ModuleRegistry.module($0)?.name }.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func chip(_ id: String) -> some View {
        let module = ModuleRegistry.module(id)
        return Label(module?.name ?? id, systemImage: module?.symbol ?? "square")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.15)))
            .draggable(id)
            .accessibilityHint("Glissez la carte, ou utilisez les actions pour la déplacer")
    }

    private func drop(_ items: [String], column: Int, before: String?) -> Bool {
        guard let id = items.first, ModuleRegistry.module(id) != nil else { return false }
        var settings = store.settings
        Layout.move(id, toColumn: column, before: before, in: &settings)
        store.settings = settings
        return true
    }
}

/// La taille du panneau pour des réglages donnés, mesurée sur la vraie vue
/// avec les mesures du moment — sans rien afficher ni écrire.
@MainActor
enum PanelMeasure {
    struct Fit: Equatable {
        /// Le panneau tel que les réglages le décrivent, sans limite.
        var natural: CGSize
        /// Le panneau sur l'écran principal, ajusté s'il le faut.
        var fitted: CGSize
        /// La hauteur offerte au panneau.
        var screen: CGFloat
        var columns: Int
    }

    static func fit(sampler: Sampler, settings: PulseSettings) -> Fit {
        let scratch = SettingsStore(url: URL(fileURLWithPath: "/dev/null/reglages.json"), writes: false)
        scratch.settings = settings
        let limits = PanelLimits.of(nil)
        let natural = NSHostingView(rootView: PopoverView(sampler: sampler, store: scratch)).fittingSize
        let fitted = NSHostingView(rootView: PopoverView(sampler: sampler, store: scratch, limits: limits)).fittingSize
        let columns = Int(((fitted.width - 24 + 10) / (PopoverView.columnWidth + 10)).rounded())
        return Fit(natural: natural, fitted: fitted, screen: limits?.height ?? 1274, columns: columns)
    }
}

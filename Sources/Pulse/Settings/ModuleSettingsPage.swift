import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Page d'un module

struct ModuleSettingsPage: View {
    let module: any PulseModule
    @ObservedObject var store: SettingsStore
    let sampler: Sampler

    private var mine: ModuleSettings { store.settings.module(module.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    Toggle("Afficher la carte dans le panneau", isOn: enabled)
                    if Layout.columnCount(store.settings) > 1 {
                        Picker("Colonne", selection: column) {
                            ForEach(0..<Layout.columnCount(store.settings), id: \.self) { Text("\($0 + 1)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Carte compacte", isOn: compact)
                    if module.listsApps {
                        Stepper("Apps listées : \(mine.appCount ?? ModuleSettings.defaultAppCount)",
                                value: appCount, in: ModuleSettings.appCountRange)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(module.name, systemImage: module.symbol).font(.title3.weight(.semibold))
                        if !module.summary.isEmpty {
                            Text(module.summary).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)
                }

                if !module.options.isEmpty {
                    Section("Réglages de la carte") {
                        ForEach(module.options) { option in optionRow(option) }
                    }
                }

                if let extra = module.settingsSection(store) {
                    Section(extra.title) { extra.content }
                }

                if !module.series.isEmpty {
                    Section {
                        ForEach(module.series) { series in
                            SeriesTintRow(series: series, chosen: tint(series))
                        }
                    } header: {
                        Text("Couleurs")
                    } footer: {
                        Text("Une couleur doit tenir 3:1 sur le fond des cartes, en sombre comme en clair : en dessous, elle est refusée (barrée).")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Coût") {
                    Text(costText).font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)

            preview
        }
        // Le fond de la fenêtre sous l'aperçu aussi : la carte s'y lit comme
        // dans le panneau, posée sur son propre fond.
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(module.name)
    }

    /// La carte telle qu'elle est dans le panneau, avec les réglages en
    /// cours et les mesures du moment.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Aperçu en direct")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                module.card(CardContext(module: module, sampler: sampler, open: .constant(nil),
                                        settings: mine, display: store.settings.display))
                    .frame(width: PopoverView.columnWidth)
                    .padding(12)
                    .background(PopoverBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(Layout.isEnabled(module, in: store.settings) ? 1 : 0.5)
            }
        }
        .padding(16)
        .frame(width: PopoverView.columnWidth + 24 + 32)
    }

    /// Pour qui règle Pulse : les chiffres seulement. La note de mesure — sa
    /// source, sa date, « relevé commun du socle… (11/10) » — reste dans
    /// `--probe`, section MODULES ; envoyée telle quelle, elle parlait au
    /// développeur dans les Réglages d'un ami (26/10).
    private var costText: String {
        let cost = module.cost
        var parts: [String] = []
        if let closed = cost.closed { parts.append("panneau fermé \(Self.percent(closed)) d'un cœur") }
        if let open = cost.open { parts.append("ouvert \(Self.percent(open))") }
        guard !parts.isEmpty else {
            return "Mesurée avec les autres cartes de base : Pulse entier reste sous 1 % d'un cœur panneau fermé."
        }
        return parts.joined(separator: ", ") + "."
    }

    private static func percent(_ value: Double) -> String {
        String(format: value < 0.01 ? "%.4f %%" : "%.2f %%", value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Liaisons

    private func update(_ change: (inout ModuleSettings) -> Void) {
        var settings = store.settings.module(module.id)
        change(&settings)
        store.settings.modules[module.id] = settings
    }

    private var enabled: Binding<Bool> {
        Binding(get: { Layout.isEnabled(module, in: store.settings) },
                set: { value in update { $0.enabled = value } })
    }

    private var column: Binding<Int> {
        Binding(get: { Layout.column(of: module, in: store.settings) },
                set: { value in update { $0.column = value } })
    }

    private var compact: Binding<Bool> {
        Binding(get: { mine.compact }, set: { value in update { $0.compact = value } })
    }

    private var appCount: Binding<Int> {
        Binding(get: { mine.appCount ?? ModuleSettings.defaultAppCount },
                set: { value in update { $0.appCount = value } })
    }

    private func tint(_ series: ModuleSeries) -> Binding<String?> {
        Binding(get: { mine.tints[series.id] },
                set: { value in update { $0.tints[series.id] = value } })
    }

    @ViewBuilder
    private func optionRow(_ option: ModuleOption) -> some View {
        let current = mine.options[option.id] ?? option.defaultValue
        let set: (OptionValue) -> Void = { value in update { $0.options[option.id] = value } }
        VStack(alignment: .leading, spacing: 2) {
            switch option.kind {
            case .toggle:
                Toggle(option.label, isOn: Binding(get: { current.bool ?? false }, set: { set(.bool($0)) }))
            case .choice(let choices, _):
                Picker(option.label, selection: Binding(get: { current.text ?? "" }, set: { set(.text($0)) })) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
            case .number(let range, _, let unit):
                Stepper("\(option.label) : \(current.int ?? range.lowerBound) \(unit)",
                        value: Binding(get: { current.int ?? range.lowerBound }, set: { set(.int($0)) }),
                        in: range)
            }
            if !option.help.isEmpty {
                Text(option.help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Le choix de teinte d'une série : une pastille par couleur proposée, celles
/// qui tombent sous 3:1 barrées et inactives ; le ratio se lit au survol et
/// à VoiceOver.
struct SeriesTintRow: View {
    let series: ModuleSeries
    @Binding var chosen: String?

    private var current: String { chosen ?? series.defaultTint.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(series.label)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
                if chosen != nil {
                    Button("Par défaut") { chosen = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            HStack(spacing: 6) {
                ForEach(TintChoice.candidates, id: \.raw) { candidate in
                    swatch(candidate.raw, name: candidate.name)
                }
            }
        }
    }

    private var summary: String {
        let choice = TintChoice(raw: current)
        guard let ratios = choice.ratios else { return TintChoice.name(of: current) }
        return "\(TintChoice.name(of: current)) · \(Contrast.text(ratios.dark)) sombre · \(Contrast.text(ratios.light)) clair"
    }

    private func swatch(_ raw: String, name: String) -> some View {
        let choice = TintChoice(raw: raw)
        let ratios = choice.ratios
        let passes = choice.passes
        let selected = raw == current
        let detail = ratios.map { "\(Contrast.text($0.dark)) sur fond sombre, \(Contrast.text($0.light)) sur fond clair" } ?? ""
        return Button {
            chosen = raw == series.defaultTint.rawValue ? nil : raw
        } label: {
            ZStack {
                Circle().fill(Color(nsColor: choice.nsColor ?? .gray))
                if !passes {
                    // Barrée : refusée, et la raison se lit sans la couleur.
                    Rectangle().fill(Color.primary).frame(width: 2).rotationEffect(.degrees(45))
                }
            }
            .frame(width: 18, height: 18)
            .padding(3)
            .overlay(Circle().strokeBorder(Color.primary, lineWidth: selected ? 2 : 0))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!passes)
        .help(passes ? "\(name) : \(detail)" : "\(name) refusée : \(detail), sous 3:1")
        .accessibilityLabel(name)
        .accessibilityValue(passes ? (selected ? "choisie, \(detail)" : detail) : "refusée, \(detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

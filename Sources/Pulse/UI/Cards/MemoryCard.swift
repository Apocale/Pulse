import SwiftUI

/// Mémoire : la pression et l'occupation en anneaux, la répartition, le swap
/// et sa pente, les apps qui tiennent le plus.
struct MemoryModule: PulseModule {
    let id = "memoire"
    let name = "Mémoire"
    let symbol = "memorychip"
    var summary: String { "Pression, occupation par catégorie, swap et sa pente, les apps qui tiennent le plus." }
    var listsApps: Bool { true }
    var defaultColumn: Int { 1 }
    /// L'anneau de pression n'en fait pas partie : sa teinte dit le niveau du
    /// noyau (normal, avertissement, critique), pas une série.
    var series: [ModuleSeries] {
        [ModuleSeries(id: "apps", label: "Apps", defaultTint: .data),
         ModuleSeries(id: "systeme", label: "Système", defaultTint: .muted),
         ModuleSeries(id: "compressee", label: "Compressée", defaultTint: .tertiary)]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(MemoryCard(sampler: context.sampler, context: context))
    }

    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        let used = sampler.memory.usedFraction
        return MenuBarSegment(label: "MÉM", value: Fmt.percent(used),
                              spoken: "mémoire \(Fmt.percent(used))", fraction: used)
    }
}

struct MemoryCard: View {
    @ObservedObject var sampler: Sampler
    let context: CardContext

    var body: some View {
        let memory = sampler.memory
        let total = Double(max(memory.total, 1))
        let byMemory = sampler.processes.sorted { $0.footprint > $1.footprint }.prefix(context.appCount)

        return Card {
            // Le titre ouvre l'historique longue durée (chantier 02).
            HistoryToggle(key: "memoire", label: "de la mémoire", spoken: "Mémoire",
                          value: "\(Fmt.memory(memory.used)) sur \(Fmt.memory(memory.total, digits: 0))",
                          heading: true, open: context.open) {
                CardTitle(title: "Mémoire", symbol: "memorychip",
                          trailing: "\(Fmt.memory(memory.used)) sur \(Fmt.memory(memory.total, digits: 0))",
                          open: context.open.wrappedValue == "memoire")
            }
            HStack(spacing: 22) {
                Spacer(minLength: 0)
                if let pressure = memory.pressure {
                    Ring(fraction: pressure, tint: pressureTint(memory), lineWidth: 7) {
                        // Le niveau qui colore l'anneau, écrit aussi : la
                        // couleur ne le dit jamais seule (chantier 16).
                        RingCenter(value: Fmt.percent(pressure), caption: "pression",
                                   note: memory.pressureLevel == 4 ? "critique"
                                       : memory.pressureLevel == 2 ? "élevée" : nil)
                    }
                    .frame(width: 84, height: 84)
                }
                SegmentedRing(segments: [(Double(memory.app) / total, context.tint("apps")),
                                         (Double(memory.wired) / total, context.tint("systeme")),
                                         (Double(memory.compressed) / total, context.tint("compressee"))],
                              lineWidth: 7) {
                    RingCenter(value: Fmt.percent(memory.usedFraction), caption: "utilisée")
                }
                .frame(width: 84, height: 84)
                Spacer(minLength: 0)
            }
            // Compacte : les deux anneaux, rien d'autre.
            if !context.compact {
                VStack(spacing: 3) {
                    InfoRow(label: "Apps", value: Fmt.memory(memory.app), dot: context.tint("apps"))
                    InfoRow(label: "Système", value: Fmt.memory(memory.wired), dot: context.tint("systeme"))
                    InfoRow(label: "Compressée", value: Fmt.memory(memory.compressed), dot: context.tint("compressee"))
                    InfoRow(label: "Swap, sur le disque", value: swapText(memory))
                }
                if !byMemory.isEmpty {
                    CardCaption(text: "Apps")
                    ForEach(Array(byMemory)) { group in
                        AppRow(group: group, value: Fmt.memory(group.footprint))
                    }
                }
            }
            HistoryPanel(key: "memoire", open: context.open.wrappedValue) {
                HistoryChart(keys: ["memoire.utilisee"], title: "Mémoire utilisée", plotHeight: 34)
            }
        }
    }

    /// Le niveau du noyau colore l'anneau : la pression en pourcentage monte
    /// et descend sans cesse, seul le niveau dit quand elle devient un
    /// problème.
    private func pressureTint(_ memory: MemorySample) -> Color {
        switch memory.pressureLevel {
        case 4: return Palette.alert
        case 2: return Palette.warning
        default: return Palette.data
        }
    }

    /// Le swap et sa pente sur la fenêtre des courbes : c'est la hausse qui
    /// fait mal, pas le stock.
    private func swapText(_ memory: MemorySample) -> String {
        guard memory.swapUsed > 0 else { return "aucun" }
        let value = Fmt.memory(memory.swapUsed)
        let recent = CardKit.recentSeries(sampler.series)
        guard let first = recent.first, let last = recent.last, last.t - first.t >= 300 else { return value }
        let rise = Double(memory.swapUsed) - first.swap
        return rise >= 256 * 1_048_576 ? "+\(Fmt.memory(rise)) en 1 h · \(value)" : value
    }
}

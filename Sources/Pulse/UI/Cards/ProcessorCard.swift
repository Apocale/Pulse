import SwiftUI

/// Processeur : la dernière heure en barres, utilisateur et système, un
/// anneau par cœur, les apps qui calculent, la carte graphique, la charge.
struct ProcessorModule: PulseModule {
    let id = "processeur"
    let name = "Processeur"
    let symbol = "cpu"
    var summary: String { "La dernière heure, chaque cœur, les apps qui calculent, la carte graphique." }
    var listsApps: Bool { true }
    var defaultColumn: Int { 0 }
    var series: [ModuleSeries] {
        [ModuleSeries(id: "historique", label: "Dernière heure", defaultTint: .data),
         ModuleSeries(id: "performance", label: "Cœurs performance", defaultTint: .data),
         ModuleSeries(id: "efficacite", label: "Cœurs efficacité", defaultTint: .muted),
         ModuleSeries(id: "graphique", label: "Carte graphique", defaultTint: .data)]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(ProcessorCard(sampler: context.sampler, context: context))
    }

    /// « CPU » sur « 44 % » : tous les cœurs, la part d'un total réel.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        let total = sampler.cpu.total
        return MenuBarSegment(label: "CPU", value: Fmt.percent(total),
                              spoken: "processeur \(Fmt.percent(total))", fraction: total)
    }
}

struct ProcessorCard: View {
    @ObservedObject var sampler: Sampler
    let context: CardContext

    var body: some View {
        let cpu = sampler.cpu
        let bars = minuteBars(recentSeries.map(\.cpu))
        let e = CPUMonitor.efficiencyCores

        return Card {
            // Le titre ouvre l'historique longue durée (chantier 02), comme
            // ceux des cartes Disques, Capteurs et Énergie.
            HistoryToggle(key: "processeur", label: "du processeur", spoken: "Processeur",
                          value: Fmt.percent(cpu.total), heading: true, open: context.open) {
                CardTitle(title: "Processeur", symbol: "cpu", trailing: Fmt.percent(cpu.total),
                          open: context.open.wrappedValue == "processeur")
            }
            VStack(alignment: .leading, spacing: 3) {
                HistoryBars(values: bars, tint: context.tint("historique"), readout: { index in
                    // Survol : l'heure de la barre et sa charge (chantier 10).
                    let points = recentSeries
                    let size = max(1, points.count / 60)
                    let last = min(points.count - 1, index * size + size - 1)
                    guard index < bars.count, last >= 0 else { return nil }
                    return [HoverTime.minute(Date(timeIntervalSince1970: points[last].t)),
                            "processeur \(Fmt.percent(bars[index]))"]
                }, spoken: bars.isEmpty ? nil : "Processeur, \(historyLegend) à maintenant, une barre par minute")
                    .frame(height: 34)
                HStack {
                    Text(bars.isEmpty ? "collecte en cours" : historyLegend)
                    Spacer()
                    Text("maintenant")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                // L'axe du temps : le libellé du graphique le dit déjà
                // (HIG Charts, « Hide visible text labels for axes »).
                .accessibilityHidden(!bars.isEmpty)
            }
            // Sans pastille : les barres montrent le TOTAL, toutes de la même
            // teinte ; une pastille bleue « utilisateur » les faisait lire
            // comme la part utilisateur (chantier 16).
            HStack(spacing: 12) {
                legend("utilisateur", Fmt.percent(cpu.user), nil)
                legend("système", Fmt.percent(cpu.system), nil)
            }
            // Compacte : la dernière heure et la répartition, rien d'autre.
            if !context.compact { details(cpu, e) }
            HistoryPanel(key: "processeur", open: context.open.wrappedValue) {
                HistoryChart(keys: ["cpu.total"], title: "Processeur", plotHeight: 34)
            }
        }
    }

    @ViewBuilder
    private func details(_ cpu: CPUSample, _ e: Int) -> some View {
        // Un anneau par cœur, efficacité d'abord : c'est l'ordre dans
        // lequel le noyau les énumère, et celui d'iStat.
        if !cpu.perCore.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { index, load in
                    Ring(fraction: load, tint: index < e ? context.tint("efficacite") : context.tint("performance"),
                         lineWidth: 3) {
                        EmptyView()
                    }
                    .frame(width: 18, height: 18)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(cpu.perCore.count) cœurs : efficacité \(Fmt.percent(cpu.efficiency)), performance \(Fmt.percent(cpu.performance))")
            // Douze petits anneaux posés d'emblée : les remplir à l'ouverture
            // doublait le coût de la cascade pour un geste qu'on ne voit pas
            // à 18 pt (mesuré, docs/chantiers/10-animations.md).
            .environment(\.fillProgress, 1)
            HStack(spacing: 12) {
                legend("\(e) efficacité", Fmt.percent(cpu.efficiency), context.tint("efficacite"))
                legend("\(cpu.perCore.count - e) performance", Fmt.percent(cpu.performance), context.tint("performance"))
            }
        }
        if context.appCount > 0 {
            CardCaption(text: "Apps", trailing: "% d'un cœur")
            ForEach(Array(sampler.processes.prefix(context.appCount))) { group in
                AppRow(group: group, value: Fmt.cpu(group.cpu))
            }
        }
        if let gpu = sampler.gpu {
            HStack(spacing: 8) {
                Text("Carte graphique").font(.callout).foregroundStyle(.secondary)
                Meter(fraction: gpu, tint: context.tint("graphique"), height: 5)
                Text(Fmt.percent(gpu)).font(.callout.monospacedDigit())
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
        if cpu.load.count == 3 {
            // « 1 · 5 · 15 » se lisait « 1 point 5 point 15 » (chantier 16).
            InfoRow(label: "Charge 1 · 5 · 15 min",
                    value: cpu.load.map { Self.loadFormat($0) }.joined(separator: "  "),
                    spoken: "Charge moyenne : " + zip(cpu.load, ["1 minute", "5 minutes", "15 minutes"])
                        .map { "\(Self.loadFormat($0)) sur \($1)" }.joined(separator: ", "))
        }
        if let boot = SystemClock.bootDate {
            InfoRow(label: "Allumé depuis", value: Self.uptime(Date().timeIntervalSince(boot)))
        }
    }

    private func legend(_ label: String, _ value: String, _ tint: Color?) -> some View {
        HStack(spacing: 5) {
            if let tint { Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true) }
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private var recentSeries: [SeriesPoint] { CardKit.recentSeries(sampler.series) }

    /// « dernière heure » seulement quand c'est vrai.
    private var historyLegend: String {
        guard let first = recentSeries.first, let last = recentSeries.last else { return "collecte en cours" }
        let span = last.t - first.t
        return span >= 55 * 60 ? "il y a 1 h" : "il y a \(Fmt.duration(span))"
    }

    /// Une barre par minute : la série tombe toutes les 10 s, soit six points
    /// par barre, moyennés. Soixante barres tiennent dans une colonne.
    private func minuteBars(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return [] }
        let size = max(1, values.count / 60)
        return stride(from: 0, to: values.count, by: size).map { start in
            let slice = values[start..<min(values.count, start + size)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    /// « 6 h 12 », « 3 j 4 h » : au-delà d'un jour, les minutes ne servent plus.
    static func uptime(_ seconds: TimeInterval) -> String {
        guard seconds >= 86_400 else { return Fmt.duration(seconds) }
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
        return hours == 0 ? "\(days) j" : "\(days) j \(hours) h"
    }

    /// « 1,83 » : deux décimales, virgule française.
    static func loadFormat(_ value: Double) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
    }
}

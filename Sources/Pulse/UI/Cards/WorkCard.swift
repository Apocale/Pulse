import SwiftUI

/// Montage : la carte qu'iStat n'a pas. La session de montage, l'export en
/// cours, le temps d'écran, les incidents. Absente quand il n'y a rien à en
/// dire.
struct WorkModule: PulseModule {
    let id = "montage"
    let name = "Montage"
    let symbol = "film"
    var summary: String { "La session de montage, l'export en cours, le temps d'écran, les plantages." }
    var defaultColumn: Int { 1 }

    func card(_ context: CardContext) -> AnyView {
        AnyView(WorkCard(sampler: context.sampler, context: context))
    }

    func hasContent(_ sampler: Sampler) -> Bool {
        sampler.session != nil || sampler.export != nil || sampler.focusTotal > 0 || !sampler.incidents.isEmpty
    }
}

struct WorkCard: View {
    @ObservedObject var sampler: Sampler
    let context: CardContext

    private var open: String? { context.open.wrappedValue }

    var body: some View {
        Card {
            CardTitle(title: "Montage", symbol: "film")
            if let session = sampler.session {
                HistoryToggle(key: "session", label: "de la session de montage",
                              spoken: Fmt.appName(session.name),
                              value: "depuis \(Fmt.duration(session.duration))"
                                + (sessionProcess.map { ", \(Fmt.memory($0.footprint))" } ?? ""),
                              open: context.open) {
                    HStack(spacing: 7) {
                        AppIcon(path: sessionProcess?.bundlePath).frame(width: 15, height: 15)
                        Text(Fmt.appName(session.name)).font(.callout)
                        Text("depuis \(Fmt.duration(session.duration))").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(sessionProcess.map { Fmt.memory($0.footprint) } ?? "—")
                            .font(.callout.monospacedDigit())
                        DisclosureChevron(open: open == "session")
                    }
                }
                HistoryPanel(key: "session", open: open) { SessionPanel(sampler: sampler) }
            }
            // La ligne « Export », dépliable sur les exports de la semaine,
            // la carte graphique et le cache (chantier 08, `Metrics/Media/`).
            if sampler.export != nil || sampler.session != nil {
                ExportsDisclosure(sampler: sampler, open: context.open)
            }
            // Compacte : la session et l'export, rien d'autre.
            if sampler.focusTotal > 0, !context.compact {
                HistoryToggle(key: "apps", label: "du temps par application", spoken: "Temps d'écran",
                              value: Fmt.duration(sampler.focusTotal)
                                + (sampler.apps.first.map { ", dont \(Fmt.appName($0.name)) \(Fmt.duration($0.focus))" } ?? ""),
                              open: context.open) {
                    HStack(spacing: 7) {
                        Text("Temps d'écran").font(.callout).foregroundStyle(.secondary)
                        if let top = sampler.apps.first {
                            Text("\(Fmt.appName(top.name)) \(Fmt.duration(top.focus))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(Fmt.duration(sampler.focusTotal)).font(.callout.monospacedDigit())
                        DisclosureChevron(open: open == "apps")
                    }
                }
                HistoryPanel(key: "apps", open: open) { AppsPanel(sampler: sampler) }
            }
            if !sampler.incidents.isEmpty, !context.compact {
                HistoryToggle(key: "incidents", label: "des incidents", spoken: "Incidents sur 14 jours",
                              value: "\(sampler.incidents.count)", open: context.open) {
                    HStack {
                        Text("Incidents · 14 jours").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(sampler.incidents.count)").font(.callout.monospacedDigit())
                        DisclosureChevron(open: open == "incidents")
                    }
                }
                HistoryPanel(key: "incidents", open: open) { IncidentsPanel(sampler: sampler) }
            }
        }
    }

    /// Mesures propres à l'application de montage, ses processus auxiliaires
    /// compris. C'est Premiere qui remplit la mémoire, pas « le système ».
    private var sessionProcess: ProcessGroup? {
        guard let bundleId = sampler.session?.bundleId else { return nil }
        return sampler.processes.first { $0.bundleId == bundleId }
    }
}

import WidgetKit
import SwiftUI

// Les widgets de Pulse : disque de rushes, mémoire, partage iPhone.
//
// Ils ne mesurent rien. Chacun relit `etat-partage.json`, que l'app écrit
// au plus une fois par minute, et l'affiche avec les vues de l'app
// (`PulseWidgetView`). L'extension est sandboxée — WidgetKit l'exige —, et
// une exception temporaire en lecture seule lui ouvre le seul dossier
// `~/Library/Application Support/Pulse/` : ni groupe d'apps, ni sandbox pour
// l'app (règle dure n°1). Prouvé en signature ad hoc par une sonde (journal
// du chantier 13).

struct Entree: TimelineEntry {
    let date: Date
    let etat: EtatPartage?
}

struct Fournisseur: TimelineProvider {
    func placeholder(in context: Context) -> Entree {
        Entree(date: Date(), etat: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entree) -> Void) {
        completion(Entree(date: Date(), etat: EtatPartage.read()))
    }

    /// Une entrée, relue toutes les 5 minutes : l'app écrit au plus une
    /// fois par minute, et macOS rationne les rafraîchissements.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entree>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [Entree(date: now, etat: EtatPartage.read())],
                            policy: .after(now.addingTimeInterval(300))))
    }
}

/// La vue d'un widget, à la taille que macOS lui donne.
struct VueWidget: View {
    let kind: WidgetKind
    let entree: Entree
    @Environment(\.widgetFamily) private var famille

    var body: some View {
        PulseWidgetView(kind: kind, size: famille == .systemSmall ? .petit : .moyen,
                        etat: entree.etat, now: entree.date)
            .containerBackground(WidgetTint.background, for: .widget)
    }
}

struct WidgetDisque: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.isma.pulse.disque", provider: Fournisseur()) { entree in
            VueWidget(kind: .disque, entree: entree)
        }
        .configurationDisplayName(WidgetKind.disque.title)
        .description(WidgetKind.disque.summary)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetMemoire: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.isma.pulse.memoire", provider: Fournisseur()) { entree in
            VueWidget(kind: .memoire, entree: entree)
        }
        .configurationDisplayName(WidgetKind.memoire.title)
        .description(WidgetKind.memoire.summary)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetForfait: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.isma.pulse.forfait", provider: Fournisseur()) { entree in
            VueWidget(kind: .forfait, entree: entree)
        }
        .configurationDisplayName(WidgetKind.forfait.title)
        .description(WidgetKind.forfait.summary)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct PulseWidgets: WidgetBundle {
    var body: some Widget {
        WidgetDisque()
        WidgetMemoire()
        WidgetForfait()
    }
}

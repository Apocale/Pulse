import SwiftUI

/// Ce qui s'ouvre sous la ligne « internet » : le débit du moment, puis la
/// consommation des sept derniers jours, jour par jour et réseau par réseau.
///
/// Une barre par jour, empilée par réseau. Le partage iPhone porte la teinte
/// d'avertissement : c'est du forfait mobile, chaque gigaoctet y compte.
/// Starlink porte la teinte des données, les autres réseaux restent neutres.
/// Les teintes ne colorent que les barres et les pastilles, jamais du texte
/// (règle dure n°6). Base 1000, comme les opérateurs et le Finder.
struct NetworkPanel: View {
    @ObservedObject var sampler: Sampler

    var body: some View {
        NetworkChart(now: sampler.network, history: sampler.networkHistory(days: 7))
    }
}

/// Le dépliant lui-même, nourri de données plutôt que du Sampler : c'est ce
/// qui permet à `--snapshot` de le rendre hors écran avec les vraies données,
/// sans lancer un second échantillonnage à côté de l'app.
struct NetworkChart: View {
    var now: NetworkSample
    var history: [(day: Date, usage: [NetworkTracker.Usage])]

    private let chartHeight: CGFloat = 54

    var body: some View {
        let totals = history.map { $0.usage.reduce(0) { $0 + $1.rx + $1.tx } }
        let peak = max(totals.max() ?? 0, 1)
        let net = now

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("en ce moment").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(net.connected
                     ? "↓ \(Fmt.bytes(net.rxRate))/s   ↑ \(Fmt.bytes(net.txRate))/s"
                     : "hors ligne")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }

            if totals.allSatisfy({ $0 == 0 }) {
                Text("collecte en cours — le cumul se remplit tant que Pulse tourne")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                        VStack(spacing: 3) {
                            column(entry.usage, total: totals[index], peak: peak)
                            Text(initial(entry.day))
                                .font(.caption2)
                                .foregroundStyle(index == history.count - 1 ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                // VoiceOver lisait « L, M, M, J, V, S, D » : chaque jour est
                // dit en entier, réseau par réseau, avec les chiffres de la
                // section RÉSEAU de `--probe` (chantier 16).
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenDays)
                HStack(spacing: 10) {
                    ForEach(kindsSeen(history), id: \.self) { kind in
                        LegendDot(color: tint(kind), label: kind.label)
                    }
                    Spacer()
                    Text("pic \(Fmt.bytes(peak, digits: 1))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let today = history.last, !today.usage.isEmpty {
                    ForEach(today.usage, id: \.kind) { usage in
                        HStack {
                            Text("aujourd'hui · \(usage.label)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("↓ \(Fmt.bytes(usage.rx, digits: 1))   ↑ \(Fmt.bytes(usage.tx, digits: 1))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Les sept jours en mots : « lundi : partage iPhone, reçu 1,2 Go, envoyé
    /// 200 Mo ; … », les jours sans trafic sautés.
    private var spokenDays: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d"
        let days = history.filter { !$0.usage.isEmpty }.map { entry in
            "\(f.string(from: entry.day)) : " + entry.usage
                .map { "\($0.label), reçu \(Fmt.bytes($0.rx)), envoyé \(Fmt.bytes($0.tx))" }
                .joined(separator: " ; ")
        }
        return "Consommation internet des 7 derniers jours. " + days.joined(separator: ". ")
    }

    /// Une colonne : la journée, empilée par sorte de réseau, à l'échelle du
    /// jour le plus chargé de la semaine. Un jour sans trafic garde un trait
    /// de 2 pt : une colonne absente se lirait comme un jour non mesuré.
    ///
    /// Identité par sorte, unique par construction (`history` les fusionne).
    /// Identifiée par le nom, la colonne du 08/10 — quatre « Wi-Fi » — a
    /// répété quatre fois son plus gros segment : `ForEach` ne garantit rien
    /// sur des identités en double.
    private func column(_ usage: [NetworkTracker.Usage], total: UInt64, peak: UInt64) -> some View {
        let height = max(2, chartHeight * CGFloat(Double(total) / Double(peak)))
        return VStack(spacing: 1) {
            if total == 0 {
                RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(height: 2)
            } else {
                ForEach(usage, id: \.kind) { part in
                    let share = CGFloat(Double(part.rx + part.tx) / Double(total))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint(part.kind))
                        .frame(height: max(1, (height - CGFloat(usage.count - 1)) * share))
                }
            }
        }
        .frame(height: chartHeight, alignment: .bottom)
    }

    /// Le partage iPhone en violet, comme les barres du forfait : l'orange
    /// veut dire « attention » partout ailleurs, et des barres orange à
    /// chaque coup d'œil se lisaient comme une alerte (chantier 16).
    private func tint(_ kind: NetworkKind) -> Color {
        switch kind {
        case .hotspot:      return Palette.tertiary
        case .starlink:     return Palette.data
        case .wifi, .wired: return Palette.muted
        }
    }

    private func kindsSeen(_ history: [(day: Date, usage: [NetworkTracker.Usage])]) -> [NetworkKind] {
        var seen: [NetworkKind] = []
        for entry in history { for u in entry.usage where !seen.contains(u.kind) { seen.append(u.kind) } }
        return seen
    }

    private func initial(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEEE"
        return f.string(from: day).uppercased()
    }
}

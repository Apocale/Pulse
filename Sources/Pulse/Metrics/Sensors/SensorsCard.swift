import SwiftUI
import AppKit

/// La carte « Capteurs », façon iStat : trois anneaux — processeur, carte
/// graphique, ventilateurs —, la pression thermique, puis les températures
/// et la puissance en listes. Le détail par ventilateur et par cœur est dans
/// `--probe`.
///
/// Les anneaux ne montrent PAS de température : une température n'a pas de
/// dénominateur réel — aucune limite thermique n'est publiée par Apple ni
/// lisible dans l'IORegistry —, et un anneau rempli « sur 100 °C » serait
/// une échelle inventée (règle dure n°7). Ils montrent ce qui a un plafond
/// mesuré : la fréquence sur la plus haute fréquence de la table DVFS de la
/// puce, et la vitesse des ventilateurs sur le maximum d'Apple (`F0Mx`). Le
/// plafond est écrit sous chaque anneau. Les températures sont en tête de
/// carte et dans la liste.
///
/// Autonome, prête pour le registre du chantier 01 : elle ne dépend que de
/// son `SensorStore`. Teintes de `Palette` seulement, ratios mesurés.
struct SensorsCard: View {
    @ObservedObject var store: SensorStore
    /// Réglage du socle : le titre, les anneaux et la pression, sans les
    /// listes.
    var compact = false
    /// L'historique déplié du panneau, un seul à la fois (socle). Nil : pas
    /// de dépliant (rendu `--snapshot --capteurs`).
    var open: Binding<String?>? = nil

    static let historyKey = "capteurs"

    var body: some View {
        let sample = store.sample
        Card {
            title(sample)
            if let sample {
                rings(sample)
                if let level = sample.thermalPressure { pressureRow(level) }
                if !compact {
                    temperatures(sample)
                    power(sample)
                }
            } else {
                Text("lecture des capteurs…").font(.callout).foregroundStyle(.secondary)
            }
            history
        }
    }

    // MARK: - Titre et historique

    /// Le titre ouvre l'historique des températures, comme celui des
    /// disques ouvre l'espace libre.
    @ViewBuilder
    private func title(_ sample: SensorSample?) -> some View {
        let trailing = sample?.cpuTemperature.map { "Processeur \(SensorFormat.celsius($0))" }
        if let open {
            HistoryToggle(key: Self.historyKey, label: "des températures", spoken: "Capteurs",
                          value: trailing ?? "", heading: true, open: open) {
                CardTitle(title: "Capteurs", symbol: "thermometer.medium", trailing: trailing,
                          open: open.wrappedValue == Self.historyKey)
            }
        } else {
            CardTitle(title: "Capteurs", symbol: "thermometer.medium", trailing: trailing)
        }
    }

    /// La moyenne des cœurs et celle de la carte graphique dans l'historique
    /// longue durée (chantier 02) : la chaleur d'un export d'hier se relit.
    /// Pas d'échelle « sur 100 °C » : une température n'a pas de plein, le
    /// graphique trace une courbe sur son maximum observé, nommé comme tel.
    @ViewBuilder
    private var history: some View {
        if let open, open.wrappedValue == Self.historyKey {
            DetailPanel(legende: "Moyenne des cœurs et de la carte graphique, lue toutes les 30 s panneau fermé, toutes les 1,5 s ouvert.",
                        detail: nil) {
                HistoryChart(keys: [SensorStore.historyKeys.cpu, SensorStore.historyKeys.gpu], title: "Températures")
            }
        }
    }

    // MARK: - Anneaux

    private func rings(_ s: SensorSample) -> some View {
        HStack(alignment: .top, spacing: 0) {
            clockRing(s.performance, name: "Processeur", spoken: "cœurs performance", pending: s.reportPending)
            clockRing(s.gpuClock, name: "Carte graphique", spoken: "carte graphique", pending: s.reportPending)
            fanRing(s.fans)
        }
        .padding(.vertical, 2)
    }

    /// Fréquence pendant le temps actif, sur la fréquence maximale. Au repos
    /// complet sur l'intervalle, « repos » plutôt qu'un zéro qui se lirait
    /// comme une panne.
    private func clockRing(_ clock: SensorSample.Clock?, name: String, spoken: String, pending: Bool) -> some View {
        let resting = (clock?.active ?? 0) < 0.01
        let value = clock.map { resting ? "repos" : SensorFormat.number($0.mhz / 1000, digits: 2) } ?? "—"
        return ringColumn(fraction: resting ? 0 : clock?.fraction ?? 0,
                          value: value, unit: clock == nil || resting ? "" : "GHz", name: name,
                          ceiling: clock.map { "max \(SensorFormat.megahertz($0.max))" } ?? (pending ? "mesure…" : "illisible"))
            // Le nom, puis la mesure ET son plafond, comme sous l'anneau : le
            // maximum écrit à l'écran n'était pas dit (chantier 16).
            .accessibilityLabel("\(name), \(spoken)")
            .accessibilityValue(clock.map {
                resting ? "au repos" : "\(SensorFormat.megahertz($0.mhz)), au plus \(SensorFormat.megahertz($0.max))"
            } ?? (pending ? "mesure en cours" : "illisible"))
    }

    /// Les ventilateurs ensemble : vitesse moyenne, et part de la somme des
    /// maximums — un dénominateur réel, lu au SMC.
    private func fanRing(_ fans: [SensorSample.Fan]) -> some View {
        let rpm = SensorSample.mean(fans.map(\.rpm))
        let ceiling = fans.reduce(0) { $0 + $1.max }
        let fraction = ceiling > 0 ? fans.reduce(0) { $0 + $1.rpm } / ceiling : 0
        let value = rpm.map { $0 < 1 ? "arrêt" : SensorFormat.thousands(Int($0.rounded())) } ?? "—"
        // Une vitesse imposée par un logiciel (`F0Md`, le chantier 14 un
        // jour) se dit sous l'anneau : macOS ne pilote plus.
        let maxText = SensorSample.mean(fans.map(\.max)).map {
            "max \(SensorFormat.thousands(Int($0.rounded())))" + (fans.contains(where: \.forced) ? " · imposée" : "")
        }
        return ringColumn(fraction: fraction, value: value, unit: (rpm ?? 0) < 1 ? "" : "tr/min",
                          name: fans.count > 1 ? "Ventilateurs" : "Ventilateur",
                          ceiling: maxText ?? "illisibles")
            .accessibilityLabel(rpm.map { "Ventilateurs : \(SensorFormat.rpm($0)) en moyenne, \(SensorFormat.percentOfMax(fraction)) du maximum" }
                                ?? "Ventilateurs illisibles")
    }

    private func ringColumn(fraction: Double, value: String, unit: String, name: String, ceiling: String) -> some View {
        VStack(spacing: 3) {
            Ring(fraction: fraction, tint: Palette.data, lineWidth: 6) {
                VStack(spacing: -1) {
                    Text(value).font(.callout.monospacedDigit().weight(.medium)).lineLimit(1).minimumScaleFactor(0.84)
                    if !unit.isEmpty {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
            }
            .frame(width: 66, height: 66)
            Text(name).font(.caption).lineLimit(1)
            Text(ceiling).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pression thermique

    /// Le niveau que macOS publie lui-même. Seule la pastille porte la
    /// couleur : orange à « forte », rouge au-delà (règle dure n°6, le texte
    /// reste neutre).
    private func pressureRow(_ level: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: level >= 2 ? "thermometer.high" : "thermometer.low")
                .font(.callout)
                .foregroundStyle(level >= 3 ? Palette.alert : level >= 2 ? Palette.warning : Palette.muted)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("Pression thermique").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(SensorFormat.pressure(level)).font(.callout).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Listes

    @ViewBuilder
    private func temperatures(_ s: SensorSample) -> some View {
        CardCaption(text: "Températures")
        VStack(spacing: 3) {
            ForEach(rows(s), id: \.label) { row in
                InfoRow(label: row.label, value: row.value, spoken: row.spoken)
            }
        }
    }

    /// Une ligne par famille, les paires sur une seule ligne — cœurs
    /// performance · efficacité, air gauche · droite — : la carte tient dans
    /// la colonne sans pousser le panneau au-delà de l'écran. Le Wi-Fi reste
    /// dans `--probe` : il ne dit rien d'une journée de montage.
    ///
    /// Une paire se dit en entier : « cœurs performance 75 °C, efficacité
    /// 73 °C », pas « 75 point 73 » (chantier 16).
    private func rows(_ s: SensorSample) -> [(label: String, value: String, spoken: String?)] {
        func pair(_ families: [(family: String, celsius: Double, count: Int)]) -> String {
            families.map { "\(Int($0.celsius.rounded()))" }.joined(separator: " · ") + "\u{00A0}°C"
        }
        func spokenPair(_ names: [String], _ families: [(family: String, celsius: Double, count: Int)]) -> String {
            zip(names, families).map { "\($0) \(SensorFormat.celsius($1.celsius))" }.joined(separator: ", ")
        }
        var out: [(label: String, value: String, spoken: String?)] = []
        for group in SensorGroup.allCases where group != .other {
            let families = s.families(in: group)
            guard !families.isEmpty else { continue }
            if group == .cpu, families.count == 2 {
                out.append(("Cœurs, performance · efficacité", pair(families),
                            spokenPair(["Cœurs performance", "cœurs efficacité"], families)))
            } else if group == .air, families.count == 2 {
                out.append(("Flux d'air, gauche · droite", pair(families),
                            spokenPair(["Flux d'air gauche", "droite"], families)))
            } else {
                out += families.map { ($0.family, SensorFormat.celsius($0.celsius), nil) }
            }
        }
        return out
    }

    @ViewBuilder
    private func power(_ s: SensorSample) -> some View {
        if let p = s.power {
            CardCaption(text: "Puissance", trailing: "moyenne sur \(SensorFormat.number(p.seconds, digits: 1)) s")
            VStack(spacing: 3) {
                InfoRow(label: "Processeur", value: SensorFormat.watts(p.cpu))
                InfoRow(label: "Carte graphique", value: SensorFormat.watts(p.gpu))
                InfoRow(label: "Moteur neuronal", value: SensorFormat.watts(p.ane))
                InfoRow(label: "Mémoire vive", value: SensorFormat.watts(p.dram))
                if let total = s.systemPower {
                    InfoRow(label: "Machine entière", value: SensorFormat.watts(total))
                }
            }
        }
    }
}

/// Le segment de barre de menus optionnel, « CPU » sur « 62° », dessiné
/// comme les colonnes de `MenuBarLabel`. Éteint par défaut : il attend le
/// réglage du chantier 01 et la barre du chantier 09.
struct SensorBarSegment: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CPU").font(.caption2).tracking(0.3).opacity(0.72).frame(height: 11)
            Text(text).font(.caption2.monospacedDigit().weight(.semibold)).frame(height: 11)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: 22)
    }
}

/// `--snapshot x.png --capteurs` : la carte seule, hors écran, avec les
/// vraies mesures ; `--barre` en plus pour le segment de barre de menus.
@MainActor
enum SensorsSnapshot {
    static func view() -> AnyView {
        let store = SensorStore(cadence: .open)
        // Deux lectures au moins : la première pose la référence d'IOReport,
        // la seconde donne la puissance et les fréquences. Durée non fixe :
        // machine chargée, la création du lecteur a pris jusqu'à 1,3 s, et un
        // rendu à 3,6 s fixes est sorti sans puissance ni fréquences (11/10).
        let end = Date().addingTimeInterval(10)
        while Date() < end, store.sample?.power == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        if CommandLine.arguments.contains("--barre") {
            return AnyView(SensorBarSegment(text: store.sample?.menuBarText ?? "—")
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .background(Color.black)
                .scaleEffect(2, anchor: .topLeading)
                .frame(width: 120, height: 48, alignment: .topLeading))
        }
        // Le cadre du panneau autour : même marge, même fond, même largeur de
        // colonne — `outils/contraste.swift` y lit le fond de carte au même
        // endroit que sur le panneau entier.
        return AnyView(SensorsCard(store: store)
            .frame(width: PopoverView.columnWidth)
            .padding(12)
            .background(PopoverBackground()))
    }
}

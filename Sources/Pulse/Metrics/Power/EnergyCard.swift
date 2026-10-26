import SwiftUI
import AppKit

/// La carte « Énergie », façon menu Batterie d'iStat : le niveau et la santé
/// en anneaux, les détails en lignes, puis les appareils à batterie et la
/// charge de la journée.
///
/// Ce qu'elle dit qu'iStat ne dit pas : quand le chargeur ne suffit plus et
/// que la batterie complète, en plein export, sur secteur.
///
/// Chaque chiffre est dans la section ÉNERGIE de `--probe`. Teintes : celles
/// de `Palette`, mesurées ; le texte reste `.primary` ou `.secondary`.
struct EnergyCard: View {
    @ObservedObject var power: PowerSampler
    /// La carte Capteurs, quand elle mesure panneau ouvert : sa lecture du
    /// SMC (`PSTR`) devient aussi la « Consommation » d'ici. Deux lectures à
    /// des instants différents donnaient deux chiffres côte à côte pour la
    /// même grandeur — 71 W ici, 75 W « Machine entière » là (chantier 16).
    @ObservedObject var sensors: SensorStore = .shared
    /// Carte compacte (réglage du socle) : le titre et les anneaux, sans les
    /// lignes ni les listes.
    var compact = false
    /// Réglages du module (`EnergyModule.options`).
    var showsDevices = true
    var showsDay = true
    /// Teintes des séries « charge » et « santé », réglables dans les
    /// Réglages (contraste vérifié par le socle). L'orange et le rouge de
    /// batterie faible restent ceux de `Palette` : ils disent un état.
    var levelColor = Palette.data
    var healthColor = Palette.data
    /// L'historique déplié du panneau, un seul à la fois (socle) : celui de
    /// la carte s'ouvre depuis son titre, comme celui des disques.
    var open: Binding<String?> = .constant(nil)
    static let historyKey = "energie"

    /// Les symboles de la carte, vérifiés par `PowerTests`.
    nonisolated static let allSymbols = ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent",
                             "battery.100percent", "battery.100percent.bolt", "powerplug", "bolt.fill"]

    var body: some View {
        let s = power.sample
        return Card {
            if showsDay, !compact {
                HistoryToggle(key: Self.historyKey, label: "de la consommation et de la charge",
                              spoken: "Énergie", value: s.level.map(Fmt.percent) ?? "", heading: true,
                              open: open) {
                    CardTitle(title: "Énergie", symbol: Self.symbol(for: s), trailing: s.level.map(Fmt.percent),
                              open: open.wrappedValue == Self.historyKey)
                }
            } else {
                CardTitle(title: "Énergie", symbol: Self.symbol(for: s), trailing: s.level.map(Fmt.percent))
            }
            if s.hasBattery {
                rings(s)
                if !compact { VStack(spacing: 3) { rows(s) } }
            } else {
                InfoRow(label: "Alimentation", value: "secteur, sans batterie")
            }
            // Ni titre ni place pour une liste vide : la carte d'un Mac sans
            // AirPods à portée s'arrête aux lignes.
            if !compact, showsDevices, !power.accessories.isEmpty { devices }
            // Replié par défaut : déplié d'office, le graphique faisait
            // passer le panneau à 1 316 pt, au-delà des 1 290 de l'écran.
            if !compact, showsDay {
                HistoryPanel(key: Self.historyKey, open: open.wrappedValue) { history(s) }
            }
        }
    }

    // MARK: - Anneaux

    private func rings(_ s: PowerSample) -> some View {
        let health = s.health(macOS: power.health?.maximumCapacity)
        return HStack(spacing: 22) {
            Spacer(minLength: 0)
            if let level = s.level {
                Ring(fraction: level, tint: levelTint(s), lineWidth: 7) {
                    RingCenter(value: Fmt.percent(level), caption: "charge")
                }
                .frame(width: 84, height: 84)
            }
            if let health {
                Ring(fraction: health, tint: healthTint(s), lineWidth: 7) {
                    // L'orange de l'anneau, en mots : la condition d'Apple
                    // n'est plus « Good » (chantier 16, couleur jamais seule).
                    RingCenter(value: Fmt.percent(health), caption: "santé",
                               note: needsService(s) ? "à réviser" : nil)
                }
                .frame(width: 84, height: 84)
                .help(power.health?.maximumCapacity != nil
                      ? "Capacité maximale selon macOS, comme dans Réglages Système › Batterie."
                      : "Capacité nominale sur capacité d'origine, en attendant le chiffre de macOS.")
            }
            Spacer(minLength: 0)
        }
    }

    /// Bleu des données ; orange puis rouge seulement sur batterie, sous 20 %
    /// puis 10 % — les seuils du menu Batterie de macOS.
    private func levelTint(_ s: PowerSample) -> Color {
        guard s.state == .discharging, let level = s.level else { return levelColor }
        if level <= 0.10 { return Palette.alert }
        if level <= 0.20 { return Palette.warning }
        return levelColor
    }

    /// La condition d'Apple, et elle seule : « Good » reste bleu. Un seuil à
    /// moi sur la capacité contredirait les Réglages Système.
    private func healthTint(_ s: PowerSample) -> Color {
        needsService(s) ? Palette.warning : healthColor
    }

    /// La condition d'Apple n'est plus « Good » : la teinte de l'anneau et
    /// sa mention « à réviser » le disent ensemble.
    private func needsService(_ s: PowerSample) -> Bool {
        guard let condition = power.health?.condition ?? s.condition else { return false }
        return condition != "Good"
    }

    // MARK: - Lignes

    /// La lecture de la carte Capteurs, si elle tourne à la cadence ouverte ;
    /// sinon nil, et la carte garde la sienne (même capteur, `PSTR`).
    private var sharedWatts: Double? {
        guard sensors.cadence == .open else { return nil }
        return sensors.sample?.systemPower
    }

    @ViewBuilder
    private func rows(_ s: PowerSample) -> some View {
        InfoRow(label: "État", value: Self.stateText(s))
        if let watts = sharedWatts ?? s.displayedWatts {
            InfoRow(label: "Consommation", value: PowerFmt.watts(watts))
        }
        if let adapter = s.adapter {
            InfoRow(label: "Chargeur", value: Self.adapterText(adapter))
        }
        if let mode = s.activeEnergyMode {
            InfoRow(label: "Mode d'énergie", value: s.lowPowerMode && mode != .lowPower ? "économie d'énergie" : mode.label)
        }
        if let t = s.temperature {
            InfoRow(label: "Température", value: PowerFmt.celsius(t))
        }
        if let cycles = s.cycles {
            InfoRow(label: "Cycles", value: PowerFmt.count(cycles) + (s.designCycles.map { " sur \(PowerFmt.count($0))" } ?? ""))
        }
        // La pleine charge en mAh reste dans `--probe` : 6 906 sur 8 694, soit
        // 79 %, sous l'anneau qui dit 81 % — deux chiffres de santé côte à
        // côte, et le panneau grandissait d'une ligne pour un détail.
    }

    /// Décharge sur secteur à partir de laquelle la batterie « aide ».
    static let helpThreshold: Double = 5

    /// « sur batterie · reste 3 h 12 », « en charge · plein dans 45 min »,
    /// et le cas qui compte en export : sur secteur, la batterie complète.
    static func stateText(_ s: PowerSample) -> String {
        switch s.state {
        case .discharging:
            return s.minutesToEmpty.map { "sur batterie · reste \(Fmt.duration(Double($0) * 60))" } ?? "sur batterie"
        case .charging:
            return s.minutesToFull.map { "en charge · plein dans \(Fmt.duration(Double($0) * 60))" } ?? "en charge"
        case .charged, .notCharging:
            // 5 W, pas 1 : sur secteur sans charger, la batterie laisse filer
            // un filet — −89 mA (1,1 W) relevé le 11/10 à 114 W tirés d'un
            // chargeur de 140 W, qui suffisait largement.
            if let b = s.batteryWatts, b <= -Self.helpThreshold {
                return "sur secteur, la batterie aide (\(PowerFmt.watts(-b)))"
            }
            return s.state.label
        case .unknown:
            return s.state.label
        }
    }

    /// « 140 W, USB-C » : sa puissance nominale et sa prise. Ce qu'il fournit
    /// est la ligne Consommation — sur secteur, c'est le même chiffre.
    static func adapterText(_ a: PowerAdapter) -> String {
        let name = a.name ?? ""
        let plug = name.contains("MagSafe") ? "MagSafe" : name.contains("USB-C") ? "USB-C" : nil
        guard let watts = a.watts else { return plug ?? "branché" }
        return "\(watts)\u{00A0}W" + (plug.map { ", \($0)" } ?? "")
    }

    static func symbol(for s: PowerSample) -> String {
        guard s.hasBattery, let level = s.level else { return "powerplug" }
        switch s.state {
        case .charging, .charged: return "battery.100percent.bolt"
        case .notCharging: return "powerplug"
        default: break
        }
        switch level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    // MARK: - Appareils

    @ViewBuilder
    private var devices: some View {
        CardCaption(text: "Appareils")
        ForEach(power.accessories) { accessory in
            HStack(spacing: 7) {
                Image(systemName: accessory.kind.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                    .accessibilityHidden(true)
                Text(accessory.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Self.partsText(accessory)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(accessory.name) : \(PowerFmt.parts(accessory))")
        }
    }

    /// « G 80 % · D 35 % · boîtier 50 % », un éclair après ce qui charge.
    /// Gauche et droite fondues quand elles disent la même chose.
    static func partsText(_ accessory: PowerAccessory) -> Text {
        var parts = accessory.parts
        if let l = parts.first(where: { $0.role == .left }), let r = parts.first(where: { $0.role == .right }),
           Fmt.percent(l.level) == Fmt.percent(r.level), l.charging == r.charging {
            parts.removeAll { $0.role == .right }
            if let i = parts.firstIndex(where: { $0.role == .left }) { parts[i].role = .single }
        }
        var text = Text("")
        for (i, part) in parts.enumerated() {
            if i > 0 { text = text + Text(" · ") }
            let label: String
            switch part.role {
            case .left: label = "G "
            case .right: label = "D "
            case .case: label = "boîtier "
            case .single: label = ""
            }
            text = text + Text(label + Fmt.percent(part.level))
            if part.charging { text = text + Text(" ") + Text(Image(systemName: "bolt.fill")) }
        }
        return text
    }

    // MARK: - Historique

    /// L'historique de la base du chantier 02, plages 1 h → 90 j et survol
    /// comme les autres graphiques de Pulse. Sur secteur, la charge est une
    /// ligne plate : c'est la consommation qui raconte la journée, export
    /// après export. Sur batterie, la charge.
    private func history(_ s: PowerSample) -> some View {
        let charge = s.state == .discharging
        return HistoryChart(keys: [charge ? PowerSampler.chargeKey : PowerSampler.consumptionKey],
                            title: charge ? "Charge" : "Consommation",
                            range: .day, plotHeight: 34)
            // Une autre série quand la source change : un graphique neuf.
            .id(charge)
    }
}

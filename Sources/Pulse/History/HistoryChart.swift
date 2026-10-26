import SwiftUI
import AppKit

/// Le graphique d'historique réutilisable : un sélecteur de plage (1 h → 90 j),
/// des barres ou une courbe, et le survol qui dit la valeur et l'heure.
///
///     HistoryChart(keys: ["cpu.total"], title: "Processeur")
///     HistoryChart(keys: ["reseau.reception", "reseau.envoi"], title: "Débit")
///
/// L'échelle suit la règle dure n° 7 : une série qui a un dénominateur réel
/// (un pourcentage, la mémoire installée, la capacité d'un volume) se trace
/// sur ce total, en barres si l'on veut ; une série qui n'en a pas (le swap,
/// le débit) se trace en COURBE sur son maximum observé, et l'échelle le dit
/// — « max 7,2 Go » —, jamais un « plein » inventé.
///
/// Les tranches sont placées à leur HEURE, pas à leur rang : une veille, un
/// Pulse éteint laissent un trou, et un trou ne se lit pas comme un zéro.
///
/// Le chargement se fait hors du main thread (`SeriesRecorder`), puis se
/// rafraîchit tant que le graphique est à l'écran : toutes les 10 s sur 1 h,
/// chaque minute sur 24 h, toutes les 5 min au-delà. Le panneau refermé, la
/// vue disparaît et la tâche s'arrête avec elle.
struct HistoryChart: View {
    enum Style { case automatic, bars, line }

    var keys: [String]
    var title: String?
    var style: Style = .automatic
    var plotHeight: CGFloat = 64
    /// Pour `--snapshot` : une lecture déjà faite, et un survol figé.
    var preloaded: HistoryReading? = nil
    var frozenHover: Int64? = nil

    @State private var range: HistoryRange
    @State private var reading: HistoryReading?
    @State private var hover: Int64?

    init(keys: [String], title: String? = nil, range: HistoryRange = .day, style: Style = .automatic,
         plotHeight: CGFloat = 64, preloaded: HistoryReading? = nil, frozenHover: Int64? = nil) {
        self.keys = keys
        self.title = title
        self.style = style
        self.plotHeight = plotHeight
        self.preloaded = preloaded
        self.frozenHover = frozenHover
        _range = State(initialValue: preloaded?.range ?? range)
        _reading = State(initialValue: preloaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 6) {
                if let title {
                    Text(title.uppercased())
                        .font(.caption2.weight(.medium))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                // Le sélecteur ne se tronque jamais : c'est le titre qui cède.
                RangePicker(selection: $range)
                    .fixedSize()
                    .layoutPriority(1)
            }
            if let reading, reading.range == range {
                HistoryPlot(reading: reading, style: style, hover: frozenHover ?? hover, height: plotHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hover = time(at: location.x, in: reading)
                        case .ended: hover = nil
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(HistoryPlot.spoken(reading, title: title))
                    .accessibilityChartDescriptor(HistoryChartDescriptor(reading: reading, title: title))
                footer(reading)
            } else {
                // Le premier chargement : un cadre vide de la bonne hauteur,
                // pour que le panneau ne saute pas quand les barres arrivent.
                Color.clear.frame(height: plotHeight + 15)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PlotWidthKey.self, value: geometry.size.width)
        })
        .onPreferenceChange(PlotWidthKey.self) { plotWidth = $0 }
        .task(id: range) { await follow(range) }
    }

    /// La largeur du tracé, pour traduire l'abscisse du survol en heure.
    @State private var plotWidth: CGFloat = 0

    private func time(at x: CGFloat, in reading: HistoryReading) -> Int64? {
        guard plotWidth > 0 else { return nil }
        let fraction = min(1, max(0, x / plotWidth))
        return reading.from + Int64(Double(reading.to - reading.from) * fraction)
    }

    private func follow(_ range: HistoryRange) async {
        guard preloaded == nil else { return }
        while !Task.isCancelled {
            let fresh = await SeriesRecorder.shared.reading(keys: keys, range: range)
            guard !Task.isCancelled else { return }
            reading = fresh
            let pause: TimeInterval = range == .hour ? 10 : (range == .day ? 60 : 300)
            try? await Task.sleep(nanoseconds: UInt64(pause * 1e9))
        }
    }

    /// D'où part réellement la courbe, et maintenant.
    private func footer(_ reading: HistoryReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(HistoryPlot.startLabel(reading))
                Spacer(minLength: 4)
                Text("maintenant")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // Deux séries ou plus : une légende, sans quoi rien ne disait
            // quelle couleur était quoi (HIG Charts, « Descriptive content » ;
            // chantier 16). Côte à côte si elles tiennent, l'une sous l'autre
            // sinon : jamais coupées.
            if reading.lines.count > 1 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { legend(reading) }
                    VStack(alignment: .leading, spacing: 2) { legend(reading) }
                }
            }
        }
    }

    @ViewBuilder
    private func legend(_ reading: HistoryReading) -> some View {
        ForEach(Array(reading.lines.enumerated()), id: \.offset) { index, line in
            LegendDot(color: HistoryPlot.tints[index % HistoryPlot.tints.count], label: line.info.label)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct PlotWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Le sélecteur de plage, dessiné en SwiftUI : le `Picker` segmenté de macOS
/// est un contrôle AppKit, que le rendu hors écran (`--snapshot`) ne sait
/// pas dessiner.
struct RangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        HStack(spacing: 1) {
            ForEach(HistoryRange.allCases) { range in
                let selected = range == selection
                Button {
                    selection = range
                } label: {
                    Text(range.rawValue)
                        .font(.caption2.monospacedDigit().weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 5)
                        // 20 pt au moins dans les deux sens : le minimum des
                        // contrôles sur Mac (HIG Accessibility, « Mobility »).
                        // Ils faisaient 18 pt de haut (chantier 16).
                        .frame(minWidth: 20, minHeight: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? Color.primary.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pulseIcon)
                .accessibilityLabel(range.spoken)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plage")
    }
}

/// Le tracé seul : une lecture, un survol éventuel, rien d'autre. Sans état,
/// donc rendu tel quel par `--snapshot`.
struct HistoryPlot: View {
    var reading: HistoryReading
    var style: HistoryChart.Style = .automatic
    var hover: Int64?
    var height: CGFloat = 64

    /// Les teintes des séries, dans l'ordre : chacune mesurée (`Palette`).
    nonisolated static let tints: [Color] = [Palette.data, Palette.muted, Palette.tertiary]

    private var drawsBars: Bool {
        switch style {
        case .bars: return reading.bound != nil && reading.lines.count == 1
        case .line: return false
        case .automatic: return reading.bound != nil && reading.lines.count == 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Le résumé de la plage à gauche ; à droite, ce que vaut la ligne
            // du haut — le total réel, ou le maximum observé, dit comme tel.
            // Au-dessus du cadre, jamais sur une barre.
            HStack(spacing: 6) {
                // Plusieurs séries : la pastille de celle dont parlent ces
                // chiffres, la légende est sous le graphique (chantier 16).
                if reading.lines.count > 1 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.tints[0]).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(Self.summary(reading)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.scaleLabel(reading)).lineLimit(1).layoutPriority(1)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(height: 12)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: height)
            .overlay {
                if reading.isEmpty {
                    Text("rien d'enregistré sur cette plage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .topLeading) { callout }
        }
    }

    // MARK: - Dessin

    private func x(_ t: Int64, width: CGFloat) -> CGFloat {
        let span = Double(max(1, reading.to - reading.from))
        return CGFloat(Double(t - reading.from) / span) * width
    }

    private func y(_ value: Double, height: CGFloat) -> CGFloat {
        let top = reading.scaleTop
        let fraction = top > 0 ? min(1, max(0, value / top)) : 0
        return height - 1 - CGFloat(fraction) * (height - 2)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        // Le cadre : la ligne du zéro et celle du haut de l'échelle, en
        // pointillé de décor (`Palette.track`, pas une donnée).
        for lineY in [size.height - 0.5, 0.5] {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: lineY))
            path.addLine(to: CGPoint(x: size.width, y: lineY))
            context.stroke(path, with: .color(Palette.track), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
        }
        let slot = max(1, CGFloat(reading.bucket) / CGFloat(max(1, reading.to - reading.from)) * size.width)

        if drawsBars, let line = reading.lines.first {
            let width = max(1, slot * 0.7)
            for bucket in line.buckets {
                let top = y(bucket.avg, height: size.height)
                let rect = CGRect(x: x(bucket.t, width: size.width) + (slot - width) / 2,
                                  y: top, width: width, height: max(1, size.height - 1 - top))
                context.fill(Path(rect), with: .color(Self.tints[0]))
            }
        } else {
            for (index, line) in reading.lines.enumerated().reversed() {
                var path = Path()
                var previous: Int64?
                for bucket in line.buckets {
                    let point = CGPoint(x: x(bucket.t, width: size.width) + slot / 2, y: y(bucket.avg, height: size.height))
                    // Un trou de plus d'une tranche : la courbe s'interrompt.
                    if let previous, bucket.t - previous <= reading.bucket {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                        // Une tranche isolée reste visible : un point.
                        path.addEllipse(in: CGRect(x: point.x - 0.75, y: point.y - 0.75, width: 1.5, height: 1.5))
                        path.move(to: point)
                    }
                    previous = bucket.t
                }
                context.stroke(path, with: .color(Self.tints[index % Self.tints.count]),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }

        // Le survol : un filet à l'heure visée, et la tranche marquée.
        if let hover, let hit = Self.bucket(at: hover, in: reading) {
            let hx = x(hit.t, width: size.width) + slot / 2
            var rule = Path()
            rule.move(to: CGPoint(x: hx, y: 0))
            rule.addLine(to: CGPoint(x: hx, y: size.height))
            context.stroke(rule, with: .color(.primary.opacity(0.45)), lineWidth: 1)
            for (index, line) in reading.lines.enumerated() {
                guard let bucket = line.buckets.first(where: { $0.t == hit.t }) else { continue }
                let point = CGPoint(x: hx, y: y(bucket.avg, height: size.height))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                             with: .color(Self.tints[index % Self.tints.count]))
            }
        }
    }

    /// La bulle du survol : l'heure de la tranche, puis chaque valeur — et,
    /// quand la tranche en résume plusieurs, l'écart entre le plus bas et le
    /// plus haut.
    @ViewBuilder
    private var callout: some View {
        if let hover, let hit = Self.bucket(at: hover, in: reading) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let slot = max(1, CGFloat(reading.bucket) / CGFloat(max(1, reading.to - reading.from)) * width)
                let anchor = x(hit.t, width: width) + slot / 2
                // À droite du filet, ou à gauche passé le milieu : la bulle
                // ne déborde jamais du cadre, sans avoir à mesurer sa taille.
                HStack(spacing: 0) {
                    if anchor > width / 2 {
                        bubble(hit.t).frame(width: max(0, anchor - 6), alignment: .trailing)
                        Spacer(minLength: 0)
                    } else {
                        Color.clear.frame(width: anchor + 6, height: 1)
                        bubble(hit.t)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func bubble(_ t: Int64) -> some View {
        let lines = Self.calloutLines(reading, at: t)
        return VStack(alignment: .leading, spacing: 1) {
            Text(Self.timeLabel(t, reading: reading))
                .foregroundStyle(.secondary)
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index]).foregroundStyle(.primary)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color.primary.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }

    // MARK: - Mots et chiffres (partagés avec `--probe`)

    /// La tranche qui contient `t`, toutes séries confondues.
    nonisolated static func bucket(at t: Int64, in reading: HistoryReading) -> SeriesDatabase.Bucket? {
        let start = t - ((t - reading.from) % reading.bucket + reading.bucket) % reading.bucket
        for line in reading.lines {
            if let found = line.buckets.first(where: { $0.t == start }) { return found }
        }
        return nil
    }

    nonisolated static func calloutLines(_ reading: HistoryReading, at t: Int64) -> [String] {
        reading.lines.compactMap { line in
            guard let bucket = line.buckets.first(where: { $0.t == t }) else { return nil }
            let unit = line.info.unit
            var text = unit.format(bucket.avg)
            if reading.lines.count > 1 { text = "\(line.info.label) \(text)" }
            if bucket.count > 1, bucket.max - bucket.min > abs(bucket.avg) * 0.02 {
                text += "  (\(unit.format(bucket.min)) – \(unit.format(bucket.max)))"
            }
            return text
        }
    }

    nonisolated static func scaleLabel(_ reading: HistoryReading) -> String {
        guard let unit = reading.lines.first?.info.unit else { return "" }
        if let bound = reading.bound { return unit.format(bound) }
        return reading.isEmpty ? "" : "max \(unit.format(reading.observedMax))"
    }

    /// Moyenne pondérée par le nombre de relevés, et la pointe : le plus haut
    /// relevé de 10 s de la plage, pas la plus haute moyenne.
    nonisolated static func stats(_ line: HistoryReading.Line) -> (average: Double, peak: Double)? {
        let count = line.buckets.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        let sum = line.buckets.reduce(0.0) { $0 + $1.avg * Double($1.count) }
        return (sum / Double(count), line.buckets.map(\.max).max() ?? 0)
    }

    nonisolated static func summary(_ reading: HistoryReading) -> String {
        guard let line = reading.lines.first, let stats = stats(line) else { return "" }
        let unit = line.info.unit
        return "moy. \(unit.format(stats.average)) · pointe \(unit.format(stats.peak))"
    }

    nonisolated static func startLabel(_ reading: HistoryReading) -> String {
        let span = reading.to - reading.from
        if let first = reading.firstData, first - reading.from > reading.bucket * 2 {
            return "depuis " + format(first, "EEE HH:mm", "dd/MM HH:mm", span: span)
        }
        return "il y a \(reading.range.rawValue)"
    }

    /// L'heure d'une tranche, à la précision de sa largeur.
    nonisolated static func timeLabel(_ t: Int64, reading: HistoryReading) -> String {
        let end = t + reading.bucket
        switch reading.range {
        case .hour:  return Self.clock(t, "HH:mm:ss")
        case .day:   return "\(Self.clock(t, "HH:mm"))–\(Self.clock(end, "HH:mm"))"
        case .week:  return "\(Self.clock(t, "EEE HH:mm"))–\(Self.clock(end, "HH:mm"))"
        case .month, .quarter:
            return "\(Self.clock(t, "EEE dd/MM HH:mm"))–\(Self.clock(end, "HH:mm"))"
        }
    }

    nonisolated private static func format(_ t: Int64, _ short: String, _ long: String, span: Int64) -> String {
        clock(t, span > 7 * 86_400 ? long : short)
    }

    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    nonisolated private static let formatterLock = NSLock()

    nonisolated static func clock(_ t: Int64, _ pattern: String) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let formatter = formatters[pattern] ?? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = pattern
            formatters[pattern] = f
            return f
        }()
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    /// Pour VoiceOver : ce que le dessin montre, en une phrase.
    nonisolated static func spoken(_ reading: HistoryReading, title: String?) -> String {
        let name = title ?? reading.lines.first?.info.label ?? "Historique"
        guard let line = reading.lines.first, let stats = stats(line) else {
            return "\(name) sur \(reading.range.spoken) : rien d'enregistré."
        }
        let unit = line.info.unit
        var phrase = "\(name) sur \(reading.range.spoken) : moyenne \(unit.format(stats.average)), "
            + "pointe \(unit.format(stats.peak))"
        if let last = line.buckets.last { phrase += ", dernière valeur \(unit.format(last.avg))" }
        return phrase + "."
    }
}

/// Le graphique décrit à VoiceOver comme un vrai graphique : il peut le
/// parcourir et l'écouter en son (graphiques audio de macOS).
struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    var reading: HistoryReading
    var title: String?

    func makeChartDescriptor() -> AXChartDescriptor {
        let unit = reading.lines.first?.info.unit ?? .count
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Heure",
            range: Double(reading.from)...Double(max(reading.to, reading.from + 1)),
            gridlinePositions: []) { value in HistoryPlot.clock(Int64(value), "EEE dd/MM HH:mm") }
        let yAxis = AXNumericDataAxisDescriptor(
            title: reading.lines.first?.info.label ?? "Valeur",
            range: 0...max(reading.scaleTop, 1e-9),
            gridlinePositions: []) { value in unit.format(value) }
        let series = reading.lines.map { line in
            AXDataSeriesDescriptor(name: line.info.label, isContinuous: true,
                                   dataPoints: line.buckets.map { AXDataPoint(x: Double($0.t), y: $0.avg) })
        }
        return AXChartDescriptor(title: title ?? reading.lines.first?.info.label,
                                 summary: HistoryPlot.spoken(reading, title: title),
                                 xAxis: xAxis, yAxis: yAxis, additionalAxes: [], series: series)
    }
}

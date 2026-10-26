import SwiftUI
import AppKit
import PulseFanKit

/// La page Ventilateurs de la fenêtre Réglages (chantier 14) : l'état du
/// helper, son installation SUR ACCORD et sa désinstallation en un clic, les
/// trois modes, l'éditeur de courbe, les sécurités et le journal du helper.
///
/// Rien ne s'active ici sans un geste d'Isma : la page lit, elle n'écrit que
/// quand il choisit.
struct FanSettingsPage: View {
    @ObservedObject var pilot: FanPilot
    @ObservedObject var sensors: SensorStore
    @State private var helperState = FanHelperService.state
    @State private var notice: String?
    @State private var journal: [String] = []

    private var fans: [SensorSample.Fan] { sensors.sample?.fans ?? [] }
    private var ready: Bool { helperState == .installed }
    /// La version à partager n'embarque pas le helper (outils/distribue.sh) :
    /// la page n'y montre que la lecture des ventilateurs, sans modes qu'on
    /// ne pourrait jamais activer. Un helper déjà installé garde sa page,
    /// pour pouvoir le désinstaller.
    private var offersControl: Bool { FanHelperService.bundledHelper != nil || helperState == .installed }

    var body: some View {
        Form {
            Section {
                if fans.isEmpty {
                    Text("Ventilateurs en cours de lecture…").foregroundStyle(.secondary)
                }
                ForEach(fans, id: \.index) { fan in fanRow(fan) }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Ventilateurs", systemImage: "fan").font(.title3.weight(.semibold))
                    Text("Vitesse mesurée, minimum et maximum d'Apple, lus au SMC sans mot de passe.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }

            Section {
                helperRows
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Helper")
            } footer: {
                if offersControl {
                    Text(FanHelperService.explanation)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }

            if offersControl { controlSections }
        }
        .formStyle(.grouped)
        .navigationTitle("Ventilateurs")
        .task {
            // Tant que la page est sous les yeux : l'état du helper et son
            // journal toutes les 2 s. Fermée, plus rien.
            while !Task.isCancelled {
                helperState = FanHelperService.state
                journal = HelperJournal.tail(8)
                pilot.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Modes, sécurités et journal : seulement là où le helper existe.
    @ViewBuilder
    private var controlSections: some View {
        Section {
            Picker("Mode", selection: mode) {
                ForEach(FanMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!ready && pilot.settings.mode == .automatic)
            switch pilot.settings.mode {
            case .automatic:
                Text("macOS décide, comme si Pulse n'existait pas. Pulse ne lit rien de plus et ne parle pas au helper.")
                    .font(.callout).foregroundStyle(.secondary)
            case .fixed:
                fixedRows
            case .curve:
                curveRows
            }
            if let problem = pilot.report.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Mode")
        } footer: {
            Text(ready
                 ? "Toute vitesse reste entre le minimum et le maximum d'Apple, pour chaque ventilateur."
                 : "Les modes s'activent une fois le helper installé. D'ici là, macOS garde la main.")
                .foregroundStyle(.secondary)
        }

        Section("Sécurités") {
            ForEach(Self.safeguards, id: \.self) { line in
                Label(line, systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if journal.isEmpty {
                Text("Vide : le helper n'a jamais tourné.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(journal.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Journal du helper")
        } footer: {
            Text(HelperJournal.path).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Lignes

    private func fanRow(_ fan: SensorSample.Fan) -> some View {
        HStack {
            Text("Ventilateur \(fan.index + 1)")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Self.rpm(fan.rpm)) tr/min").monospacedDigit()
                Text("min \(Self.rpm(fan.min)) · max \(Self.rpm(fan.max)) · \(fan.forced ? "imposée" : "macOS")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var helperRows: some View {
        switch helperState {
        case .absent:
            HStack {
                Text("Pas installé : Pulse ne touche pas aux ventilateurs.")
                Spacer()
                Button("Installer le helper…") { install() }
            }
        case .installed:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pilot.helper.map { "Installé · actif, processus \($0.helperPID)" } ?? "Installé · au repos")
                    if let status = pilot.helper {
                        Text("\(status.writesUsed) écriture(s) du SMC sur \(FanProtocol.writeBudget) depuis le démarrage · dernier retour en automatique : \(status.fallback.phrase)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if FanHelperService.upToDate == false {
                    Button("Mettre à jour…") { install() }
                }
                Button("Désinstaller") { uninstall() }
            }
        case .unavailable(let why):
            Text(why).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var fixedRows: some View {
        let readings = fans.map { FanReading(index: $0.index, actual: $0.rpm, min: $0.min, max: $0.max, target: $0.target, manual: $0.forced) }
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: fixedLevel, in: 0...1, step: 0.05) {
                Text("Vitesse")
            } minimumValueLabel: {
                Text("min").font(.caption)
            } maximumValueLabel: {
                Text("max").font(.caption)
            }
            .disabled(!ready)
            Text("\(Int((pilot.settings.fixedLevel * 100).rounded())) % de la plage d'Apple · "
                 + FanPlan.targets(level: pilot.settings.fixedLevel, fans: readings).map { "\(Self.rpm($0))" }.joined(separator: " et ")
                 + " tr/min")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder
    private var curveRows: some View {
        Picker("Température suivie", selection: sensor) {
            ForEach(FanSensor.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .disabled(!ready)
        FanCurveEditor(curve: pilot.settings.curve,
                       current: currentPoint,
                       enabled: ready) { curve in pilot.update { $0.curve = curve } }
            .frame(height: 210)
        ForEach(Array(pilot.settings.curve.points.enumerated()), id: \.offset) { index, point in
            pointRow(index, point)
        }
        HStack {
            Button("Ajouter un point") { addPoint() }
                .disabled(!ready || pilot.settings.curve.points.count >= FanCurve.pointRange.upperBound)
            Button("Retirer le dernier") { pilot.update { $0.curve.points.removeLast() } }
                .disabled(!ready || pilot.settings.curve.points.count <= FanCurve.pointRange.lowerBound)
            Spacer()
            Button("Courbe d'origine") { pilot.update { $0.curve = .standard } }
                .disabled(!ready || pilot.settings.curve == .standard)
        }
    }

    private func pointRow(_ index: Int, _ point: FanCurve.Point) -> some View {
        HStack {
            Stepper("\(Int(point.celsius.rounded())) °C", value: Binding(
                get: { point.celsius },
                set: { value in pilot.update { $0.curve.points[index].celsius = value } }),
                in: FanCurve.celsiusRange, step: 1)
            Spacer()
            Stepper(Self.levelText(point.level), value: Binding(
                get: { point.level },
                set: { value in pilot.update { $0.curve.points[index].level = value } }),
                in: 0...1, step: 0.05)
        }
        .disabled(!ready)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Point \(index + 1)")
    }

    /// Le point de fonctionnement du moment : température suivie, niveau.
    private var currentPoint: (celsius: Double, level: Double)? {
        if let celsius = pilot.report.temperature, let level = pilot.report.level { return (celsius, level) }
        guard let sample = sensors.sample,
              let celsius = pilot.settings.sensor.pick(cpu: sample.cpuTemperature, gpu: sample.gpuTemperature)
        else { return nil }
        return (celsius, FanPlan.quantized(pilot.settings.curve.level(at: celsius)))
    }

    // MARK: Actions

    private func install() {
        let alert = NSAlert()
        alert.messageText = "Installer le helper des ventilateurs ?"
        alert.informativeText = FanHelperService.consent
        alert.addButton(withTitle: "Installer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notice = FanHelperService.install()
        helperState = FanHelperService.state
    }

    private func uninstall() {
        pilot.update { $0.mode = .automatic }
        notice = FanHelperService.uninstall()
        helperState = FanHelperService.state
    }

    private func addPoint() {
        pilot.update { settings in
            let points = settings.curve.points
            // Au milieu du plus grand écart entre deux points.
            let pairs = zip(points, points.dropFirst())
            if let widest = pairs.max(by: { ($0.1.celsius - $0.0.celsius) < ($1.1.celsius - $1.0.celsius) }) {
                settings.curve.points.append(.init((widest.0.celsius + widest.1.celsius) / 2,
                                                   (widest.0.level + widest.1.level) / 2))
            }
        }
    }

    // MARK: Liaisons

    private var mode: Binding<FanMode> {
        Binding(get: { pilot.settings.mode },
                set: { value in
                    // Hors de l'automatique, seulement si le helper est là.
                    guard value == .automatic || ready else { return }
                    pilot.update { $0.mode = value }
                })
    }

    private var fixedLevel: Binding<Double> {
        Binding(get: { pilot.settings.fixedLevel }, set: { value in pilot.update { $0.fixedLevel = value } })
    }

    private var sensor: Binding<FanSensor> {
        Binding(get: { pilot.settings.sensor }, set: { value in pilot.update { $0.sensor = value } })
    }

    // MARK: Textes

    static let safeguards = [
        "Jamais sous le minimum ni au-dessus du maximum d'Apple : le helper relit les deux au SMC à chaque consigne.",
        "Retour en automatique si Pulse quitte ou plante, si le Mac se met en veille, si la température ne se lit plus.",
        "Retour en automatique si le helper n'a plus de nouvelles de Pulse depuis 15 s (battement toutes les 5 s).",
        "Retour en automatique si macOS signale une pression thermique forte, puis 10 min sans consigne.",
        "Au démarrage et à l'arrêt du helper, tout ventilateur resté imposé est rendu à macOS.",
        "Au plus 60 écritures de consigne par démarrage du Mac, une baisse au plus par minute, la courbe par pas de 5 % : le SMC d'autres Mac refuse tout au-delà d'une centaine d'écritures.",
    ]

    static func rpm(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value))"
    }

    static func levelText(_ level: Double) -> String {
        if level <= 0.001 { return "minimum" }
        if level >= 0.999 { return "maximum" }
        return "\(Int((level * 100).rounded())) %"
    }
}

/// La courbe, à la souris : chaque point se glisse, la ligne suit. Une
/// teinte de `Palette` pour le trait et les points (règle 6 : jamais pour
/// du texte), le point du moment en `.primary`.
struct FanCurveEditor: View {
    let curve: FanCurve
    let current: (celsius: Double, level: Double)?
    let enabled: Bool
    let onChange: (FanCurve) -> Void
    @State private var dragging: Int?

    private static let range = FanCurve.celsiusRange
    private static let inset = EdgeInsets(top: 10, leading: 44, bottom: 22, trailing: 12)

    var body: some View {
        GeometryReader { geometry in
            let plot = Self.plot(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, plot: plot) }
                ForEach([30.0, 50, 70, 90, 105], id: \.self) { celsius in
                    Text("\(Int(celsius))°").font(.caption2).foregroundStyle(.secondary)
                        .position(x: Self.x(celsius, plot), y: plot.maxY + 11)
                }
                ForEach([(0.0, "min"), (0.5, "50 %"), (1.0, "max")], id: \.0) { level, label in
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                        .position(x: plot.minX - 22, y: Self.y(level, plot))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in move(drag, plot: plot) }
                .onEnded { _ in dragging = nil })
            .allowsHitTesting(enabled)
            .opacity(enabled ? 1 : 0.55)
        }
        // `.combine` et non `.ignore` : un conteneur ignoré sort en
        // AXUnknown, que VoiceOver ne lit pas (piège du README ; 16).
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Courbe des ventilateurs")
        .accessibilityValue(curve.sanitized.points
            .map { "\(Int($0.celsius.rounded())) degrés : \(FanSettingsPage.levelText($0.level))" }
            .joined(separator: ", "))
    }

    private func draw(in context: inout GraphicsContext, plot: CGRect) {
        // Quadrillage : tous les 10 °C, et les quarts de la plage.
        var grid = Path()
        for celsius in stride(from: 30.0, through: 100, by: 10) {
            grid.move(to: CGPoint(x: Self.x(celsius, plot), y: plot.minY))
            grid.addLine(to: CGPoint(x: Self.x(celsius, plot), y: plot.maxY))
        }
        for level in stride(from: 0.0, through: 1, by: 0.25) {
            grid.move(to: CGPoint(x: plot.minX, y: Self.y(level, plot)))
            grid.addLine(to: CGPoint(x: plot.maxX, y: Self.y(level, plot)))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)

        let points = curve.sanitized.points
        guard let first = points.first, let last = points.last else { return }
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: Self.y(first.level, plot)))
        for point in points { line.addLine(to: Self.point(point, plot)) }
        line.addLine(to: CGPoint(x: plot.maxX, y: Self.y(last.level, plot)))
        context.stroke(line, with: .color(Palette.data), lineWidth: 2)
        for point in points {
            let center = Self.point(point, plot)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                         with: .color(Palette.data))
        }

        if let current {
            let x = Self.x(min(max(current.celsius, Self.range.lowerBound), Self.range.upperBound), plot)
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: plot.minY))
            marker.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(marker, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let dot = CGPoint(x: x, y: Self.y(current.level, plot))
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(.primary))
        }
    }

    private func move(_ drag: DragGesture.Value, plot: CGRect) {
        var points = curve.sanitized.points
        if dragging == nil {
            let start = drag.startLocation
            let nearest = points.indices.min { a, b in
                Self.distance(Self.point(points[a], plot), start) < Self.distance(Self.point(points[b], plot), start)
            }
            guard let nearest, Self.distance(Self.point(points[nearest], plot), start) < 18 else { return }
            dragging = nearest
        }
        guard let index = dragging, points.indices.contains(index) else { return }
        // Un point reste entre ses voisins : l'ordre ne change pas en route.
        let low = index > 0 ? points[index - 1].celsius + 1 : Self.range.lowerBound
        let high = index < points.count - 1 ? points[index + 1].celsius - 1 : Self.range.upperBound
        let celsius = Self.celsius(drag.location.x, plot).rounded()
        points[index].celsius = min(max(celsius, low), max(low, high))
        points[index].level = (min(max(Self.level(drag.location.y, plot), 0), 1) * 20).rounded() / 20
        onChange(FanCurve(points: points))
    }

    // MARK: Géométrie

    private static func plot(in size: CGSize) -> CGRect {
        CGRect(x: inset.leading, y: inset.top,
               width: max(1, size.width - inset.leading - inset.trailing),
               height: max(1, size.height - inset.top - inset.bottom))
    }

    private static func x(_ celsius: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + plot.width * CGFloat((celsius - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private static func y(_ level: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - plot.height * CGFloat(level)
    }

    private static func point(_ p: FanCurve.Point, _ plot: CGRect) -> CGPoint {
        CGPoint(x: x(p.celsius, plot), y: y(p.level, plot))
    }

    private static func celsius(_ x: CGFloat, _ plot: CGRect) -> Double {
        range.lowerBound + Double((x - plot.minX) / plot.width) * (range.upperBound - range.lowerBound)
    }

    private static func level(_ y: CGFloat, _ plot: CGRect) -> Double {
        Double((plot.maxY - y) / plot.height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Le journal du helper, écrit par root dans `/Library/Logs`, lu par Pulse.
enum HelperJournal {
    static let path = "/Library/Logs/PulseHelper.log"

    /// Les dernières lignes, les plus récentes en bas ; vide si absent.
    static func tail(_ count: Int) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(count).map(String.init))
    }
}

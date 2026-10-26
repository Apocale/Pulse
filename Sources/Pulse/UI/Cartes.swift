import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Les pièces du panneau façon iStat Menus 7, relevées sur ses menus réels
// (vidéo d'Aim Apple, 11/10) : une carte par thème, un titre en petites
// capitales, le chiffre du moment, un dessin — anneau, barres, miroir —,
// puis les applications qui consomment, avec leur icône.
//
// Deux écarts volontaires avec iStat, imposés par les règles dures :
// - ses titres de section sont en couleur ; ici ils restent gris, parce qu'une
//   teinte de `Palette` ne colore jamais du texte (n° 6) ;
// - sa jauge de swap « 1,0 Go sur 2,0 Go » n'existe pas : le total du swap
//   grandit à la demande, ce ne serait pas un dénominateur réel (n° 7).

// MARK: - Carte

/// Un thème, sur un fond à peine détaché du panneau.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
    }
}

/// Le titre d'une carte : symbole, petites capitales, et le chiffre qui la
/// résume à droite.
struct CardTitle: View {
    var title: String
    var symbol: String
    var trailing: String? = nil
    /// Non nil quand la carte cache un historique : le chevron suit l'état.
    var open: Bool? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Capitales à l'écran seulement : VoiceOver lit le mot.
            Text(title)
                .textCase(.uppercase)
                .font(.caption.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }
            if let open { DisclosureChevron(open: open) }
        }
        .accessibilityElement(children: .combine)
        // Un titre de carte est un titre : VoiceOver saute de l'un à
        // l'autre (rotor « Titres »). Dans un bouton d'historique, c'est le
        // bouton qui porte le trait (`HistoryToggle(heading:)`).
        .accessibilityAddTraits(.isHeader)
    }
}

/// Un intitulé à petites capitales à l'intérieur d'une carte (« APPS »).
struct CardCaption: View {
    var text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            // Capitales à l'écran seulement : « APPS » s'épelait (chantier 16).
            Text(text).textCase(.uppercase).font(.caption2.weight(.medium)).tracking(0.5)
            Spacer()
            if let trailing { Text(trailing).font(.caption2) }
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        // Un intitulé de section, lu d'un trait, rangé parmi les titres.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Anneaux

/// Une part d'un total réel, en anneau. Le pourcentage s'écrit au centre :
/// l'anneau seul ne serait lisible qu'à l'œil.
struct Ring<Center: View>: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat
    @ViewBuilder var center: () -> Center
    /// À l'ouverture du panneau, l'arc se remplit jusqu'à sa valeur (chantier
    /// 10, `UI/Motion/Opening.swift`) ; 1 partout ailleurs.
    @Environment(\.fillProgress) private var fill

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, fraction)) * fill)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Plusieurs parts du même total, bout à bout : la mémoire utilisée, par
/// catégorie, sur la mémoire installée.
struct SegmentedRing<Center: View>: View {
    var segments: [(fraction: Double, tint: Color)]
    var lineWidth: CGFloat
    @ViewBuilder var center: () -> Center
    /// Remplissage d'ouverture : l'anneau entier se trace d'un seul geste,
    /// chaque part à sa place (chantier 10).
    @Environment(\.fillProgress) private var fill

    var body: some View {
        let segments = self.segments.map { (fraction: $0.fraction * fill, tint: $0.tint) }
        let starts = segments.indices.map { i in segments[..<i].reduce(0) { $0 + $1.fraction } }
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            ForEach(segments.indices, id: \.self) { i in
                // 0,6 % de jour entre deux parts, pour que les couleurs ne
                // se fondent pas en une seule.
                Circle()
                    .trim(from: min(1, starts[i]), to: min(1, max(starts[i], starts[i] + segments[i].fraction - 0.006)))
                    .stroke(segments[i].tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Le chiffre et son nom, au centre d'un grand anneau.
struct RingCenter: View {
    var value: String
    var caption: String
    /// L'état que la couleur de l'anneau signale (« élevée », « à réviser »),
    /// écrit en toutes lettres : la couleur ne porte jamais le sens seule
    /// (HIG Color, « Inclusive color » ; chantier 16). Nil : rien à dire.
    var note: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            // `.textCase` et non `.uppercased()` : l'écran met en capitales,
            // VoiceOver lit le mot (« APPS » s'épelait).
            Text(caption).textCase(.uppercase).font(.caption2).tracking(0.4).foregroundStyle(.secondary)
            if let note {
                Text(note).textCase(.uppercase).font(.caption2.weight(.semibold)).tracking(0.4)
                    .foregroundStyle(.primary)
            }
        }
        // Le nom d'abord, puis la valeur : « Pression, 48 % », et non
        // « 48 %, PRESSION ».
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption)
        .accessibilityValue(note.map { "\(value), \($0)" } ?? value)
    }
}

// MARK: - Barres

/// L'historique en barres, sur une échelle fixe 0–1 : le plein a un sens
/// (100 % du processeur), c'est ce qui rend deux heures comparables.
struct HistoryBars: View {
    var values: [Double]
    var tint: Color
    /// Ce que dit le survol de chaque barre (chantier 10) ; nil : pas de survol.
    var readout: BarReadout? = nil
    /// Ce que VoiceOver dit du graphique (« Processeur, il y a 1 h à
    /// maintenant ») ; il y ajoute le graphique sonore des barres, leurs
    /// valeurs mêmes (Audio Graphs). Nil : graphique muet, comme avant.
    var spoken: String? = nil

    var body: some View {
        bars.modifier(OptionalBarHover(slots: values.count, readout: readout))
            .modifier(SpokenChart(label: spoken,
                                  descriptor: spoken.map { BarsChartDescriptor(title: $0, values: values) }))
    }

    private var bars: some View {
        Canvas { context, size in
            baseline(context, size, y: size.height - 0.5)
            guard !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            let width = max(1, step * 0.64)
            var path = Path()
            for (i, value) in values.enumerated() {
                let height = max(1, CGFloat(min(1, max(0, value))) * (size.height - 1))
                path.addRect(CGRect(x: CGFloat(i) * step + (step - width) / 2,
                                    y: size.height - 1 - height, width: width, height: height))
            }
            context.fill(path, with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

/// Deux mesures liées, l'une vers le haut, l'autre vers le bas, de part et
/// d'autre d'un axe pointillé — le graphique « centré » d'iStat. Chaque côté
/// a sa propre échelle, celle de son pic : l'envoi pèse souvent cent fois
/// moins que la réception, et sur une échelle commune il disparaîtrait.
struct MirrorBars: View {
    var up: [Double]
    var down: [Double]
    var upTint: Color
    var downTint: Color
    /// Le nombre de places, fixe : les premiers relevés s'alignent à droite
    /// en barres fines, au lieu de s'étaler en deux pavés.
    var slots: Int
    /// Ce que dit le survol de chaque place (chantier 10) ; nil : pas de survol.
    var readout: BarReadout? = nil
    /// Défilement continu entre deux relevés (chantier 10,
    /// `UI/Motion/Scroll.swift`) ; nil : immobile, comme avant.
    var scroll: ScrollClock? = nil
    /// Ce que VoiceOver dit du graphique, avec les chiffres déjà écrits
    /// autour (« envoi au plus 87 ko/s ») : chaque côté a sa propre échelle,
    /// un graphique sonore les confondrait. Nil : muet, comme avant.
    var spoken: String? = nil

    var body: some View {
        // Les barres sont dessinées UNE fois par relevé ; entre deux, seul
        // leur décalage change (`visualEffect`, appliqué au rendu, sans
        // redessiner ni remettre en page) : redessinées à chaque image, elles
        // coûtaient 3,7 % d'un cœur à 12 images/s (mesuré, `--defilement`).
        let canvas = bars(0)
        let places = CGFloat(max(slots, up.count, down.count, 1))
        return Scrolling(clock: scroll) { phase in
            canvas
                .visualEffect { content, proxy in
                    content.offset(x: -CGFloat(phase) * proxy.size.width / places)
                }
                .modifier(OptionalBarHover(slots: max(slots, up.count, down.count), readout: readout, phase: phase))
        }
        .modifier(SpokenChart(label: spoken, descriptor: nil))
    }

    /// `phase` : la part de place dont les barres ont déjà glissé vers la
    /// gauche depuis le dernier relevé.
    private func bars(_ phase: Double) -> some View {
        Canvas { context, size in
            let mid = size.height / 2
            baseline(context, size, y: mid)
            let count = max(slots, up.count, down.count)
            guard count > 0 else { return }
            let step = size.width / CGFloat(count)
            let width = max(1, step * 0.64)
            // Un seul tracé par côté, rempli d'un coup : un remplissage par
            // barre coûtait 180 appels par image (chantier 10, mesuré).
            func draw(_ values: [Double], _ tint: Color, upward: Bool) {
                var path = Path()
                for (i, value) in values.enumerated() where value > 0 {
                    let height = max(1, CGFloat(min(1, value)) * (mid - 1))
                    let x = (CGFloat(i + count - values.count) - CGFloat(phase)) * step + (step - width) / 2
                    path.addRect(CGRect(x: x, y: upward ? mid - height : mid, width: width, height: height))
                }
                context.fill(path, with: .color(tint))
            }
            draw(up, upTint, upward: true)
            draw(down, downTint, upward: false)
        }
        .accessibilityHidden(true)
    }
}

/// Un graphique dit à VoiceOver : un seul élément, image, avec son libellé
/// et, s'il y en a un, son graphique sonore. HIG Charts, « Make every chart
/// in your app accessible » : les barres étaient cachées, et le survol
/// (heure et valeur) n'existait que pour la souris (chantier 16).
struct SpokenChart: ViewModifier {
    var label: String?
    var descriptor: BarsChartDescriptor?

    func body(content: Content) -> some View {
        if let label {
            // `.combine` et non `.ignore`, qui sort en AXUnknown, que
            // VoiceOver lit mal (README) ; le libellé remplace le reste.
            let element = content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isImage)
            if let descriptor {
                element.accessibilityChartDescriptor(descriptor)
            } else {
                element
            }
        } else {
            content
        }
    }
}

/// Le graphique sonore d'un historique en barres sur 0–1 : une valeur par
/// barre, de la plus ancienne à la plus récente, dites en pour cent.
struct BarsChartDescriptor: AXChartDescriptorRepresentable {
    var title: String
    var values: [Double]

    func makeChartDescriptor() -> AXChartDescriptor {
        let count = values.count
        let xAxis = AXNumericDataAxisDescriptor(title: "Barre", range: 0...Double(max(1, count - 1)),
                                                gridlinePositions: []) { "\(Int($0.rounded()) + 1) sur \(count)" }
        let yAxis = AXNumericDataAxisDescriptor(title: title, range: 0...1, gridlinePositions: []) { Fmt.percent($0) }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints:
            values.enumerated().map { AXDataPoint(x: Double($0.offset), y: min(1, max(0, $0.element))) })
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: [series])
    }
}

/// L'axe pointillé des graphiques en barres.
private func baseline(_ context: GraphicsContext, _ size: CGSize, y: CGFloat) {
    var path = Path()
    path.move(to: CGPoint(x: 0, y: y))
    path.addLine(to: CGPoint(x: size.width, y: y))
    context.stroke(path, with: .color(Palette.track), style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
}

// MARK: - Lignes

/// Étiquette à gauche, valeur à droite, pastille de légende en option.
struct InfoRow: View {
    var label: String
    var value: String
    var dot: Color? = nil
    /// Ce que VoiceOver dit à la place de « libellé, valeur », quand l'écran
    /// abrège : « 75 · 75 °C » se lirait « 75 point 75 » (chantier 16).
    var spoken: String? = nil

    var body: some View {
        let row = HStack(spacing: 7) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.primary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        if let spoken {
            row.accessibilityLabel(spoken)
        } else {
            row
        }
    }
}

/// Une application : son icône, son nom, ce qu'elle consomme.
struct AppRow: View {
    var group: ProcessGroup
    var value: String

    var body: some View {
        HStack(spacing: 7) {
            AppIcon(path: group.bundlePath)
                .frame(width: 15, height: 15)
            Text(group.bundleId.hasPrefix("exec:") ? Fmt.processName(group.name) : Fmt.appName(group.name))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// L'icône d'une application, mise en cache : `NSWorkspace` relit le bundle
/// à chaque appel, et le panneau se redessine toutes les 1,5 s.
struct AppIcon: View {
    var path: String?

    var body: some View {
        Image(nsImage: IconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .accessibilityHidden(true)
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]
    /// Un exécutable hors bundle — un service, un démon — prend l'icône
    /// générique des exécutables, comme dans le Moniteur d'activité.
    private static let generic = NSWorkspace.shared.icon(for: .unixExecutable)
    /// Une app lancée d'un dossier protégé (Téléchargements, Bureau, disque
    /// externe…) prend l'icône générique des apps : relire son bundle ferait
    /// demander à macOS l'accès au dossier (`ProtectedFolders`).
    private static let genericApp = NSWorkspace.shared.icon(for: .applicationBundle)

    static func icon(for path: String?) -> NSImage {
        guard let path else { return generic }
        if let cached = icons[path] { return cached }
        let icon = ProtectedFolders.contains(path) ? genericApp : NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

// MARK: - Raccourcis

/// La barre de raccourcis en pied de menu, comme chez iStat : les outils
/// d'Apple qui prennent le relais quand un chiffre intrigue.
struct ShortcutBar<Trailing: View>: View {
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            shortcut("Moniteur d'activité", symbol: "waveform.path.ecg",
                     url: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            shortcut("Utilitaire de disque", symbol: "internaldrive",
                     url: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
            shortcut("Réglages de stockage", symbol: "externaldrive",
                     url: URL(string: "x-apple.systempreferences:com.apple.settings.Storage"))
            shortcut("Réglages réseau", symbol: "network",
                     url: URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension"))
            Spacer()
            trailing()
        }
    }

    /// 26 pt de côté : au-dessus des 20 pt que le HIG pose en minimum sur Mac.
    private func shortcut(_ name: String, symbol: String, url: URL?) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pulseIcon)
        .help(name)
        .accessibilityLabel(name)
    }
}

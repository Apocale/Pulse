import AppKit

/// Le dessin d'un élément de barre de menus, en AppKit : une image template
/// que le système recolore selon le thème de la barre (blanc sur barre
/// sombre, noir sur barre claire, estompée sur un écran secondaire). Seule
/// l'opacité compte : l'étiquette à 72 % reste plus pâle que la valeur,
/// comme chez iStat, et le rail d'une jauge ou d'un anneau à 30 %.
///
/// Dessinée par un bloc et non par `ImageRenderer` : AppKit l'appelle à
/// l'affichage, à la densité de l'écran — rien à refaire quand la barre
/// passe sur un écran d'une autre densité —, sans monter de vue SwiftUI à
/// chaque relevé. `--snapshot --barre` dessine exactement cette image.
///
/// Grammaire unique, celle de l'élément d'avant : deux lignes de 11 pt dans
/// les 22 pt de la barre, une petite étiquette en haut, la mesure dessous.
/// Police à 10 pt, le plancher de macOS (règle dure n°5), tirée du style
/// système `caption2`.
@MainActor
enum MenuBarDrawing {
    static let height: CGFloat = 22
    static let line: CGFloat = 11
    /// Entre deux segments, comme l'élément d'avant.
    static let spacing: CGFloat = 7
    /// Entre le symbole d'alerte et le premier segment.
    static let alertGap: CGFloat = 4
    /// Mini-graphe : douze barres de 1,5 pt séparées de 0,5 pt, soit 3 et
    /// 1 pixels sur l'écran Retina — des barres nettes.
    static let barWidth: CGFloat = 1.5
    static let barGap: CGFloat = 0.5
    static var graphWidth: CGFloat { CGFloat(MenuBarHistory.length) * (barWidth + barGap) - barGap }
    static let gaugeWidth: CGFloat = 24
    static let ringDiameter: CGFloat = 10
    /// Opacités : l'étiquette et le rail.
    static let labelAlpha: CGFloat = 0.72
    static let trackAlpha: CGFloat = 0.3

    // MARK: Polices

    /// 10 pt : `caption2`, le plus petit style de macOS. Polices et attributs
    /// faits une fois : la barre se mesure à chaque relevé.
    static let labelFont = NSFont.preferredFont(forTextStyle: .caption2)
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: labelFont.pointSize, weight: .semibold)
    static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: labelFont.pointSize, weight: .regular)

    private static func attributes(_ font: NSFont, alpha: CGFloat, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha), .kern: kern]
    }
    private static let labelAttributes = attributes(labelFont, alpha: labelAlpha, kern: 0.3)
    private static let valueAttributes = attributes(valueFont, alpha: 1)
    private static let rateAttributes = attributes(rateFont, alpha: 1)

    static func labelWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: labelAttributes).width)
    }
    static func valueWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: valueAttributes).width)
    }
    static func rateWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: rateAttributes).width)
    }

    // MARK: Mise en page

    /// La largeur d'une colonne : celle de ses chaînes les plus larges, et
    /// jamais moins que ce qu'elle affiche — rien n'est jamais rogné.
    static func width(_ piece: MenuBarPiece) -> CGFloat {
        if piece.stacked {
            if piece.style == .graph { return graphWidth }
            return max(rateWidth("↑" + piece.widestValue), rateWidth(piece.label), rateWidth(piece.value))
        }
        let label = max(labelWidth(piece.widestLabel), labelWidth(piece.label))
        switch piece.style {
        case .text:  return max(label, valueWidth(piece.widestValue), valueWidth(piece.value))
        case .graph: return max(label, graphWidth)
        case .gauge: return max(label, gaugeWidth)
        case .ring:  return max(label, ringDiameter)
        }
    }

    /// Le symbole d'alerte, à la taille de la barre.
    static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// La place du symbole : celle du plus large des deux, plein ou contour.
    static let alertWidth: CGFloat = ceil(max(symbol(MenuBarComposer.alertSymbol)?.size.width ?? 13,
                                               symbol(MenuBarComposer.warningSymbol)?.size.width ?? 13,
                                               symbol(MenuBarAlert.ruleSymbol)?.size.width ?? 13))   // cloche des règles (11)

    /// Sans segment affiché, l'élément garde une icône : sans elle il n'y
    /// aurait plus rien à cliquer pour ouvrir le panneau.
    static let placeholderSymbol = "waveform.path.ecg"

    /// La taille de l'image, qui ne dépend que de la composition — styles,
    /// étiquettes, place de l'alerte —, jamais des valeurs.
    static func size(_ content: MenuBarContent) -> NSSize {
        var total: CGFloat = 0
        if content.reservesAlert { total += alertWidth + alertGap }
        let columns = content.pieces.map { width($0) }
        if !columns.isEmpty {
            total += columns.reduce(0, +) + spacing * CGFloat(columns.count - 1)
        } else {
            total += ceil(symbol(placeholderSymbol)?.size.width ?? 16)
        }
        return NSSize(width: ceil(total), height: height)
    }

    // MARK: Image

    /// L'image template de l'élément, en pixels à la densité donnée — celle
    /// de l'écran principal dans l'app, refaite quand l'écran change.
    /// Une image bitmap, comme l'élément d'avant : c'est la forme qu'on sait
    /// affichée par la barre de macOS 26.
    static func image(_ content: MenuBarContent, scale: CGFloat) -> NSImage {
        let size = size(content)
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((size.width * scale).rounded(.up)),
                                         pixelsHigh: Int((size.height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        // Origine en haut à gauche, comme une vue retournée : le texte se
        // dessine à l'endroit, les lignes se comptent de haut en bas.
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(content)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = true
        image.accessibilityDescription = content.spoken
        return image
    }

    /// Dessine dans le contexte courant, origine en haut à gauche.
    static func draw(_ content: MenuBarContent) {
        var x: CGFloat = 0
        if content.reservesAlert {
            if let alert = content.alert, let image = symbol(alert.symbol) {
                let s = image.size
                image.draw(in: NSRect(x: x + (alertWidth - s.width) / 2, y: (height - s.height) / 2,
                                      width: s.width, height: s.height))
            }
            x += alertWidth + alertGap
        }
        if content.pieces.isEmpty, let image = symbol(placeholderSymbol) {
            let s = image.size
            image.draw(in: NSRect(x: x, y: (height - s.height) / 2, width: s.width, height: s.height))
            return
        }
        for piece in content.pieces {
            let w = width(piece)
            drawPiece(piece, x: x, width: w)
            x += w + spacing
        }
    }

    private static func drawPiece(_ piece: MenuBarPiece, x: CGFloat, width: CGFloat) {
        if piece.stacked {
            guard !piece.isEmpty || piece.style == .graph else { return }
            if piece.style == .graph {
                mirror(up: piece.history, down: piece.historyDown, x: x)
            } else {
                // À droite, sur la largeur du pire cas : la flèche reste en
                // place, les chiffres s'alignent sur leur unité.
                text(piece.label, rateAttributes, x: x + width - rateWidth(piece.label), line: 0)
                text(piece.value, rateAttributes, x: x + width - rateWidth(piece.value), line: 1)
            }
            return
        }
        guard !piece.isEmpty else { return }
        text(piece.label, labelAttributes, x: x, line: 0)
        switch piece.style {
        case .text:
            text(piece.value, valueAttributes, x: x, line: 1)
        case .graph:
            bars(piece.history, x: x + width - graphWidth)
        case .gauge:
            gauge(piece.fraction ?? 0, x: x, width: width)
        case .ring:
            ring(piece.fraction ?? 0, center: CGPoint(x: x + ringDiameter / 2, y: line + line / 2))
        }
    }

    /// Une ligne de texte, centrée dans sa ligne de 11 pt.
    private static func text(_ string: String, _ attributes: [NSAttributedString.Key: Any], x: CGFloat, line index: Int) {
        guard let font = attributes[.font] as? NSFont else { return }
        let lineHeight = font.ascender - font.descender + font.leading
        let y = CGFloat(index) * line + (line - lineHeight) / 2
        (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private static func fill(_ path: NSBezierPath, alpha: CGFloat) {
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    /// Les derniers relevés en barres, les plus récents à droite, sur la
    /// ligne du bas : 9 pt pour 100 %.
    private static func bars(_ values: [Double], x: CGFloat) {
        let top = line + 1, bottom = height - 1
        let span = bottom - top
        // Le rail : la ligne de base, pour qu'un graphe à zéro se voie.
        fill(NSBezierPath(rect: NSRect(x: x, y: bottom - 0.5, width: graphWidth, height: 0.5)), alpha: trackAlpha)
        for (index, value) in values.suffix(MenuBarHistory.length).reversed().enumerated() {
            let h = max(0.5, CGFloat(value) * span)
            let bx = x + graphWidth - CGFloat(index + 1) * (barWidth + barGap) + barGap
            fill(NSBezierPath(rect: NSRect(x: bx, y: bottom - h, width: barWidth, height: h)), alpha: 1)
        }
    }

    /// Le débit en miroir, comme le graphe de la carte Réseau : l'envoi
    /// au-dessus de l'axe, la réception dessous, sur la hauteur de la barre.
    private static func mirror(up: [Double], down: [Double], x: CGFloat) {
        let axis = height / 2
        let span = axis - 1.5
        fill(NSBezierPath(rect: NSRect(x: x, y: axis - 0.25, width: graphWidth, height: 0.5)), alpha: trackAlpha)
        for (index, value) in up.suffix(MenuBarHistory.length).reversed().enumerated() {
            let h = CGFloat(min(1, max(0, value))) * span
            let bx = x + graphWidth - CGFloat(index + 1) * (barWidth + barGap) + barGap
            if h > 0.25 { fill(NSBezierPath(rect: NSRect(x: bx, y: axis - 0.5 - h, width: barWidth, height: h)), alpha: 1) }
        }
        for (index, value) in down.suffix(MenuBarHistory.length).reversed().enumerated() {
            let h = CGFloat(min(1, max(0, value))) * span
            let bx = x + graphWidth - CGFloat(index + 1) * (barWidth + barGap) + barGap
            if h > 0.25 { fill(NSBezierPath(rect: NSRect(x: bx, y: axis + 0.5, width: barWidth, height: h)), alpha: 1) }
        }
    }

    /// Une jauge horizontale sur la ligne du bas : le rail à 30 %, la part
    /// pleine.
    private static func gauge(_ fraction: Double, x: CGFloat, width: CGFloat) {
        let h: CGFloat = 4
        let y = line + (line - h) / 2
        fill(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: h), xRadius: h / 2, yRadius: h / 2),
             alpha: trackAlpha)
        let filled = width * CGFloat(min(1, max(0, fraction)))
        guard filled > 0 else { return }
        fill(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: max(filled, h), height: h), xRadius: h / 2, yRadius: h / 2),
             alpha: 1)
    }

    /// Un anneau sur la ligne du bas, à partir de midi dans le sens des
    /// aiguilles d'une montre, comme les anneaux du panneau.
    private static func ring(_ fraction: Double, center: CGPoint) {
        let lineWidth: CGFloat = 2
        let radius = (ringDiameter - lineWidth) / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.black.withAlphaComponent(trackAlpha).setStroke()
        track.stroke()
        let f = min(1, max(0, fraction))
        guard f > 0 else { return }
        // Repère retourné (origine en haut) : les angles croissent dans le
        // sens des aiguilles d'une montre ; midi est à -90°.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + 360 * CGFloat(f),
                      clockwise: false)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .butt
        NSColor.black.setStroke()
        arc.stroke()
    }
}

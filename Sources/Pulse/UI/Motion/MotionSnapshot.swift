import SwiftUI
import AppKit

/// Une animation se juge en mouvement : faute de pouvoir ouvrir le panneau sur
/// l'écran d'Isma, on la rend image par image, hors écran, sur une planche.
///
///     --snapshot x.png --ouverture             le panneau, de 0 à 300 ms
///     --snapshot x.png --carte memoire --ouverture
///
/// Chaque image est la vraie vue, avec les vraies mesures, l'horloge de la
/// cascade figée à un instant (`\.opening`). Les instants sont écrits
/// au-dessus de chaque image.
@MainActor
enum MotionSnapshot {
    /// Les instants rendus, en millisecondes.
    static let instants: [Double] = [0, 40, 80, 120, 160, 200, 240, 300]

    /// La planche : chaque instant rendu par `frame(progress)`, côte à côte,
    /// réduits à `height` points de haut s'ils sont plus grands.
    static func sheet(light: Bool, height: CGFloat? = nil, labels: [String]? = nil, values: [Double]? = nil,
                      frame: (Double) -> AnyView) -> CGImage? {
        let scale: CGFloat = 2
        var images: [CGImage] = []
        let values = values ?? instants.map { $0 / 1000 / Opening.total }
        let labels = labels ?? instants.map { "\(Int($0)) ms" }
        for value in values {
            let view = frame(value)
                .environment(\.colorScheme, light ? .light : .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            var image: CGImage?
            NSAppearance(named: light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
                image = renderer.cgImage
            }
            if let image { images.append(image) }
        }
        guard let first = images.first else { return nil }
        let ratio = height.map { min(1, $0 * scale / CGFloat(first.height)) } ?? 1
        let w = CGFloat(first.width) * ratio, h = CGFloat(first.height) * ratio
        let gap: CGFloat = 16 * scale, label: CGFloat = 22 * scale
        let width = Int(CGFloat(images.count) * w + CGFloat(images.count + 1) * gap)
        let total = Int(h + label + 2 * gap)
        guard let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(light ? CGColor(gray: 0.82, alpha: 1) : CGColor(gray: 0.32, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: total))
        for (index, image) in images.enumerated() {
            let x = gap + CGFloat(index) * (w + gap)
            context.draw(image, in: CGRect(x: x, y: gap, width: w, height: h))
            // L'instant, au-dessus de l'image.
            let text = NSAttributedString(string: labels[index], attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13 * scale, weight: .medium),
                .foregroundColor: light ? NSColor.black : NSColor.white])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: x, y: gap + h + 6 * scale)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}

extension MotionSnapshot {
    /// Ce que coûte la cascade : les images d'une ouverture à 60 Hz (18 en
    /// 300 ms, la cadence de `OpeningDriver`), l'horloge posée image par
    /// image dans l'environnement comme dans le popover, la mise en page
    /// forcée à chaque image — d'où une borne plutôt haute. Un témoin à
    /// horloge immobile retranche ce que coûtent le relevé et la mise en page.
    ///
    /// Pourquoi pas une animation chronométrée : hors écran, une animation
    /// SwiftUI tourne sans synchronisation verticale, des milliers d'images
    /// par seconde (mesuré, voir docs/chantiers/10-animations.md). On compte
    /// donc les images réelles, une par une.
    static func measureOpening(sampler: Sampler) -> String {
        let frames = Int((Opening.total * 60).rounded())
        // Comme dans le popover : une seule horloge en tête, qui ne change
        // que l'environnement. Seules les vues qui la lisent se refont.
        let clock = FrameClock()
        let host = NSHostingController(rootView: AnyView(ClockedPanel(sampler: sampler, clock: clock)))
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        host.view.display()
        // Témoin : les mêmes images, horloge immobile. L'écart est ce que la
        // cascade ajoute ; le reste est le prix d'un dessin forcé.
        func run(_ progress: (Int) -> Double) -> Double {
            let start = cpuSeconds()
            for index in 0...frames {
                clock.progress = progress(index)
                host.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date())
            }
            return cpuSeconds() - start
        }
        let still = run { _ in 1 }
        let moving = run { Double($0) / Double(frames) }
        window.contentViewController = nil
        return String(format: "cascade : %d images (300 ms à 60 Hz) : %.1f ms de processeur par ouverture, témoin immobile %.1f ms, soit %.2f ms par image ajoutée\n%@",
                      frames + 1, moving * 1000, still * 1000, (moving - still) * 1000 / Double(frames + 1),
                      checkDriver())
    }

    /// L'horloge du vrai popover, essayée hors écran sur une vue témoin :
    /// combien d'images, à quelle cadence, et la dernière bien à 1.
    static func checkDriver() -> String {
        DriverProbe.seen = []
        let host = NSHostingController(rootView: DriverProbe().modifier(OpeningDriver()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        let end = Date().addingTimeInterval(0.8)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        window.contentViewController = nil
        let seen = DriverProbe.seen
        guard let first = seen.first, let last = seen.last else { return "horloge : aucune image" }
        let moving = seen.filter { $0.value > 0 && $0.value < 1 }
        let span = (moving.last?.time ?? first.time) - (moving.first?.time ?? first.time)
        return String(format: "horloge : %d images en mouvement sur %.0f ms (%.0f images/s), dernière valeur %.3f, %d images en tout",
                      moving.count, span * 1000, span > 0 ? Double(max(0, moving.count - 1)) / span : 0,
                      last.value, seen.count)
    }

    private struct DriverProbe: View {
        @MainActor static var seen: [(time: Double, value: Double)] = []
        @Environment(\.opening) private var opening
        var body: some View {
            DriverProbe.seen.append((Date().timeIntervalSinceReferenceDate, opening))
            return Color.clear.frame(width: 40, height: 40)
        }
    }

    @MainActor final class FrameClock: ObservableObject {
        @Published var progress: Double = 0
    }

    private struct ClockedPanel: View {
        let sampler: Sampler
        @ObservedObject var clock: FrameClock
        var body: some View {
            PopoverView(sampler: sampler).environment(\.opening, clock.progress)
        }
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}

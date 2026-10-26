import SwiftUI
import AppKit

// Le défilement continu des graphiques en barres (chantier 10).
//
// Pourquoi : un relevé de débit tombe toutes les 2 s, et le graphique miroir
// sautait d'une barre à chaque fois — le panneau semblait figé entre deux
// sauts. En glissant d'une barre sur la durée d'un relevé, il dit ce qu'il
// est : un flux. La nouvelle barre entre par la droite à son arrivée.
//
// **3 images par seconde, un pixel chacune.** Une barre fait 3 pt et met
// 2 s à passer : 1,5 pt par seconde. À 3 images par seconde, chaque image
// avance d'un sixième de barre, un pixel sur cet écran : le plus petit pas
// visible, donc un glissement sans saut. À 12 images par seconde, la même
// chose coûtait 3,2 à 3,8 % d'un cœur — 2,6 ms par image, la mise à jour de
// SwiftUI et non le dessin, mesuré avec `--defilement` — pour des quarts de
// pixel que l'œil ne sépare pas. Les barres ne sont dessinées qu'une fois
// par relevé ; entre deux, seul leur décalage change (`visualEffect`).
// Une `TimelineView` périodique, et non une animation SwiftUI : sa cadence
// est la même à l'écran et hors écran, donc le banc la mesure telle
// qu'Isma la vit (une animation hors écran tourne sans frein, README).
//
// Réduire les animations : le graphique saute d'une barre par relevé, comme
// avant. Rendus et banc sans horloge : immobiles, identiques à avant.

/// L'horloge d'un graphique qui défile : l'arrivée du dernier relevé et
/// l'écart entre deux relevés.
struct ScrollClock: Equatable {
    var arrival: Date
    var period: TimeInterval

    static let rate: Double = 3

    /// Où en est le glissement, de 0 (le relevé vient d'arriver) à 1 (le
    /// suivant est dû) ; il attend à 1 un relevé en retard.
    func phase(at date: Date) -> Double {
        guard period > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(arrival) / period))
    }
}

/// `content(phase)` qui défile en continu, ou posé à 0.
struct Scrolling<Content: View>: View {
    let clock: ScrollClock?
    @ViewBuilder let content: (Double) -> Content

    var body: some View {
        if let clock, !Motion.reduceMotion {
            TimelineView(.periodic(from: clock.arrival, by: 1 / ScrollClock.rate)) { context in
                content(clock.phase(at: context.date))
            }
        } else {
            content(0)
        }
    }
}

/// `--snapshot x.png --defilement` : le miroir du débit à cinq instants d'un
/// glissement (0, ¼, ½, ¾, 1 relevé), sur des débits fabriqués, puis ce que
/// coûte son défilement, mesuré dans une fenêtre jamais affichée.
@MainActor
enum ScrollSnapshot {
    static let phases: [Double] = [0, 0.25, 0.5, 0.75, 1]

    /// Des débits qui ondulent, comme sur le relevé typique des tests.
    static func sample(_ count: Int) -> (up: [Double], down: [Double]) {
        let up = (0..<count).map { 0.35 + 0.3 * sin(Double($0) / 6) }
        let down = (0..<count).map { 0.5 + 0.35 * cos(Double($0) / 9) }
        return (up, down)
    }

    static func bars(phase: Double) -> some View {
        let (up, down) = sample(Sampler.networkTrailLength)
        return MirrorBars(up: up, down: down, upTint: Palette.data, downTint: Palette.muted,
                          slots: Sampler.networkTrailLength,
                          scroll: ScrollClock(arrival: Date().addingTimeInterval(-phase * Sampler.networkPeriod),
                                              period: Sampler.networkPeriod))
            .clipped()
            .frame(width: PopoverView.columnWidth - 20, height: 40)
            // Un repère fixe : le glissement se lit contre lui.
            .overlay(alignment: .topTrailing) {
                Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1, height: 40).offset(x: -40)
            }
            .padding(10)
            .background(Palette.card)
    }

    /// Le coût du défilement : 5 s de miroir qui défile dans une fenêtre
    /// jamais affichée — la `TimelineView` périodique y tourne à sa cadence,
    /// comme à l'écran —, contre 5 s du même miroir immobile.
    static func measure() -> String {
        func run(scrolling: Bool) -> Double {
            let (up, down) = sample(Sampler.networkTrailLength)
            let view = MirrorBars(up: up, down: down, upTint: Palette.data, downTint: Palette.muted,
                                  slots: Sampler.networkTrailLength,
                                  scroll: scrolling ? ScrollClock(arrival: Date(), period: 1000) : nil)
                .frame(width: PopoverView.columnWidth - 20, height: 40)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            let start = MotionSnapshot.cpuSeconds()
            let end = Date().addingTimeInterval(5)
            // Une minuterie à l'échéance garde une source à la boucle : sans
            // elle, le témoin immobile tournerait à vide (comme `Banc.pompe`).
            let guardTimer = Timer(fire: end, interval: 0, repeats: false) { _ in }
            RunLoop.main.add(guardTimer, forMode: .default)
            while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
            guardTimer.invalidate()
            let spent = MotionSnapshot.cpuSeconds() - start
            window.contentViewController = nil
            return spent
        }
        let still = run(scrolling: false)
        let moving = run(scrolling: true)
        return String(format: "défilement : %.1f ms de processeur en 5 s contre %.1f ms immobile, soit %.3f %% d'un cœur ajouté panneau ouvert (%.0f images/s)",
                      moving * 1000, still * 1000, (moving - still) / 5 * 100, ScrollClock.rate)
    }
}

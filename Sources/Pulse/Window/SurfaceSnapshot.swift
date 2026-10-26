import SwiftUI
import AppKit
import Darwin

/// Rendus hors écran des surfaces du chantier 13 — rien ne s'ouvre :
///
///     --snapshot x.png --fenetre                 le panneau détaché
///     --snapshot x.png --tableau [--largeur L] [--hauteur H]
///     --snapshot x.png --widget disque|memoire|forfait [--taille petit|moyen]
///
/// Les fenêtres sont les vraies (`FloatingWindow.makePanel`,
/// `DashboardWindow.makeWindow`), jamais posées à l'écran : dessinées par
/// `cacheDisplay`, cadre et barre de titre compris, comme AppKit les dessine.
/// `--light` pour le clair. Rien n'est écrit (`Persistence` coupée).
@MainActor
enum SurfaceSnapshot {
    /// Vrai si l'une des options était demandée — le rendu est alors fait.
    static func run(to path: String, sampler: Sampler, light: Bool) -> Bool {
        let args = CommandLine.arguments
        if args.contains("--fenetre") {
            let panel = FloatingWindow.shared.makePanel(sampler: sampler, persist: false)
            render(panel, to: path, light: light, settle: 1.5)
            return true
        }
        if args.contains("--tableau") {
            let width = Snapshot.value(after: "--largeur").flatMap(Double.init) ?? DashboardWindow.defaultSize.width
            let height = Snapshot.value(after: "--hauteur").flatMap(Double.init) ?? DashboardWindow.defaultSize.height
            let window = DashboardWindow.shared.makeWindow(sampler: sampler, persist: false,
                                                           size: NSSize(width: width, height: height))
            // Les graphes lisent l'historique sur leur propre file : on leur
            // laisse le temps d'arriver.
            render(window, to: path, light: light, settle: 3)
            return true
        }
        if let kind = Snapshot.value(after: "--widget") {
            WidgetSnapshot.run(kind, to: path, sampler: sampler, light: light)
            return true
        }
        return false
    }

    /// La fenêtre entière, hors écran.
    static func render(_ window: NSWindow, to path: String, light: Bool, settle: TimeInterval) {
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let end = Date().addingTimeInterval(settle)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Le cadre de la fenêtre (barre de titre, bouton de fermeture) est le
        // parent de la vue de contenu.
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            fail("rendu impossible")
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { fail("écriture impossible") }
        let size = window.frame.size
        print("→ \(path) · fenêtre \(Int(size.width)) × \(Int(size.height)) pt · à l'écran : \(onScreenWindows())")
    }

    /// Les fenêtres de ce processus effectivement affichées : doit valoir 0.
    static func onScreenWindows() -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return -1 }
        let pid = Int(getpid())
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.count
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}

/// `--banc <s> --fenetre` ou `--banc <s> --tableau` : ce que coûte la
/// surface, mesuré comme `--banc` mesure le panneau — le vrai `Sampler`,
/// écriture coupée, rien à l'écran. Trois phases : fermée, ouverte (la vraie
/// fenêtre, jamais posée à l'écran, cadence ouverte), refermée (contenu
/// vidé). La phase « refermée » doit retomber au niveau de « fermée ».
@MainActor
enum SurfacesBanc {
    static func runIfAsked(seconds: Double) -> Bool {
        let args = CommandLine.arguments
        // `--reglages [page]` : la fenêtre Réglages cachée (19-suivis).
        if args.contains("--reglages") { SettingsBanc.run(seconds: seconds); return true }
        guard args.contains("--fenetre") || args.contains("--tableau") else { return false }
        run(seconds: seconds, dashboard: args.contains("--tableau"))
        return true
    }

    struct Phase {
        var name: String
        var start: Banc.Compteurs
        var end: Banc.Compteurs
        var duration: Double { end.horloge - start.horloge }
        var core: Double { duration > 0 ? (end.cpu - start.cpu) / duration : 0 }
        var wakeups: Double { duration > 0 ? Double(end.reveils &- start.reveils) / duration : 0 }
    }

    static func run(seconds: Double, dashboard: Bool) {
        Persistence.enabled = false
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sampler = Sampler()
        AppDelegate.panelDidChange(open: false, sampler: sampler)
        pump(5)
        let span = max(10, ((seconds - 5) / 3 / 10).rounded() * 10)

        func measure(_ name: String, _ work: () -> Void) -> Phase {
            let start = Banc.Compteurs.lire()
            work()
            return Phase(name: name, start: start, end: Banc.Compteurs.lire())
        }

        let closed = measure("fermée") { pump(span) }
        var shown = -1
        var size = CGSize.zero
        let open = measure("ouverte") {
            AppDelegate.panelDidChange(open: true, sampler: sampler)
            let window: NSWindow = dashboard
                ? DashboardWindow.shared.makeWindow(sampler: sampler, persist: false)
                : FloatingWindow.shared.makePanel(sampler: sampler, persist: false)
            window.contentView?.layoutSubtreeIfNeeded()
            pump(span / 2)
            size = window.frame.size
            shown = SurfaceSnapshot.onScreenWindows()
            pump(span / 2)
            AppDelegate.panelDidChange(open: false, sampler: sampler)
            (window.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(EmptyView())
            window.contentViewController = nil
        }
        pump(2.5)
        let reclosed = measure("refermée") { pump(span) }

        // L'état des widgets, fabriqué et encodé comme chaque minute dans
        // l'app (l'écriture elle-même est coupée ici) : son coût, à part.
        let t0 = Banc.Compteurs.lire()
        var bytes = 0
        for _ in 0..<200 { bytes = (try? EtatBuilder.build(sampler).encoded().count) ?? 0 }
        let perState = (Banc.Compteurs.lire().cpu - t0.cpu) / 200

        let label = dashboard ? "tableau de bord" : "panneau détaché"
        print("BANC · \(label) · vrai Sampler, écriture coupée, rien à l'écran")
        for phase in [closed, open, reclosed] {
            print("  \(phase.name.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + "\(Int(phase.duration.rounded())) s   "
                  + String(format: "%.2f %% d'un cœur   %.1f réveils/s   %@", phase.core * 100, phase.wakeups,
                           Fmt.memory(phase.end.empreinte)).replacingOccurrences(of: ".", with: ","))
        }
        print("  fenêtre \(Int(size.width)) × \(Int(size.height)) pt · fenêtres à l'écran pendant la mesure : \(shown)")
        print(String(format: "  état des widgets : %.2f ms de CPU et %d octets par écriture, une par minute au plus — %.4f %% d'un cœur",
                     perState * 1000, bytes, perState / SharedStateWriter.interval * 100).replacingOccurrences(of: ".", with: ","))
        print(String(format: "mesure ferme=%.5f ouvert=%.5f referme=%.5f fenetres=%d",
                     closed.core, open.core, reclosed.core, shown))
    }

    /// La boucle principale d'un seul tenant jusqu'à l'échéance, comme
    /// `Banc` : des tranches courtes réveilleraient le processus.
    private static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        let keep = Timer(fire: end, interval: 0, repeats: false) { _ in }
        RunLoop.main.add(keep, forMode: .default)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
        keep.invalidate()
    }
}

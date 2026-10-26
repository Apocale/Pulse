import SwiftUI
import AppKit

/// `--banc <s> --reglages [page]` : ce que coûte la fenêtre Réglages ouverte
/// mais cachée (derrière Premiere en plein écran, réduite, sur un autre
/// espace), mesuré comme `--banc --fenetre` — le vrai `Sampler`, écriture
/// coupée, la vraie fenêtre jamais posée à l'écran.
///
/// Cinq phases de même durée : fermée ; « visible », la fenêtre sous les
/// yeux d'Isma (cadence ouverte, contenu vivant, au premier plan) ; « avant »,
/// la même fenêtre cachée, l'app en arrière-plan — ce que faisait l'app
/// avant le 19, qui ne savait pas qu'elle était cachée ; « cachée », la règle
/// d'aujourd'hui lue sur la fenêtre elle-même (jamais à l'écran, donc
/// recouverte) ; refermée. « cachée » doit retomber au niveau de « fermée ».
@MainActor
enum SettingsBanc {
    static func run(seconds: Double) {
        Persistence.enabled = false
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Hors écran, une animation tournerait sans frein (`Motion.sansAnimation`).
        Motion.sansAnimation = true
        let sampler = Sampler()
        let cadence = SettingsStore.shared.settings.refresh.sanitized
        sampler.setIntervals(open: cadence.openInterval, closed: cadence.closedInterval)
        AppDelegate.panelDidChange(open: false, sampler: sampler)
        let settings = SettingsWindow.shared
        settings.sampler = sampler
        settings.visibilityDidChange = { visible in
            AppDelegate.panelDidChange(open: visible, sampler: sampler)
        }
        let page: SettingsPage = Snapshot.value(after: "--reglages").map {
            $0 == "general" ? .general : $0 == "barre" ? .menuBar : $0 == "regles" ? .regles
                : $0 == "ventilateurs" ? .fans : .module($0)
        } ?? .general
        // Cachée, la fenêtre tient des heures : c'est le régime établi qui
        // compte, la bascule (contenu vidé, modules ralentis) reste hors des
        // fenêtres de mesure, 3 s avant chacune. Des phases de 120 s portent
        // chacune la tâche de 2 min et les deux de 1 min du relevé (disques,
        // incidents, prévision) : elles se comparent entre elles.
        pump(5)
        let span = max(10, ((seconds - 5 - 3 * 3 - 2.5) / 5 / 10).rounded() * 10)

        func measure(_ name: String, _ work: () -> Void) -> SurfacesBanc.Phase {
            let start = Banc.Compteurs.lire()
            work()
            return SurfacesBanc.Phase(name: name, start: start, end: Banc.Compteurs.lire())
        }

        // Hors de vue, l'app tourne sur les cœurs d'efficacité, comme
        // panneau fermé (README, « Un banc lancé d'un terminal ne tourne pas
        // sur les mêmes cœurs que l'app ») ; sous les yeux d'Isma, au premier
        // plan.
        Banc.surCoeursEfficaces(true)
        let closed = measure("fermée") { pump(span) }
        var shown = 0
        Banc.surCoeursEfficaces(false)
        let window = settings.makeWindow(sampler: sampler, page: page)
        window.contentView?.layoutSubtreeIfNeeded()
        // Ce que fait `show` après `makeKeyAndOrderFront` : la fenêtre
        // annoncée sous les yeux d'Isma, cadence ouverte.
        settings.announce(true)
        pump(3)
        let visible = measure("visible") {
            pump(span / 2)
            shown = max(shown, SurfaceSnapshot.onScreenWindows())
            pump(span / 2)
        }
        let liveBefore = settings.isLive
        // Avant le 19 : cachée, l'app passe en arrière-plan, mais la fenêtre
        // reste comptée sous les yeux d'Isma — cadence ouverte, contenu vivant.
        Banc.surCoeursEfficaces(true)
        pump(3)
        let before = measure("avant") {
            pump(span / 2)
            shown = max(shown, SurfaceSnapshot.onScreenWindows())
            pump(span / 2)
        }
        // Aujourd'hui : la fenêtre relit sa visibilité.
        settings.visibilityChanged()
        pump(3)
        let hidden = measure("cachée") {
            pump(span / 2)
            shown = max(shown, SurfaceSnapshot.onScreenWindows())
            pump(span / 2)
        }
        let liveHidden = settings.isLive
        let seenHidden = settings.isSeen
        settings.close()
        pump(2.5)
        let reclosed = measure("refermée") { pump(span) }

        print("BANC · fenêtre Réglages (page \(Snapshot.value(after: "--reglages") ?? "general")) · vrai Sampler, écriture coupée, rien à l'écran")
        for phase in [closed, visible, before, hidden, reclosed] {
            print("  \(phase.name.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + "\(Int(phase.duration.rounded())) s   "
                  + String(format: "%.2f %% d'un cœur   %.1f réveils/s   %@", phase.core * 100, phase.wakeups,
                           Fmt.memory(phase.end.empreinte)).replacingOccurrences(of: ".", with: ","))
        }
        print("  contenu : \(liveBefore ? "vivant" : "vidé") visible, \(liveHidden ? "vivant" : "vidé") cachée · "
              + "cachée comptée \(seenHidden ? "sous les yeux" : "hors de vue") · fenêtres à l'écran : \(shown)")
        print(String(format: "mesure ferme=%.5f visible=%.5f avant=%.5f cachee=%.5f referme=%.5f fenetres=%d",
                     closed.core, visible.core, before.core, hidden.core, reclosed.core, shown))
        withExtendedLifetime(window) {}
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

import SwiftUI
import AppKit

/// `Pulse --ajuste [dossier]` : le panneau tient-il dans l'écran d'Isma ?
///
/// Le cas de la coordination (11/10), sur le relevé figé du banc
/// (`Releve.typique`, forfait iPhone réglé à 20 Go) : les sept cartes par
/// défaut, puis les mêmes avec la carte Médias, en sombre et en clair. Pour
/// chacun, la taille du panneau sans ajustement et sur l'écran du 16 pouces
/// (zone visible 2 056 × 1 290 pt, Dock masqué), imprimées ; échoue si le
/// panneau ajusté dépasse en hauteur OU en largeur. Rendus dans le dossier
/// (`.build/ajuste` par défaut). Rien ne s'ouvre, rien ne s'écrit.
@MainActor
enum PanelFitCheck {
    /// La zone visible de l'écran d'Isma (`NSScreen.visibleFrame`, relevée
    /// le 11/10) : 2 056 × 1 329 pt moins la barre de menus de 39 pt.
    static let ismaScreen = (width: CGFloat(2056), height: CGFloat(1290))

    static func run(directory: String) {
        Persistence.enabled = false
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let releve = Releve.typique
        let sampler = releve.sampler()
        let limits = PanelLimits.screenSized(width: ismaScreen.width, height: ismaScreen.height)
        print("écran d'Isma : zone visible \(Int(ismaScreen.width)) × \(Int(ismaScreen.height)) pt, "
              + "place pour le panneau \(Int(limits.width)) × \(Int(limits.height)) pt")

        var failures = 0
        for (name, extra) in [("sept-cartes", [String]()), ("plus-medias", ["medias"])] {
            let store = Rendu.reglagesFiges(releve.reglages)
            for id in extra { store.settings.modules[id] = ModuleSettings(enabled: true) }
            let shown = Layout.columns(store.settings).flatMap { $0 }
            for dark in [true, false] {
                let look = dark ? "sombre" : "clair"
                let free = Rendu.image(PopoverView(sampler: sampler, store: store), sombre: dark)
                let fitted = Rendu.image(PopoverView(sampler: sampler, store: store, limits: limits), sombre: dark)
                guard let free, let fitted else {
                    print("ÉCHEC   \(name) \(look) : rendu impossible")
                    failures += 1
                    continue
                }
                // Rendus à l'échelle 2 : deux pixels par point.
                let w = CGFloat(fitted.width) / 2, h = CGFloat(fitted.height) / 2
                let fits = h <= limits.height && w <= limits.width
                if !fits { failures += 1 }
                let file = folder.appendingPathComponent("\(name)-\(look).png")
                try? Pixels(fitted)?.png()?.write(to: file)
                print("\(fits ? "ok    " : "ÉCHEC ")  \(name) \(look) (\(shown.count) cartes) : sans ajustement "
                      + "\(free.width / 2) × \(free.height / 2) pt → ajusté \(Int(w)) × \(Int(h)) pt"
                      + (fits ? "" : " — dépasse \(Int(limits.width)) × \(Int(limits.height))")
                      + " → \(file.path)")

                // Le panneau détaché (chantier 13) : même mise en page, sous
                // sa barre de titre ; la fenêtre entière tient dans l'écran.
                let windowLimits = PanelLimits.windowSized(width: ismaScreen.width, height: ismaScreen.height)
                let floating = FloatingContent(sampler: sampler, limits: windowLimits, store: store,
                                               onTop: true, setOnTop: { _ in })
                guard let window = Rendu.image(floating, sombre: dark) else {
                    print("ÉCHEC   \(name) \(look), fenêtre : rendu impossible")
                    failures += 1
                    continue
                }
                let ww = CGFloat(window.width) / 2, wh = CGFloat(window.height) / 2
                let windowFits = wh <= ismaScreen.height && ww <= ismaScreen.width
                if !windowFits { failures += 1 }
                let windowFile = folder.appendingPathComponent("\(name)-fenetre-\(look).png")
                try? Pixels(window)?.png()?.write(to: windowFile)
                print("\(windowFits ? "ok    " : "ÉCHEC ")  \(name) \(look), panneau détaché : fenêtre \(Int(ww)) × \(Int(wh)) pt"
                      + (windowFits ? "" : " — dépasse \(Int(ismaScreen.width)) × \(Int(ismaScreen.height))")
                      + " → \(windowFile.path)")
            }
        }
        print("mesure ajustements=8 depassements=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

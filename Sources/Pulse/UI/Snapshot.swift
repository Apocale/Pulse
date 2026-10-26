import SwiftUI
import AppKit

/// `--snapshot <fichier.png>` : le panneau entier rendu hors écran, avec les
/// vraies mesures du moment, puis sortie. `--light` pour l'apparence claire,
/// `--reseau` pour le seul dépliant internet.
///
/// `--show` ouvre le popover sur l'écran de l'utilisateur, souvent en plein
/// montage. Ceci ne montre rien : ImageRenderer dessine dans un fichier.
///
/// Un vrai `Sampler` tourne quelques secondes — le processeur exige deux
/// relevés, le débit deux relevés espacés de 2 s —, l'écriture sur disque
/// COUPÉE (`Persistence`) : l'app en cours garde seule la main sur
/// l'historique, le journal et le cumul réseau.
@MainActor
enum Snapshot {
    static func run(to path: String) {
        Persistence.enabled = false
        overrideSettings()
        var light = CommandLine.arguments.contains("--light")
        // `--theme <id>` (chantier 10) : un thème essayé sans rien écrire ;
        // un thème sombre (ou clair) impose son apparence.
        if let id = value(after: "--theme"), let theme = PulseTheme(rawValue: id) {
            Theme.current = theme
            if let forced = theme.appearance { light = forced == .aqua }
        }

        let view: AnyView
        if CommandLine.arguments.contains("--reseau") {
            view = AnyView(networkOnly())
        } else if CommandLine.arguments.contains("--capteurs") {
            view = SensorsSnapshot.view()   // carte Capteurs seule (chantier 04)
        } else if CommandLine.arguments.contains("--historique") {
            view = AnyView(HistoryGallery.view())   // le composant d'historique (History/)
        } else if CommandLine.arguments.contains("--conseils") {
            view = AdviceSnapshot.view()   // chaque sorte de conseil du verdict (chantier 12)
        } else {
            let sampler = Sampler()
            sampler.mediaTracker.warmUp()
            pump(seconds: 3)
            sampler.setPopoverOpen(true)
            // Comme à l'ouverture du popover : les modules qui mesurent
            // eux-mêmes (énergie, capteurs…) passent à leur cadence ouverte.
            ModuleRegistry.panelDidChange(open: true, settings: SettingsStore.shared.settings)
            pump(seconds: 3)
            if CommandLine.arguments.contains("--barre") {
                // La barre de menus : la réglée, puis chaque style (chantier 09).
                view = MenuBarSnapshot.view(sampler)
            } else if SurfaceSnapshot.run(to: path, sampler: sampler, light: light) {
                return   // --fenetre, --tableau, --widget : chantier 13
            } else if CommandLine.arguments.contains("--reglages") {
                // La fenêtre Réglages, hors écran (chantier 01).
                SettingsSnapshot.run(to: path, sampler: sampler, light: light)
                return
            } else if CommandLine.arguments.contains("--defilement") {
                // Le défilement du miroir, à cinq instants (chantier 10).
                let sheet = MotionSnapshot.sheet(light: light, labels: ScrollSnapshot.phases.map { "\(Int($0 * 100)) %" },
                                                 values: ScrollSnapshot.phases) { phase in
                    AnyView(ScrollSnapshot.bars(phase: phase))
                }
                write(sheet, to: path)
                print(ScrollSnapshot.measure())
                return
            } else if CommandLine.arguments.contains("--ouverture") {
                // La cascade d'ouverture image par image (chantier 10).
                let id = value(after: "--carte")
                let sheet = MotionSnapshot.sheet(light: light, height: id == nil ? 520 : nil) { progress in
                    if let id, let card = card(id, sampler: sampler, opening: progress) { return card }
                    return AnyView(PopoverView(sampler: sampler, frozenOpening: progress))
                }
                write(sheet, to: path)
                if id == nil { print(MotionSnapshot.measureOpening(sampler: sampler)) }
                return
            } else if let id = value(after: "--carte") {
                guard let only = card(id, sampler: sampler) else {
                    FileHandle.standardError.write(Data("carte inconnue : \(id) — connues : \(ModuleRegistry.ids.joined(separator: ", "))\n".utf8))
                    exit(1)
                }
                view = only
            } else if CommandLine.arguments.contains("--verre") {
                // Chantier 10 : le panneau tel que le popover le pose sur son
                // cadre de verre, devant un fond criard — tout ce qui laisse
                // voir le fond est du verre. Aucune donnée ne doit y être.
                view = AnyView(PopoverView(sampler: sampler, glassFrame: true)
                    .background(GlassWitness()))
            } else {
                // `--ouvert <clé>` : un historique déplié, comme dans le popover.
                PopoverView.lastOpen = value(after: "--ouvert")
                // Comme l'app : le panneau tient dans l'écran principal, ou
                // dans celui de `--ecran 2056x1290` (zone visible, en points).
                view = AnyView(PopoverView(sampler: sampler, limits: screenLimits()))
            }
        }
        let content = view.environment(\.colorScheme, light ? .light : .dark)
            .environment(\.forcedHover, CommandLine.arguments.contains("--survol"))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var png: Data?
        // Les couleurs AppKit (fond, libellés) se résolvent sur l'apparence
        // de dessin courante, pas sur l'environnement SwiftUI.
        NSAppearance(named: light ? .aqua : .darkAqua)?.performAsCurrentDrawingAppearance {
            if let image = renderer.cgImage {
                png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let png, (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            FileHandle.standardError.write(Data("rendu impossible\n".utf8))
            exit(1)
        }
        print("→ \(path)")
    }

    /// `--carte <id>` : une carte seule, à la largeur d'une colonne, sur le
    /// fond du panneau, avec les réglages d'Isma. `--ouvert <clé>` la rend
    /// avec un historique déplié (« volumes », « reseau », « session »…).
    private static func card(_ id: String, sampler: Sampler, opening: Double? = nil) -> AnyView? {
        guard let module = ModuleRegistry.module(id) else { return nil }
        let settings = SettingsStore.shared.settings
        let context = CardContext(module: module, sampler: sampler, open: .constant(value(after: "--ouvert")),
                                  settings: settings.module(id), display: settings.display)
        return AnyView(module.card(context)
            .entrance(rank: 1)
            .frame(width: PopoverView.columnWidth)
            .padding(12)
            .background(PopoverBackground())
            .environment(\.opening, opening ?? 1))
    }

    /// Une image déjà rendue, en PNG.
    static func write(_ image: CGImage?, to path: String) {
        guard let image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            FileHandle.standardError.write(Data("rendu impossible\n".utf8))
            exit(1)
        }
        print("→ \(path)")
    }

    /// Réglages essayés sans les écrire (`--snapshot` n'écrit jamais
    /// `reglages.json`) : `--colonnes 1|2|3`, `--compact` (toutes les cartes),
    /// `--apps <n>`, `--bits` (débit en bits), `--masque <id>`.
    private static func overrideSettings() {
        let store = SettingsStore.shared
        var settings = store.settings
        if let count = value(after: "--colonnes").flatMap(Int.init) { Layout.setColumns(count, in: &settings) }
        for module in ModuleRegistry.all {
            if CommandLine.arguments.contains("--compact") { settings.modules[module.id, default: ModuleSettings()].compact = true }
            if let apps = value(after: "--apps").flatMap(Int.init) { settings.modules[module.id, default: ModuleSettings()].appCount = apps }
        }
        if CommandLine.arguments.contains("--bits") { settings.display.rateUnit = .bits }
        if let hidden = value(after: "--masque") { settings.modules[hidden, default: ModuleSettings()].enabled = false }
        store.settings = settings
    }

    /// `--ecran <largeur>x<hauteur>` : la zone visible d'un écran, en points
    /// (`2056x1290` sur le 16 pouces d'Isma) ; sinon l'écran principal.
    static func screenLimits() -> PanelLimits? {
        PanelLimits.visibleArea().map { .screenSized(width: $0.width, height: $0.height) }
    }

    /// La valeur qui suit une option (« --carte memoire »).
    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count,
              !args[index + 1].hasPrefix("--") else { return nil }
        return args[index + 1]
    }

    /// Fait tourner la boucle principale : c'est sur elle que le `Sampler`
    /// publie ses relevés.
    private static func pump(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Le dépliant internet seul, avec une zone vide AU-DESSUS : dans le
    /// popover ce sont les lignes de mesure qui l'occupent, et un graphique
    /// qui déborde de son cadre y peint — c'est ainsi qu'a été reproduit le
    /// défaut du 09/10, où la colonne de jeudi recouvrait les volumes.
    private static func networkOnly() -> some View {
        let live = NetworkMonitor.measure()?.sample ?? NetworkSample()
        return VStack(spacing: 0) {
            Color.clear.frame(height: 160)
            DetailPanel(legende: Legendes.all["reseau"] ?? "", detail: nil) {
                NetworkChart(now: live, history: NetworkTracker().history(days: 7))
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(PopoverBackground())
    }
}

import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement

@main
struct Entry {
    /// NSApplication ne retient pas son delegate : sans cette référence,
    /// il serait libéré dès la sortie de main().
    @MainActor private static var delegate: AppDelegate?

    static func main() {
        // Mode diagnostic : relevé texte de tous les capteurs, puis sortie.
        if CommandLine.arguments.contains("--probe") {
            // Relevé continu pendant un export depuis Premiere (chantier 08).
            if CommandLine.arguments.contains("--suivi-export") { ExportWatch.run(); return }
            Probe.run()
            return
        }
        // Banc d'essai : ce que coûte Pulse, mesuré sans rien ouvrir ni écrire.
        if let index = CommandLine.arguments.firstIndex(of: "--banc") {
            let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Double.init) ?? 60
            // `--fenetre` ou `--tableau` : le coût d'une surface du chantier 13.
            MainActor.assumeIsolated {
                if !SurfacesBanc.runIfAsked(seconds: seconds) {
                    Banc.run(seconds: seconds, ecrit: CommandLine.arguments.contains("--ecrit"))
                }
            }
            return
        }
        // Le panneau tient-il dans l'écran d'Isma ? Relevé figé, rendus et tailles.
        if let index = CommandLine.arguments.firstIndex(of: "--ajuste") {
            let folder = CommandLine.arguments.dropFirst(index + 1).first(where: { !$0.hasPrefix("--") }) ?? ".build/ajuste"
            MainActor.assumeIsolated { PanelFitCheck.run(directory: folder) }
            return
        }
        // Cartes figées comparées à Tests/References ; --references les régénère.
        if CommandLine.arguments.contains("--rendus") {
            MainActor.assumeIsolated { Rendu.run(regenerer: CommandLine.arguments.contains("--references")) }
            return
        }
        // Rendu hors écran du dépliant internet dans un PNG : rien ne s'ouvre.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let path = CommandLine.arguments.dropFirst(index + 1)
                .first(where: { !$0.hasPrefix("--") }) ?? "reseau.png"
            MainActor.assumeIsolated { Snapshot.run(to: path) }
            return
        }
        // Une seconde instance s'arrête AVANT de créer son AppDelegate : le
        // Sampler qu'il porte ouvre la base et relève dès sa création, et sa
        // sortie réécrivait history.json et reseau.json avec la copie lue au
        // lancement, et marquait le journal des verdicts (17-audit-code).
        // La vérification de `applicationDidFinishLaunching` reste en renfort.
        // main() s'exécute sur le main thread : l'hypothèse d'isolation est vraie.
        MainActor.assumeIsolated {
            let mine = ProcessInfo.processInfo.processIdentifier
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.isma.pulse")
                .contains(where: { $0.processIdentifier != mine }) else { return }
            let app = NSApplication.shared
            let created = AppDelegate()
            delegate = created
            app.delegate = created
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

/// L'item de barre de menus est construit en AppKit plutôt qu'avec
/// MenuBarExtra : sur cette machine la scène SwiftUI se construit sans jamais
/// produire d'item visible. NSStatusItem donne en prime un contrôle direct
/// sur l'ouverture du popover, ce dont dépend la cadence d'échantillonnage.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let sampler = Sampler()
    /// Les éléments de barre de menus (chantier 09, `MenuBar/`).
    private var menuBar: MenuBarController?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var anchorWindow: NSWindow?

    /// Le gestionnaire Carbon est un pointeur de fonction C : il ne capture
    /// rien, d'où cette référence de classe pour retrouver l'instance.
    private static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deux instances de Pulse tiendraient chacune une copie complète de
        // l'historique en mémoire et se l'écraseraient mutuellement toutes les
        // 60 secondes, sans que rien ne le signale.
        let mine = ProcessInfo.processInfo.processIdentifier
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: "com.isma.pulse")
            .filter { $0.processIdentifier != mine }
        if !twins.isEmpty {
            NSApp.terminate(nil)
            return
        }

        // Lu avant l'enregistrement, qui pose son drapeau.
        let firstLaunch = !CommandLine.arguments.contains("--show")
            && !UserDefaults.standard.bool(forKey: "loginItemRegistered")
            && !UserDefaults.standard.bool(forKey: "firstPanelShown")
        if !CommandLine.arguments.contains("--show") {
            registerLoginItemOnce()
        }

        // Force l'apparence claire pour vérifier les contrastes sans toucher
        // au réglage du système. N'affecte que Pulse.
        if CommandLine.arguments.contains("--light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        // Les éléments de barre de menus : un seul ou un par module, réglés
        // dans la fenêtre Réglages. Sans autosaveName, macOS ne mémoriserait
        // aucun emplacement ; le contrôleur le pose (`MenuBarController`).
        menuBar = MenuBarController(sampler: sampler, target: self, action: #selector(statusItemClicked(_:)))
        SettingsWindow.shared.sampler = sampler
        SettingsWindow.shared.visibilityDidChange = { [weak self] visible in
            guard let self else { return }
            settingsVisible = visible
            Self.panelDidChange(open: measuringOpen, sampler: sampler)
        }
        // Fenêtre détachée, tableau de bord, état des widgets (chantier 13).
        Surfaces.attach(sampler: sampler) { [weak self] in
            guard let self else { return }
            Self.panelDidChange(open: measuringOpen, sampler: sampler)
        }
        registerHotKey()
        // Règles et notifications (chantier 11) : n'écoute le relevé que si
        // Isma a allumé une règle ; sinon, coût nul.
        SurveillantRegles.shared.demarrer(sampler)
        // Ventilateurs (chantier 14) : en automatique, le défaut, rien du tout.
        FanPilot.shared.start()

        let popover = NSPopover()
        // En mode inspection le popover doit rester ouvert : .transient le
        // referme dès qu'une autre app reprend le focus, ce qui rend toute
        // capture d'écran aléatoire.
        popover.behavior = CommandLine.arguments.contains("--show") ? .applicationDefined : .transient
        // `animates` ne gouverne QUE l'apparition et la fermeture, jamais le
        // redimensionnement — vérifié : à true comme à false, la hauteur passe
        // de 1129 à 1069 en une seule frame, identique sur les 40 relevés
        // suivants. Inutile donc d'y toucher pour lisser un dépliage ; voir le
        // commentaire de `Explainable` dans Explain.swift.
        popover.animates = false
        popover.delegate = self
        // NSPopover ouvre sa propre fenêtre et n'hérite pas de NSApp.appearance.
        if CommandLine.arguments.contains("--light") {
            popover.appearance = NSAppearance(named: .aqua)
        }
        // Pas de contenu ici : il est créé à l'ouverture (voir `makeContent`).
        self.popover = popover
        // Les réglages s'appliquent à chaud, et une première fois tout de
        // suite : cadence du relevé, cartes affichées ou masquées (chaque
        // module apprend son état, panneau fermé).
        settingsCancellable = SettingsStore.shared.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                MainActor.assumeIsolated { self?.apply(settings) }
            }

        menuBar?.refresh()

        // Le rendu fige la densité de l'écran principal. Avec deux écrans de
        // densités différentes, la barre de menus peut changer d'écran : sans
        // ce nouveau rendu, le libellé y serait flou.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuBar?.refresh(force: true) }
            }

        // Ouverture immédiate pour inspection visuelle pendant le développement.
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover() }
        }
        // Tout premier lancement sur ce Mac : le panneau s'ouvre une fois,
        // seul. Une app de barre de menus n'a ni fenêtre ni icône dans le
        // Dock ; sur un 14 pouces à la barre pleine, son icône peut naître
        // derrière l'encoche, et rien ne dirait que Pulse tourne (version
        // partagée, 26/10). Jamais chez qui l'a déjà lancé : le drapeau du
        // lancement à l'ouverture de session y est posé.
        if firstLaunch {
            UserDefaults.standard.set(true, forKey: "firstPanelShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.togglePopover() }
        }
        // Le libellé est réimprimé à chaque publication du sampler, mais au
        // plus une fois par seconde : au-delà l'œil ne suit pas et le rendu
        // deviendrait le poste de dépense principal de l'app.
        cancellable = sampler.objectWillChange
            // DispatchQueue.main et non RunLoop.main : l'ordonnanceur RunLoop
            // ne délivre qu'en mode .default, si bien que le libellé se figeait
            // dès qu'un menu était ouvert ou qu'un glisser était en cours.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.menuBar?.refreshIfDue() }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        sampler.flush()
        SettingsStore.shared.flush()
        ReglesStore.shared.vider()
        FanPilot.shared.shutdown()      // 14-ventilateurs : la main à macOS
    }

    /// Lancement à l'ouverture de session.
    ///
    /// Un outil de surveillance éteint ne surveille rien. Relevé dans
    /// l'historique : aucun point entre le 27/08 et le 21/09, puis aucun entre
    /// le 21/09 et le 24/09. Or la tendance des disques exige six heures de
    /// collecte continue, et le verdict « Le swap monte » compare avec l'heure
    /// précédente.
    ///
    /// Enregistré UNE fois, au premier lancement, puis plus jamais. Si
    /// l'utilisateur retire Pulse de ses éléments d'ouverture dans Réglages
    /// Système, ce choix doit tenir : réenregistrer à chaque lancement rendrait
    /// l'élément impossible à désactiver. Le drapeau n'est posé qu'en cas de
    /// succès — un échec se retente au lancement suivant.
    ///
    /// `SMAppService` et non un LaunchAgent déposé à la main : l'élément
    /// apparaît là où macOS range les éléments d'ouverture, avec la
    /// notification système qui l'annonce, et se retire d'un clic.
    private func registerLoginItemOnce() {
        let key = "loginItemRegistered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            FileHandle.standardError.write(
                "élément d'ouverture non enregistré : \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    /// Raccourci global ⌃⌥M.
    ///
    /// L'item de barre de menus est inaccessible tant qu'une app est en plein
    /// écran : macOS masque la barre, et c'est précisément quand Premiere
    /// mouline qu'on veut regarder la mémoire. Le raccourci ouvre le popover
    /// par-dessus, plein écran ou non.
    ///
    /// Carbon RegisterEventHotKey plutôt que NSEvent.addGlobalMonitorForEvents :
    /// le moniteur global exige l'autorisation « Surveillance de la saisie » et
    /// ne consomme pas la frappe, qui partirait aussi dans Premiere.
    private func registerHotKey() {
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppDelegate.shared?.togglePopover(transient: false) }
            }
            return noErr
        }, 1, &spec, nil, nil)

        bindHotKey()

        // La disposition peut changer en cours de route : le code de touche
        // résolu ci-dessous ne vaudrait plus rien.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bindHotKey() }
            }
    }

    /// (Ré)enregistre ⌃⌥M sur la touche qui porte réellement « m ».
    private func bindHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        // Signature 'PULS', identifiant arbitraire : ils ne servent qu'à
        // distinguer plusieurs raccourcis d'une même app.
        let id = EventHotKeyID(signature: OSType(0x50554C53), id: 1)
        RegisterEventHotKey(Self.keyCode(for: "m") ?? UInt32(kVK_ANSI_M),
                            UInt32(controlKey | optionKey),
                            id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Le code attendu par `RegisterEventHotKey` désigne une POSITION de
    /// touche, pas un caractère. `kVK_ANSI_M` est la position du M sur un
    /// QWERTY ; sur l'AZERTY elle produit une virgule, et le M est ailleurs.
    /// Codé en dur, le raccourci ne partait jamais sous les doigts — alors
    /// qu'un envoi synthétique du code 46 le déclenchait, si bien que le test
    /// passait et l'usage non. On demande donc à la disposition active quelle
    /// position produit « m ».
    /// `layout` : une autre disposition que l'active, pour les tests (le
    /// piège AZERTY du README se vérifie sans changer le clavier d'Isma).
    static func keyCode(for target: Character, layout: TISInputSource? = nil) -> UInt32? {
        guard let source = layout ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> UInt32? in
            guard let layout = buffer.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            let kbdType = UInt32(LMGetKbdType())
            for code in UInt16(0)..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                            kbdType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, 4, &length, &chars)
                guard status == noErr, length > 0, let scalar = UnicodeScalar(chars[0]) else { continue }
                if Character(scalar) == target { return UInt32(code) }
            }
            return nil
        }
    }

    /// Où accrocher le popover.
    ///
    /// Normalement le bouton de l'item de barre de menus. Mais dès qu'une app
    /// passe en plein écran, macOS masque la barre : le bouton n'a plus de
    /// fenêtre visible et `NSPopover.show` échoue en silence — le raccourci
    /// semblait mort alors qu'il arrivait bien. On retombe alors sur une
    /// fenêtre invisible de 1 pt en haut à droite, marquée `fullScreenAuxiliary`
    /// pour avoir le droit de s'afficher au-dessus de l'espace plein écran.
    private func anchorView(fromClick: Bool) -> NSView? {
        // L'élément cliqué — il se voit, puisqu'on vient de cliquer dessus —,
        // ou le premier dont une fenêtre affichée de la barre contient le
        // cadre (`MenuBarRoom`) ; à défaut, l'ancien critère, qui ne voit pas
        // une icône effacée sous une pastille.
        if let button = menuBar?.anchorButton(fromClick: fromClick) { return button }
        if let button = menuBar?.items.first?.button, let window = button.window,
           window.isVisible, Self.isReachable(window) {
            return button
        }
        // Aucun écran (couvercle fermé, écrans en cours de reconfiguration) :
        // pas d'ancrage plutôt qu'un index hors limites.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let frame = screen.frame
        let rect = NSRect(x: frame.maxX - 240, y: frame.maxY - 1, width: 1, height: 1)
        let window = anchorWindow ?? NSWindow(contentRect: rect, styleMask: .borderless,
                                              backing: .buffered, defer: false)
        window.setFrame(rect, display: false)
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()
        anchorWindow = window
        return window.contentView
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        menuBar?.didClick(sender)
        // Clic droit ou ⌃-clic : le menu de l'app, comme toute icône de barre
        // de menus. Le clic simple garde le panneau.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showAppMenu()
            return
        }
        togglePopover()
    }

    /// Le menu de l'app : une app accessoire n'a pas de barre de menus à elle.
    private func showAppMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Réglages de Pulse…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        Surfaces.menuItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Le menu n'est posé que le temps de ce clic : le clic simple doit
        // continuer d'ouvrir le panneau.
        let item = menuBar?.clickedItem
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    /// La fenêtre Réglages, depuis le menu de l'app ou le bouton du panneau.
    @objc func openSettings() {
        popover?.performClose(nil)
        SettingsWindow.shared.show()
    }

    /// Le panneau devient une fenêtre, à sa place (chantier 13).
    @objc func detachPanel() {
        let frame = popover?.contentViewController?.view.window?.frame
        popover?.performClose(nil)
        FloatingWindow.shared.show(replacing: frame)
    }

    /// Le tableau de bord, pour un second écran (chantier 13).
    @objc func openDashboard() {
        popover?.performClose(nil)
        DashboardWindow.shared.show()
    }

    /// `transient` : le popover se referme dès qu'une autre app prend le focus.
    /// C'est ce qu'on veut au clic sur l'item, jamais au raccourci clavier —
    /// Premiere en plein écran reprend la main dans la seconde et le refermait
    /// avant qu'on ait pu lire quoi que ce soit. Ouvert au clavier, il reste
    /// donc jusqu'au ⌃⌥M suivant.
    /// Le panneau est-il réellement sous les yeux de l'utilisateur ?
    ///
    /// `popover.isShown` ne suffit pas : un panneau peut être « ouvert » sur un
    /// autre espace, derrière une app en plein écran, ou ancré sur une icône
    /// passée sous l'encoche. Une bascule fondée sur `isShown` refermait alors
    /// un panneau invisible — l'appui sur ⌃⌥M ne montrait rien, et il fallait
    /// appuyer une seconde fois. « Il ne s'ouvre pas tout le temps. »
    private var popoverOnScreen: Bool {
        guard let popover, popover.isShown,
              let window = popover.contentViewController?.view.window else { return false }
        return window.isVisible && window.isOnActiveSpace && window.occlusionState.contains(.visible)
    }

    /// Une icône de barre de menus est-elle là où on peut la voir ?
    ///
    /// Relevé le 07/10 : la zone à droite de l'encoche fait 918 pt, les icônes
    /// en demandent 954. Celles qui débordent passent sous l'encoche, où macOS
    /// les garde « visibles » au sens de NSWindow. Un panneau ancré dessus
    /// s'ouvrait sous l'encoche.
    private static func isReachable(_ window: NSWindow) -> Bool {
        guard let screen = window.screen else { return false }
        let frame = window.frame
        if let right = screen.auxiliaryTopRightArea {
            return frame.minX >= right.minX - 1 && frame.maxX <= right.maxX + 1
        }
        return screen.frame.contains(frame)
    }

    private func togglePopover(transient: Bool = true) {
        guard let popover else { return }
        let source = transient ? "clic" : "⌃⌥M"
        let before = (shown: popover.isShown, onScreen: popoverOnScreen)
        // Visible : l'appui le referme, c'est ce que l'utilisateur attend.
        if before.onScreen {
            popover.performClose(nil)
            HotKeyLog.record(source: source, before: before, action: "fermé", anchor: nil, after: nil)
            return
        }
        // Ouvert mais invisible : on le referme sans bruit, puis on le rouvre
        // là où il se voit. Un seul appui suffit.
        if before.shown { popover.close() }
        guard let anchor = anchorView(fromClick: transient) else { return }
        popover.behavior = transient && !CommandLine.arguments.contains("--show")
            ? .transient : .applicationDefined

        // Sans activation, un popover transitoire lancé par une app
        // accessoire se referme immédiatement et ne prend jamais le clavier.
        NSApp.activate(ignoringOtherApps: true)
        // Une icône de Pulse cachée faute de place se dit dans le panneau :
        // vérifié AVANT de le créer, sa hauteur en tient compte.
        menuBar?.publishVisibility()
        // Le panneau tient dans l'écran de l'icône (ou du secours) : au-delà
        // de sa hauteur, il prend une colonne de plus (`PanelFit`).
        if popover.contentViewController == nil {
            popover.contentViewController = makeContent(limits: PanelLimits.of(anchor.window?.screen))
        }
        // La hauteur dépend du nombre de volumes montés, qui peut changer
        // entre deux ouvertures : on la recalcule à chaque fois.
        if let host = popover.contentViewController {
            host.view.layoutSubtreeIfNeeded()
            let fitting = host.view.fittingSize
            if fitting.height > 0 { popover.contentSize = fitting }
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Le popover ouvre sa propre fenêtre : sans ce comportement elle
        // resterait cantonnée à l'espace de bureau et n'apparaîtrait pas
        // par-dessus une app en plein écran.
        popover.contentViewController?.view.window?.collectionBehavior =
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        popover.contentViewController?.view.window?.makeKey()

        let anchorKind = anchor is NSStatusBarButton ? "icône" : "secours"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            HotKeyLog.record(source: source, before: before, action: "ouvert", anchor: anchorKind,
                             after: self?.popoverOnScreen)
        }
        if CommandLine.arguments.contains("--show") {
            let w = popover.contentViewController?.view.window?.frame
            let msg = "SHOW isShown=\(popover.isShown) window=\(w?.debugDescription ?? "nil")\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
        }
    }

    /// Applique les réglages : cadence du relevé, état de chaque module.
    private func apply(_ settings: PulseSettings) {
        // Le thème (chantier 10) : les fonds de Palette le lisent au dessin,
        // et le popover prend l'apparence qu'il impose.
        Theme.current = settings.display.theme
        if !CommandLine.arguments.contains("--light") {
            popover?.appearance = settings.display.theme.appearance.flatMap { NSAppearance(named: $0) }
        }
        let refresh = settings.refresh.sanitized
        sampler.setIntervals(open: refresh.openInterval, closed: refresh.closedInterval)
        ModuleRegistry.panelDidChange(open: measuringOpen, settings: settings)
        menuBar?.refresh()
    }

    /// La fenêtre Réglages est ouverte : son aperçu en direct mesure comme
    /// le panneau ouvert, et revient à la cadence fermée avec elle.
    private var settingsVisible = false

    /// Panneau ou fenêtre Réglages sous les yeux d'Isma.
    private var measuringOpen: Bool { popover?.isShown == true || settingsVisible || Surfaces.anyVisible }

    func popoverDidShow(_ notification: Notification) {
        Self.panelDidChange(open: true, sampler: sampler)
    }

    func popoverDidClose(_ notification: Notification) {
        // Rouvert entre-temps : la bascule « ouvert mais invisible » referme
        // puis rouvre dans la foulée. Rien à ralentir, rien à libérer.
        guard popover?.isShown != true else { return }
        Self.panelDidChange(open: measuringOpen, sampler: sampler)
        // Au tour de boucle suivant, pas au milieu de la fermeture.
        DispatchQueue.main.async { [weak self] in self?.releaseContent() }
    }

    /// Tout ce que l'ouverture ou la fermeture du panneau change à la mesure :
    /// la cadence du sampler, celle des modules qui mesurent eux-mêmes.
    /// Partagé avec `--banc`, qui mesure ainsi exactement ce que fait l'app.
    static func panelDidChange(open: Bool, sampler: Sampler) {
        sampler.setPopoverOpen(open)
        ModuleRegistry.panelDidChange(open: open, settings: SettingsStore.shared.settings)
    }

    /// Le contenu du popover n'existe que pendant qu'il est ouvert.
    ///
    /// Relevé le 09/10 : panneau FERMÉ, Pulse dépensait 8,2 % d'un cœur dès
    /// qu'il avait été ouvert une fois, 2,1 % s'il ne l'avait jamais été. Au
    /// profileur, l'écart partait à redessiner ce panneau : sa vue SwiftUI,
    /// créée une fois pour toutes au lancement, restait abonnée au sampler.
    /// Chaque relevé la recalculait et relançait l'animation des chiffres,
    /// image par image, dans une fenêtre retirée de l'écran.
    ///
    /// Sans sizingOptions, le popover garde une taille fixe et rogne le
    /// contenu : la hauteur dépend du nombre de volumes montés.
    private func makeContent(limits: PanelLimits?) -> NSHostingController<AnyView> {
        // La cascade d'ouverture et le cadre en verre : le vrai popover
        // seulement (chantier 10). Réduire la transparence relu à chaque
        // ouverture : le contenu est recréé chaque fois. Les limites : celles
        // de l'écran de l'icône (`PanelFit`, chantier 01).
        let host = NSHostingController(rootView: AnyView(PopoverView(sampler: sampler, animatesOpening: true,
                                                                     glassFrame: Glass.allowed, limits: limits)))
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// Vide puis libère le contenu d'un popover refermé.
    ///
    /// La vue racine est remplacée par une vue vide AVANT d'être lâchée : si
    /// AppKit en gardait une référence quelque part, elle ne suivrait plus
    /// rien pour autant. La libération seule ne garantirait pas ça.
    private func releaseContent() {
        guard let popover, !popover.isShown,
              let host = popover.contentViewController as? NSHostingController<AnyView> else { return }
        host.rootView = AnyView(EmptyView())
        popover.contentViewController = nil
    }
}

import AppKit
import ApplicationServices

/// La section BARRE DE MENUS de `--probe` : les réglages, ce que la barre
/// affiche en ce moment — calculé par le même code que l'app —, la largeur
/// de chaque élément, la place à droite de l'encoche, et si les éléments du
/// Pulse installé se voient vraiment.
///
/// Les valeurs du moment demandent un vrai `Sampler` (le débit exige deux
/// relevés espacés de 2 s) : il tourne 4,5 s, écriture coupée, comme sous
/// `--snapshot`. Section imprimée en dernier : la coupure ne change rien à
/// ce qui précède.
@MainActor
enum MenuBarProbe {
    static func lines() -> [String] {
        Persistence.enabled = false
        var out: [String] = []
        let settings = SettingsStore.shared.settings
        let bar = settings.menuBar
        let items = MenuBarCatalog.items(settings)
        out.append("mode             \(bar.mode == .combined ? "un seul élément" : "un élément par segment") · symbole d'alerte : \(bar.alert.label.lowercased())")
        out.append("segments         " + items.map { item in
            "\(item.id) \(item.shown ? item.style.label.lowercased() : "masqué")"
        }.joined(separator: " · "))

        let sampler = Sampler()
        AppDelegate.panelDidChange(open: false, sampler: sampler)
        pump(4.5)
        let history = MenuBarHistory()
        history.seed(from: sampler)
        let contents = MenuBarComposer.contents(sampler, settings: settings, history: history)
        out.append("verdict          \(sampler.verdict.phrase) (niveau \(sampler.verdict.level.rawValue)) → "
                   + (contents.first?.alert.map { "symbole \($0.symbol)" } ?? "pas de symbole"))
        for (index, content) in contents.enumerated() {
            let size = MenuBarDrawing.size(content)
            let pieces = content.pieces.map { piece -> String in
                let shown = piece.isEmpty ? "(vide : \(piece.spoken))" : "\(piece.label) \(piece.value)".trimmingCharacters(in: .whitespaces)
                let fraction = piece.fraction.map { " [\(Fmt.percent($0))]" } ?? ""
                return "\(shown)\(fraction) en \(piece.style.label.lowercased())"
            }
            out.append("élément \(index + 1)        image \(Int(size.width)) × \(Int(size.height)) pt, figée"
                       + (content.reservesAlert ? ", place de l'alerte \(Int(MenuBarDrawing.alertWidth + MenuBarDrawing.alertGap)) pt" : ""))
            out.append("                 " + (pieces.isEmpty ? "aucun segment : icône de Pulse seule" : pieces.joined(separator: " · ")))
        }
        out.append("infobulle        \(contents.first?.spoken ?? "—")")
        out += room()
        return out
    }

    /// La place à droite de l'encoche, et les éléments du Pulse installé.
    private static func room() -> [String] {
        var out: [String] = []
        let windows = MenuBarRoom.shownWindows()
        let area = MenuBarRoom.rightOfNotch()
        if let area {
            let room = MenuBarRoom.room(windows, rightOfNotch: area)
            out.append("à droite de l'encoche  \(Int(room.area)) pt · \(room.count) icônes en prennent \(Int(room.used)) · libre \(Int(room.free)) pt (fenêtres de la barre, CGWindowList)")
        } else {
            out.append("pas d'encoche : \(windows.count) icônes dans la barre")
        }
        guard let pulse = NSRunningApplication.runningApplications(withBundleIdentifier: "com.isma.pulse")
            .first(where: { $0.processIdentifier != getpid() }) else {
            out.append("Pulse installé   ne tourne pas")
            return out
        }
        guard AXIsProcessTrusted() else {
            out.append("Pulse installé   position illisible sans l'autorisation d'accessibilité du terminal (rien n'est demandé) ; le panneau le dit à son ouverture")
            return out
        }
        let frames = installedFrames(pulse.processIdentifier)
        if frames.isEmpty { out.append("Pulse installé   aucun élément dans la barre") }
        for (index, frame) in frames.enumerated() {
            let place = MenuBarRoom.place(of: frame, in: windows, rightOfNotch: area, screen: MenuBarRoom.notchScreen())
            out.append("Pulse installé   élément \(index + 1) : x \(Int(frame.minX))–\(Int(frame.maxX)), \(Int(frame.width)) pt — \(place.label)")
        }
        return out
    }

    /// Les cadres des éléments du Pulse installé, lus par l'API
    /// d'accessibilité (`AXExtrasMenuBar`), en coordonnées Quartz.
    private static func installedFrames(_ pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        return ((children as? [AXUIElement]) ?? []).compactMap { child in
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { return nil }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            return CGRect(origin: p, size: s)
        }
        .sorted { $0.minX < $1.minX }
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

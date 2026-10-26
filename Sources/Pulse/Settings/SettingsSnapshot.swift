import SwiftUI
import AppKit

/// `--snapshot x.png --reglages [page]` : la fenêtre Réglages rendue hors
/// écran — `general` ou l'identifiant d'un module (`memoire`…). Rien ne
/// s'ouvre : la fenêtre n'est jamais posée à l'écran, et `reglages.json`
/// n'est pas écrit (`Persistence` coupée par `--snapshot`).
///
/// `ImageRenderer` ne dessine pas les contrôles d'AppKit (interrupteurs,
/// menus, listes) : la vue est donc hébergée dans une fenêtre hors écran et
/// dessinée par `cacheDisplay`, comme AppKit dessine une fenêtre.
@MainActor
enum SettingsSnapshot {
    static func run(to path: String, sampler: Sampler, light: Bool) {
        let page: SettingsPage = Snapshot.value(after: "--reglages").map {
            $0 == "general" ? .general : $0 == "barre" ? .menuBar : $0 == "regles" ? .regles
                : $0 == "ventilateurs" ? .fans : .module($0)
        } ?? .general
        if case .module(let id) = page, ModuleRegistry.module(id) == nil {
            FileHandle.standardError.write(Data("page inconnue : \(id) — general, \(ModuleRegistry.ids.joined(separator: ", "))\n".utf8))
            exit(1)
        }
        let host = NSHostingView(rootView: SettingsView(store: .shared, sampler: sampler, page: page))
        host.frame = NSRect(origin: .zero, size: SettingsWindow.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = host
        // Laisse SwiftUI construire la page et la barre latérale.
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("rendu impossible\n".utf8))
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            FileHandle.standardError.write(Data("rendu impossible\n".utf8))
            exit(1)
        }
        print("→ \(path)")
    }
}

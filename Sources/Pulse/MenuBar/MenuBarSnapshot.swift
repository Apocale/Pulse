import SwiftUI
import AppKit

/// `--snapshot x.png --barre` : la barre de menus hors écran, avec les vraies
/// mesures. Rien ne s'ouvre, aucun élément n'est posé dans la barre d'Isma.
///
/// Ce sont les images mêmes que l'app pose dans la barre
/// (`MenuBarDrawing.image`), recolorées comme le fait macOS pour une image
/// template — blanc sur barre sombre, noir sur barre claire —, agrandies
/// deux fois. En haut, la barre réglée ; dessous, chaque style sur tous les
/// segments qui le permettent, l'alerte et l'avertissement, le mode « un
/// élément par module » ; la largeur de chaque image en points.
@MainActor
enum MenuBarSnapshot {
    /// Agrandissement du rendu : 2 × l'échelle 2 du fichier, soit 4 pixels
    /// par point — les images sont faites à cette densité, sans flou.
    static let zoom: CGFloat = 2

    static func view(_ sampler: Sampler) -> AnyView {
        let settings = SettingsStore.shared.settings
        let history = MenuBarHistory()
        history.seed(from: sampler)
        let configured = MenuBarComposer.contents(sampler, settings: settings, history: history)
        let verdict = sampler.verdict

        var rows: [(title: String, contents: [MenuBarContent])] = []
        rows.append(("Barre réglée — \(settings.menuBar.mode == .combined ? "un seul élément" : "un élément par module"), verdict « \(verdict.phrase) »", configured))

        // Tous les segments du catalogue, affichés, dans chaque style permis.
        // Les réglages du rendu sont posés EN MÉMOIRE (`--snapshot` n'écrit
        // jamais reglages.json) : un module qui tient son interrupteur lui-même
        // (Capteurs) le lit là.
        var all = settings
        all.menuBar.alert = .alerts
        for entry in MenuBarCatalog.entries { MenuBarCatalog.setShown(true, id: entry.id, in: &all) }
        SettingsStore.shared.settings = all
        defer { SettingsStore.shared.settings = settings }
        for style in MenuBarSettings.Style.allCases {
            var styled = all
            for entry in MenuBarCatalog.entries where entry.styles.contains(style) {
                MenuBarCatalog.setStyle(style, id: entry.id, in: &styled)
            }
            for entry in MenuBarCatalog.entries where !entry.styles.contains(style) {
                MenuBarCatalog.setShown(false, id: entry.id, in: &styled)
            }
            styled.menuBar.mode = .combined
            var content = MenuBarComposer.contents(sampler, settings: styled, history: history)
            content = content.map { var c = $0; c.alert = nil; return c }
            rows.append(("Style « \(style.label) » — segments qui le permettent", content))
        }
        // L'alerte et l'avertissement, sur la barre réglée : la largeur ne
        // bouge pas.
        if var first = configured.first {
            first.reservesAlert = true
            first.alert = MenuBarAlert(symbol: MenuBarComposer.alertSymbol, spoken: "")
            rows.append(("Alerte du verdict : triangle plein, place réservée", [first]))
            first.alert = MenuBarAlert(symbol: MenuBarComposer.warningSymbol, spoken: "")
            rows.append(("Avertissement (réglage « alertes et avertissements ») : triangle en contour", [first]))
            first.alert = nil
            rows.append(("Sans alerte : même largeur", [first]))
        }
        var separate = settings
        separate.menuBar.mode = .separate
        rows.append(("Un élément par module", MenuBarComposer.contents(sampler, settings: separate, history: history)))

        return AnyView(
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title + " · " + widths(row.contents))
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.85))
                        HStack(spacing: 0) {
                            bar(row.contents, dark: true)
                            bar(row.contents, dark: false)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(white: 0.16))
            .fixedSize()
        )
    }

    /// « 118 pt », ou « 40 + 38 + 52 pt » pour plusieurs éléments.
    private static func widths(_ contents: [MenuBarContent]) -> String {
        contents.map { "\(Int(MenuBarDrawing.size($0).width))" }.joined(separator: " + ") + " pt"
    }

    /// Une barre sombre ou claire, les éléments espacés comme dans la vraie
    /// barre (14 pt : les marges des fenêtres de Control Center, relevées).
    private static func bar(_ contents: [MenuBarContent], dark: Bool) -> some View {
        HStack(spacing: 14 * zoom) {
            ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                let size = MenuBarDrawing.size(content)
                Image(nsImage: MenuBarDrawing.image(content, scale: 2 * zoom))
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size.width * zoom, height: size.height * zoom)
                    .foregroundStyle(dark ? Color.white : Color.black)
            }
        }
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 4 * zoom)
        .background(dark ? Color.black : Color(white: 0.93))
    }
}

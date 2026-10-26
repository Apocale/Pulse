import SwiftUI
import AppKit

/// Le panneau, façon iStat Menus 7 en mode combiné : le verdict en tête, puis
/// une carte par thème sur deux colonnes, et la barre de raccourcis en pied.
///
/// Deux colonnes plutôt qu'une : empilées, les cinq cartes mesuraient plus de
/// 900 pt de haut ; côte à côte, environ 520 — comme les menus alignés de la
/// page d'iStat Menus. Chaque carte suit la recette relevée sur ses menus
/// réels : un titre, le chiffre du moment, un dessin, les apps qui consomment.
///
/// Ce qu'iStat ne sait pas faire reste en place : le verdict, l'échéance d'un
/// disque, le cumul par réseau (partage iPhone compris), la session de
/// montage et l'export. Les historiques des anciens dépliants s'ouvrent depuis
/// le titre de leur carte, un seul à la fois.
///
/// Les cartes viennent du registre (`ModuleRegistry`), une par fichier dans
/// `UI/Cards/` ; leur place, des réglages (`Layout`). Ce fichier ne garde que
/// le verdict, les colonnes et le pied.
struct PopoverView: View {
    @ObservedObject var sampler: Sampler
    @ObservedObject var store: SettingsStore
    /// La cascade d'ouverture (chantier 10, `UI/Motion/Opening.swift`) : le
    /// vrai popover seulement (`AppDelegate.makeContent`). Rendus et banc
    /// dessinent le panneau posé ; `--snapshot --ouverture` fige un instant.
    var animatesOpening = false
    /// Un instant figé de la cascade, de 0 à 1 (`--snapshot --ouverture`).
    var frozenOpening: Double? = nil
    /// Le cadre en verre (chantier 10, `UI/Themes/Glass.swift`) : le vrai
    /// popover seulement, sous macOS 26 et sans Réduire la transparence.
    var glassFrame = false
    /// La place que l'écran de l'icône offre au panneau. Nil : sans limite
    /// (rendus de référence). Voir `PanelFit`.
    let limits: PanelLimits?

    init(sampler: Sampler, store: SettingsStore? = nil, animatesOpening: Bool = false,
         frozenOpening: Double? = nil, glassFrame: Bool = false, limits: PanelLimits? = nil) {
        self.sampler = sampler
        self.store = store ?? .shared
        self.animatesOpening = animatesOpening
        self.frozenOpening = frozenOpening
        self.glassFrame = glassFrame
        self.limits = limits
    }

    /// La largeur d'une colonne : celle d'un menu d'iStat, mesurée sur sa
    /// vidéo de démonstration, arrondie pour loger douze anneaux de cœur.
    nonisolated static let columnWidth: CGFloat = 296

    /// Un seul historique ouvert à la fois, comme les anciens dépliants.
    @State private var open: String? = PopoverView.lastOpen

    /// L'historique ouvert survit à la fermeture du popover, dont le contenu
    /// est recréé à chaque ouverture (voir `AppDelegate.makeContent`).
    /// Interne : `--snapshot x.png --ouvert <clé>` rend le panneau entier
    /// avec un historique déplié, pour en mesurer la hauteur.
    @MainActor static var lastOpen: String?

    var body: some View {
        let settings = store.settings
        // Sur une seule colonne, le verdict s'y tient : sa preuve se coupe
        // plutôt que d'élargir tout le panneau.
        let bannerWidth: CGFloat? = Layout.columnCount(settings) == 1 ? Self.columnWidth : nil
        // Par défaut, activité à gauche, capacité et travail à droite : c'est
        // aussi le partage qui équilibre les deux hauteurs (relevé sur le
        // rendu du 11/10 : 690 contre 495 pt dans l'ordre inverse). Voir
        // `defaultColumn` des modules. Une carte sans rien à dire se retire
        // sans laisser de trou : filtrée ici, pas vide dans la pile.
        //
        // Un historique déplié : les autres cartes de sa colonne PEUVENT
        // passer en compactes, le temps qu'il est ouvert — sans quoi le
        // panneau dépassait l'écran (1 344 à 1 445 pt pour 1 290 utiles,
        // mesuré le 11/10 avec `--ouvert`). La mise en page n'en compacte que
        // ce qu'il faut, de bas en haut (`PanelFit.shrink`, chantier 16).
        //
        // Un écran bas (moins de 800 pt utiles : un 14 pouces en « texte plus
        // grand ») : toutes les cartes portent aussi leur forme compacte, au
        // cas où, même rangées au plus serré, les pleines ne tiendraient pas
        // (`PanelCompactKey`). Pleine tant qu'elle tient, la carte ne change
        // pas (26/10).
        let lowScreen = (limits?.height ?? .infinity) < 800
        let cards = Layout.columns(settings).enumerated().flatMap { column, ids in
            let shown = ids.filter { ModuleRegistry.module($0)?.hasContent(sampler) == true }
            let focus = open.flatMap { Self.historyOwners[$0] }.flatMap { shown.contains($0) ? $0 : nil }
            return shown.enumerated().map { row, id in
                let shrinkable = focus != nil && focus != id
                return (id: id, column: column, row: row, shrinkable: shrinkable, compactable: shrinkable || lowScreen)
            }
        }
        return PanelLayout(columnCount: Layout.columnCount(settings),
                           maxHeight: limits.map { $0.height - 24 },
                           maxColumns: limits.map { PanelFit.maxColumns(width: $0.width, columnWidth: Self.columnWidth,
                                                                        spacing: 10) } ?? 1) {
            verdictBanner
                .padding(.horizontal, 4)
                .padding(.bottom, glassFrame ? 0 : 2)
                // Sur le verre, le verdict prend une surface opaque comme les
                // cartes : son symbole est une teinte mesurée (chantier 10).
                .padding(.vertical, glassFrame ? 7 : 0)
                .padding(.horizontal, glassFrame ? 4 : 0)
                .modifier(OptionalDataSurface(active: glassFrame))
                .frame(width: bannerWidth)
                .entrance(rank: 0)
                .layoutValue(key: PanelSlotKey.self, value: .header)
            // L'icône de Pulse cachée dans la barre de menus (chantier 09).
            MenuBarNotice(width: CGFloat(Layout.columns(settings).count) * (Self.columnWidth + 10) - 10)
                .layoutValue(key: PanelSlotKey.self, value: .header)
            ForEach(cards, id: \.id) { item in
                // La cascade d'ouverture descend en diagonale : ligne +
                // colonne, après le verdict.
                Group {
                    if item.compactable {
                        // Pleine si elle tient, compacte sinon : c'est la
                        // hauteur que la mise en page lui propose qui tranche.
                        ViewThatFits(in: .vertical) {
                            card(item.id, settings)
                            card(item.id, settings, compact: true)
                        }
                    } else {
                        card(item.id, settings)
                    }
                }
                .entrance(rank: 1 + item.row + item.column)
                .layoutValue(key: PanelSlotKey.self, value: .card(column: item.column))
                .layoutValue(key: PanelShrinkKey.self, value: item.shrinkable)
                .layoutValue(key: PanelCompactKey.self, value: item.compactable)
            }
            ShortcutBar {
                HStack(spacing: 8) {
                    SurfaceButtons()   // détacher, tableau de bord : chantier 13
                    settingsButton
                    quitButton
                }
            }
            .entrance(rank: Opening.maxRank)
            .layoutValue(key: PanelSlotKey.self, value: .footer)
        }
        .padding(12)
        .background(PopoverBackground())
        .environment(\.glassFrame, glassFrame)
        .onChange(of: open) { _, now in PopoverView.lastOpen = now }
        .modifier(OpeningSource(animates: animatesOpening, frozen: frozenOpening))
    }

    /// La carte du module `id`, avec ses réglages.
    @ViewBuilder
    private func card(_ id: String, _ settings: PulseSettings, compact: Bool = false) -> some View {
        if let module = ModuleRegistry.module(id) {
            var own = settings.module(id)
            let _ = compact ? (own.compact = true) : ()
            module.card(CardContext(module: module, sampler: sampler, open: $open,
                                    settings: own, display: settings.display))
        }
    }

    /// Quelle carte porte quel dépliant. Une clé absente d'ici ne compacte
    /// rien : le panneau garde alors le comportement d'avant.
    static let historyOwners: [String: String] = [
        "processeur": "processeur", "memoire": "memoire",
        "debit": "reseau", "reseau": "reseau", "connexion": "reseau",
        "volumes": "disques", "activite-disques": "disques",
        "capteurs": "capteurs", "energie": "energie",
        "session": "montage", "apps": "montage", "incidents": "montage",
    ]

    // MARK: - Le verdict

    /// Le jugement rendu par l'application : une phrase, puis le chiffre qui
    /// l'a produite. Ce qu'iStat Menus n'a pas, et qui reste donc en tête.
    ///
    /// Réfutable par construction : la ligne de preuve n'énonce que des
    /// grandeurs mesurées, et `--probe` imprime la règle retenue.
    private var verdictBanner: some View {
        let verdict = sampler.verdict
        let color = tint(for: verdict.level)
        // Le conseil et son bouton (chantier 12) : calculés ici, panneau
        // ouvert, sur les relevés déjà publiés — rien panneau fermé.
        let advice = Advisor.advice(for: verdict, sampler.adviceInput, ingestions: sampler.disks.state.ingestions)

        return HStack(alignment: .top, spacing: 0) {
            // Filet tracé UNIQUEMENT en avertissement ou en alerte : l'état
            // sain doit rester le plus silencieux de l'écran.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .opacity(verdict.level == .alert || verdict.level == .warning ? 1 : 0)
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Le symbole dit la NATURE du verdict — la couleur ne porte
                // jamais le sens à elle seule.
                Image(systemName: verdict.symbol)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 22)
                    // Le niveau, que seuls la couleur et le symbole disaient :
                    // VoiceOver l'énonce avant la phrase, avec les mots de la
                    // barre de menus (chantier 16). Muet quand tout va bien.
                    .accessibilityLabel(Self.spokenLevel(verdict.level))
                    .accessibilityHidden(Self.spokenLevel(verdict.level).isEmpty)
                    .accessibilitySortPriority(5)

                VerdictLines(advice: advice, stacked: Layout.columnCount(store.settings) == 1) {
                    // Deux lignes plutôt qu'une phrase coupée : sur une
                    // colonne, « La mémoire commence à man… » (chantier 16).
                    // Sur deux, elle tient toujours sur une.
                    Text(verdict.phrase)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                } evidence: {
                    // Texte `.secondary` et non teinté : une teinte de
                    // `Palette` est mesurée à 3:1, pas aux 4,5:1 du texte.
                    evidenceLine(verdict.also.isEmpty
                                 ? verdict.evidence
                                 : verdict.evidence + "  ·  et aussi : " + verdict.also.joined(separator: ", "))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 8)
        }
        .animation(Motion.value, value: verdict)
        // `.combine` : la phrase et la preuve lues d'un trait. En `.ignore`,
        // relevé à l'arbre d'accessibilité, le bandeau sortait en AXUnknown.
        // Avec un conseil, `.contain` : son bouton reste un bouton.
        .accessibilityElement(children: advice == nil ? .combine : .contain)
        // Un verdict qui change sous les yeux se dit, sans attendre qu'on
        // revienne au bandeau (HIG VoiceOver, « Inform VoiceOver when
        // visible content or layout changes occur »). Rare : il tient 5 min.
        // La phrase ET le niveau : « Ssd 2 plein vers lundi » garde sa phrase
        // en passant d'avertissement à alerte.
        .onChange(of: "\(verdict.level.rawValue) \(verdict.phrase)") { _, _ in
            let level = Self.spokenLevel(verdict.level)
            AccessibilityNotification.Announcement(level.isEmpty ? verdict.phrase : "\(level) : \(verdict.phrase)").post()
        }
    }

    /// Le niveau du verdict en mots, comme la barre de menus : vide quand
    /// rien ne demande l'attention.
    static func spokenLevel(_ level: VerdictLevel) -> String {
        switch level {
        case .alert: return "Alerte"
        case .warning: return "Attention"
        case .data, .muted: return ""
        }
    }

    /// Chiffres nets : plus de transition numérique. Rejouée à chaque relevé,
    /// elle laissait un chiffre à moitié effacé sur les captures (« 3 1 % »),
    /// et le HIG déconseille le mouvement sur ce qui change souvent.
    private func evidenceLine(_ text: String) -> some View {
        // Deux lignes au plus : coupée en bout, la preuve perdait d'abord
        // « et aussi », le second problème (chantier 16).
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
    }

    /// Le niveau du verdict, traduit en teinte mesurée — ici et nulle part
    /// ailleurs (règle dure n°4).
    private func tint(for level: VerdictLevel) -> Color {
        switch level {
        case .alert:   return Palette.alert
        case .warning: return Palette.warning
        case .data:    return Palette.data
        case .muted:   return Palette.muted
        }
    }

    // MARK: - Pied

    /// La fenêtre Réglages, à côté de Quitter comme chez iStat. Même dessin
    /// que les raccourcis de gauche : 26 pt de côté, au-dessus des 20 pt du
    /// HIG. ⌘, comme partout sur Mac.
    private var settingsButton: some View {
        Button {
            (NSApp.delegate as? AppDelegate)?.openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pulseIcon)
        .keyboardShortcut(",", modifiers: .command)
        .help("Réglages de Pulse")
        .accessibilityLabel("Réglages de Pulse")
    }

    /// Le même dessin que les raccourcis, en mot : le bouton de verre qu'il
    /// était ne se distinguait plus une fois tout le cadre en verre
    /// (chantier 10), et `--snapshot` ne savait pas le dessiner.
    private var quitButton: some View {
        Button { NSApplication.shared.terminate(nil) } label: {
            Text("Quitter")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pulseIcon)
        .keyboardShortcut("q", modifiers: .command)
        .help("Quitter Pulse")
        .accessibilityLabel("Quitter")
    }
}

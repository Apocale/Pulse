import SwiftUI
import AppKit

/// Les lignes du bandeau du verdict, conseil compris.
///
/// Le panneau fait 1 216 pt sur les 1 290 de l'écran d'Isma : le conseil
/// n'ajoute AUCUNE ligne. La phrase est courte (30 caractères au plus) et
/// laisse libre la moitié droite de sa ligne : le conseil s'y loge, et le
/// bouton se range sous lui, au bout de la ligne de preuve. Une grille aligne
/// les lignes de base des deux colonnes. Sur une seule colonne, la place
/// manque : le conseil passe sur une troisième ligne, la seule exception.
///
/// Le détail du conseil — les chiffres et le calcul — est dans l'infobulle,
/// comme dans `--probe` (section CONSEIL).
struct VerdictLines<Phrase: View, Evidence: View>: View {
    let advice: Advice?
    /// Une seule colonne de cartes : le bandeau fait 296 pt de large.
    let stacked: Bool
    @ViewBuilder let phrase: Phrase
    @ViewBuilder let evidence: Evidence

    var body: some View {
        if let advice {
            if stacked {
                // Une colonne, 296 pt : le bouton au bout de la preuve comme
                // à deux colonnes, le conseil seul sur la troisième ligne,
                // toute la largeur pour lui.
                VStack(alignment: .leading, spacing: 2) {
                    phrase.accessibilitySortPriority(4)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        evidence
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilitySortPriority(3)
                        if let action = advice.action { AdviceButton(action: action, detail: advice.detail) }
                    }
                    AdviceText(advice: advice, alignment: .leading, lines: 2)
                }
            } else {
                // Deux lignes partagées chacune de leur côté : la phrase prend
                // sa largeur et le conseil le reste ; le bouton prend la
                // sienne et la preuve le reste. Une grille partagerait UNE
                // largeur de colonne entre la phrase et la preuve, et la
                // preuve, plus longue, pousserait le conseil hors du bandeau.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        // La phrase ne se coupe jamais (bloc 0) : le conseil
                        // cède la place, pas elle.
                        phrase
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilitySortPriority(4)
                        AdviceText(advice: advice)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        evidence
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilitySortPriority(3)
                        if let action = advice.action {
                            AdviceButton(action: action, detail: advice.detail)
                        }
                    }
                }
            }
        } else {
            // Sans conseil, le bandeau d'avant, au pixel près.
            VStack(alignment: .leading, spacing: 2) {
                phrase
                evidence
            }
        }
    }
}

/// La ligne de conseil : texte principal, pas une teinte — une teinte de
/// `Palette` est mesurée à 3:1, le texte en exige 4,5 (règle dure n° 6).
private struct AdviceText: View {
    let advice: Advice
    var alignment: Alignment = .trailing
    /// Sur une colonne, deux lignes : « Déplacer 41 Go vers Extreme Pro
    /// (719 Go l… » perdait la fin du conseil (chantier 16).
    var lines = 1

    var body: some View {
        Text(advice.text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(lines)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
            .help(advice.detail)
            .accessibilityLabel("Conseil : \(advice.text)")
            .accessibilityHint(advice.detail)
            .accessibilitySortPriority(2)
    }
}

/// Le bouton du conseil, dessiné comme « Régler le forfait iPhone » et
/// « 7 derniers jours » : un libellé `.secondary` et un chevron. La couleur
/// de lien du système tombe à 4,08:1 sur le fond sombre (README), sous les
/// 4,5:1 du texte ; l'accent d'Isma, à 1,37:1 en jaune.
///
/// Il n'agit qu'au clic d'Isma : ni `--snapshot`, ni `--probe`, ni les tests
/// n'appellent `perform`.
struct AdviceButton: View {
    let action: AdviceAction
    let detail: String

    var body: some View {
        Button {
            action.perform()
        } label: {
            // Le chevron DANS le texte : posé sur sa ligne de base, il ne
            // grandit pas la ligne. Une `Image` à côté l'allongeait d'un
            // point (mesuré sur le rendu), et le bandeau n'en a aucun à céder.
            Text("\(action.label) \(Image(systemName: "chevron.forward"))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                // Tout le libellé répond au clic, pas seulement ses pixels.
                .contentShape(Rectangle())
        }
        .buttonStyle(.pulseIcon)
        .help("\(action.spoken)\n\(detail)")
        .accessibilityLabel(action.spoken)
        .accessibilitySortPriority(1)
    }
}

extension AdviceAction {
    /// Le geste, au clic seulement. Une fenêtre s'ouvre ; rien ne se ferme,
    /// rien ne s'efface.
    @MainActor
    func perform() {
        let workspace = NSWorkspace.shared
        switch self {
        case .finder(let path, _):
            // Une fenêtre du Finder posée sur le volume, explicitement le
            // Finder : `open` sur un dossier passerait par l'app associée.
            workspace.selectFile(nil, inFileViewerRootedAtPath: path)
        case .activityMonitor:
            if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .storageSettings:
            // Réglages Système › Général › Stockage : l'extension
            // `com.apple.settings.Storage`, vérifiée dans
            // /System/Library/ExtensionKit/Extensions/Storage.appex (11/10).
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                workspace.open(url)
            }
        }
    }
}

extension Sampler {
    /// Les relevés du barème tels que le panneau les a sous les yeux, pour le
    /// conseil : rien n'est mesuré de plus, tout est déjà publié.
    @MainActor
    var adviceInput: VerdictInput {
        VerdictInput(memory: memory, cpu: cpu, volumes: volumes, forecasts: forecasts,
                     volumeAges: [:], incidents: incidents, processes: processes,
                     export: export, series: series)
    }
}

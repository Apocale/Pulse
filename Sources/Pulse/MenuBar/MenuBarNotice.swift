import SwiftUI

/// Dans le panneau, sous le verdict : l'icône de Pulse est cachée dans la
/// barre de menus. Vérifié à chaque ouverture (`MenuBarController.visibility`)
/// — c'est le moment où l'on s'en aperçoit, panneau ouvert au raccourci ⌃⌥M
/// faute d'icône où cliquer. Rien quand tout se voit.
///
/// Le texte reste `.secondary` (règle dure n°6) ; le symbole dit la nature
/// de la ligne, sans couleur.
struct MenuBarNotice: View {
    /// La largeur des colonnes du panneau : le texte s'y replie au lieu
    /// d'élargir le panneau.
    var width: CGFloat
    @ObservedObject var status: MenuBarStatus = .shared

    /// `--snapshot x.png --barre-cachee` : la ligne telle qu'elle s'affiche,
    /// pour la regarder sans cacher l'icône d'Isma.
    private var hidden: [String] {
        if !Persistence.enabled, CommandLine.arguments.contains("--barre-cachee") { return ["Pulse"] }
        return status.hidden
    }

    /// « L'icône de Pulse est cachée… », ou, un élément par segment,
    /// « 2 icônes de Pulse cachées : Mémoire, Débit internet ». Le détail —
    /// derrière l'encoche, ou pas dessinée — est dans `--probe`.
    private var title: String {
        if hidden == ["Pulse"] { return "L'icône de Pulse est cachée dans la barre de menus" }
        let plural = hidden.count > 1 ? "s" : ""
        return "\(hidden.count) icône\(plural) de Pulse cachée\(plural) : " + hidden.joined(separator: ", ")
    }

    var body: some View {
        if !hidden.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text("Barre pleine à droite de l'encoche, ou Pulse décoché dans Réglages Système › Barre de menus : retirez une icône, ou ⌘-glissez Pulse vers la droite.")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .frame(width: width, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

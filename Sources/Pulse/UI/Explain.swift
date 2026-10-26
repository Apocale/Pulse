import SwiftUI

/// Ce qu'on montre quand l'utilisateur déplie une statistique.
///
/// Trois champs, dans l'ordre où on en a besoin : ce que le chiffre mesure,
/// comment le lire quand on monte, et le malentendu le plus probable. Le
/// dernier est facultatif — toutes les mesures n'ont pas de piège.
struct Explanation {
    var mesure: String
    var lecture: String
    var piege: String = ""
}

/// Triangle de divulgation.
///
/// HIG, « Disclosure controls » : *A disclosure triangle points inward from
/// the leading edge when its content is hidden and down when its content is
/// visible.* Un triangle et non un bouton de divulgation : le HIG limite ces
/// derniers à un seul par vue, alors que les triangles peuvent être multiples
/// — le Finder en aligne des dizaines dans une même liste.
struct DisclosureChevron: View {
    var open: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            // `.secondary` et non `.tertiary` : seul signe qu'une ligne se
            // déplie, le chevron tombait sous les 3:1 des objets graphiques
            // (1,9:1 en clair, mesuré au chantier 16 ; HIG Accessibility,
            // « Strive to meet color contrast minimum standards »).
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(open ? 90 : 0))
            .animation(Motion.value, value: open)
            // Le libellé parlant est porté par la zone cliquable entière,
            // pas par le chevron : VoiceOver annoncerait sinon deux fois.
            .accessibilityHidden(true)
    }
}

/// Le panneau déplié : un graphique, et une ligne pour dire ce qu'on regarde.
///
/// Il a d'abord affiché trois paragraphes. L'utilisateur a tranché : « je veux
/// pas de texte mais par exemple un graph, quelque chose de visuel ». La donnée
/// a donc pris la place de la prose — et Pulse en collectait déjà beaucoup
/// qu'il ne montrait nulle part : l'historique processeur et GPU des 60
/// dernières minutes, trente jours d'espace libre par volume, les pics mémoire
/// de chaque session.
///
/// Les explications vérifiées ne sont pas perdues pour autant : elles passent
/// en infobulle. Rien à l'écran tant qu'on ne s'y attarde pas, et le détail
/// reste à portée de curseur.
///
/// Fond sobre et opaque, pas de verre : ce bloc porte un graphique, et le verre
/// le ferait concurrencer les tuiles qui portent les chiffres.
struct DetailPanel<Chart: View>: View {
    var legende: String
    var detail: Explanation?
    @ViewBuilder var chart: () -> Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            chart()
            Text(legende)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
        .help(detail.map { [$0.mesure, $0.lecture, $0.piege]
                .filter { !$0.isEmpty }.joined(separator: "\n\n") } ?? "")
    }
}

/// Rend un bloc dépliable : le contenu devient cliquable, l'explication
/// apparaît dessous.
///
/// HIG : *Place controls that people are most likely to use at the top of the
/// disclosure hierarchy so they're always visible, with more advanced
/// functionality hidden by default.* Les chiffres restent donc toujours
/// visibles ; seule leur explication se replie.
///
/// `.buttonStyle(.plain)` : un bouton système repeindrait son propre fond
/// par-dessus la ligne.
struct Explainable<Content: View>: View {
    var key: String
    /// Ce que le contrôle révèle, AVEC sa préposition : « de la mémoire »,
    /// « du swap », « des cœurs ». Le gabarit « Déplier le détail de \(label) »
    /// faisait dire à VoiceOver « de le swap » et « de les cœurs ».
    var label: String
    /// Le nom et la valeur que VoiceOver énonce pour ce bouton, posés sur le
    /// bouton lui-même plutôt que déduits de son contenu : on choisit ce qui
    /// est dit (« incidents sur 14 jours », pas « incidents point 14 jours »),
    /// et la valeur peut en dire plus que la colonne D (« 21,9 Gio sur 32
    /// Gio »). Vérifié à l'API d'accessibilité : les neuf lignes portent leur
    /// nom et leur valeur.
    ///
    /// Piège pour qui vérifie : sur macOS 26, SwiftUI range ce nom dans
    /// `AXAttributedDescription`, une chaîne enrichie que System Events ne
    /// sait pas lire. Interrogé par `osascript`, le bouton paraît anonyme
    /// alors qu'il ne l'est pas. Lire l'arbre avec AXUIElementCopyAttributeValue.
    var spokenName: String
    var spokenValue: String = ""
    @Binding var open: String?
    @ViewBuilder var content: () -> Content

    private var isOpen: Bool { open == key }

    var body: some View {
        Button {
            // Sans `withAnimation`, volontairement.
            //
            // `NSHostingController.sizingOptions = [.preferredContentSize]`
            // remonte la taille IDÉALE du contenu, pas sa taille animée : la
            // fenêtre du popover reçoit donc la valeur finale immédiatement.
            // Mesuré à l'accessibilité, la hauteur passe de 1129 à 1069 en une
            // seule frame, identique sur les 40 relevés suivants.
            //
            // Animer le contenu par-dessus ne produisait pas une transition
            // mais un décalage : la fenêtre sautait à sa taille finale pendant
            // que le contenu glissait encore sur 0,4 s. Faute de pouvoir animer
            // la fenêtre — `NSPopover.animates` ne gouverne que l'apparition et
            // la fermeture, vérifié par la même mesure —, les deux changent
            // ensemble. Seul le chevron garde son ressort : il ne touche pas à
            // la mise en page, donc il n'entre en concurrence avec rien.
            open = isOpen ? nil : key
        } label: {
            content()
                // Sans forme explicite, SwiftUI ne teste le clic que sur les
                // pixels réellement dessinés : l'espace entre le nom et la
                // valeur ne répondait pas, et il fallait retomber pile sur le
                // texte. Mesuré à l'époque des en-têtes de section, 13 pt de
                // haut — c'était la cause des « trois clics ». Toute ligne est
                // désormais cliquable sur ses 332 pt de large.
                .contentShape(Rectangle())
        }
        // Voile au survol, resserrement à l'appui (chantier 10) : un
        // style à nous, qui ne repeint rien sous la ligne au repos.
        .buttonStyle(.pulseRow)
        .accessibilityLabel(spokenName)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Replier le détail \(label)"
                                  : "Déplier le détail \(label)")
    }
}

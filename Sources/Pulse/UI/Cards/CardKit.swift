import SwiftUI

// Ce que les cartes du socle partagent : l'historique dépliable, un seul
// ouvert à la fois dans tout le panneau, et la dernière heure de série.
//
// Les pièces de dessin (`Card`, `CardTitle`, anneaux, barres, lignes) sont
// dans `UI/Cartes.swift`, inchangées : toute carte, celle d'un chantier
// comprise, s'en sert pour ressembler aux autres.

/// Une zone cliquable qui ouvre ou ferme l'historique `key`. Les historiques
/// des anciens dépliants s'ouvrent depuis le titre ou une ligne de leur
/// carte ; un seul à la fois dans tout le panneau.
struct HistoryToggle<Content: View>: View {
    let key: String
    /// Ce que le contrôle révèle, avec sa préposition (« des volumes »).
    let label: String
    /// Ce que VoiceOver énonce pour ce bouton : le nom de la carte ou de la
    /// ligne, tel qu'il est écrit (« Processeur », « Temps d'écran »).
    let spoken: String
    /// Le chiffre que la zone affiche (« 40 % », « 3 h 09 »). Le libellé
    /// posé sur le bouton remplace son contenu pour VoiceOver : sans cette
    /// valeur, le chiffre de tête d'une carte n'était jamais dit
    /// (chantier 16).
    var value: String = ""
    /// Le titre d'une carte : rangé parmi les titres, VoiceOver saute de
    /// carte en carte (rotor « Titres »).
    var heading = false
    @Binding var open: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Explainable(key: key, label: label, spokenName: spoken, spokenValue: value, open: $open) {
            content().padding(.vertical, 1)
        }
        .accessibilityAddTraits(heading ? .isHeader : [])
    }
}

/// L'historique `key`, s'il est ouvert : le graphique, sa légende, et
/// l'explication vérifiée en infobulle.
struct HistoryPanel<Chart: View>: View {
    let key: String
    let open: String?
    @ViewBuilder var chart: () -> Chart

    var body: some View {
        if open == key {
            DetailPanel(legende: Legendes.all[key] ?? "", detail: Explanations.all[key]) {
                chart()
            }
        }
    }
}

enum CardKit {
    /// La dernière heure de la série, recoupée sur le dernier point : au
    /// réveil, la série porte encore des points plus vieux que l'heure.
    static func recentSeries(_ points: [SeriesPoint]) -> [SeriesPoint] {
        guard let last = points.last else { return [] }
        return points.filter { $0.t >= last.t - 3600 }
    }
}

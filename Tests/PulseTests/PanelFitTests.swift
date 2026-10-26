import Foundation
import Testing
@testable import Pulse

/// Le panneau ne dépasse jamais l'écran : les colonnes trop hautes
/// débordent dans une colonne de plus (`PanelFit.arrange`).
@Suite struct PanelFitTests {
    /// Quatre cartes : deux à gauche, deux à droite, 10 pt entre deux cartes.
    static let heights: [CGFloat] = [400, 500, 300, 300]
    static let columns = [0, 0, 1, 1]

    static func arrange(budget: CGFloat?, heights: [CGFloat] = heights, columns: [Int] = columns,
                        count: Int = 2, maxColumns: Int = 6) -> [[Int]] {
        PanelFit.arrange(heights: heights, columns: columns, count: count, spacing: 10,
                         budget: budget, maxColumns: maxColumns)
    }

    /// Tout tient : la disposition réglée, à l'identique — c'est ce qui garde
    /// le rendu au pixel près.
    @Test func quandToutTientRienNeBouge() {
        #expect(Self.arrange(budget: nil) == [[0, 1], [2, 3]])
        #expect(Self.arrange(budget: 910) == [[0, 1], [2, 3]])
    }

    /// La colonne de gauche dépasse (910 pt pour 900) : sa dernière carte
    /// passe dans une colonne de plus ; la droite ne bouge pas.
    @Test func laDerniereCarteDeLaColonneTropHautePasseADroite() {
        #expect(Self.arrange(budget: 900) == [[0], [2, 3], [1]])
    }

    /// Les deux colonnes dépassent : la nouvelle colonne reçoit leurs
    /// dernières cartes dans l'ordre de lecture, gauche d'abord.
    @Test func lOrdreDeLectureEstGarde() {
        #expect(Self.arrange(budget: 500, heights: [400, 200, 300, 250]) == [[0], [2], [1, 3]])
    }

    /// La colonne ajoutée dépasse à son tour : une autre encore.
    @Test func autantDeColonnesQuIlEnFaut() {
        let arranged = Self.arrange(budget: 450, heights: [400, 400, 400, 400], columns: [0, 0, 0, 0], count: 1)
        #expect(arranged == [[0], [1], [2], [3]])
    }

    /// Pas plus de colonnes que la largeur de l'écran n'en permet.
    @Test func laLargeurBorneLeNombreDeColonnes() {
        let arranged = Self.arrange(budget: 450, heights: [400, 400, 400, 400], columns: [0, 0, 0, 0],
                                    count: 1, maxColumns: 2)
        #expect(arranged.count == 2)
        #expect(arranged.flatMap { $0 }.sorted() == [0, 1, 2, 3])
    }

    /// Une carte seule plus haute que l'écran reste où elle est, sans
    /// colonne vide ajoutée pour rien.
    @Test func uneCarteSeuleTropHauteNeFaitRienBouger() {
        #expect(Self.arrange(budget: 100, heights: [400], columns: [0], count: 1) == [[0]])
        #expect(Self.arrange(budget: 350, heights: [400, 100], columns: [0, 1]) == [[0], [1]])
    }

    /// Trois colonnes réglées dont la dernière vide : elle reçoit le
    /// débordement avant qu'on en ajoute une quatrième.
    @Test func uneColonneVideADroiteSertDAbord() {
        #expect(Self.arrange(budget: 900, count: 3) == [[0], [2, 3], [1]])
    }

    /// Le cas de la coordination : la colonne Processeur + Réseau (forfait)
    /// + Énergie trop haute de quelques points ; Énergie passe à droite.
    @Test func leCasDuForfait() {
        let arranged = Self.arrange(budget: 1100, heights: [560, 530, 450, 300, 330, 200, 0],
                                    columns: [0, 0, 0, 1, 1, 1, 1])
        #expect(arranged == [[0, 1], [3, 4, 5, 6], [2]])
    }

    @Test func colonnesPermisesParLaLargeur() {
        // 2 056 pt visibles moins la flèche : six colonnes de 296 pt.
        #expect(PanelFit.maxColumns(width: 2040, columnWidth: 296, spacing: 10) == 6)
        #expect(PanelFit.maxColumns(width: 632, columnWidth: 296, spacing: 10) == 2)
        #expect(PanelFit.maxColumns(width: 300, columnWidth: 296, spacing: 10) == 1)
    }

    @Test func placeLaisseeParLEcran() {
        let limits = PanelLimits.screenSized(width: 2056, height: 1290)
        #expect(limits.height == 1274)
        #expect(limits.width == 2040)
    }

    /// La variante équilibrée (décision d'Isma, `--equilibre`) : le relevé
    /// figé avec Médias — Processeur, Réseau, Énergie, Médias | Mémoire,
    /// Disques, Montage, Capteurs — tient dans les mêmes trois colonnes,
    /// Capteurs rejoignant Énergie et Médias, la plus haute 905 pt au lieu
    /// de 1 126.
    @Test func laVarianteEquilibreeGardeLesColonnesEtRaccourcit() {
        let heights: [CGFloat] = [360, 518, 293, 181, 327, 223, 135, 411]
        let columns = [0, 0, 0, 0, 1, 1, 1, 1]
        let base = PanelFit.arrange(heights: heights, columns: columns, count: 2, spacing: 10,
                                    budget: 1140, maxColumns: 6)
        let balanced = PanelFit.arrangeBalanced(heights: heights, columns: columns, count: 2, spacing: 10,
                                                budget: 1140, maxColumns: 6)
        #expect(base == [[0, 1], [4, 5, 6, 7], [2, 3]])
        #expect(balanced == [[0, 1], [4, 5, 6], [2, 3, 7]])
    }

    /// Un 14 pouces en « texte plus grand » (1 352 × 771 pt, 26/10) : les
    /// sept cartes du relevé figé, 655 pt de budget, quatre colonnes au plus.
    /// `arrange` empile le débordement dans la dernière (859 pt) ; rangées au
    /// plus serré, elles tiennent (644 pt), Processeur en tête.
    @Test func unPetitEcranRangeLesCartesAuPlusSerre() {
        let heights: [CGFloat] = [360, 518, 293, 327, 223, 135, 411]
        let columns = [0, 0, 0, 1, 1, 1, 1]
        let base = PanelFit.arrange(heights: heights, columns: columns, count: 2, spacing: 10,
                                    budget: 655, maxColumns: 4)
        #expect(PanelFit.tallest(base, heights: heights, spacing: 10) == 859)
        let fitted = PanelFit.arrangeToFit(heights: heights, columns: columns, count: 2, spacing: 10,
                                           budget: 655, maxColumns: 4)
        #expect(fitted == [[0, 5], [1], [2, 3], [4, 6]])
        #expect(PanelFit.tallest(fitted, heights: heights, spacing: 10) == 644)
        // Quand `arrange` tient, rien ne change.
        #expect(PanelFit.arrangeToFit(heights: heights, columns: columns, count: 2, spacing: 10,
                                      budget: 1140, maxColumns: 6)
                == PanelFit.arrange(heights: heights, columns: columns, count: 2, spacing: 10,
                                    budget: 1140, maxColumns: 6))
        // Rien ne tient : jamais plus haut que l'empilement.
        let squeezed = PanelFit.arrangeToFit(heights: heights, columns: columns, count: 2, spacing: 10,
                                             budget: 500, maxColumns: 3)
        #expect(PanelFit.tallest(squeezed, heights: heights, spacing: 10)
                <= PanelFit.tallest(PanelFit.arrange(heights: heights, columns: columns, count: 2, spacing: 10,
                                                     budget: 500, maxColumns: 3), heights: heights, spacing: 10))
        #expect(squeezed.flatMap { $0 }.sorted() == Array(0..<7))
    }

    /// Le dernier recours d'un écran bas (1 147 × 708 pt) : dans une colonne
    /// rangée qui dépasse encore, les cartes passent en compactes de bas en
    /// haut, pas une de plus ; une colonne qui tient ne change pas.
    @Test func leDernierRecoursCompacteDeBasEnHaut() {
        let heights: [CGFloat] = [300, 300, 300]
        let compact: [CGFloat?] = [100, 100, 100]
        #expect(PanelFit.shrink(arranged: [[0, 1, 2]], heights: heights, compactHeights: compact,
                                spacing: 10, budget: 750) == [300, 300, 100])
        #expect(PanelFit.shrink(arranged: [[0], [1, 2]], heights: heights, compactHeights: compact,
                                spacing: 10, budget: 700) == heights)
        #expect(PanelFit.shrink(arranged: [[0, 1, 2]], heights: heights, compactHeights: [nil, nil, nil],
                                spacing: 10, budget: 750) == heights)
    }

    // MARK: - Historique ouvert : compacter le moins possible (chantier 16)

    /// Le cas relevé sur `--ouvert volumes` : Mémoire 327, Disques ouvert
    /// 430, Montage 108, Capteurs 412 pt, pour 1 140 de budget. Compacter
    /// Capteurs seule (171) suffit : Mémoire et Montage restent pleines.
    /// Avant, les trois passaient en compactes.
    @Test func seuleLaCarteDuBasPasseEnCompacte() {
        let kept = PanelFit.shrink(heights: [327, 430, 108, 412], compactHeights: [128, nil, 83, 171],
                                   columns: [1, 1, 1, 1], count: 2, spacing: 10, budget: 1140)
        #expect(kept == [327, 430, 108, 171])
    }

    /// Une seule ne suffit pas : la suivante en remontant, pas davantage.
    @Test func onRemonteTantQueLaColonneDepasse() {
        let kept = PanelFit.shrink(heights: [327, 430, 108, 412], compactHeights: [128, nil, 83, 171],
                                   columns: [1, 1, 1, 1], count: 2, spacing: 10, budget: 1000)
        #expect(kept == [128, 430, 83, 171])
    }

    /// Une colonne qui tient ne change pas, ni sans budget (rendus figés) ;
    /// la carte de l'historique ouvert (nil) ne se compacte jamais.
    @Test func rienNeSeCompacteSansNecessite() {
        let heights: [CGFloat] = [360, 518, 292, 327, 430]
        let compact: [CGFloat?] = [nil, 120, 100, 128, nil]
        let columns = [0, 0, 0, 1, 1]
        #expect(PanelFit.shrink(heights: heights, compactHeights: compact, columns: columns, count: 2,
                                spacing: 10, budget: nil) == heights)
        #expect(PanelFit.shrink(heights: heights, compactHeights: compact, columns: columns, count: 2,
                                spacing: 10, budget: 1200) == heights)
        // Gauche trop haute (1 190 pour 1 100) : Énergie seule, la plus basse.
        #expect(PanelFit.shrink(heights: heights, compactHeights: compact, columns: columns, count: 2,
                                spacing: 10, budget: 1100) == [360, 518, 100, 327, 430])
    }
}

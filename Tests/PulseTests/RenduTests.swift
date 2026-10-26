import Foundation
import AppKit
import Testing
@testable import Pulse

/// Ce sur quoi reposent les comparaisons de `Pulse --rendus` : un relevé figé
/// qui se rend à l'identique, et une comparaison qui voit un seul chiffre
/// changer. Les images elles-mêmes se comparent dans le binaire de l'app,
/// pas ici : le processus des tests résout autrement les couleurs système
/// (voir `Rendu`).
@MainActor
@Suite(.serialized) struct RenduTests {
    /// Un sampler pour toute la suite : sa création relit l'historique.
    static let sampler = Releve.typique.sampler()

    @Test(arguments: Rendu.cartesFigees)
    func uneCarteFigeeSeRendAlIdentique(_ id: String) throws {
        let a = try #require(Rendu.carte(id, sampler: Self.sampler, sombre: true).flatMap(Pixels.init))
        let b = try #require(Rendu.carte(id, sampler: Self.sampler, sombre: true).flatMap(Pixels.init))
        #expect(a == b, "« \(id) » change d'un rendu à l'autre : rien ne peut s'y comparer")
    }

    /// Le seuil de `Rendu` ne doit pas avaler un vrai changement : la carte
    /// processeur avec 69 % de carte graphique au lieu de 68.
    @Test func unChiffreQuiChangeSeVoit() throws {
        var autre = Releve.typique
        autre.gpu = 0.69
        let attendu = try #require(Rendu.carte("processeur", sampler: Self.sampler, sombre: true).flatMap(Pixels.init))
        let rendu = try #require(Rendu.carte("processeur", sampler: autre.sampler(), sombre: true).flatMap(Pixels.init))
        let (differents, pire, carte) = rendu.ecart(avec: attendu, seuil: Rendu.seuilCanal)
        #expect(differents > Rendu.seuilPixels + 50, "\(differents) pixels seulement")
        #expect(pire > 100)
        #expect(carte != nil)
    }

    /// Les cartes qui mesurent elles-mêmes ne se comparent pas, mais elles
    /// doivent se rendre, et tenir dans une colonne.
    @Test func lesCartesVivantesSeRendent() throws {
        for id in ModuleRegistry.ids where !Rendu.cartesFigees.contains(id) {
            let image = try #require(Rendu.carte(id, sampler: Self.sampler, sombre: true), "« \(id) » ne se rend pas")
            // Colonne de 296 pt et 12 pt de marge de chaque côté, à l'échelle 2.
            #expect(image.width == Int((PopoverView.columnWidth + 24) * 2),
                    "« \(id) » déborde de sa colonne : \(image.width / 2) pt")
            #expect(image.height / 2 < 1290, "« \(id) » plus haute que l'écran : \(image.height / 2) pt")
        }
    }

    /// Un rendu d'aspect juste mais plat — tout gris, aucune donnée en
    /// couleur — passerait la comparaison si la référence était fausse elle
    /// aussi. Le bleu des barres et des cœurs performance doit y être.
    @Test func lesDonneesSontEnCouleur() throws {
        let pixels = try #require(Rendu.carte("processeur", sampler: Self.sampler, sombre: true).flatMap(Pixels.init))
        #expect(pixels.compte { r, g, b in b > 200 && r < 80 && g > 100 && g < 180 } > 200)
    }

    // MARK: - La comparaison elle-même

    static func uni(_ valeur: UInt8, cote: Int = 4) -> Pixels {
        Pixels(largeur: cote, hauteur: cote, octets: [UInt8](repeating: valeur, count: cote * cote * 4))
    }

    @Test func deuxImagesIdentiques() {
        let (differents, pire, carte) = Self.uni(100).ecart(avec: Self.uni(100), seuil: 0)
        #expect(differents == 0 && pire == 0 && carte == nil)
    }

    @Test func unArrondiPasseUnVraiEcartNon() {
        // Un niveau d'écart sur tous les pixels : sous le seuil.
        #expect(Self.uni(101).ecart(avec: Self.uni(100), seuil: Rendu.seuilCanal).differents == 0)
        // Un seul pixel franchement différent : vu.
        var octets = Self.uni(100).octets
        octets[20] = 250
        let un = Pixels(largeur: 4, hauteur: 4, octets: octets)
        let (differents, pire, carte) = un.ecart(avec: Self.uni(100), seuil: Rendu.seuilCanal)
        #expect(differents == 1)
        #expect(pire == 150)
        #expect(carte != nil)
    }

    @Test func lAllerRetourParLePNGEstExact() throws {
        let image = try #require(Rendu.carte("memoire", sampler: Self.sampler, sombre: false).flatMap(Pixels.init))
        let png = try #require(image.png())
        let relu = try #require(Pixels(png: png))
        let relu2 = try #require(relu.png().flatMap { Pixels(png: $0) })
        // Le premier passage arrondit peut-être ; le second ne change plus rien.
        #expect(relu == relu2)
    }
}

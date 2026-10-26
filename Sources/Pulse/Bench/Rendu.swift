import SwiftUI
import AppKit

/// `--rendus` : les cartes figées et le panneau, rendus hors écran sur un
/// relevé fixe (`Releve.typique`), en sombre et en clair, et comparés pixel à
/// pixel aux images de `Tests/References`. `--rendus --references` les
/// régénère, après un changement voulu. Rien ne s'ouvre, comme `--snapshot`.
///
/// Dans le binaire de l'app et non dans `swift test` : le processus des tests
/// résout les couleurs système autrement. Relevé le 11/10 : le fond clair du
/// panneau (`windowBackgroundColor`) y rend #FFFEFF, contre #EFEFEF dans
/// l'app — des cartes blanches sur fond blanc. Une référence n'a de valeur
/// que si elle montre ce qu'Isma voit.
@MainActor
enum Rendu {
    /// Les cartes qui savent se dessiner sur un relevé figé (`Releve`) : à
    /// l'identique d'une exécution à l'autre, elles se comparent pixel à
    /// pixel. Énergie, capteurs et réseau mesurent eux-mêmes : `Releve`
    /// fige aussi leurs modules (`PowerSampler(figé:)`, `SensorStore.figer`,
    /// `MoniteurReseau.figer`), et fixe « aujourd'hui » pour le forfait.
    /// Médias (19-suivis) : son état et sa semaine d'exports viennent du
    /// relevé (`Releve.medias`, `ExportHistory(figé:)`), ni journal d'AME
    /// ni exports.json.
    ///
    /// Une carte absente d'ici — un module nouveau — se dessine d'après la
    /// machine du moment : elle est rendue (elle ne doit ni planter ni
    /// déborder) mais pas comparée, jusqu'à ce que `Releve` sache la figer.
    nonisolated static let cartesFigees = ["processeur", "reseau", "memoire", "disques", "montage",
                                           "capteurs", "energie", "medias"]

    /// La tolérance, mesurée le 11/10. Rendu deux fois, le même relevé donne
    /// les mêmes octets. Comparé à sa référence relue, un rendu inchangé s'en
    /// écartait d'un niveau sur 255 au plus, sur 62 à 295 pixels des anneaux :
    /// l'aller-retour par le PNG arrondit certaines teintes. Le rendu passe
    /// donc par le même PNG avant d'être comparé — identique à l'octet. Les
    /// 2 niveaux sont une marge ; aucun pixel de plus : un seul chiffre qui
    /// change (« 68 % » devenu « 69 % ») en déplace 180 de 190 niveaux et plus.
    nonisolated static let seuilCanal = 2
    nonisolated static let seuilPixels = 0

    // MARK: - --rendus

    struct Resultat {
        var nom: String
        /// nil : identique, à la tolérance près.
        var probleme: String?
    }

    static func run(regenerer: Bool) {
        let racine = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let references = racine.appendingPathComponent("Tests/References")
        let sorties = racine.appendingPathComponent(".build/rendus")
        guard regenerer || FileManager.default.fileExists(atPath: references.path) else {
            FileHandle.standardError.write(Data("pas de Tests/References ici : lancer depuis la racine du dépôt\n".utf8))
            exit(2)
        }
        try? FileManager.default.createDirectory(at: sorties, withIntermediateDirectories: true)
        if regenerer { try? FileManager.default.createDirectory(at: references, withIntermediateDirectories: true) }

        let releve = Releve.typique
        let sampler = releve.sampler()
        var resultats: [Resultat] = []
        func traite(_ image: CGImage?, _ nom: String) {
            resultats.append(compare(image, nom: nom, references: references, sorties: sorties, regenerer: regenerer))
        }
        for id in cartesFigees {
            for sombre in [true, false] {
                traite(carte(id, sampler: sampler, sombre: sombre, settings: releve.reglages),
                       "carte-\(id)-\(sombre ? "sombre" : "clair")")
            }
        }
        let store = reglagesFiges(releve.reglages)
        for sombre in [true, false] {
            traite(panneau(sampler: sampler, store: store, sombre: sombre), "panneau-\(sombre ? "sombre" : "clair")")
        }

        // Les cartes vivantes : rendues, jamais comparées.
        var vivantes: [String] = []
        for id in ModuleRegistry.ids where !cartesFigees.contains(id) {
            guard let image = carte(id, sampler: sampler, sombre: true) else {
                resultats.append(Resultat(nom: "carte-\(id)", probleme: "ne se rend pas"))
                continue
            }
            if image.height / 2 >= 1290 {
                resultats.append(Resultat(nom: "carte-\(id)", probleme: "\(image.height / 2) pt de haut, plus que l'écran"))
            }
            try? Pixels(image)?.png()?.write(to: sorties.appendingPathComponent("vivante-\(id)-sombre.png"))
            vivantes.append(id)
        }

        let problemes = resultats.filter { $0.probleme != nil }
        for r in resultats {
            print(r.probleme.map { "ÉCHEC   \(r.nom) : \($0)" } ?? "ok      \(r.nom)\(regenerer ? " (référence écrite)" : "")")
        }
        if !vivantes.isEmpty {
            print("rendues sans comparaison (elles mesurent la machine) : \(vivantes.joined(separator: ", "))")
        }
        print("mesure rendus=\(resultats.count) ecarts=\(problemes.count) vivantes=\(vivantes.count)")
        exit(problemes.isEmpty ? 0 : 1)
    }

    /// Compare un rendu à sa référence, après le même passage par le PNG.
    /// Laisse dans `sorties` le rendu, et la carte de l'écart s'il y en a un.
    static func compare(_ image: CGImage?, nom: String, references: URL, sorties: URL,
                        regenerer: Bool) -> Resultat {
        guard let image, let png = Pixels(image)?.png(), let rendu = Pixels(png: png) else {
            return Resultat(nom: nom, probleme: "rendu impossible")
        }
        let sortie = sorties.appendingPathComponent("\(nom).png")
        try? png.write(to: sortie)
        let reference = references.appendingPathComponent("\(nom).png")
        if regenerer {
            do { try png.write(to: reference) } catch {
                return Resultat(nom: nom, probleme: "référence non écrite : \(error.localizedDescription)")
            }
            return Resultat(nom: nom)
        }
        guard let attendu = Pixels(png: reference) else {
            return Resultat(nom: nom, probleme: "pas de référence (\(reference.lastPathComponent)) — nouvelle carte ? ./verifie.sh --references")
        }
        guard attendu.largeur == rendu.largeur, attendu.hauteur == rendu.hauteur else {
            return Resultat(nom: nom, probleme: "\(rendu.largeur) × \(rendu.hauteur) px au lieu de \(attendu.largeur) × \(attendu.hauteur) — rendu : .build/rendus/\(nom).png")
        }
        let (differents, pire, carte) = rendu.ecart(avec: attendu, seuil: seuilCanal)
        guard differents > seuilPixels else { return Resultat(nom: nom) }
        try? carte?.write(to: sorties.appendingPathComponent("\(nom)-ecart.png"))
        return Resultat(nom: nom, probleme: "\(differents) pixels différents, jusqu'à \(pire) niveaux sur 255 — écart en rouge : .build/rendus/\(nom)-ecart.png")
    }

    // MARK: - Les rendus

    /// Une carte seule, à la largeur d'une colonne, sur le fond du panneau :
    /// la même mise en scène que `--snapshot --carte`.
    static func carte(_ id: String, sampler: Sampler, sombre: Bool,
                      settings: PulseSettings = PulseSettings()) -> CGImage? {
        guard let module = ModuleRegistry.module(id) else { return nil }
        let context = CardContext(module: module, sampler: sampler, open: .constant(nil),
                                  settings: settings.module(id), display: settings.display)
        return image(module.card(context)
                        .frame(width: PopoverView.columnWidth)
                        .padding(12)
                        .background(PopoverBackground()),
                     sombre: sombre)
    }

    /// Le panneau entier, verdict et pied compris. À l'échelle 1 : il vérifie
    /// l'assemblage — colonnes, verdict, pied —, les cartes ont leurs propres
    /// références au détail. Quatre fois moins de pixels, et 125 ko par
    /// régénération au lieu de 300.
    static func panneau(sampler: Sampler, store: SettingsStore, sombre: Bool, echelle: CGFloat = 1) -> CGImage? {
        image(PopoverView(sampler: sampler, store: store), sombre: sombre, echelle: echelle)
    }

    /// Des réglages où seules les cartes figées sont affichées : le panneau
    /// entier se compare alors lui aussi. Jamais écrits (`writes: false`), et
    /// lus d'un fichier qui n'existe pas : les réglages par défaut.
    static func reglagesFiges(_ base: PulseSettings = PulseSettings()) -> SettingsStore {
        let store = SettingsStore(url: URL(fileURLWithPath: "/dev/null/pulse-reglages-figes.json"), writes: false)
        store.settings = base
        for id in ModuleRegistry.ids where !cartesFigees.contains(id) {
            store.settings.modules[id] = ModuleSettings(enabled: false)
        }
        return store
    }

    static func image(_ view: some View, sombre: Bool, echelle: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, sombre ? .dark : .light))
        renderer.scale = echelle
        var image: CGImage?
        // Les couleurs AppKit se résolvent sur l'apparence de dessin courante,
        // pas sur l'environnement SwiftUI (voir `Snapshot`).
        NSAppearance(named: sombre ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        return image
    }
}

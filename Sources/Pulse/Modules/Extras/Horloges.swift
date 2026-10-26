import SwiftUI

/// Une personne suivie : son nom et sa ville.
struct Personne: Equatable, Hashable {
    var nom: String
    /// Clé de `Villes` (« montreal »), ou identifiant IANA écrit à la main.
    var lieu: String

    var ville: Ville? { Villes.ville(lieu) }
    /// Le nom, ou celui de la ville si Isma n'en a pas donné.
    var affiche: String {
        let n = nom.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (ville?.nom ?? lieu) : n
    }
}

/// Les réglages des horloges, rangés avec ceux des autres modules dans
/// `reglages.json` (`modules.horloges.options`).
///
/// Les personnes tiennent dans UN texte, une par ligne, « Nom = ville » :
/// lisible et réparable à la main dans le fichier. Relu de façon tolérante
/// (règle dure n°2) : une ligne illisible ou une ville inconnue est sautée
/// sans emporter les autres.
struct ReglagesHorloges: Equatable {
    static let module = "horloges"
    static let maximum = 8

    var personnes: [Personne] = []
    /// La ville d'ici, pour le soleil (« auto » : selon le fuseau du Mac).
    var ville = "auto"
    var soleil = true

    init(personnes: [Personne] = [], ville: String = "auto", soleil: Bool = true) {
        self.personnes = personnes
        self.ville = ville
        self.soleil = soleil
    }

    init(options: [String: OptionValue]) {
        personnes = Self.lire(options["personnes"]?.text ?? "")
        ville = options["ville"]?.text ?? "auto"
        soleil = options["soleil"]?.bool ?? true
    }

    func options(fusionnees avec: [String: OptionValue] = [:]) -> [String: OptionValue] {
        var out = avec
        out["personnes"] = .text(Self.ecrire(personnes))
        out["ville"] = .text(ville)
        out["soleil"] = .bool(soleil)
        return out
    }

    /// « Alex = montreal », une personne par ligne. Sans « = », la ligne
    /// entière est prise pour une ville (« tokyo ») ; une ville inconnue est
    /// sautée ; au-delà de huit, le reste aussi.
    static func lire(_ texte: String) -> [Personne] {
        var out: [Personne] = []
        for ligne in texte.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let brut = String(ligne)
            let (nom, lieu): (String, String)
            if let egal = brut.firstIndex(of: "=") {
                // Le nom tel quel, moins l'espace qu'`ecrire` pose avant
                // « = » : rogné davantage, l'espace qu'Isma tape entre deux
                // mots disparaîtrait sous ses doigts, le champ relisant ceci.
                var avant = String(brut[..<egal])
                if avant.hasSuffix(" ") { avant.removeLast() }
                nom = avant
                lieu = String(brut[brut.index(after: egal)...]).trimmingCharacters(in: .whitespaces)
            } else {
                nom = ""
                lieu = brut.trimmingCharacters(in: .whitespaces)
            }
            guard !lieu.isEmpty, Villes.ville(lieu) != nil else { continue }
            out.append(Personne(nom: nom, lieu: lieu))
            if out.count == maximum { break }
        }
        return out
    }

    static func ecrire(_ personnes: [Personne]) -> String {
        personnes.prefix(maximum).map { p in
            let nom = p.nom.replacingOccurrences(of: "=", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: ",")
            return "\(nom) = \(p.lieu)"
        }.joined(separator: "\n")
    }

    /// Ce que la carte montre sous `--exemple` : des rôles, pas des gens.
    static let exemple = ReglagesHorloges(personnes: [
        Personne(nom: "Client", lieu: "montreal"),
        Personne(nom: "Famille", lieu: "paris"),
        Personne(nom: "Agence", lieu: "dubai"),
        Personne(nom: "", lieu: "tokyo"),
    ])

    /// Les réglages d'Isma, ou ceux d'exemple sous `--exemple`.
    @MainActor
    static func actuels(_ options: [String: OptionValue]? = nil) -> ReglagesHorloges {
        if Extras.exemple { return exemple }
        return ReglagesHorloges(options: options ?? SettingsStore.shared.settings.module(module).options)
    }

    @MainActor
    static func enregistrer(_ reglages: ReglagesHorloges, dans magasin: SettingsStore? = nil) {
        let store = magasin ?? .shared
        var mien = store.settings.module(module)
        mien.options = reglages.options(fusionnees: mien.options)
        store.settings.modules[module] = mien
    }
}

/// Une horloge calculée pour un instant : tout ce que la carte, le segment
/// de barre et `--probe` écrivent, au même endroit.
struct LigneHorloge: Equatable {
    var nom: String
    var ville: Ville
    /// « 02:14 », à l'heure de la ville.
    var heure: String
    /// « demain », « hier » : la date de là-bas n'est pas celle d'ici.
    var jourRelatif: String?
    /// Écart avec ici, en secondes (positif : en avance sur ici).
    var ecartSecondes: Int
    var soleil: Soleil.Journee
    var faitJour: Bool

    static func calcule(nom: String, ville: Ville, ici: TimeZone = .current, maintenant: Date = Date()) -> LigneHorloge {
        let fuseau = ville.timeZone
        var calLa = Calendar(identifier: .gregorian); calLa.timeZone = fuseau
        var calIci = Calendar(identifier: .gregorian); calIci.timeZone = ici
        let la = calLa.dateComponents([.year, .month, .day], from: maintenant)
        let iciJour = calIci.dateComponents([.year, .month, .day], from: maintenant)
        var relatif: String?
        if let a = calIci.date(from: la), let b = calIci.date(from: iciJour), a != b {
            relatif = a > b ? "demain" : "hier"
        }
        let journee = Soleil.journee(maintenant, ville: ville)
        return LigneHorloge(nom: nom, ville: ville, heure: Extras.heure(maintenant, fuseau), jourRelatif: relatif,
                            ecartSecondes: fuseau.secondsFromGMT(for: maintenant) - ici.secondsFromGMT(for: maintenant),
                            soleil: journee, faitJour: journee.fait(jour: maintenant))
    }

    /// « +5 h », « −3 h 30 », « même heure ».
    var ecart: String { Self.ecart(ecartSecondes) }

    static func ecart(_ secondes: Int) -> String {
        guard secondes != 0 else { return "même heure" }
        let signe = secondes > 0 ? "+" : "\u{2212}"
        let minutes = abs(secondes) / 60
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(signe)\(m) min" }
        return m == 0 ? "\(signe)\(h) h" : "\(signe)\(h) h \(String(format: "%02d", m))"
    }

    /// « lever 07:12 · coucher 18:22 », à l'heure de la ville ; « soleil
    /// levé toute la journée » les jours polaires.
    var soleilTexte: String {
        switch soleil.polaire {
        case .jour?: return "soleil levé toute la journée"
        case .nuit?: return "soleil couché toute la journée"
        case nil:
            guard let lever = soleil.lever, let coucher = soleil.coucher else { return "" }
            return "lever \(Extras.heure(lever, ville.timeZone)) · coucher \(Extras.heure(coucher, ville.timeZone))"
        }
    }

    /// Ce que VoiceOver lit : « Client, Montréal, 2 h 14, nuit, 4 h de moins ».
    var parle: String {
        var parts = [nom]
        if nom != ville.nom { parts.append(ville.nom) }
        parts.append(heure.replacingOccurrences(of: ":", with: " h "))
        if let jourRelatif { parts.append(jourRelatif) }
        parts.append(faitJour ? "jour" : "nuit")
        if ecartSecondes != 0 {
            parts.append(ecart.replacingOccurrences(of: "\u{2212}", with: "moins ").replacingOccurrences(of: "+", with: "plus "))
        }
        return parts.joined(separator: ", ")
    }
}

/// Les horloges du monde, chantier 18 : l'heure des personnes qu'Isma suit,
/// nommées, et le lever et le coucher du soleil, ici et chez elles. Tout est
/// calculé sur le Mac : ni réseau, ni autorisation.
struct HorlogesModule: PulseModule {
    let id = ReglagesHorloges.module
    let name = "Horloges"
    let symbol = "globe.europe.africa"
    var summary: String {
        "L'heure des personnes suivies, chacune nommée, et le lever et le coucher du soleil, ici et chez elles. Calculé sur le Mac : rien ne sort."
    }
    var enabledByDefault: Bool { false }
    var defaultColumn: Int { 1 }

    /// Aucune minuterie : la carte se redessine chaque minute (`TimelineView`)
    /// tant qu'elle est à l'écran, c'est-à-dire panneau ouvert seulement.
    /// Mesure d'un calcul complet (huit horloges, soleil compris) dans
    /// `ExtrasTests` : voir `docs/chantiers/18-extras.md`.
    var cost: ModuleCost {
        ModuleCost(closed: 0, open: 0.0001,
                   note: "horloges : rien panneau fermé ; ouvert, un calcul par minute, 0,1 ms pour huit horloges (11/10)")
    }

    var options: [ModuleOption] {
        [ModuleOption(id: "ville", label: "Ville d'ici",
                      help: "Pour le lever et le coucher du soleil ici. Aucune localisation n'est demandée au Mac.",
                      kind: .choice(Villes.choix(), default: "auto")),
         ModuleOption(id: "soleil", label: "Lever et coucher du soleil",
                      help: "Calculés sur le Mac, pour ici et pour chaque personne.",
                      kind: .toggle(default: true))]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(CarteHorloges(reglages: ReglagesHorloges.actuels(context.settings.options), compact: context.compact))
    }

    /// La première personne : « CLIENT » sur « 02:14 ». Personne : rien.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        guard let premiere = ReglagesHorloges.actuels().personnes.first, let ville = premiere.ville else { return nil }
        let ligne = LigneHorloge.calcule(nom: premiere.affiche, ville: ville)
        return MenuBarSegment(label: String(ligne.nom.uppercased().prefix(6)), value: ligne.heure, spoken: ligne.parle)
    }

    func probeSection() -> ProbeSection? {
        Self.section(ReglagesHorloges.actuels(), affichee: Layout.isEnabled(self, in: SettingsStore.shared.settings))
    }

    static func section(_ reglages: ReglagesHorloges, affichee: Bool, maintenant: Date = Date()) -> ProbeSection {
        var lignes: [String] = []
        lignes.append(affichee ? "carte affichée · calcul sur le Mac, rien ne sort, aucune minuterie panneau fermé"
                               : "carte masquée (désactivée par défaut) : rien ne tourne")
        let ici = TimeZone.current
        if let ville = Villes.choisie(reglages.ville) {
            let l = LigneHorloge.calcule(nom: "ici", ville: ville, ici: ici, maintenant: maintenant)
            var texte = "ici            \(ville.nom) (\(ici.identifier), UTC\(decalage(ici, maintenant))) \(l.heure)"
            if reglages.soleil {
                texte += " · \(l.soleilTexte)"
                if let duree = l.soleil.duree { texte += " · \(Extras.duree(duree)) de jour" }
                texte += l.faitJour ? " · jour" : " · nuit"
            }
            lignes.append(texte)
        } else {
            lignes.append("ici            fuseau \(ici.identifier) hors de la table et de zone.tab : pas de soleil")
        }
        if reglages.personnes.isEmpty {
            lignes.append("aucune personne réglée — Réglages de Pulse › Horloges")
        }
        for p in reglages.personnes {
            guard let ville = p.ville else { continue }
            let l = LigneHorloge.calcule(nom: p.affiche, ville: ville, ici: ici, maintenant: maintenant)
            var texte = "\(l.nom.padding(toLength: 14, withPad: " ", startingAt: 0)) \(ville.nom) (\(ville.fuseau)) \(l.heure)"
            if let r = l.jourRelatif { texte += " \(r)" }
            texte += " · \(l.ecart) · \(l.faitJour ? "jour" : "nuit")"
            if reglages.soleil { texte += " · \(l.soleilTexte)" }
            lignes.append(texte)
        }
        return ProbeSection(title: "HORLOGES · \(reglages.personnes.count) personne\(reglages.personnes.count > 1 ? "s" : "")", lines: lignes)
    }

    private static func decalage(_ fuseau: TimeZone, _ instant: Date) -> String {
        let s = fuseau.secondsFromGMT(for: instant)
        return String(format: "%@%02d:%02d", s < 0 ? "-" : "+", abs(s) / 3600, abs(s) % 3600 / 60)
    }

    func settingsSection(_ store: SettingsStore) -> (title: String, content: AnyView)? {
        ("Personnes", AnyView(EditeurPersonnes(store: store)))
    }
}

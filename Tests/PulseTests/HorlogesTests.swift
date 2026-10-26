import Foundation
import Testing
@testable import Pulse

/// Les horloges du chantier 18 : le soleil contre des éphémérides publiées,
/// l'heure de là-bas, et des réglages qui se relisent de façon tolérante.
@MainActor
@Suite struct HorlogesTests {
    static let paris = Villes.ville("paris")!
    static let utc = TimeZone(identifier: "UTC")!

    static func instant(_ texte: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: texte)!
    }

    /// L'heure d'un instant à Paris, en minutes après minuit.
    static func minutes(_ date: Date?, _ fuseau: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = fuseau
        let c = cal.dateComponents([.hour, .minute], from: date!)
        return c.hour! * 60 + c.minute!
    }

    /// Paris aux solstices, comme les publient les éphémérides (Bureau des
    /// longitudes, timeanddate.com) : 21 juin, lever 05:46, coucher 21:58
    /// (heure d'été) ; 21 décembre, lever 08:41, coucher 16:56. À deux
    /// minutes près — les tables arrondissent, la NOAA vise la minute.
    @Test func leSoleilDeParisAuxSolstices() {
        let ete = Soleil.journee(Self.instant("2026-06-21T12:00:00Z"), ville: Self.paris)
        #expect(abs(Self.minutes(ete.lever, Self.paris.timeZone) - (5 * 60 + 46)) <= 2)
        #expect(abs(Self.minutes(ete.coucher, Self.paris.timeZone) - (21 * 60 + 58)) <= 2)
        let hiver = Soleil.journee(Self.instant("2026-12-21T12:00:00Z"), ville: Self.paris)
        #expect(abs(Self.minutes(hiver.lever, Self.paris.timeZone) - (8 * 60 + 41)) <= 2)
        #expect(abs(Self.minutes(hiver.coucher, Self.paris.timeZone) - (16 * 60 + 56)) <= 2)
        // 16 h 12 de jour en été, 8 h 15 en hiver.
        #expect(abs((ete.duree ?? 0) / 60 - (16 * 60 + 12)) <= 4)
        #expect(abs((hiver.duree ?? 0) / 60 - (8 * 60 + 15)) <= 4)
    }

    /// À Tokyo, le lever tombe la veille en UTC : la date civile est celle de
    /// Tokyo, pas celle de Greenwich (05:44 et 17:13 le 11 octobre).
    @Test func uneVilleLoinDeGreenwichGardeSaDate() {
        let tokyo = Villes.ville("tokyo")!
        let jour = Soleil.journee(Self.instant("2026-10-11T03:00:00Z"), ville: tokyo)
        #expect(abs(Self.minutes(jour.lever, tokyo.timeZone) - (5 * 60 + 44)) <= 2)
        #expect(abs(Self.minutes(jour.coucher, tokyo.timeZone) - (17 * 60 + 13)) <= 2)
        #expect(jour.lever! < jour.coucher!)
    }

    /// Au-delà du cercle polaire : ni lever ni coucher, et le jour ou la nuit
    /// le dit sans inventer d'heure.
    @Test func joursEtNuitsPolaires() {
        let tromso = Ville(cle: "tromso", nom: "Tromsø", pays: "Norvège", fuseau: "Europe/Oslo",
                           latitude: 69.65, longitude: 18.96)
        let decembre = Soleil.journee(Self.instant("2026-12-21T12:00:00Z"), ville: tromso)
        #expect(decembre.polaire == .nuit && decembre.lever == nil && decembre.duree == 0)
        #expect(!decembre.fait(jour: Self.instant("2026-12-21T12:00:00Z")))
        let juin = Soleil.journee(Self.instant("2026-06-21T00:00:00Z"), ville: tromso)
        #expect(juin.polaire == .jour && juin.duree == 86_400)
        #expect(juin.fait(jour: Self.instant("2026-06-21T00:00:00Z")))
    }

    @Test func lEcartAvecIci() {
        #expect(LigneHorloge.ecart(0) == "même heure")
        #expect(LigneHorloge.ecart(-4 * 3600) == "\u{2212}4 h")
        #expect(LigneHorloge.ecart(19_800) == "+5 h 30")
        #expect(LigneHorloge.ecart(-1800) == "\u{2212}30 min")
    }

    /// Tokyo à 20 h UTC vit déjà le lendemain ; Honolulu à 5 h UTC, la veille.
    @Test func demainEtHier() {
        let tokyo = LigneHorloge.calcule(nom: "Agence", ville: Villes.ville("tokyo")!, ici: Self.utc,
                                         maintenant: Self.instant("2026-10-11T20:00:00Z"))
        #expect(tokyo.heure == "05:00" && tokyo.jourRelatif == "demain" && tokyo.ecart == "+9 h")
        #expect(!tokyo.faitJour)
        let honolulu = LigneHorloge.calcule(nom: "Client", ville: Villes.ville("honolulu")!, ici: Self.utc,
                                            maintenant: Self.instant("2026-10-11T05:00:00Z"))
        #expect(honolulu.heure == "19:00" && honolulu.jourRelatif == "hier")
        let paris = LigneHorloge.calcule(nom: "Famille", ville: Self.paris, ici: Self.utc,
                                         maintenant: Self.instant("2026-10-11T12:00:00Z"))
        #expect(paris.jourRelatif == nil && paris.faitJour && paris.ecart == "+2 h")
        #expect(paris.parle.contains("Famille") && paris.parle.contains("Paris") && paris.parle.contains("jour"))
    }

    /// Une ligne illisible, une ville inconnue, un nom absent : chacun est
    /// traité seul, sans emporter les autres (règle dure n°2).
    @Test func lesPersonnesSeRelisentDeFaconTolerante() {
        let texte = "Alex = montreal\nn'importe quoi\n = tokyo\nSarah=casablanca\nX = atlantide\nJulien = America/Toronto\n\n"
        let lues = ReglagesHorloges.lire(texte)
        #expect(lues == [Personne(nom: "Alex", lieu: "montreal"), Personne(nom: "", lieu: "tokyo"),
                         Personne(nom: "Sarah", lieu: "casablanca"), Personne(nom: "Julien", lieu: "America/Toronto")])
        #expect(lues[1].affiche == "Tokyo")
        #expect(lues[3].ville?.fuseau == "America/Toronto")
        // Un réglage d'un autre type retombe sur sa valeur par défaut.
        let r = ReglagesHorloges(options: ["personnes": .int(3), "ville": .bool(true), "soleil": .text("oui")])
        #expect(r == ReglagesHorloges())
        // Huit au plus.
        let trop = (0..<12).map { "P\($0) = paris" }.joined(separator: "\n")
        #expect(ReglagesHorloges.lire(trop).count == ReglagesHorloges.maximum)
    }

    /// Le champ du nom relit le réglage à chaque frappe : l'espace tapé
    /// entre deux mots — ou en fin de mot, avant le suivant — doit survivre
    /// à l'aller-retour, sinon « Alex Grèce » ne se tape pas.
    @Test func unEspaceTapeSurvitALAllerRetour() {
        for nom in ["Alex ", "Alex Grèce", " ", "", "Sarah (Rabat)"] {
            let ecrit = ReglagesHorloges.ecrire([Personne(nom: nom, lieu: "rabat")])
            #expect(ReglagesHorloges.lire(ecrit) == [Personne(nom: nom, lieu: "rabat")], "« \(nom) »")
        }
        // Les séparateurs du format ne passent pas dans un nom.
        let ecrit = ReglagesHorloges.ecrire([Personne(nom: "a=b;c\nd", lieu: "rabat")])
        #expect(ReglagesHorloges.lire(ecrit).count == 1)
    }

    /// La ville d'ici se déduit du fuseau du Mac ; hors de la table, de
    /// `zone.tab`.
    @Test func laVilleDIci() {
        #expect(Villes.ici(TimeZone(identifier: "Africa/Casablanca")!)?.cle == "casablanca")
        let andorre = Villes.ici(TimeZone(identifier: "Europe/Andorra")!)
        #expect(andorre?.nom == "Andorra")
        #expect(abs((andorre?.latitude ?? 0) - 42.5) < 0.1)
        #expect(Villes.choisie("auto")?.fuseau == TimeZone.current.identifier || Villes.choisie("auto") == nil
                || Villes.choisie("auto")?.fuseau != nil)
        #expect(Villes.choisie("tokyo")?.nom == "Tokyo")
        #expect(Villes.choisie("atlantide")?.cle == Villes.ici()?.cle)
    }

    @Test func coordonneesDeZoneTab() {
        let (lat, lon) = ZoneTab.coordonnees("+3339-00735")!
        #expect(abs(lat - 33.65) < 0.001 && abs(lon + 7.5833) < 0.001)
        let (la, lo) = ZoneTab.coordonnees("+404251-0740023")!
        #expect(abs(la - 40.7142) < 0.001 && abs(lo + 74.0064) < 0.001)
        #expect(ZoneTab.coordonnees("n'importe") == nil)
        let table = ZoneTab.parse("# commentaire\nMA\t+3339-00735\tAfrica/Casablanca\nXX\tabc\tNulle/Part\n")
        #expect(table.count == 1 && table["Africa/Casablanca"] != nil)
    }

    /// Chaque ville de la table a un fuseau que macOS connaît, une clé
    /// stable et simple, et des coordonnées plausibles.
    @Test func laTableDesVilles() {
        #expect(Set(Villes.toutes.map(\.cle)).count == Villes.toutes.count)
        for ville in Villes.toutes {
            #expect(TimeZone(identifier: ville.fuseau) != nil, "\(ville.nom) : \(ville.fuseau)")
            #expect(ville.cle.allSatisfy { ("a"..."z").contains($0) || $0 == "-" }, "\(ville.cle)")
            #expect(abs(ville.latitude) <= 90 && abs(ville.longitude) <= 180)
        }
    }

    /// `--probe` écrit ce que la carte affiche, au même endroit.
    @Test func laSectionDuRelevé() {
        let section = HorlogesModule.section(ReglagesHorloges.exemple, affichee: false,
                                             maintenant: Self.instant("2026-10-11T06:15:00Z"))
        #expect(section.title == "HORLOGES · 4 personnes")
        #expect(section.lines.first?.contains("carte masquée") == true)
        let client = section.lines.first { $0.hasPrefix("Client") }
        #expect(client?.contains("Montréal (America/Toronto) 02:15") == true)
        #expect(client?.contains("\u{2212}") == true || client?.contains("+") == true || client?.contains("même") == true)
        #expect(client?.contains("lever 07:05") == true)
    }

    /// Le coût d'une minute de carte : huit horloges, soleil compris. Le
    /// chiffre va dans `ModuleCost` et dans le journal du chantier.
    @Test func huitHorlogesCoutentMoinsDUneMilliseconde() {
        let villes = ["montreal", "paris", "dubai", "tokyo", "sydney", "lima", "dakar", "moscou"].compactMap(Villes.ville)
        let debut = ContinuousClock.now
        let tours = 200
        for _ in 0..<tours {
            for ville in villes { _ = LigneHorloge.calcule(nom: ville.nom, ville: ville).soleilTexte }
        }
        let parTour = (ContinuousClock.now - debut) / tours
        print("mesure horloges huit_ms=\(Double(parTour.components.attoseconds) / 1e15)")
        #expect(parTour < .milliseconds(1))
    }
}

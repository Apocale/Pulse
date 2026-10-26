import Foundation
import AppKit
import Testing
@testable import Pulse

/// Les instants où se rejouent les tests du calendrier, figés : le matin
/// d'origine, minuit moins dix et minuit pile, les nuits où Paris passe à
/// l'heure d'été et à l'heure d'hiver (à lancer aussi sous `TZ=Europe/Paris`),
/// la nuit du nouvel an. Jamais la vraie horloge : des événements d'essai
/// posés à une heure fixe devenaient passés une heure plus tard, et le test
/// cassait `main` (11/10, 07:15).
let instantsCalendrier: [Date] = ["2026-10-11T06:20:00Z", "2026-10-11T23:50:00Z", "2026-10-12T00:00:00Z",
                                  "2026-03-29T00:50:00Z", "2026-10-25T00:50:00Z", "2026-12-31T23:50:00Z"]
    .map { ISO8601DateFormatter().date(from: $0)! }

/// Le calendrier du chantier 18, sur un magasin simulé : EventKit n'est
/// jamais appelé par les tests (`Agenda.sourceParDefaut` rend nil hors de
/// l'app installée, ce que le premier test vérifie).
@MainActor
@Suite struct CalendrierTests {
    static let maintenant = instantsCalendrier[0]

    static func evenement(_ id: String, dans minutes: Double, duree: Double = 30, journee: Bool = false,
                          depuis instant: Date = maintenant) -> EvenementAgenda {
        let debut = instant.addingTimeInterval(minutes * 60)
        return EvenementAgenda(id: id, titre: "É\(id)", debut: debut, fin: debut.addingTimeInterval(duree * 60),
                               journee: journee, calendrier: "Travail")
    }

    /// Hors de l'app installée — ici, un `.xctest` —, aucune source : ni
    /// EventKit, ni demande d'accès, même carte activée.
    @Test func horsDeLAppRienNEstLuNiDemande() {
        #expect(!Extras.appReelle)
        #expect(Agenda.sourceParDefaut() == nil)
        let agenda = Agenda()
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(agenda.horsApp && agenda.evenements.isEmpty && agenda.acces == nil)
    }

    /// La demande d'accès part quand la carte est activée, une fois, et
    /// jamais tant qu'elle est masquée.
    @Test(arguments: instantsCalendrier) func laDemandeNePartQuALActivation(maintenant: Date) {
        var creees = 0
        let source = SourceSimulee(acces: .jamaisDemande, reponse: .accorde,
                                   evenements: [Self.evenement("1", dans: 25, depuis: maintenant)])
        let agenda = Agenda(source: { creees += 1; return source }, horloge: { maintenant })
        agenda.regler(affiche: false, reglages: ReglagesCalendrier())
        #expect(creees == 0 && source.demandes == 0)
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(creees == 1 && source.demandes == 1)
        #expect(agenda.acces == .accorde && agenda.evenements.count == 1)
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(source.demandes == 1, "une seule demande par lancement")
        agenda.arreter()
    }

    /// Au lancement, carte déjà activée et accès jamais donné — macOS peut
    /// l'oublier à chaque reconstruction d'un Pulse signé ad hoc — : rien ne
    /// se demande seul. C'est le bouton de la carte qui demande, une fois.
    @Test(arguments: instantsCalendrier) func auLancementRienNeSeDemandeSeul(maintenant: Date) {
        let source = SourceSimulee(acces: .jamaisDemande, reponse: .accorde,
                                   evenements: [Self.evenement("1", dans: 25, depuis: maintenant)])
        let agenda = Agenda(source: { source }, horloge: { maintenant })
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(source.demandes == 0 && agenda.acces == .jamaisDemande && agenda.evenements.isEmpty)
        agenda.demanderAcces()
        agenda.demanderAcces()
        #expect(source.demandes == 1 && agenda.acces == .accorde && agenda.evenements.count == 1)
        agenda.arreter()
    }

    /// L'agenda lit à l'heure de son horloge : un événement fini quitte la
    /// liste à la lecture suivante. C'est ce qui rendait le test dépendant
    /// de l'heure réelle ; ici l'horloge avance à la main.
    @Test(arguments: instantsCalendrier) func unEvenementFiniQuitteLaListe(depart: Date) {
        final class Horloge { var instant: Date; init(_ instant: Date) { self.instant = instant } }
        let horloge = Horloge(depart)
        let source = SourceSimulee(evenements: [Self.evenement("1", dans: 25, depuis: depart),
                                                Self.evenement("2", dans: 120, depuis: depart)])
        let agenda = Agenda(source: { source }, horloge: { horloge.instant })
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(agenda.evenements.map(\.id) == ["1", "2"] && agenda.lu == depart)
        horloge.instant = depart.addingTimeInterval(60 * 60)   // le premier a fini
        agenda.relire()
        #expect(agenda.evenements.map(\.id) == ["2"] && agenda.lu == horloge.instant)
        agenda.arreter()
    }

    /// Masquée : tout s'arrête, la source est lâchée, plus rien n'est lu.
    @Test func masqueeToutSArrete() {
        let source = SourceSimulee(evenements: [Self.evenement("1", dans: 25)])
        let agenda = Agenda(source: { source }, horloge: { Self.maintenant })
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(agenda.evenements.count == 1)
        let lectures = source.lectures
        agenda.regler(affiche: false, reglages: ReglagesCalendrier())
        #expect(agenda.source == nil && agenda.evenements.isEmpty)
        agenda.relire()
        #expect(source.lectures == lectures)
    }

    @Test func unRefusSeDitSansRienLire() {
        let source = SourceSimulee(acces: .jamaisDemande, reponse: .refuse, evenements: [Self.evenement("1", dans: 25)])
        let agenda = Agenda(source: { source }, horloge: { Self.maintenant })
        agenda.regler(affiche: false, reglages: ReglagesCalendrier())
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        #expect(source.demandes == 1 && agenda.acces == .refuse && agenda.evenements.isEmpty)
        agenda.arreter()
    }

    /// Les journées entières en tête de leur jour ; masquées, elles partent.
    @Test(arguments: instantsCalendrier) func triEtJourneesEntieres(maintenant: Date) {
        var reglages = ReglagesCalendrier()
        let tous = [Self.evenement("tard", dans: 300, depuis: maintenant), Self.evenement("tot", dans: 25, depuis: maintenant),
                    Self.evenement("anniv", dans: -380, duree: 1440, journee: true, depuis: maintenant)]
        #expect(Agenda.trier(tous, reglages: reglages).map(\.id) == ["anniv", "tot", "tard"])
        reglages.journees = false
        #expect(Agenda.trier(tous, reglages: reglages).map(\.id) == ["tot", "tard"])
    }

    @Test func quandEcritLaCarte() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let m = Self.maintenant
        #expect(QuandEvenement.texte(Self.evenement("a", dans: 25), m, calendrier: cal) == "dans 25 min")
        #expect(QuandEvenement.texte(Self.evenement("b", dans: -10), m, calendrier: cal) == "en cours")
        let soir = Self.evenement("c", dans: 8 * 60)
        #expect(QuandEvenement.texte(soir, m, calendrier: cal) == "à \(Extras.heure(soir.debut))")
        let demain = Self.evenement("d", dans: 26 * 60)
        #expect(QuandEvenement.texte(demain, m, calendrier: cal).hasPrefix("demain "))
        // Minuit moins dix : dans 25 min, c'est déjà demain, mais le compte
        // à rebours prime ; huit heures plus tard, « demain 07:50 ».
        let tard = instantsCalendrier[1]
        #expect(QuandEvenement.texte(Self.evenement("e", dans: 25, depuis: tard), tard, calendrier: cal) == "dans 25 min")
        let matin = Self.evenement("f", dans: 8 * 60, depuis: tard)
        #expect(QuandEvenement.texte(matin, tard, calendrier: cal) == "demain \(Extras.heure(matin.debut))")
    }

    /// Un réglage d'un autre type, ou hors bornes, retombe sur sa valeur
    /// par défaut, sans emporter les autres (règle dure n°2).
    @Test func reglagesTolerants() {
        let r = ReglagesCalendrier(options: ["nombre": .text("cinq"), "horizon": .text("jamais"), "journees": .bool(false)])
        #expect(r.nombre == 5 && r.horizon == .demain && !r.journees)
        #expect(ReglagesCalendrier(options: ["nombre": .int(99)]).nombre == 10)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var aujourdhui = ReglagesCalendrier()
        aujourdhui.horizon = .aujourdhui
        let (_, fin) = aujourdhui.fenetre(Self.maintenant, calendrier: cal)
        #expect(fin == ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))
    }

    /// La fenêtre « jusqu'à demain soir » court jusqu'au minuit du
    /// surlendemain, heure locale, même la nuit d'un changement d'heure (23 h
    /// ou 25 h dans la journée) : jamais un pas fixe de 86 400 s.
    @Test func laFenetreSuitLeCalendrierAuChangementDHeure() {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        let reglages = ReglagesCalendrier()
        // 29 mars 2026, 01:50 à Paris (00:50 UTC) : à 02:00, il sera 03:00.
        let (_, fin) = reglages.fenetre(instantsCalendrier[3], calendrier: paris)
        #expect(fin == ISO8601DateFormatter().date(from: "2026-03-30T22:00:00Z"), "minuit du 31 mars, heure d'été")
        // 25 octobre 2026, 02:50 à Paris (00:50 UTC) : à 03:00, il sera 02:00.
        let (_, finHiver) = reglages.fenetre(instantsCalendrier[4], calendrier: paris)
        #expect(finHiver == ISO8601DateFormatter().date(from: "2026-10-26T23:00:00Z"), "minuit du 27 octobre, heure d'hiver")
    }

    /// `--probe` dit ce que la carte affiche — et, carte masquée, que rien
    /// n'a été demandé.
    @Test(arguments: instantsCalendrier) func laSectionDuReleve(maintenant: Date) {
        let masquee = CalendrierModule.section(Agenda(), affichee: false, maintenant: maintenant)
        #expect(masquee.lines == ["carte masquée (désactivée par défaut) : EventKit jamais appelé, aucune demande d'accès"])
        let source = SourceSimulee(evenements: [Self.evenement("1", dans: 25, depuis: maintenant)])
        let agenda = Agenda(source: { source }, horloge: { maintenant })
        agenda.regler(affiche: true, reglages: ReglagesCalendrier())
        let section = CalendrierModule.section(agenda, affichee: true, maintenant: maintenant)
        #expect(section.lines.contains { $0.contains("accès accordé") && $0.contains("1 événement") })
        #expect(section.lines.contains { $0.hasPrefix("dans 25 min") && $0.contains("É1 (Travail)") })
        agenda.arreter()
    }
}

/// La météo du chantier 18 : décodage des réponses écrites d'après la
/// documentation d'Open-Meteo, et la garantie qu'aucune requête ne part
/// hors de l'app installée.
@MainActor
@Suite struct MeteoTests {
    static func iso(_ texte: String) -> Date { ISO8601DateFormatter().date(from: texte)! }

    @Test func laReponseDeCasablancaEnISO8601() throws {
        let p = try OpenMeteo.decode(Data(ExemplesMeteo.casablanca.utf8))
        #expect(p.fuseau.identifier == "Africa/Casablanca")
        #expect(p.heures.count == 24 && p.jours.count == 7)
        #expect(p.actuelle == .init(date: Self.iso("2026-10-11T07:00:00Z"), temperature: 17.8, code: 1, jour: true))
        #expect(p.heures[0].date == Self.iso("2026-10-11T07:00:00Z"))
        #expect(p.heures[14].code == 61 && p.heures[14].pluie == 55)
        #expect(p.jours[0].date == Self.iso("2026-10-11T00:00:00Z"))
        #expect(p.jours[0].lever == Self.iso("2026-10-11T06:32:00Z") && p.jours[0].coucher == Self.iso("2026-10-11T18:02:00Z"))
        #expect(p.jours[6].maximum == 20.5 && p.jours[6].code == 95)
    }

    /// `timeformat=unixtime`, celui que Pulse demande : secondes UTC, et des
    /// `null` qui restent des trous, sans emporter la prévision.
    @Test func laReponseDeParisEnUnixtimeAvecDesNull() throws {
        let p = try OpenMeteo.decode(Data(ExemplesMeteo.parisUnixtime.utf8))
        #expect(p.fuseau.identifier == "Europe/Paris")
        #expect(p.heures.map(\.temperature) == [12.4, 13.1, nil])
        #expect(p.heures.map(\.pluie) == [nil, 10, 20])
        #expect(p.heures[0].date == Self.iso("2026-10-11T06:00:00Z"))
        // Minuit à Paris, le 11 : 22 h UTC la veille.
        #expect(p.jours[0].date == Self.iso("2026-10-10T22:00:00Z"))
        #expect(p.jours[1].minimum == nil && p.jours[1].pluie == nil && p.jours[1].maximum == 14.0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = p.fuseau
        #expect(cal.component(.day, from: p.jours[0].date) == 11)
        #expect(Extras.heure(p.jours[0].lever!, p.fuseau) == "08:05")
    }

    @Test func lesRefusEtLesReponsesIllisibles() {
        #expect(throws: OpenMeteo.Erreur.refus("Cannot initialize WeatherVariable from invalid String value tempeture_2m for key hourly")) {
            try OpenMeteo.decode(Data(ExemplesMeteo.erreur.utf8))
        }
        #expect(throws: OpenMeteo.Erreur.pasDuJSON) { try OpenMeteo.decode(Data("<html>502</html>".utf8)) }
        #expect(throws: OpenMeteo.Erreur.pasDuJSON) { try OpenMeteo.decode(Data("[1, 2]".utf8)) }
        #expect(throws: OpenMeteo.Erreur.incomplete) { try OpenMeteo.decode(Data("{}".utf8)) }
    }

    /// Une valeur d'un autre type devient un trou, pas une panne.
    @Test func uneValeurDUnAutreTypeDevientUnTrou() throws {
        let texte = ExemplesMeteo.parisUnixtime.replacingOccurrences(of: "\"temperature_2m\":[12.4,13.1,null]",
                                                                    with: "\"temperature_2m\":[\"chaud\",true,13]")
        let p = try OpenMeteo.decode(Data(texte.utf8))
        #expect(p.heures.map(\.temperature) == [nil, 1, 13])
    }

    /// Ce qui sort : la position au centième de degré, rien d'autre de
    /// personnel ; HTTPS vers le seul hôte d'Open-Meteo.
    @Test func laRequeteNEnvoieQueLaPosition() {
        let casa = Villes.ville("casablanca")!
        let url = OpenMeteo.url(latitude: casa.latitude, longitude: casa.longitude)
        #expect(url.scheme == "https" && url.host == "api.open-meteo.com" && url.path == "/v1/forecast")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let valeurs = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(valeurs["latitude"] == "33.57" && valeurs["longitude"] == "-7.59")
        #expect(valeurs["timezone"] == "auto" && valeurs["timeformat"] == "unixtime")
        #expect(Set(valeurs.keys) == ["latitude", "longitude", "current", "hourly", "daily", "timezone",
                                      "timeformat", "forecast_days", "forecast_hours"])
    }

    /// Hors de l'app installée, la carte activée ne demande rien.
    @Test func horsDeLAppAucuneRequete() {
        #expect(!Extras.appReelle && !Extras.exemple)
        let meteo = Meteo()
        meteo.regler(affiche: true, panneauOuvert: true, reglages: ReglagesMeteo())
        #expect(meteo.etat == .horsApp && meteo.requetes == 0)
        meteo.rafraichirSiBesoin()
        #expect(meteo.requetes == 0)
        meteo.regler(affiche: false, panneauOuvert: true, reglages: ReglagesMeteo())
        #expect(meteo.etat == .desactivee && meteo.requetes == 0)
    }

    /// Chaque code de la documentation a un nom français et un symbole que
    /// macOS dessine.
    @Test func chaqueCodeAUnNomEtUnSymbole() {
        for code in [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77, 80, 81, 82, 85, 86, 95, 96, 97, 99] {
            #expect(!CodeMeteo.libelle(code).hasPrefix("Code météo"), "\(code)")
            for jour in [true, false] {
                let symbole = CodeMeteo.symbole(code, jour: jour)
                #expect(symbole != "questionmark.circle", "\(code)")
                #expect(NSImage(systemSymbolName: symbole, accessibilityDescription: nil) != nil, "\(symbole)")
            }
        }
    }

    /// La dernière prévision se garde et se relit ; un fichier abîmé est
    /// ignoré sans erreur.
    @Test func leCacheSeRelitDeFaconTolerante() throws {
        let dossier = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-meteo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dossier) }
        let url = dossier.appendingPathComponent("meteo.json")
        let recue = Self.iso("2026-10-11T06:30:00Z")
        CacheMeteo.ecrire(reponse: Data(ExemplesMeteo.casablanca.utf8), ville: "casablanca", recue: recue, url, autorise: true)
        let lu = try #require(CacheMeteo.lire(url))
        #expect(lu.ville == "casablanca" && lu.recue == recue)
        #expect(lu.prevision == (try OpenMeteo.decode(Data(ExemplesMeteo.casablanca.utf8))))
        try Data("{abîmé".utf8).write(to: url)
        #expect(CacheMeteo.lire(url) == nil)
    }

    @Test func lExempleSeRecaleSurLHeureDuRendu() throws {
        let maintenant = Self.iso("2026-11-02T15:40:00Z")
        let p = try #require(ExemplesMeteo.recalee(maintenant))
        #expect(p.heures.first?.date == Self.iso("2026-11-02T15:00:00Z"))
        #expect(p.jours.first?.date == Self.iso("2026-11-02T00:00:00Z"))
        #expect(p.prochainesHeures(12, depuis: maintenant).count == 12)
    }

    @Test func lesDegres() {
        #expect(CarteMeteo.degres(17.5) == "18°")
        #expect(CarteMeteo.degres(-2.6) == "\u{2212}3°")
        #expect(CarteMeteo.degres(-0.4) == "0°")
    }

    @Test func laSectionDuReleve() {
        let masquee = MeteoModule.section(Meteo(), affichee: false)
        #expect(masquee.lines == ["carte masquée (désactivée par défaut) : aucune requête n'est jamais partie"])
    }
}

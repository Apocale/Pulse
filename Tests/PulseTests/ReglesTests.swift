import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Pulse

/// Le moteur des règles, rejoué sur des relevés construits à la main et
/// datés : durée minimale, hystérésis, plages horaires, une notification par
/// épisode, regroupement, retenue en montage, veille, rafales, reprise.
/// Aucune notification réelle : le moteur rend ce qu'il FAUDRAIT envoyer, et
/// le surveillant reçoit un notificateur-carnet.
@Suite struct ReglesTests {
    /// Le 11/10/2026 à 14 h 00, heure de Paris : rien ne dépend de l'heure
    /// du test ni du fuseau de la machine.
    static let t0 = Date(timeIntervalSince1970: 1_791_720_000)
    static let paris: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()
    static let go = 1e9

    static func disque(_ modifier: (inout Regle) -> Void = { _ in }) -> Regle {
        var r = Prereglages.tous.first { $0.id == "disque-rushes" }!
        r.active = true
        modifier(&r)
        return r
    }

    static func releve(_ secondes: TimeInterval, libre: Double?, montage: Bool = false,
                       sujet: String = "UUID-SSD2") -> ReleveRegles {
        var r = ReleveRegles(date: t0.addingTimeInterval(secondes), enMontage: montage)
        if let libre {
            r.valeurs["disques.libre"] = [Echantillon(sujet: sujet, nom: "Ssd 2", valeur: libre),
                                          Echantillon(sujet: "UUID-HD", nom: "Macintosh HD", valeur: 5 * go,
                                                      suiviParDefaut: false)]
        }
        return r
    }

    /// Rejoue une suite de relevés ; rend tout ce qui est parti.
    struct Rejeu {
        var moteur = MoteurRegles()
        var envoyees: [NotificationRegle] = []
        var journal: [EntreeJournal] = []
        var alertes = ReglagesAlertes()

        mutating func passer(_ regles: [Regle], _ releve: ReleveRegles) {
            let (lignes, notifications) = moteur.evaluer(regles, releve, alertes: alertes, calendrier: ReglesTests.paris)
            journal += lignes
            envoyees += notifications
        }

        func genres(_ genre: EntreeJournal.Genre) -> Int { journal.filter { $0.genre == genre }.count }

        /// Un relevé tous les `pas` secondes, de `debut` à `fin` compris.
        mutating func passerDe(_ debut: TimeInterval, a fin: TimeInterval, pas: TimeInterval, _ regles: [Regle],
                               _ releve: (TimeInterval) -> ReleveRegles) {
            var t = debut
            while t <= fin { passer(regles, releve(t)); t += pas }
        }
    }

    // MARK: - Préréglages et fichier

    @Test func prereglagesTousEteints() throws {
        let fichier = FichierRegles()
        #expect(fichier.regles.count == 8)
        #expect(fichier.regles.allSatisfy { !$0.active })
        #expect(Set(fichier.regles.map(\.id)) == ["disque-rushes", "export-termine", "copie-terminee", "premiere-plante",
                                                    "forfait-80", "forfait-100", "swap-monte", "connexion-perdue"])
        // Chaque préréglage porte sur une mesure du catalogue, avec une
        // comparaison qui a un sens pour elle.
        for regle in fichier.regles {
            let mesure = try #require(CatalogueMesures.mesure(regle.mesure))
            #expect(mesure.comparaisons.contains(regle.comparaison), "\(regle.id)")
        }
        // Un fichier vide : les préréglages, éteints.
        #expect(try JSONDecoder().decode(FichierRegles.self, from: Data("{}".utf8)) == FichierRegles())
    }

    /// Règle dure n°2 : un champ illisible retombe seul sur sa valeur par
    /// défaut, une règle sans mesure est écartée seule, et les préréglages
    /// manquants reviennent, éteints.
    @Test func lectureTolerante() throws {
        let json = #"""
        {"regles": [
          {"id": "disque-rushes", "nom": "Mon disque", "active": true, "mesure": "disques.libre",
           "comparaison": "sous", "seuil": "beaucoup", "duree": 120, "plage": {"debut": 540, "fin": "soir", "jours": [2, 9, "x"]}},
          {"id": "cassee", "comparaison": "sous"},
          {"id": "perso", "nom": "CPU", "active": true, "mesure": "processeur.total", "comparaison": "atteint",
           "seuil": 0.9, "champ-futur": 3}
        ], "alertes": {"intervalle": "court", "retenirEnMontage": false}}
        """#
        let lu = try JSONDecoder().decode(FichierRegles.self, from: Data(json.utf8))
        let disque = try #require(lu.regles.first { $0.id == "disque-rushes" })
        #expect(disque.nom == "Mon disque")
        #expect(disque.active)
        #expect(disque.seuil == 0)          // illisible : valeur par défaut
        #expect(disque.duree == 120)
        #expect(disque.plage == PlageHoraire(debut: 540, fin: 20 * 60, jours: [2]))
        #expect(lu.regles.contains { $0.id == "perso" && $0.seuil == 0.9 })
        #expect(!lu.regles.contains { $0.id == "cassee" })
        #expect(lu.regles.count == 9)       // 8 préréglages + la règle perso
        #expect(lu.regles.filter { $0.prereglage != nil && $0.id != "disque-rushes" }.allSatisfy { !$0.active })
        #expect(lu.alertes.intervalle == 300)
        #expect(lu.alertes.retenirEnMontage == false)
        // Aller-retour.
        let relu = try JSONDecoder().decode(FichierRegles.self, from: try ReglesStore.encoder(lu))
        #expect(relu == lu)
    }

    // MARK: - Durée minimale

    @Test func dureeMinimale() {
        let regles = [Self.disque()]
        var r = Rejeu()
        r.passer(regles, Self.releve(0, libre: 90 * Self.go))
        r.passer(regles, Self.releve(30, libre: 90 * Self.go))
        #expect(r.envoyees.isEmpty)
        #expect(r.genres(.debut) == 0)
        r.passer(regles, Self.releve(60, libre: 90 * Self.go))
        #expect(r.genres(.debut) == 1)
        #expect(r.envoyees.count == 1)
        #expect(r.envoyees.first?.titre == "Disque de rushes presque plein")
        #expect(r.envoyees.first?.corps == "Ssd 2 : 90,0\u{00A0}Go libres, sous 100\u{00A0}Go")
        // Le disque interne n'est pas suivi par une règle sans sujet.
        #expect(!r.journal.contains { $0.sujet == "UUID-HD" })
    }

    /// Une interruption remet le compteur à zéro : la durée se compte sans
    /// trou.
    @Test func dureeInterrompue() {
        let regles = [Self.disque()]
        var r = Rejeu()
        r.passer(regles, Self.releve(0, libre: 90 * Self.go))
        r.passer(regles, Self.releve(30, libre: 150 * Self.go))
        r.passer(regles, Self.releve(40, libre: 90 * Self.go))
        r.passer(regles, Self.releve(90, libre: 90 * Self.go))
        #expect(r.envoyees.isEmpty)
        r.passer(regles, Self.releve(100, libre: 90 * Self.go))
        #expect(r.envoyees.count == 1)
    }

    // MARK: - Hystérésis

    /// Dans la marge (100 à 110 Go), l'épisode continue ; repassé sous le
    /// seuil, il ne renotifie pas. Il ne finit qu'au-delà de 110 Go tenus
    /// 10 min — et alors seulement, un nouveau passage sous le seuil est un
    /// nouvel épisode.
    @Test func hysteresisUneNotificationParEpisode() {
        let regles = [Self.disque { $0.duree = 0 }]
        var r = Rejeu()
        r.alertes.intervalle = 0
        r.passer(regles, Self.releve(0, libre: 95 * Self.go))
        #expect(r.envoyees.count == 1)
        // Oscille autour du seuil, dans la marge.
        for (i, libre) in [105.0, 98, 108, 99, 104, 97].enumerated() {
            r.passer(regles, Self.releve(Double(10 * (i + 1)), libre: libre * Self.go))
        }
        #expect(r.envoyees.count == 1)
        // Dans la marge (105 Go) plus longtemps que le délai de sortie :
        // l'épisode tient, et repasser sous le seuil ne redit rien.
        r.passerDe(70, a: 790, pas: 10, regles) { Self.releve($0, libre: 105 * Self.go) }
        r.passer(regles, Self.releve(800, libre: 98 * Self.go))
        #expect(r.envoyees.count == 1)
        #expect(r.genres(.fin) == 0)
        // Au-delà de la marge, mais pas assez longtemps (un relevé toutes
        // les 10 s, comme l'app).
        r.passerDe(810, a: 1_240, pas: 10, regles) { Self.releve($0, libre: 115 * Self.go) }
        r.passer(regles, Self.releve(1_250, libre: 95 * Self.go))
        #expect(r.envoyees.count == 1)
        #expect(r.genres(.fin) == 0)
        // Au-delà de la marge pendant 10 min : fin d'épisode.
        r.passerDe(1_260, a: 1_850, pas: 10, regles) { Self.releve($0, libre: 120 * Self.go) }
        #expect(r.genres(.fin) == 0)
        r.passer(regles, Self.releve(1_860, libre: 120 * Self.go))
        #expect(r.genres(.fin) == 1)
        // Un nouveau passage sous le seuil : un nouvel épisode.
        r.passer(regles, Self.releve(1_870, libre: 90 * Self.go))
        #expect(r.envoyees.count == 2)
    }

    // MARK: - Plages horaires

    @Test func plageHoraire() {
        let cal = Self.paris
        func a(_ jour: Int, _ h: Int, _ m: Int = 0) -> Date {
            // Octobre 2026 : le 12 est un lundi, le 16 un vendredi, le 17 un samedi.
            cal.date(from: DateComponents(year: 2026, month: 10, day: jour, hour: h, minute: m))!
        }
        let jour = PlageHoraire(debut: 9 * 60, fin: 20 * 60)
        #expect(jour.contient(a(12, 9), calendrier: cal))
        #expect(jour.contient(a(12, 19, 59), calendrier: cal))
        #expect(!jour.contient(a(12, 20), calendrier: cal))
        #expect(!jour.contient(a(12, 8, 59), calendrier: cal))
        // À cheval sur minuit, le vendredi seulement : la nuit de vendredi à
        // samedi en fait partie, celle de samedi à dimanche non.
        let nuit = PlageHoraire(debut: 22 * 60, fin: 7 * 60, jours: [6])
        #expect(nuit.contient(a(16, 23), calendrier: cal))
        #expect(nuit.contient(a(17, 3), calendrier: cal))
        #expect(!nuit.contient(a(17, 23), calendrier: cal))
        #expect(!nuit.contient(a(16, 12), calendrier: cal))
        #expect(!nuit.contient(a(16, 3), calendrier: cal))   // la nuit de jeudi
        #expect(PlageHoraire(debut: 0, fin: 0).contient(a(12, 4), calendrier: cal))
        #expect(nuit.texte == "de 22 h à 7 h, ven.")
    }

    /// Un état qui commence hors plage est dit à l'ouverture de la plage
    /// s'il tient encore ; un événement hors plage n'est jamais dit.
    @Test func horsPlageDiffereOuTu() {
        let plage = PlageHoraire(debut: 9 * 60, fin: 20 * 60)
        let regles = [Self.disque { $0.duree = 0; $0.plage = plage }]
        var r = Rejeu()
        // 14 h + 9 h = 23 h : hors plage.
        r.passer(regles, Self.releve(9 * 3600, libre: 90 * Self.go))
        #expect(r.genres(.debut) == 1)
        #expect(r.genres(.horsPlage) == 1)
        #expect(r.envoyees.isEmpty)
        // La nuit, relevé toutes les 30 s : toujours rien.
        var t = 9.0 * 3600
        while t < 18 * 3600 { t += 30; r.passer(regles, Self.releve(t, libre: 90 * Self.go)) }
        #expect(r.envoyees.isEmpty)
        // 14 h + 19 h = 9 h le lendemain : la plage s'ouvre, l'état tient.
        r.passer(regles, Self.releve(19 * 3600, libre: 90 * Self.go))
        #expect(r.envoyees.count == 1)
        #expect(r.envoyees.first?.corps.contains("depuis 23 h 00") == true)

        // Un plantage à 23 h : tu, pas différé.
        var crash = Prereglages.tous.first { $0.id == "premiere-plante" }!
        crash.active = true
        crash.plage = plage
        var e = Rejeu()
        var releve = ReleveRegles(date: Self.t0.addingTimeInterval(9 * 3600))
        releve.evenements["montage.plantage"] = [Evenement(sujet: "Premiere Pro", date: releve.date,
                                                           texte: "Premiere Pro a planté à 23 h 00")]
        e.passer([crash], releve)
        e.passer([crash], ReleveRegles(date: Self.t0.addingTimeInterval(19 * 3600)))
        #expect(e.envoyees.isEmpty)
        #expect(e.genres(.horsPlage) == 1)
    }

    // MARK: - Regroupement, retenue

    /// Au plus une notification par intervalle ; ce qui arrive entre-temps
    /// part, regroupé, dans la suivante.
    @Test func regroupement() {
        var forfait = Prereglages.tous.first { $0.id == "forfait-80" }!
        forfait.active = true
        var horsLigne = Prereglages.tous.first { $0.id == "connexion-perdue" }!
        horsLigne.active = true
        horsLigne.duree = 0
        let regles = [Self.disque { $0.duree = 0 }, forfait, horsLigne]
        var r = Rejeu()
        func releve(_ t: TimeInterval, forfait: Double, horsLigne: Bool) -> ReleveRegles {
            var rel = Self.releve(t, libre: 90 * Self.go)
            rel.valeurs["reseau.forfait"] = [Echantillon(valeur: forfait)]
            rel.valeurs["reseau.horsLigne"] = [Echantillon(valeur: horsLigne ? 1 : 0)]
            return rel
        }
        r.passer(regles, releve(0, forfait: 0.5, horsLigne: false))
        #expect(r.envoyees.count == 1)                       // le disque, tout de suite
        r.passer(regles, releve(60, forfait: 0.82, horsLigne: false))
        r.passer(regles, releve(120, forfait: 0.83, horsLigne: true))
        #expect(r.envoyees.count == 1)                       // dans l'intervalle : rien
        r.passer(regles, releve(299, forfait: 0.83, horsLigne: true))
        #expect(r.envoyees.count == 1)
        r.passer(regles, releve(300, forfait: 0.83, horsLigne: true))
        #expect(r.envoyees.count == 2)
        let groupee = r.envoyees[1]
        #expect(groupee.titre == "Pulse · 2 alertes")
        #expect(groupee.corps.contains("Forfait iPhone à 80 %"))
        #expect(groupee.corps.contains("Connexion perdue"))
        #expect(groupee.alertes.count == 2)
    }

    /// Une app de montage au premier plan : la notification attend, sauf
    /// règle urgente ; elle part quand Premiere passe en arrière-plan.
    @Test func retenueEnMontage() {
        var urgente = Prereglages.tous.first { $0.id == "connexion-perdue" }!
        urgente.active = true
        urgente.duree = 0
        urgente.urgente = true
        let disque = Self.disque { $0.duree = 0 }
        var r = Rejeu()
        r.alertes.intervalle = 0
        r.passer([disque], Self.releve(0, libre: 90 * Self.go, montage: true))
        r.passer([disque], Self.releve(5, libre: 90 * Self.go, montage: true))
        #expect(r.envoyees.isEmpty)
        #expect(r.genres(.retenue) == 1)                     // écrit une fois
        // Urgente : passe.
        var rel = Self.releve(10, libre: 90 * Self.go, montage: true)
        rel.valeurs["reseau.horsLigne"] = [Echantillon(valeur: 1)]
        r.passer([disque, urgente], rel)
        #expect(r.envoyees.count == 1)
        #expect(r.envoyees.last?.titre == "Connexion perdue")
        // Premiere en arrière-plan : le disque part.
        r.passer([disque, urgente], Self.releve(3600, libre: 90 * Self.go, montage: false))
        #expect(r.envoyees.count == 2)
        #expect(r.envoyees.last?.titre == "Disque de rushes presque plein")
        // Retenue réglée à non : rien n'attend.
        var s = Rejeu()
        s.alertes.retenirEnMontage = false
        s.passer([disque], Self.releve(0, libre: 90 * Self.go, montage: true))
        #expect(s.envoyees.count == 1)
    }

    /// Isma coche le son pendant que l'alerte attend : elle part avec ; il
    /// décoche la notification : elle ne part pas.
    @Test func reglagesDuMomentPourUneAlerteEnAttente() {
        var disque = Self.disque { $0.duree = 0 }
        var r = Rejeu()
        r.alertes.intervalle = 0
        r.passer([disque], Self.releve(0, libre: 90 * Self.go, montage: true))
        disque.son = true
        r.passer([disque], Self.releve(5, libre: 90 * Self.go, montage: false))
        #expect(r.envoyees.count == 1)
        #expect(r.envoyees.first?.son == true)

        var muette = Self.disque { $0.duree = 0 }
        var s = Rejeu()
        s.passer([muette], Self.releve(0, libre: 90 * Self.go, montage: true))
        muette.notification = false
        s.passer([muette], Self.releve(5, libre: 90 * Self.go, montage: false))
        #expect(s.envoyees.isEmpty)
    }

    /// Retenue pendant le montage puis retombée : elle ne part jamais.
    @Test func retombeeAvantDEtreDite() {
        let disque = Self.disque { $0.duree = 0; $0.relache = 0 }
        var r = Rejeu()
        r.passer([disque], Self.releve(0, libre: 90 * Self.go, montage: true))
        r.passer([disque], Self.releve(5, libre: 200 * Self.go, montage: true))
        r.passer([disque], Self.releve(10, libre: 200 * Self.go, montage: false))
        #expect(r.envoyees.isEmpty)
        #expect(r.genres(.tombee) == 1)
    }

    // MARK: - Veille, absence de mesure

    /// Deux relevés séparés par une nuit de veille ne font pas « hors ligne
    /// depuis 30 s » : le Wi-Fi est coupé pendant la veille par
    /// construction.
    @Test func trouDeVeille() {
        var horsLigne = Prereglages.tous.first { $0.id == "connexion-perdue" }!
        horsLigne.active = true
        func releve(_ t: TimeInterval) -> ReleveRegles {
            var r = ReleveRegles(date: Self.t0.addingTimeInterval(t))
            r.valeurs["reseau.horsLigne"] = [Echantillon(valeur: 1)]
            return r
        }
        var r = Rejeu()
        r.passer([horsLigne], releve(0))
        r.passer([horsLigne], releve(8 * 3600))
        #expect(r.genres(.debut) == 0)
        r.passer([horsLigne], releve(8 * 3600 + 5))
        r.passer([horsLigne], releve(8 * 3600 + 30))
        #expect(r.genres(.debut) == 1)
    }

    /// Un disque débranché puis rebranché, toujours presque plein, n'est pas
    /// un nouvel épisode.
    @Test func mesureAbsenteGeleLEpisode() {
        let disque = Self.disque { $0.duree = 0; $0.relache = 0 }
        var r = Rejeu()
        r.alertes.intervalle = 0
        r.passer([disque], Self.releve(0, libre: 90 * Self.go))
        r.passer([disque], Self.releve(10, libre: nil))
        r.passer([disque], Self.releve(600, libre: nil))
        r.passer([disque], Self.releve(700, libre: 90 * Self.go))
        #expect(r.envoyees.count == 1)
        #expect(r.genres(.fin) == 0)
    }

    // MARK: - Événements

    /// Trois plantages en dix minutes : UNE notification. Passé la rafale,
    /// un nouveau plantage en refait une.
    @Test func rafaleDEvenements() {
        var crash = Prereglages.tous.first { $0.id == "premiere-plante" }!
        crash.active = true
        var r = Rejeu()
        r.alertes.intervalle = 0
        func plantage(_ t: TimeInterval, app: String = "Premiere Pro") -> ReleveRegles {
            var rel = ReleveRegles(date: Self.t0.addingTimeInterval(t))
            rel.evenements["montage.plantage"] = [Evenement(sujet: app, date: rel.date, texte: "\(app) a planté")]
            return rel
        }
        r.passer([crash], plantage(0))
        r.passer([crash], plantage(200))
        r.passer([crash], plantage(400))
        #expect(r.envoyees.count == 1)
        #expect(r.genres(.rafale) == 2)
        // Le sujet filtre : Media Encoder n'est pas Premiere.
        r.passer([crash], plantage(450, app: "Adobe Media Encoder"))
        #expect(r.genres(.rafale) == 2)
        // Dix minutes sans plantage : la rafale est close.
        r.passer([crash], ReleveRegles(date: Self.t0.addingTimeInterval(1_000)))
        #expect(r.genres(.fin) == 1)
        r.passer([crash], plantage(1_100))
        #expect(r.envoyees.count == 2)
    }

    /// Retenue pendant le montage, la notification d'une rafale dit le
    /// compte à jour quand elle part.
    @Test func rafaleRetenueDitLeCompte() {
        var crash = Prereglages.tous.first { $0.id == "premiere-plante" }!
        crash.active = true
        var r = Rejeu()
        func plantage(_ t: TimeInterval) -> ReleveRegles {
            var rel = ReleveRegles(date: Self.t0.addingTimeInterval(t), enMontage: true)
            rel.evenements["montage.plantage"] = [Evenement(sujet: "Premiere Pro", date: rel.date,
                                                            texte: "Premiere Pro a planté")]
            return rel
        }
        r.passer([crash], plantage(0))
        r.passer([crash], plantage(60))
        r.passer([crash], ReleveRegles(date: Self.t0.addingTimeInterval(120)))
        #expect(r.envoyees.count == 1)
        #expect(r.envoyees.first?.corps.contains("2 fois depuis 14 h 00") == true)
    }

    /// Le premier relevé pose la référence : les plantages déjà là ne sont
    /// pas nouveaux. Un export qui finit en est un.
    @Test func detecteurEvenements() {
        var d = DetecteurEvenements()
        let ancien = Incident(app: "Premiere Pro", bundleId: nil, kind: .crash, date: Self.t0.addingTimeInterval(-3600))
        let export = ExportActivity(app: "Adobe Media Encoder 2026", began: Self.t0.addingTimeInterval(-720),
                                    lastActive: Self.t0.addingTimeInterval(-30))
        #expect(d.observer(export: export, incidents: [ancien], date: Self.t0).isEmpty)
        #expect(d.observer(export: export, incidents: [ancien], date: Self.t0.addingTimeInterval(5)).isEmpty)
        let nouveau = Incident(app: "Premiere Pro", bundleId: nil, kind: .crash, date: Self.t0.addingTimeInterval(8))
        let tue = Incident(app: "Vivaldi", bundleId: nil, kind: .jetsam, date: Self.t0.addingTimeInterval(9))
        let vus = d.observer(export: nil, incidents: [nouveau, ancien, tue], date: Self.t0.addingTimeInterval(10))
        #expect(vus["montage.exportTermine"]?.first?.texte == "Media Encoder · 11 min")
        #expect(vus["montage.plantage"]?.count == 1)
        #expect(vus["montage.plantage"]?.first?.sujet == "Premiere Pro")
        #expect(vus["memoire.processusTue"]?.count == 1)
        #expect(d.observer(export: nil, incidents: [nouveau, ancien, tue], date: Self.t0.addingTimeInterval(15)).isEmpty)
    }

    // MARK: - Reprise après un redémarrage

    /// Un épisode resté ouvert au journal est repris, déjà dit : relancer
    /// Pulse ne redit pas « disque presque plein ».
    @Test func repriseSansRedire() {
        let disque = Self.disque { $0.duree = 0 }
        let journal = [
            EntreeJournal(date: Self.t0, genre: .debut, regle: "disque-rushes", nom: disque.nom,
                          sujet: "UUID-SSD2", sujetNom: "Ssd 2", texte: "Ssd 2 : 90 Go"),
            EntreeJournal(date: Self.t0, genre: .notifiee, regle: "disque-rushes", nom: disque.nom,
                          sujet: "UUID-SSD2", sujetNom: "Ssd 2"),
        ]
        var r = Rejeu()
        r.moteur.reprendre(journal, regles: [disque])
        r.passer([disque], Self.releve(3600, libre: 90 * Self.go))
        #expect(r.envoyees.isEmpty)
        #expect(r.genres(.debut) == 0)
        // Clos au journal : un nouvel épisode, dit.
        var s = Rejeu()
        s.moteur.reprendre(journal + [EntreeJournal(date: Self.t0.addingTimeInterval(60), genre: .fin,
                                                    regle: "disque-rushes", nom: disque.nom, sujet: "UUID-SSD2")],
                           regles: [disque])
        s.passer([disque], Self.releve(3600, libre: 90 * Self.go))
        #expect(s.envoyees.count == 1)
    }

    /// Éteindre une règle clôt ses épisodes au journal et retire ses
    /// alertes en attente sans rien envoyer.
    @Test func extinction() {
        let disque = Self.disque { $0.duree = 0 }
        var r = Rejeu()
        r.passer([disque], Self.releve(0, libre: 90 * Self.go, montage: true))
        #expect(r.moteur.boite.count == 1)
        var eteinte = disque
        eteinte.active = false
        r.passer([eteinte], Self.releve(10, libre: 90 * Self.go, montage: false))
        #expect(r.envoyees.isEmpty)
        #expect(r.moteur.boite.isEmpty)
        #expect(r.journal.contains { $0.genre == .fin && $0.texte == "règle éteinte" })
        // Retirée sans bruit, pas « retombée ».
        #expect(r.genres(.tombee) == 0)

        // Un événement ne retombe jamais : seule l'extinction le retire.
        var crash = Prereglages.tous.first { $0.id == "premiere-plante" }!
        crash.active = true
        var e = Rejeu()
        var rel = ReleveRegles(date: Self.t0, enMontage: true)
        rel.evenements["montage.plantage"] = [Evenement(sujet: "Premiere Pro", date: Self.t0, texte: "Premiere Pro a planté")]
        e.passer([crash], rel)
        crash.active = false
        e.passer([crash], ReleveRegles(date: Self.t0.addingTimeInterval(10)))
        #expect(e.envoyees.isEmpty)
    }

    // MARK: - Mesures

    @Test func hausseDuSwap() {
        let gio = 1_073_741_824.0
        let t = Self.t0.timeIntervalSince1970
        let serie = (0..<360).map { i in
            SeriesPoint(t: t - 3600 + Double(i) * 10, ram: 0.5, swap: gio + Double(i) * 4_000_000, cpu: 0.2, gpu: 0)
        }
        let hausse = LectureRegles.hausseSwap(series: serie, swap: UInt64(2.5 * gio), date: Self.t0)
        #expect(hausse == 1.5 * gio)
        // Moins de cinq minutes d'historique : rien plutôt qu'une extrapolation.
        #expect(LectureRegles.hausseSwap(series: Array(serie.suffix(20)), swap: UInt64(2.5 * gio), date: Self.t0) == nil)

        var e = EntreesRegles()
        e.memoire = MemorySample(total: 32 * UInt64(gio), app: 8 * UInt64(gio), swapUsed: UInt64(2.5 * gio))
        e.series = serie
        e.volumes = [VolumeSample(name: "Ssd 2", path: "/Volumes/Ssd 2", total: 2_000_000_000_000,
                                  available: 90_000_000_000, isInternal: false, uuid: "UUID-SSD2",
                                  availableStrict: 80_000_000_000)]
        let v = LectureRegles.valeurs(e, mesures: ["memoire.swapHausse", "disques.libre", "reseau.horsLigne",
                                                    "reseau.forfait"], date: Self.t0)
        #expect(v["memoire.swapHausse"]?.first?.valeur == 1.5 * gio)
        #expect(v["disques.libre"]?.first == Echantillon(sujet: "UUID-SSD2", nom: "Ssd 2", valeur: 90e9))
        // Ni relevé réseau encore, ni forfait réglé : absentes, pas fausses.
        #expect(v["reseau.horsLigne"] == nil)
        #expect(v["reseau.forfait"] == nil)
        // Seulement ce qui est demandé.
        #expect(v["memoire.utilisee"] == nil)
    }
}

/// Le surveillant branché sur un relevé figé : coût nul sans règle active,
/// notificateur injecté, jamais `UNUserNotificationCenter`.
@MainActor
@Suite struct SurveillantReglesTests {
    final class Carnet: Notificateur {
        var recues: [NotificationRegle] = []
        func envoyer(_ notification: NotificationRegle, fin: @escaping @Sendable @MainActor (String?) -> Void) {
            recues.append(notification)
            fin(nil)
        }
    }

    static func store() -> ReglesStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-regles-\(UUID().uuidString)/regles.json")
        return ReglesStore(url: url, ecrit: false)
    }

    @Test func coutNulSansRegleActive() {
        let sampler = Releve.typique.sampler()
        let store = Self.store()
        let surveillant = SurveillantRegles(store: store, notificateur: Carnet(), journalise: false)
        surveillant.demarrer(sampler)
        #expect(!surveillant.ecoute)
        store.modifier("swap-monte") { $0.active = true }
        #expect(surveillant.ecoute)
        store.modifier("swap-monte") { $0.active = false }
        #expect(!surveillant.ecoute)
    }

    @Test func notificateurInjecte() {
        var releve = Releve.typique
        releve.volumes = [VolumeSample(name: "Ssd 2", path: "/Volumes/Ssd 2", total: 2_000_000_000_000,
                                       available: 42_000_000_000, isInternal: false, uuid: "UUID-SSD2",
                                       availableStrict: 40_000_000_000)]
        let sampler = releve.sampler()
        let store = Self.store()
        let carnet = Carnet()
        let surveillant = SurveillantRegles(store: store, notificateur: carnet, journalise: false)
        surveillant.appAuPremierPlan = { "com.apple.finder" }
        surveillant.demarrer(sampler)
        store.modifier("disque-rushes") { $0.active = true; $0.duree = 0 }
        surveillant.evaluer(date: Date())
        #expect(carnet.recues.count == 1)
        #expect(carnet.recues.first?.corps == "Ssd 2 : 42,0\u{00A0}Go libres, sous 100\u{00A0}Go")
        #expect(surveillant.enCours.map(\.regle) == ["disque-rushes"])
        // Premiere au premier plan : une nouvelle alerte est retenue.
        var memoire = PageRegles.nouvelle(CatalogueMesures.mesure("memoire.utilisee")!)
        memoire.active = true
        memoire.duree = 0
        memoire.seuil = 0.01
        store.fichier.regles.append(memoire)
        surveillant.appAuPremierPlan = { "com.adobe.PremierePro.26" }
        surveillant.evaluer(date: Date().addingTimeInterval(400))
        #expect(surveillant.enCours.count == 2)
        #expect(carnet.recues.count == 1)
        // Premiere en arrière-plan : elle part.
        surveillant.appAuPremierPlan = { "com.apple.finder" }
        surveillant.evaluer(date: Date().addingTimeInterval(405))
        #expect(carnet.recues.count == 2)
        #expect(carnet.recues.last?.titre == "Mémoire utilisée")
    }
}

/// La cloche de la barre et le disque que la règle suit d'office.
@MainActor
@Suite struct BarreEtDisqueTests {
    @Test func clocheReserveeSeulementSiDemandee() {
        var regles = Prereglages.tous
        let signal = SurveillantRegles.Signal(id: "x", regle: "disque-rushes", nom: "Disque", texte: "",
                                              debut: Date(), barre: true)
        // Aucune règle allumée : rien de réservé, l'icône garde sa largeur.
        #expect(SurveillantRegles.alerte(regles: regles, enCours: []) == nil)
        // Allumée sans cloche : rien de réservé non plus.
        regles[0].active = true
        regles[0].barre = false
        #expect(SurveillantRegles.alerte(regles: regles, enCours: []) == nil)
        // Allumée avec cloche : la place, puis la cloche pendant l'épisode.
        regles[0].barre = true
        #expect(SurveillantRegles.alerte(regles: regles, enCours: []) == false)
        #expect(SurveillantRegles.alerte(regles: regles, enCours: [signal]) == true)
        // Dans la barre du chantier 09 : la place est réservée dès qu'une
        // règle la demande, même symbole du verdict réglé sur « jamais » ;
        // la cloche passe devant le triangle du verdict.
        var reglages = PulseSettings()
        reglages.menuBar.alert = .never
        var alerte = Verdict.pending
        alerte.level = .alert
        alerte.phrase = "Ssd 2 est plein à 96 %"
        func contenu(_ regles: Bool?) -> MenuBarContent {
            let lecture = MenuBarComposer.Reading(segments: [], verdict: alerte, regles: regles,
                                                  reglesDit: regles == true ? "alerte : Disque de rushes presque plein" : nil)
            return MenuBarComposer.contents(lecture, settings: reglages, history: nil)[0]
        }
        #expect(contenu(nil).reservesAlert == false)
        #expect(contenu(false).reservesAlert == true)
        #expect(contenu(false).alert == nil)
        #expect(contenu(true).alert?.symbol == MenuBarAlert.ruleSymbol)
        #expect(contenu(true).spoken.contains("Disque de rushes presque plein"))
        reglages.menuBar.alert = .alerts
        #expect(contenu(nil).alert?.symbol == MenuBarAlert.alertSymbol)
        #expect(contenu(true).alert?.symbol == MenuBarAlert.ruleSymbol)
        #expect(contenu(true).spoken.contains("Ssd 2 est plein à 96 %"))
        // La largeur ne bouge pas quand la cloche s'allume.
        #expect(contenu(false).widest == contenu(true).widest)
    }

    @Test func disqueDeRushesPlutotQueLePlusGrand() {
        func v(_ nom: String, _ cle: String, libre: UInt64, interne: Bool = false) -> VolumeSample {
            VolumeSample(name: nom, path: "/Volumes/\(nom)", total: 2_000_000_000_000, available: libre,
                         isInternal: interne, uuid: cle, availableStrict: libre)
        }
        let volumes = [v("Macintosh HD", "HD", libre: 50_000_000_000, interne: true),
                       v("Extreme Pro", "EP", libre: 719_000_000_000),
                       v("Ssd 2", "S2", libre: 302_000_000_000)]
        #expect(LigneRegle.disqueDeRushes(volumes, [:])?.name == "Ssd 2")
        let previsions = ["EP": FillForecast(bytesPerDay: -50e9, daysUntilFull: 14, ruptures: 0, calmSeconds: 86_400)]
        #expect(LigneRegle.disqueDeRushes(volumes, previsions)?.name == "Extreme Pro")
        #expect(LigneRegle.disqueDeRushes([volumes[0]], [:]) == nil)
    }
}

/// Ce que coûtent les règles ALLUMÉES, mesuré : les sept préréglages actifs,
/// évalués comme dans l'app — un relevé toutes les 5 s, forfait relu chaque
/// minute, app au premier plan lue à chaque fois — sur un relevé figé.
/// Temps processeur du processus (`getrusage`), rapporté à la cadence
/// panneau fermé. Hors de la suite ordinaire :
///
///     PULSE_BANC_REGLES=20000 swift test --filter BancRegles
@MainActor
@Suite struct BancReglesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSE_BANC_REGLES"] != nil))
    func coutDesReglesAllumees() {
        let n = Int(ProcessInfo.processInfo.environment["PULSE_BANC_REGLES"] ?? "") ?? 20_000
        let sampler = Releve.typique.sampler()
        let store = SurveillantReglesTests.store()
        let surveillant = SurveillantRegles(store: store, notificateur: SurveillantReglesTests.Carnet(), journalise: false)
        surveillant.demarrer(sampler)
        store.fichier.regles = store.regles.map { var r = $0; r.active = true; return r }
        let debut = Date()
        func cpu() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }
        let avant = cpu()
        for i in 0..<n { surveillant.evaluer(date: debut.addingTimeInterval(Double(i) * 5)) }
        let parReleve = (cpu() - avant) / Double(n)
        let partDUnCoeur = parReleve / 5 * 100
        print(String(format: "mesure regles=7 releves=%d par_releve_us=%.1f coeur_ferme_pct=%.5f", n, parReleve * 1e6, partDUnCoeur))
        #expect(partDUnCoeur < 0.01)
    }
}

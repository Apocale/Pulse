import Foundation

/// Une ligne du journal des règles (`regles.jsonl`).
struct EntreeJournal: Equatable {
    enum Genre: String, CaseIterable {
        /// L'épisode commence : la condition a tenu sa durée, ou l'événement
        /// est survenu.
        case debut
        /// Un événement de plus dans un épisode en cours : pas de seconde
        /// notification.
        case rafale
        /// L'épisode se termine, hystérésis passée (ou la règle est éteinte).
        case fin
        /// Partie dans une notification, seule ou regroupée.
        case notifiee
        /// Retenue : une app de montage est au premier plan.
        case retenue
        /// Hors de la plage horaire : différée (un état), tue (un événement).
        case horsPlage
        /// L'épisode a fini avant que la notification parte : tue.
        case tombee
        /// macOS ne l'a pas prise : autorisation refusée ou jamais demandée.
        case nonEnvoyee
        /// La réponse d'Isma à la demande d'autorisation.
        case autorisation
    }

    var date: Date
    var genre: Genre
    var regle: String
    var nom: String
    /// Clé stable du sujet (UUID d'un volume, nom d'une app) ; vide sinon.
    var sujet = ""
    var sujetNom = ""
    var texte = ""
}

/// Une alerte en attente de sa notification.
struct Alerte: Equatable {
    /// « règle|sujet » : l'épisode qui l'a produite.
    var cle: String
    var regle: String
    var nom: String
    var sujet: String
    var sujetNom: String
    var texte: String
    /// Début de l'épisode (un état) ou date de l'événement.
    var date: Date
    var son: Bool
    var urgente: Bool
    var evenement: Bool
    /// La retenue « en montage » n'est écrite qu'une fois au journal.
    var retenueNotee = false
}

/// Une notification : UNE seule, même pour plusieurs alertes.
struct NotificationRegle: Equatable {
    var titre: String
    var corps: String
    var son: Bool
    var alertes: [Alerte]
}

/// Un épisode en cours : la condition tient (hystérésis comprise), ou un
/// événement vient de survenir.
struct Episode: Equatable {
    var debut: Date
    /// Son alerte est partie dans la boîte, ou il n'y a rien à notifier.
    var notifie: Bool
    var sujetNom: String
    var texte: String
    var valeur: Double?
    /// Pour un événement : le dernier de la rafale, et combien.
    var dernierEvenement: Date?
    var nombre = 1
}

/// Le moteur des règles. Pur : ni horloge, ni fichier, ni notification —
/// il reçoit un relevé daté et rend ce qu'il faut écrire et envoyer. Le
/// surveillant (`SurveillantRegles`) le nourrit sur le fil principal ; les
/// tests le nourrissent de relevés construits à la main, à des dates
/// choisies.
///
/// Un ÉPISODE est la période où la condition tient : il commence quand elle
/// a tenu `duree` sans interruption et ne finit qu'une fois la mesure
/// repassée au-delà du seuil de `marge`, et restée là `relache` secondes.
/// Une seule notification par épisode : une valeur qui oscille autour du
/// seuil n'en produit pas dix.
struct MoteurRegles {
    /// Au-delà, deux relevés ne se suivent pas : le Mac dormait, ou Pulse
    /// était arrêté. Les compteurs de durée repartent de zéro — « hors ligne
    /// depuis 30 s » ne peut pas se déduire de deux relevés séparés par une
    /// nuit de veille, pendant laquelle le Wi-Fi est coupé par construction.
    static let trouMax: TimeInterval = 60

    struct EtatSujet: Equatable {
        /// La condition d'entrée tient depuis…
        var vraiDepuis: Date?
        /// La condition de sortie tient depuis… (épisode en cours)
        var relacheDepuis: Date?
        var episode: Episode?
    }

    private(set) var etats: [String: EtatSujet] = [:]
    private(set) var boite: [Alerte] = []
    private(set) var derniereNotification: Date?
    private(set) var dernierReleve: Date?

    static func cle(_ regle: String, _ sujet: String) -> String { "\(regle)|\(sujet)" }

    /// Un relevé. Rend les lignes du journal et les notifications à envoyer
    /// (zéro ou une).
    mutating func evaluer(_ regles: [Regle], _ releve: ReleveRegles, alertes reglages: ReglagesAlertes,
                          calendrier: Calendar = .current) -> (journal: [EntreeJournal], notifications: [NotificationRegle]) {
        let date = releve.date
        let trou = dernierReleve.map { date.timeIntervalSince($0) > Self.trouMax || date < $0 } ?? false
        dernierReleve = date
        var journal: [EntreeJournal] = []

        let actives = regles.filter { $0.active && CatalogueMesures.mesure($0.mesure) != nil }
        journal += oublier(sauf: Set(actives.map(\.id)), date: date, regles: regles)

        for regle in actives {
            guard let mesure = CatalogueMesures.mesure(regle.mesure) else { continue }
            if regle.comparaison == .survient || mesure.unite == .evenement {
                journal += evenements(regle, mesure, releve, calendrier: calendrier)
            } else {
                journal += niveaux(regle, mesure, releve, trou: trou, calendrier: calendrier)
            }
        }

        // Une règle a pu changer pendant que son alerte attendait (Isma a
        // décoché la notification, coché le son) : elle part selon les
        // réglages du moment, ou pas du tout.
        let parId = Dictionary(actives.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        boite = boite.compactMap { alerte in
            guard let regle = parId[alerte.regle], regle.notification else { return nil }
            var a = alerte
            a.nom = regle.nom
            a.son = regle.son
            a.urgente = regle.urgente
            return a
        }

        let (lignes, notification) = vider(releve, reglages: reglages, calendrier: calendrier)
        journal += lignes
        return (journal, notification.map { [$0] } ?? [])
    }

    /// Toutes les règles s'éteignent : chaque épisode se clôt au journal,
    /// la boîte se vide sans rien envoyer. (À la fermeture de l'app, rien de
    /// tout cela : les épisodes se reprennent au lancement suivant.)
    mutating func eteindre(date: Date, regles: [Regle]) -> [EntreeJournal] {
        let journal = oublier(sauf: [], date: date, regles: regles)
        dernierReleve = nil
        return journal
    }

    // MARK: - Mesures à niveau (un seuil)

    private mutating func niveaux(_ regle: Regle, _ mesure: MesureRegle, _ releve: ReleveRegles,
                                  trou: Bool, calendrier: Calendar) -> [EntreeJournal] {
        let date = releve.date
        var journal: [EntreeJournal] = []
        let presents: [Echantillon]? = releve.valeurs[mesure.id].map { tous in
            if let sujet = regle.sujet, mesure.parSujet { return tous.filter { $0.sujet == sujet } }
            return tous.filter { mesure.parSujet ? $0.suiviParDefaut : $0.sujet.isEmpty }
        }
        var vus = Set<String>()
        for echantillon in presents ?? [] {
            let cle = Self.cle(regle.id, echantillon.sujet)
            vus.insert(cle)
            var etat = etats[cle] ?? EtatSujet()
            if trou { etat.vraiDepuis = nil; etat.relacheDepuis = nil }
            let v = echantillon.valeur
            let (entree, sortie) = Self.conditions(regle, v)
            let texte = Self.phrase(regle, mesure, nom: echantillon.nom, valeur: v)
            let permis = regle.plage?.contient(date, calendrier: calendrier) ?? true

            if var episode = etat.episode {
                episode.valeur = v
                episode.sujetNom = echantillon.nom
                episode.texte = texte
                if sortie {
                    let depuis = etat.relacheDepuis ?? date
                    if date.timeIntervalSince(depuis) >= regle.relache {
                        journal.append(ligne(.fin, regle, echantillon.sujet, echantillon.nom, texte, date))
                        etats[cle] = nil
                        continue
                    }
                    etat.relacheDepuis = depuis
                } else {
                    etat.relacheDepuis = nil
                    // Différée (hors plage, ou reprise après un redémarrage) :
                    // dite dès que la plage s'ouvre, si la condition tient
                    // encore pour de bon — pas dans la marge d'hystérésis.
                    if !episode.notifie, entree, permis {
                        poster(regle, cle: cle, sujet: echantillon.sujet, nom: echantillon.nom,
                               texte: texte, debut: episode.debut, evenement: false)
                        episode.notifie = true
                    }
                }
                etat.episode = episode
            } else if entree {
                let depuis = etat.vraiDepuis ?? date
                etat.vraiDepuis = depuis
                if date.timeIntervalSince(depuis) >= regle.duree {
                    var episode = Episode(debut: date, notifie: true, sujetNom: echantillon.nom, texte: texte, valeur: v)
                    journal.append(ligne(.debut, regle, echantillon.sujet, echantillon.nom, texte, date))
                    if regle.notification {
                        if permis {
                            poster(regle, cle: cle, sujet: echantillon.sujet, nom: echantillon.nom,
                                   texte: texte, debut: date, evenement: false)
                        } else {
                            episode.notifie = false
                            journal.append(ligne(.horsPlage, regle, echantillon.sujet, echantillon.nom,
                                                 "différée : \(regle.plage?.texte ?? "")", date))
                        }
                    }
                    etat.episode = episode
                    etat.vraiDepuis = nil
                }
            } else {
                etat.vraiDepuis = nil
            }
            etats[cle] = etat
        }
        // Mesure absente pour un sujet suivi (disque débranché, forfait plus
        // réglé) : ni vraie ni fausse. Un épisode en cours est gelé — un
        // disque presque plein qu'on débranche et rebranche n'a pas été vidé
        // pour autant —, les compteurs repartent de zéro.
        let prefixe = Self.cle(regle.id, "")
        for cle in etats.keys where cle.hasPrefix(prefixe) && !vus.contains(cle) {
            etats[cle]?.vraiDepuis = nil
            etats[cle]?.relacheDepuis = nil
            if etats[cle]?.episode == nil { etats[cle] = nil }
        }
        return journal
    }

    /// Entrée et sortie de l'épisode. Entre les deux, la marge
    /// d'hystérésis : l'épisode en cours continue, aucun ne commence.
    static func conditions(_ regle: Regle, _ v: Double) -> (entree: Bool, sortie: Bool) {
        switch regle.comparaison {
        case .sous:     return (v < regle.seuil, v >= regle.seuil + regle.marge)
        case .atteint:  return (v >= regle.seuil, v < regle.seuil - regle.marge)
        case .vrai:     return (v >= 0.5, v < 0.5)
        case .survient: return (false, true)
        }
    }

    // MARK: - Événements

    private mutating func evenements(_ regle: Regle, _ mesure: MesureRegle, _ releve: ReleveRegles,
                                     calendrier: Calendar) -> [EntreeJournal] {
        let date = releve.date
        var journal: [EntreeJournal] = []
        // Un épisode par règle : trois plantages en dix minutes font UNE
        // notification, « a planté 3 fois ».
        let cle = Self.cle(regle.id, "")
        var etat = etats[cle] ?? EtatSujet()
        if let episode = etat.episode, let dernier = episode.dernierEvenement,
           date.timeIntervalSince(dernier) >= regle.relache {
            journal.append(ligne(.fin, regle, "", episode.sujetNom, episode.texte, date))
            etat = EtatSujet()
        }
        let survenus = (releve.evenements[mesure.id] ?? [])
            .filter { evt in regle.sujet.map { evt.sujet.localizedCaseInsensitiveContains($0) } ?? true }
            .sorted { $0.date < $1.date }
        for evt in survenus {
            if var episode = etat.episode {
                episode.nombre += 1
                episode.dernierEvenement = evt.date
                episode.texte = "\(evt.texte) — \(episode.nombre) fois depuis \(Self.heure(episode.debut, calendrier))"
                etat.episode = episode
                journal.append(ligne(.rafale, regle, evt.sujet, evt.sujet, episode.texte, date))
                // Pas encore partie (retenue, ou dans l'intervalle) : elle
                // dira le compte à jour.
                if let i = boite.firstIndex(where: { $0.cle == cle }) { boite[i].texte = episode.texte }
            } else {
                etat.episode = Episode(debut: evt.date, notifie: true, sujetNom: evt.sujet, texte: evt.texte,
                                       dernierEvenement: evt.date)
                journal.append(ligne(.debut, regle, evt.sujet, evt.sujet, evt.texte, date))
                if regle.notification {
                    if regle.plage?.contient(date, calendrier: calendrier) ?? true {
                        poster(regle, cle: cle, sujet: evt.sujet, nom: evt.sujet, texte: evt.texte,
                               debut: evt.date, evenement: true)
                    } else {
                        // Un fait passé ne se dit pas le lendemain matin.
                        journal.append(ligne(.horsPlage, regle, evt.sujet, evt.sujet,
                                             "tue : \(regle.plage?.texte ?? "")", date))
                    }
                }
            }
        }
        etats[cle] = etat.episode == nil ? nil : etat
        return journal
    }

    // MARK: - La boîte : regrouper, retenir, espacer

    private mutating func poster(_ regle: Regle, cle: String, sujet: String, nom: String, texte: String,
                                 debut: Date, evenement: Bool) {
        boite.removeAll { $0.cle == cle }
        boite.append(Alerte(cle: cle, regle: regle.id, nom: regle.nom, sujet: sujet, sujetNom: nom,
                            texte: texte, date: debut, son: regle.son, urgente: regle.urgente,
                            evenement: evenement))
    }

    /// Ce qui part maintenant : au plus UNE notification, qui regroupe tout
    /// ce qui attend. Rien tant qu'une notification est partie il y a moins
    /// de `intervalle` ; rien de non urgent tant qu'une app de montage est
    /// au premier plan.
    private mutating func vider(_ releve: ReleveRegles, reglages: ReglagesAlertes,
                                calendrier: Calendar) -> ([EntreeJournal], NotificationRegle?) {
        let date = releve.date
        var journal: [EntreeJournal] = []
        // Un état retombé avant d'avoir été dit ne se dit plus : « disque
        // presque plein » pour un disque qu'on vient de vider serait faux.
        boite.removeAll { alerte in
            guard !alerte.evenement, etats[alerte.cle]?.episode?.debut != alerte.date else { return false }
            journal.append(EntreeJournal(date: date, genre: .tombee, regle: alerte.regle, nom: alerte.nom,
                                         sujet: alerte.sujet, sujetNom: alerte.sujetNom,
                                         texte: "retombée avant d'être dite"))
            return true
        }
        guard !boite.isEmpty else { return (journal, nil) }

        let retenir = reglages.retenirEnMontage && releve.enMontage
        for i in boite.indices where retenir && !boite[i].urgente && !boite[i].retenueNotee {
            boite[i].retenueNotee = true
            journal.append(EntreeJournal(date: date, genre: .retenue, regle: boite[i].regle, nom: boite[i].nom,
                                         sujet: boite[i].sujet, sujetNom: boite[i].sujetNom,
                                         texte: "app de montage au premier plan"))
        }
        let partantes = boite.filter { !retenir || $0.urgente }
        guard !partantes.isEmpty else { return (journal, nil) }
        if let derniere = derniereNotification, date.timeIntervalSince(derniere) < reglages.intervalle {
            return (journal, nil)
        }
        let cles = Set(partantes.map(\.cle))
        boite.removeAll { cles.contains($0.cle) }
        derniereNotification = date
        let notification = Self.composer(partantes, date: date, calendrier: calendrier)
        for alerte in partantes {
            journal.append(EntreeJournal(date: date, genre: .notifiee, regle: alerte.regle, nom: alerte.nom,
                                         sujet: alerte.sujet, sujetNom: alerte.sujetNom,
                                         texte: partantes.count > 1 ? "regroupée (\(partantes.count) alertes)" : alerte.texte))
        }
        return (journal, notification)
    }

    /// Une alerte : son nom en titre, le fait mesuré en corps. Plusieurs :
    /// une ligne chacune. Une alerte qui a attendu dit depuis quand.
    static func composer(_ alertes: [Alerte], date: Date, calendrier: Calendar = .current) -> NotificationRegle {
        func ligne(_ a: Alerte) -> String {
            // Un événement dit déjà son heure (« a planté à 14 h 02 »).
            let attente = !a.evenement && date.timeIntervalSince(a.date) >= 120
            return a.texte + (attente ? " · depuis \(heure(a.date, calendrier))" : "")
        }
        let son = alertes.contains { $0.son }
        if alertes.count == 1, let seule = alertes.first {
            return NotificationRegle(titre: seule.nom, corps: ligne(seule), son: son, alertes: alertes)
        }
        return NotificationRegle(titre: "Pulse · \(alertes.count) alertes",
                                 corps: alertes.map { "\($0.nom) — \(ligne($0))" }.joined(separator: "\n"),
                                 son: son, alertes: alertes)
    }

    // MARK: - Reprise et extinction

    /// Au lancement : les épisodes que le journal laisse ouverts (un
    /// « début » sans « fin ») sont repris, déjà dits. Sans cela, chaque
    /// relance de Pulse redirait « disque presque plein » pour le même
    /// disque : une seule notification par épisode, redémarrage compris.
    mutating func reprendre(_ entrees: [EntreeJournal], regles: [Regle]) {
        let parId = Dictionary(regles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ouverts: [String: (episode: Episode, regle: Regle)] = [:]
        for entree in entrees.sorted(by: { $0.date < $1.date }) {
            guard let regle = parId[entree.regle], regle.active,
                  let mesure = CatalogueMesures.mesure(regle.mesure) else { continue }
            let evenement = regle.comparaison == .survient || mesure.unite == .evenement
            let cle = Self.cle(regle.id, evenement ? "" : entree.sujet)
            switch entree.genre {
            case .debut:
                ouverts[cle] = (Episode(debut: entree.date, notifie: evenement || !regle.notification,
                                        sujetNom: entree.sujetNom, texte: entree.texte,
                                        dernierEvenement: evenement ? entree.date : nil), regle)
            case .rafale:
                ouverts[cle]?.episode.dernierEvenement = entree.date
                ouverts[cle]?.episode.nombre += 1
            case .notifiee, .tombee:
                ouverts[cle]?.episode.notifie = true
            case .fin:
                ouverts[cle] = nil
            default:
                break
            }
        }
        for (cle, ouvert) in ouverts where etats[cle]?.episode == nil {
            etats[cle] = EtatSujet(episode: ouvert.episode)
        }
    }

    /// Oublie les règles éteintes ou supprimées : leurs épisodes se closent
    /// au journal, leurs alertes en attente sont retirées sans bruit.
    private mutating func oublier(sauf actives: Set<String>, date: Date, regles: [Regle] = []) -> [EntreeJournal] {
        var journal: [EntreeJournal] = []
        let noms = Dictionary(regles.map { ($0.id, $0.nom) }, uniquingKeysWith: { a, _ in a })
        for (cle, etat) in etats {
            let id = String(cle.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            guard !actives.contains(id) else { continue }
            if let episode = etat.episode {
                let sujet = String(cle.dropFirst(id.count + 1))
                journal.append(EntreeJournal(date: date, genre: .fin, regle: id,
                                             nom: noms[id] ?? boite.first { $0.regle == id }?.nom ?? id,
                                             sujet: sujet, sujetNom: episode.sujetNom, texte: "règle éteinte"))
            }
            etats[cle] = nil
        }
        boite.removeAll { !actives.contains($0.regle) }
        return journal
    }

    // MARK: - Ce que le panneau et la barre montrent

    /// Les épisodes en cours, règle par règle, dans l'ordre des règles.
    func enCours(_ regles: [Regle]) -> [(regle: Regle, sujet: String, episode: Episode)] {
        regles.filter(\.active).flatMap { regle in
            etats.filter { $0.key.hasPrefix(Self.cle(regle.id, "")) }
                .compactMap { cle, etat in
                    etat.episode.map { (regle, String(cle.dropFirst(regle.id.count + 1)), $0) }
                }
                .sorted { $0.episode.debut < $1.episode.debut }
        }
    }

    // MARK: - Phrases

    /// « Ssd 2 : 48,2 Go libres, sous 100 Go » ; « Forfait iPhone : 82 %,
    /// seuil 80 % » ; « Aucun réseau ».
    static func phrase(_ regle: Regle, _ mesure: MesureRegle, nom: String, valeur v: Double) -> String {
        let qui = nom.isEmpty ? mesure.nom : nom
        let suffixe = mesure.suffixe.isEmpty ? "" : " " + mesure.suffixe
        switch regle.comparaison {
        case .vrai, .survient: return qui
        case .sous: return "\(qui) : \(mesure.texte(v))\(suffixe), sous \(mesure.texte(regle.seuil))"
        case .atteint: return "\(qui) : \(mesure.texte(v))\(suffixe), seuil \(mesure.texte(regle.seuil))"
        }
    }

    static func heure(_ date: Date, _ calendrier: Calendar = .current) -> String {
        let c = calendrier.dateComponents([.hour, .minute], from: date)
        return String(format: "%d h %02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func ligne(_ genre: EntreeJournal.Genre, _ regle: Regle, _ sujet: String, _ nom: String,
                       _ texte: String, _ date: Date) -> EntreeJournal {
        EntreeJournal(date: date, genre: genre, regle: regle.id, nom: regle.nom, sujet: sujet,
                      sujetNom: nom, texte: texte)
    }
}

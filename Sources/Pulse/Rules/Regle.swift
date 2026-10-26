import Foundation

// Les règles d'Isma, telles qu'elles sont persistées dans `regles.json`.
//
// Règle dure n°2 : chaque champ se lit en `decodeIfPresent` (par
// `tolerant`, voir Settings.swift) et une valeur illisible retombe sur sa
// valeur par défaut. Une règle sans mesure ni comparaison lisible est
// écartée seule : jamais tout le fichier.

/// Comment une règle juge sa mesure.
enum Comparaison: String, Codable, CaseIterable {
    /// La mesure passe SOUS le seuil (l'espace libre d'un disque).
    case sous
    /// La mesure ATTEINT le seuil ou le dépasse (le forfait, le swap).
    case atteint
    /// L'état est vrai (hors ligne).
    case vrai
    /// Un événement survient (un export se termine, une app plante).
    case survient
}

/// Les heures où une règle a le droit de prévenir.
///
/// Une plage à cheval sur minuit (22 h → 7 h) appartient au jour où elle
/// commence : à 3 h du matin un samedi, c'est la plage du vendredi.
struct PlageHoraire: Codable, Equatable {
    /// Minutes depuis minuit, de 0 à 1439.
    var debut = 9 * 60
    var fin = 20 * 60
    /// Jours où la plage vaut, numérotés comme `Calendar` : 1 = dimanche,
    /// 2 = lundi … 7 = samedi. Vide : tous les jours.
    var jours: Set<Int> = []

    init(debut: Int = 9 * 60, fin: Int = 20 * 60, jours: Set<Int> = []) {
        self.debut = debut
        self.fin = fin
        self.jours = jours
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        debut = c.tolerant(Int.self, .debut).map { min(1439, max(0, $0)) } ?? 9 * 60
        fin = c.tolerant(Int.self, .fin).map { min(1439, max(0, $0)) } ?? 20 * 60
        jours = Set((c.tolerant([Lossy<Int>].self, .jours) ?? []).compactMap(\.value).filter { (1...7).contains($0) })
    }

    func contient(_ date: Date, calendrier: Calendar = .current) -> Bool {
        let c = calendrier.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let jour = c.weekday ?? 1
        let veille = jour == 1 ? 7 : jour - 1
        func vaut(_ j: Int) -> Bool { jours.isEmpty || jours.contains(j) }
        // Début et fin confondus : toute la journée.
        if debut == fin { return vaut(jour) }
        if debut < fin { return minute >= debut && minute < fin && vaut(jour) }
        if minute >= debut { return vaut(jour) }
        if minute < fin { return vaut(veille) }
        return false
    }

    /// « de 9 h à 20 h », « de 22 h 30 à 7 h, du lundi au vendredi ».
    var texte: String {
        func heure(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60) h" : String(format: "%d h %02d", m / 60, m % 60) }
        var out = debut == fin ? "toute la journée" : "de \(heure(debut)) à \(heure(fin))"
        if !jours.isEmpty, jours.count < 7 {
            let noms = [2: "lun.", 3: "mar.", 4: "mer.", 5: "jeu.", 6: "ven.", 7: "sam.", 1: "dim."]
            let ordre = [2, 3, 4, 5, 6, 7, 1]
            out += ", " + ordre.filter(jours.contains).compactMap { noms[$0] }.joined(separator: " ")
        }
        return out
    }
}

/// Une règle : une mesure, une condition, ce qu'il faut faire quand elle
/// tient, et quand se taire.
struct Regle: Codable, Equatable, Identifiable {
    /// Stable : clé du journal. « disque-rushes » pour un préréglage.
    var id: String
    var nom: String
    /// Éteinte par défaut, TOUJOURS : c'est Isma qui allume.
    var active = false
    /// Identifiant d'une `MesureRegle` (« disques.libre »).
    var mesure: String
    /// Pour une mesure par disque : la clé d'historique (UUID) du volume
    /// suivi, `nil` pour chaque disque externe. Pour un événement : un
    /// morceau du nom de l'app (« Premiere »), `nil` pour toutes.
    var sujet: String?
    /// Le dernier nom connu du sujet (« Ssd 2 »), pour l'affichage : un
    /// disque se remonte sous des noms variables, sa clé ne change pas.
    var sujetNom: String?
    var comparaison: Comparaison
    /// Dans l'unité de base de la mesure : octets, part de 1, jours.
    var seuil: Double = 0
    /// La condition doit tenir au moins tant, sans interruption.
    var duree: TimeInterval = 0
    /// Hystérésis : pour finir l'épisode, la mesure doit repasser le seuil
    /// de cette marge (« sous 100 Go » ne retombe qu'au-delà de 110 Go)…
    var marge: Double = 0
    /// … et y rester tant. Pour un événement : la rafale — un second
    /// plantage dans ce délai appartient au même épisode.
    var relache: TimeInterval = 60
    /// Les heures où la règle peut prévenir ; `nil` : à toute heure.
    var plage: PlageHoraire?
    /// Une notification macOS — retenue par Ne pas déranger et les modes de
    /// concentration, comme toute notification ordinaire.
    var notification = true
    /// La notification sonne (le son se tait lui aussi sous Ne pas déranger).
    var son = false
    /// Un symbole dans la barre de menus tant que l'épisode dure.
    var barre = true
    /// Passe même quand une app de montage est au premier plan.
    var urgente = false
    /// Le préréglage d'origine, `nil` pour une règle créée par Isma.
    var prereglage: String?

    init(id: String, nom: String, active: Bool = false, mesure: String, sujet: String? = nil,
         sujetNom: String? = nil, comparaison: Comparaison, seuil: Double = 0, duree: TimeInterval = 0,
         marge: Double = 0, relache: TimeInterval = 60, plage: PlageHoraire? = nil,
         notification: Bool = true, son: Bool = false, barre: Bool = true, urgente: Bool = false,
         prereglage: String? = nil) {
        self.id = id; self.nom = nom; self.active = active; self.mesure = mesure
        self.sujet = sujet; self.sujetNom = sujetNom; self.comparaison = comparaison
        self.seuil = seuil; self.duree = duree; self.marge = marge; self.relache = relache
        self.plage = plage; self.notification = notification; self.son = son; self.barre = barre
        self.urgente = urgente; self.prereglage = prereglage
    }

    enum CodingKeys: String, CodingKey {
        case id, nom, active, mesure, sujet, sujetNom, comparaison, seuil, duree, marge, relache
        case plage, notification, son, barre, urgente, prereglage
    }

    /// Une règle sans identifiant, sans mesure ou sans comparaison lisible
    /// ne veut rien dire : elle lève, et `Lossy` l'écarte SEULE.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.tolerant(String.self, .id), !id.isEmpty,
              let mesure = c.tolerant(String.self, .mesure),
              let comparaison = c.tolerant(String.self, .comparaison).flatMap(Comparaison.init(rawValue:))
        else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "règle illisible")) }
        self.id = id
        self.mesure = mesure
        self.comparaison = comparaison
        nom = c.tolerant(String.self, .nom) ?? id
        active = c.tolerant(Bool.self, .active) ?? false
        sujet = c.tolerant(String.self, .sujet)
        sujetNom = c.tolerant(String.self, .sujetNom)
        seuil = c.tolerant(Double.self, .seuil).flatMap { $0.isFinite ? $0 : nil } ?? 0
        duree = max(0, c.tolerant(Double.self, .duree) ?? 0)
        marge = max(0, c.tolerant(Double.self, .marge) ?? 0)
        relache = max(0, c.tolerant(Double.self, .relache) ?? 60)
        plage = c.tolerant(PlageHoraire.self, .plage)
        notification = c.tolerant(Bool.self, .notification) ?? true
        son = c.tolerant(Bool.self, .son) ?? false
        barre = c.tolerant(Bool.self, .barre) ?? true
        urgente = c.tolerant(Bool.self, .urgente) ?? false
        prereglage = c.tolerant(String.self, .prereglage)
    }
}

/// Les réglages communs à toutes les règles : comment Pulse se tait.
struct ReglagesAlertes: Codable, Equatable {
    /// Au plus une notification par intervalle : ce qui se déclenche
    /// entre-temps part, regroupé, dans la suivante.
    var intervalle: TimeInterval = 300
    /// Tant qu'une app de montage (Premiere…) est au premier plan, les
    /// notifications attendent, sauf celles des règles urgentes. Le symbole
    /// de la barre, lui, s'allume tout de suite : il ne fait pas de bruit.
    var retenirEnMontage = true

    static let intervalles: [TimeInterval] = [60, 300, 900, 1800]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalle = c.tolerant(Double.self, .intervalle).map { max(0, $0) } ?? 300
        retenirEnMontage = c.tolerant(Bool.self, .retenirEnMontage) ?? true
    }
}

/// `regles.json` tout entier.
struct FichierRegles: Codable, Equatable {
    var version = 1
    var regles: [Regle] = Prereglages.tous
    var alertes = ReglagesAlertes()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerant(Int.self, .version) ?? 1
        let lues = (c.tolerant([Lossy<Regle>].self, .regles) ?? []).compactMap(\.value)
        regles = Prereglages.completer(lues)
        alertes = c.tolerant(ReglagesAlertes.self, .alertes) ?? ReglagesAlertes()
    }
}

/// Les préréglages : TOUS éteints. Isma allume ceux qu'il veut.
enum Prereglages {
    static let go = 1e9                 // stockage : base 1000, comme le Finder
    static let gio = 1_073_741_824.0    // mémoire : base 1024 (règle dure n°3)

    static var tous: [Regle] {
        [
            Regle(id: "disque-rushes", nom: "Disque de rushes presque plein",
                  mesure: "disques.libre", comparaison: .sous, seuil: 100 * go,
                  duree: 60, marge: 10 * go, relache: 600, prereglage: "disque-rushes"),
            Regle(id: "export-termine", nom: "Export terminé",
                  mesure: "montage.exportTermine", comparaison: .survient,
                  relache: 900, prereglage: "export-termine"),
            // 19-suivis : la fin d'une copie de carte ou entre disques,
            // panneau fermé compris (le chantier 05 la publie pour elle).
            Regle(id: "copie-terminee", nom: "Copie de rushes terminée",
                  mesure: "disques.copieTerminee", comparaison: .survient,
                  relache: 900, prereglage: "copie-terminee"),
            Regle(id: "premiere-plante", nom: "Premiere a planté",
                  mesure: "montage.plantage", sujet: "Premiere", sujetNom: "Premiere",
                  comparaison: .survient, relache: 600, prereglage: "premiere-plante"),
            Regle(id: "forfait-80", nom: "Forfait iPhone à 80 %",
                  mesure: "reseau.forfait", comparaison: .atteint, seuil: 0.8,
                  relache: 600, prereglage: "forfait-80"),
            Regle(id: "forfait-100", nom: "Forfait iPhone épuisé",
                  mesure: "reseau.forfait", comparaison: .atteint, seuil: 1.0,
                  relache: 600, prereglage: "forfait-100"),
            Regle(id: "swap-monte", nom: "Le swap monte",
                  mesure: "memoire.swapHausse", comparaison: .atteint, seuil: 1 * gio,
                  duree: 60, marge: 0.25 * gio, relache: 600, prereglage: "swap-monte"),
            Regle(id: "connexion-perdue", nom: "Connexion perdue",
                  mesure: "reseau.horsLigne", comparaison: .vrai,
                  duree: 30, relache: 30, prereglage: "connexion-perdue"),
        ]
    }

    /// Les règles lues, plus les préréglages qui leur manquent (ajoutés par
    /// une version plus récente), éteints, à leur place d'origine.
    static func completer(_ lues: [Regle]) -> [Regle] {
        var vues = Set<String>()
        var out = lues.filter { vues.insert($0.id).inserted }
        for (rang, prereglage) in tous.enumerated() where !vues.contains(prereglage.id) {
            out.insert(prereglage, at: min(rang, out.count))
        }
        return out
    }
}

import SwiftUI

/// Une prévision Open-Meteo, décodée.
struct PrevisionMeteo: Equatable {
    struct Instant: Equatable {
        var date: Date
        var temperature: Double?
        var code: Int?
        var jour: Bool?
    }

    struct Heure: Equatable {
        var date: Date
        var temperature: Double?
        /// Probabilité de pluie, en pour cent (0 à 100) : un vrai total.
        var pluie: Double?
        var code: Int?
        var jour: Bool?
    }

    struct Jour: Equatable {
        /// Minuit, heure du lieu.
        var date: Date
        var code: Int?
        var maximum: Double?
        var minimum: Double?
        var pluie: Double?
        var lever: Date?
        var coucher: Date?
    }

    var latitude: Double
    var longitude: Double
    /// Le fuseau du lieu, lu dans la réponse (`timezone`, sinon le décalage).
    var fuseau: TimeZone
    var actuelle: Instant?
    var heures: [Heure]
    var jours: [Jour]

    /// Les heures à venir à partir de l'heure entamée.
    func prochainesHeures(_ nombre: Int, depuis maintenant: Date) -> [Heure] {
        let debut = maintenant.addingTimeInterval(-3599)
        return Array(heures.filter { $0.date > debut }.prefix(nombre))
    }

    /// Toutes les dates décalées d'un même écart : l'exemple, recalé sur
    /// l'heure du rendu.
    func decalee(de ecart: TimeInterval) -> PrevisionMeteo {
        var copie = self
        copie.actuelle?.date.addTimeInterval(ecart)
        copie.heures = heures.map { var h = $0; h.date.addTimeInterval(ecart); return h }
        copie.jours = jours.map { j in
            var j = j
            j.date.addTimeInterval(ecart); j.lever?.addTimeInterval(ecart); j.coucher?.addTimeInterval(ecart)
            return j
        }
        return copie
    }
}

/// L'API de prévision d'Open-Meteo : gratuite, sans clé, sans compte. Ce
/// qui sort : la latitude et la longitude de la ville choisie, au centième
/// de degré (≈ 1 km), et l'adresse IP du Mac, comme toute requête.
enum OpenMeteo {
    static let hote = "api.open-meteo.com"

    enum Erreur: Error, Equatable {
        case pasDuJSON
        case refus(String)
        case incomplete
    }

    /// `timeformat=unixtime` : des secondes UTC, sans fuseau à deviner ;
    /// `timezone=auto` : les jours coupés à minuit du lieu.
    static func url(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = hote
        c.path = "/v1/forecast"
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "forecast_hours", value: "24"),
        ]
        return c.url!
    }

    /// Décodage tolérant : une valeur absente, `null` ou d'un autre type
    /// devient nil sans faire échouer la prévision ; les dates se lisent en
    /// secondes UTC (`unixtime`) comme en ISO 8601 local (« 2026-10-11T07:00 »,
    /// « 2026-10-11 »), à l'heure du lieu. Seule une réponse qui n'est pas
    /// un objet JSON, une erreur déclarée (`"error": true`) ou une réponse
    /// sans aucune heure ni aucun jour sont refusées.
    static func decode(_ data: Data) throws -> PrevisionMeteo {
        guard let racine = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Erreur.pasDuJSON }
        if racine["error"] as? Bool == true {
            throw Erreur.refus(racine["reason"] as? String ?? "raison non donnée")
        }
        let decalage = (racine["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0
        let fuseau = (racine["timezone"] as? String).flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: decalage) ?? TimeZone(identifier: "UTC")!

        func date(_ valeur: Any?) -> Date? {
            if let n = valeur as? NSNumber, !(valeur is Bool) { return Date(timeIntervalSince1970: n.doubleValue) }
            guard let texte = valeur as? String else { return nil }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = fuseau
            for motif in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
                f.dateFormat = motif
                if let d = f.date(from: texte) { return d }
            }
            return nil
        }
        func nombre(_ valeur: Any?) -> Double? {
            guard let n = valeur as? NSNumber, n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func entier(_ valeur: Any?) -> Int? { nombre(valeur).map { Int($0) } }
        func booleen(_ valeur: Any?) -> Bool? { nombre(valeur).map { $0 != 0 } }
        func serie(_ bloc: [String: Any]?, _ cle: String) -> [Any] { bloc?[cle] as? [Any] ?? [] }
        func a(_ tableau: [Any], _ i: Int) -> Any? { i < tableau.count ? tableau[i] : nil }

        var actuelle: PrevisionMeteo.Instant?
        if let c = racine["current"] as? [String: Any], let d = date(c["time"]) {
            actuelle = .init(date: d, temperature: nombre(c["temperature_2m"]), code: entier(c["weather_code"]),
                             jour: booleen(c["is_day"]))
        }

        let h = racine["hourly"] as? [String: Any]
        let ht = serie(h, "time"), hT = serie(h, "temperature_2m"), hP = serie(h, "precipitation_probability")
        let hC = serie(h, "weather_code"), hJ = serie(h, "is_day")
        var heures: [PrevisionMeteo.Heure] = []
        for i in ht.indices {
            guard let d = date(ht[i]) else { continue }
            heures.append(.init(date: d, temperature: nombre(a(hT, i)), pluie: nombre(a(hP, i)),
                                code: entier(a(hC, i)), jour: booleen(a(hJ, i))))
        }

        let j = racine["daily"] as? [String: Any]
        let jt = serie(j, "time"), jC = serie(j, "weather_code"), jMax = serie(j, "temperature_2m_max")
        let jMin = serie(j, "temperature_2m_min"), jP = serie(j, "precipitation_probability_max")
        let jL = serie(j, "sunrise"), jCo = serie(j, "sunset")
        var jours: [PrevisionMeteo.Jour] = []
        for i in jt.indices {
            guard let d = date(jt[i]) else { continue }
            jours.append(.init(date: d, code: entier(a(jC, i)), maximum: nombre(a(jMax, i)), minimum: nombre(a(jMin, i)),
                               pluie: nombre(a(jP, i)), lever: date(a(jL, i)), coucher: date(a(jCo, i))))
        }
        guard !heures.isEmpty || !jours.isEmpty || actuelle != nil else { throw Erreur.incomplete }
        return PrevisionMeteo(latitude: nombre(racine["latitude"]) ?? 0, longitude: nombre(racine["longitude"]) ?? 0,
                              fuseau: fuseau, actuelle: actuelle, heures: heures, jours: jours)
    }
}

/// Les codes météo de l'OMM qu'Open-Meteo utilise, en français et en
/// symboles. Le jour et la nuit se lisent au symbole, jamais à la couleur.
enum CodeMeteo {
    static func libelle(_ code: Int?) -> String {
        switch code {
        case 0?: return "Ciel dégagé"
        case 1?: return "Plutôt dégagé"
        case 2?: return "Partiellement nuageux"
        case 3?: return "Couvert"
        case 45?: return "Brouillard"
        case 48?: return "Brouillard givrant"
        case 51?: return "Bruine légère"
        case 53?: return "Bruine"
        case 55?: return "Bruine dense"
        case 56?, 57?: return "Bruine verglaçante"
        case 61?: return "Pluie faible"
        case 63?: return "Pluie"
        case 65?: return "Forte pluie"
        case 66?, 67?: return "Pluie verglaçante"
        case 71?: return "Neige faible"
        case 73?: return "Neige"
        case 75?: return "Forte neige"
        case 77?: return "Grains de neige"
        case 80?: return "Averses"
        case 81?: return "Averses modérées"
        case 82?: return "Averses violentes"
        case 85?, 86?: return "Averses de neige"
        case 95?, 97?: return "Orage"
        case 96?, 99?: return "Orage et grêle"
        case let autre?: return "Code météo \(autre)"
        case nil: return "Temps inconnu"
        }
    }

    static func symbole(_ code: Int?, jour: Bool = true) -> String {
        switch code {
        case 0?: return jour ? "sun.max" : "moon.stars"
        case 1?: return jour ? "sun.max" : "moon"
        case 2?: return jour ? "cloud.sun" : "cloud.moon"
        case 3?: return "cloud"
        case 45?, 48?: return "cloud.fog"
        case 51?, 53?, 55?: return "cloud.drizzle"
        case 56?, 57?, 66?, 67?: return "cloud.sleet"
        case 61?, 63?: return "cloud.rain"
        case 65?, 82?: return "cloud.heavyrain"
        case 71?, 73?, 75?, 77?, 85?, 86?: return "cloud.snow"
        case 80?, 81?: return jour ? "cloud.sun.rain" : "cloud.moon.rain"
        case 95?, 97?: return "cloud.bolt"
        case 96?, 99?: return "cloud.bolt.rain"
        default: return "questionmark.circle"
        }
    }
}

/// La dernière prévision reçue, gardée dans
/// `~/Library/Application Support/Pulse/meteo.json` : la réponse brute
/// d'Open-Meteo, la ville et l'heure de réception. Relue de façon tolérante
/// (un fichier abîmé est ignoré, la prochaine réponse le remplace) ; écrite
/// seulement par l'app installée.
enum CacheMeteo {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true).appendingPathComponent("meteo.json")
    }

    struct Contenu {
        var ville: String
        var recue: Date
        var prevision: PrevisionMeteo
    }

    static func lire(_ url: URL = url) -> Contenu? {
        guard let data = try? Data(contentsOf: url),
              let racine = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let reponse = racine["reponse"],
              // Une « reponse » qui n'est pas un objet lèverait une exception
              // Objective-C, que `try?` ne rattrape pas.
              JSONSerialization.isValidJSONObject(reponse),
              let brut = try? JSONSerialization.data(withJSONObject: reponse),
              let prevision = try? OpenMeteo.decode(brut) else { return nil }
        let recue = (racine["recue"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
        return Contenu(ville: racine["ville"] as? String ?? "", recue: recue, prevision: prevision)
    }

    /// `autorise` : la persistance de l'app (`Persistence`), sauf dans un
    /// test qui écrit dans son propre dossier.
    static func ecrire(reponse: Data, ville: String, recue: Date, _ url: URL = url,
                       autorise: Bool = Persistence.enabled) {
        guard autorise, let objet = try? JSONSerialization.jsonObject(with: reponse) else { return }
        let racine: [String: Any] = ["ville": ville, "recue": recue.timeIntervalSince1970, "reponse": objet]
        guard let data = try? JSONSerialization.data(withJSONObject: racine, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Les réglages de la carte Météo (`modules.meteo.options`).
struct ReglagesMeteo: Equatable {
    static let module = "meteo"
    var ville = "auto"

    init() {}
    init(options: [String: OptionValue]) {
        ville = options["ville"]?.text ?? "auto"
    }
}

/// La prévision du moment, et ce qu'il advient de la requête. Partagée par
/// la carte, le segment de barre et `--probe`.
@MainActor
final class Meteo: ObservableObject {
    static let shared = Meteo()

    enum Etat: Equatable {
        /// Carte masquée : rien ne part, rien ne tourne.
        case desactivee
        /// Hors de l'app installée (rendu, relevé, banc) : aucune requête.
        case horsApp
        case enCours
        case recue
        case echec(String)
    }

    @Published private(set) var prevision: PrevisionMeteo?
    @Published private(set) var recue: Date?
    @Published private(set) var etat = Etat.desactivee
    @Published private(set) var ville: Ville?
    private(set) var requetes = 0

    /// Une prévision de moins de 30 min ne se redemande pas, panneau
    /// ouvert ; panneau fermé, d'une heure — pour le segment de barre.
    static let fraicheOuvert: TimeInterval = 30 * 60
    static let fraicheFerme: TimeInterval = 60 * 60

    private var minuterie: Timer?
    private var tache: URLSessionDataTask?
    private var ouvert = false

    /// Carte affichée ou non, panneau ouvert ou non.
    func regler(affiche: Bool, panneauOuvert: Bool, reglages: ReglagesMeteo) {
        ouvert = panneauOuvert
        let choisie = Villes.choisie(reglages.ville)
        if choisie?.cle != ville?.cle {
            ville = choisie
            if Extras.appReelle || Extras.exemple { prevision = nil; recue = nil }
        }
        guard affiche || Extras.exemple else {
            minuterie?.invalidate(); minuterie = nil
            tache?.cancel(); tache = nil
            etat = .desactivee
            // Carte masquée : plus de prévision en mémoire, donc plus de
            // segment de barre figé sur une température d'il y a des heures.
            prevision = nil
            recue = nil
            return
        }
        if Extras.exemple {
            prevision = ExemplesMeteo.recalee(Date())
            recue = Date()
            etat = .recue
            return
        }
        guard Extras.appReelle else {
            // Un rendu ou un relevé lit la dernière prévision de l'app,
            // sans rien demander.
            if let cache = CacheMeteo.lire() {
                prevision = cache.prevision
                recue = cache.recue
            }
            etat = .horsApp
            return
        }
        if prevision == nil, let cache = CacheMeteo.lire(), cache.ville == ville?.cle {
            prevision = cache.prevision
            recue = cache.recue
            etat = .recue
        }
        if minuterie == nil {
            let m = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rafraichirSiBesoin() }
            }
            m.tolerance = 60
            RunLoop.main.add(m, forMode: .common)
            minuterie = m
        }
        rafraichirSiBesoin()
    }

    func rafraichirSiBesoin(_ maintenant: Date = Date()) {
        guard Extras.appReelle, tache == nil, let ville else { return }
        let age = recue.map { maintenant.timeIntervalSince($0) } ?? .infinity
        guard age >= (ouvert ? Self.fraicheOuvert : Self.fraicheFerme) else { return }
        demander(ville)
    }

    private func demander(_ ville: Ville) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        etat = .enCours
        requetes += 1
        let cle = ville.cle
        let t = session.dataTask(with: OpenMeteo.url(latitude: ville.latitude, longitude: ville.longitude)) { data, reponse, erreur in
            // Annulée parce que la carte a été masquée : `regler` a déjà
            // tout remis à zéro, et une requête suivante a peut-être pris sa
            // place — la rendre ici effaçait sa poignée (`tache = nil`), ce
            // qui permettait une requête en double, et affichait un faux
            // échec (17-audit-code).
            if (erreur as? URLError)?.code == .cancelled { return }
            let resultat: Reponse
            if let erreur {
                resultat = .echec(erreur.localizedDescription)
            } else if let data {
                do { resultat = .recue(try OpenMeteo.decode(data), data) }
                catch OpenMeteo.Erreur.refus(let raison) { resultat = .echec("refusée : \(raison)") }
                catch { resultat = .echec("réponse illisible (HTTP \((reponse as? HTTPURLResponse)?.statusCode ?? 0))") }
            } else {
                resultat = .echec("réponse vide")
            }
            Task { @MainActor in self.recevoir(resultat, ville: cle) }
        }
        tache = t
        t.resume()
        session.finishTasksAndInvalidate()
    }

    /// Ce que rend une requête : la prévision et la réponse brute, à garder
    /// dans `meteo.json`, ou la raison de l'échec.
    private enum Reponse {
        case recue(PrevisionMeteo, Data)
        case echec(String)
    }

    private func recevoir(_ resultat: Reponse, ville cle: String) {
        tache = nil
        switch resultat {
        case .recue(let prevision, let brut):
            guard cle == ville?.cle else { return }
            let maintenant = Date()
            self.prevision = prevision
            recue = maintenant
            etat = .recue
            CacheMeteo.ecrire(reponse: brut, ville: cle, recue: maintenant)
        case .echec(let message):
            etat = .echec(message)
        }
    }
}

/// Le module Météo, chantier 18 : la prévision d'Open-Meteo, heure par heure
/// et sur la semaine. DÉSACTIVÉ par défaut ; activé par Isma, il sort sur
/// Internet, et la carte le dit.
struct MeteoModule: PulseModule {
    let id = ReglagesMeteo.module
    let name = "Météo"
    let symbol = "cloud.sun"
    var summary: String {
        "La prévision d'Open-Meteo, heure par heure et sur 7 jours. Sort sur Internet : la position de la ville choisie part vers api.open-meteo.com."
    }
    var enabledByDefault: Bool { false }
    var defaultColumn: Int { 1 }

    var cost: ModuleCost {
        ModuleCost(closed: 0, open: 0,
                   note: "météo : carte masquée, rien ; affichée, une requête HTTPS au plus toutes les 30 min panneau ouvert, toutes les heures fermé (contrôle toutes les 15 min)")
    }

    var options: [ModuleOption] {
        [ModuleOption(id: "ville", label: "Ville",
                      help: "Sa position, au centième de degré, est envoyée à api.open-meteo.com. Aucune localisation n'est demandée au Mac.",
                      kind: .choice(Villes.choix(), default: "auto"))]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(CarteMeteo(meteo: Meteo.shared, compact: context.compact,
                           affichee: context.settings.enabled ?? false))
    }

    func stateDidChange(_ state: ModuleState) {
        Meteo.shared.regler(affiche: state.enabled, panneauOuvert: state.panelOpen,
                            reglages: ReglagesMeteo(options: SettingsStore.shared.settings.module(id).options))
    }

    /// « MÉTÉO » sur « 18° ».
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        guard let p = Meteo.shared.prevision, let t = p.actuelle?.temperature ?? p.prochainesHeures(1, depuis: Date()).first?.temperature
        else { return nil }
        let code = p.actuelle?.code
        return MenuBarSegment(label: "MÉTÉO", value: CarteMeteo.degres(t),
                              spoken: "\(CodeMeteo.libelle(code)), \(Int(t.rounded())) degrés")
    }

    /// Comme le calendrier : la section règle la météo comme l'app au
    /// lancement ; hors de l'app installée, aucune requête, la dernière
    /// prévision de l'app (`meteo.json`) seulement.
    func probeSection() -> ProbeSection? {
        let affichee = Layout.isEnabled(self, in: SettingsStore.shared.settings)
        stateDidChange(ModuleState(enabled: affichee, panelOpen: false))
        return Self.section(Meteo.shared, affichee: affichee)
    }

    static func section(_ meteo: Meteo, affichee: Bool, maintenant: Date = Date()) -> ProbeSection {
        var lignes: [String] = []
        if !affichee && !Extras.exemple {
            lignes.append("carte masquée (désactivée par défaut) : aucune requête n'est jamais partie")
            return ProbeSection(title: "MÉTÉO", lines: lignes)
        }
        if Extras.exemple { lignes.append("réponse d'exemple (--exemple), écrite d'après la documentation : aucune requête") }
        if meteo.etat == .horsApp { lignes.append("hors de l'app installée : aucune requête, dernière prévision de l'app (meteo.json)") }
        if case .echec(let message) = meteo.etat { lignes.append("dernière requête en échec : \(message)") }
        guard let p = meteo.prevision else {
            lignes.append("aucune prévision reçue")
            return ProbeSection(title: "MÉTÉO", lines: lignes)
        }
        let ville = meteo.ville.map { "\($0.nom) (\(String(format: "%.2f", $0.latitude)), \(String(format: "%.2f", $0.longitude)))" } ?? "?"
        lignes.append("\(ville) · grille Open-Meteo \(String(format: "%.3f", p.latitude)), \(String(format: "%.3f", p.longitude)) · \(p.fuseau.identifier)"
                      + (meteo.recue.map { " · reçue à \(Extras.heure($0))" } ?? ""))
        if let a = p.actuelle {
            lignes.append("maintenant      \(a.temperature.map(CarteMeteo.degres) ?? "?") · \(CodeMeteo.libelle(a.code)) · \(a.jour == false ? "nuit" : "jour")")
        }
        let heures = p.prochainesHeures(12, depuis: maintenant)
        if !heures.isEmpty {
            lignes.append("12 heures       " + heures.map { h in
                "\(Extras.formateur("HH", p.fuseau).string(from: h.date))h \(h.temperature.map(CarteMeteo.degres) ?? "?")"
                    + (h.pluie.map { $0 >= 10 ? " \(Int($0)) %" : "" } ?? "")
            }.joined(separator: " · "))
        }
        for j in p.jours {
            lignes.append("\(Extras.formateur("EEE d", p.fuseau).string(from: j.date).padding(toLength: 15, withPad: " ", startingAt: 0)) "
                          + "\(j.minimum.map(CarteMeteo.degres) ?? "?") → \(j.maximum.map(CarteMeteo.degres) ?? "?") · \(CodeMeteo.libelle(j.code))"
                          + (j.pluie.map { " · pluie \(Int($0)) %" } ?? ""))
        }
        return ProbeSection(title: "MÉTÉO", lines: lignes)
    }
}

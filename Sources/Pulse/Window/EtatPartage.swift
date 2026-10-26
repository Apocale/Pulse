import Foundation

/// Ce que les widgets et les actions Raccourcis disent, tiré de ce que Pulse
/// relève déjà : ils ne mesurent RIEN eux-mêmes.
///
/// Les chiffres y sont déjà mis en mots par l'app (`Fmt`) : le widget, un
/// autre processus, n'a qu'à les afficher, et dit donc au caractère près ce
/// que dit le panneau — et ce qu'imprime `--probe` (section WIDGETS ET
/// RACCOURCIS). Les nombres bruts restent à côté pour les jauges et les
/// réponses des Raccourcis.
///
/// Persisté dans `etat-partage.json` pour l'extension de widgets : chaque
/// champ se relit en `decodeIfPresent` (règle dure n°2), une version future
/// de l'app ne doit jamais casser le widget d'une version passée.
struct EtatPartage: Codable, Equatable {
    var version = 1
    /// Quand ces valeurs ont été relevées.
    var date = Date()
    var verdict = VerdictPartage()
    var memoire = MemoirePartagee()
    var disques: [DisquePartage] = []
    /// Identifiant (UUID) du disque de rushes, s'il est branché.
    var rushes: String?
    var forfait: ForfaitPartage?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? .distantPast
        verdict = (try? c.decodeIfPresent(VerdictPartage.self, forKey: .verdict)) ?? VerdictPartage()
        memoire = (try? c.decodeIfPresent(MemoirePartagee.self, forKey: .memoire)) ?? MemoirePartagee()
        disques = ((try? c.decodeIfPresent([Tolerant<DisquePartage>].self, forKey: .disques)) ?? [])
            .compactMap(\.value)
        rushes = (try? c.decodeIfPresent(String.self, forKey: .rushes)) ?? nil
        forfait = (try? c.decodeIfPresent(ForfaitPartage.self, forKey: .forfait)) ?? nil
    }

    /// Le disque de rushes branché, sinon le disque interne : un widget
    /// « disque » qui n'aurait rien à dire resterait vide sur le bureau.
    var disqueDeRushes: DisquePartage? {
        disques.first { $0.id == rushes } ?? disques.first { $0.interne }
    }

    /// Le disque d'identifiant `id`, ou celui dont le nom correspond
    /// (« Ssd 2 », sans tenir compte de la casse ni des accents).
    func disque(_ query: String) -> DisquePartage? {
        if let exact = disques.first(where: { $0.id == query }) { return exact }
        let wanted = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return disques.first {
            $0.nom.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == wanted
        }
    }
}

/// Le verdict, tel que l'affiche le bandeau du panneau.
struct VerdictPartage: Codable, Equatable {
    /// `alert`, `warning`, `data`, `muted` (`VerdictLevel`).
    var niveau = "muted"
    var phrase = "Premier relevé en cours"
    var preuve = ""
    var symbole = "clock"
    /// Aucune règle d'avertissement ni d'alerte : « Pulse est calme ».
    /// Faux tant qu'aucun relevé n'a été fait : une absence de mesure ne se
    /// lit jamais comme un feu vert.
    var calme = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        niveau = (try? c.decodeIfPresent(String.self, forKey: .niveau)) ?? "muted"
        phrase = (try? c.decodeIfPresent(String.self, forKey: .phrase)) ?? ""
        preuve = (try? c.decodeIfPresent(String.self, forKey: .preuve)) ?? ""
        symbole = (try? c.decodeIfPresent(String.self, forKey: .symbole)) ?? "clock"
        calme = (try? c.decodeIfPresent(Bool.self, forKey: .calme)) ?? false
    }
}

struct MemoirePartagee: Codable, Equatable {
    /// « 21,3 Go » : `Fmt.memory`, base 1024 (règle dure n°3).
    var utilisee = "—"
    var totale = "—"
    /// Utilisée sur installée, de 0 à 1 : un dénominateur réel.
    var fraction = 0.0
    /// « normale », « modérée », « élevée », « critique ».
    var pression = "—"
    /// La pression d'iStat (complément de la mémoire libre du noyau), de 0
    /// à 1 ; nil si le noyau ne répond pas.
    var pressionFraction: Double?
    var swap = "—"
    var swapOctets: UInt64 = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilisee = (try? c.decodeIfPresent(String.self, forKey: .utilisee)) ?? "—"
        totale = (try? c.decodeIfPresent(String.self, forKey: .totale)) ?? "—"
        fraction = (try? c.decodeIfPresent(Double.self, forKey: .fraction)) ?? 0
        pression = (try? c.decodeIfPresent(String.self, forKey: .pression)) ?? "—"
        pressionFraction = (try? c.decodeIfPresent(Double.self, forKey: .pressionFraction)) ?? nil
        swap = (try? c.decodeIfPresent(String.self, forKey: .swap)) ?? "—"
        swapOctets = (try? c.decodeIfPresent(UInt64.self, forKey: .swapOctets)) ?? 0
    }
}

struct DisquePartage: Codable, Equatable, Identifiable {
    /// L'UUID du volume : le point de montage change (« Ssd », « Ssd 2 »),
    /// l'UUID non. C'est aussi la clé de l'historique.
    var id = ""
    var nom = ""
    /// « 212 Go » : `Fmt.bytes`, base 1000, purgeable compris — le chiffre
    /// « libres » de la carte Disques.
    var libre = "—"
    var libreOctets: UInt64 = 0
    var total = "—"
    /// Occupée sur capacité, de 0 à 1 : la seule barre permise (règle n°7).
    var occupation = 0.0
    /// « 91 % », arrondi vers le bas comme l'anneau et la barre de menus.
    var occupationTexte = "—"
    /// « plein vers lundi », « plein dans ~3 mois », « se vide de… » ; nil
    /// tant que la tendance n'est pas établie (6 h d'observation calme).
    var tendance: String?
    var joursAvantPlein: Double?
    var interne = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        nom = (try? c.decodeIfPresent(String.self, forKey: .nom)) ?? ""
        libre = (try? c.decodeIfPresent(String.self, forKey: .libre)) ?? "—"
        libreOctets = (try? c.decodeIfPresent(UInt64.self, forKey: .libreOctets)) ?? 0
        total = (try? c.decodeIfPresent(String.self, forKey: .total)) ?? "—"
        occupation = (try? c.decodeIfPresent(Double.self, forKey: .occupation)) ?? 0
        occupationTexte = (try? c.decodeIfPresent(String.self, forKey: .occupationTexte)) ?? "—"
        tendance = (try? c.decodeIfPresent(String.self, forKey: .tendance)) ?? nil
        joursAvantPlein = (try? c.decodeIfPresent(Double.self, forKey: .joursAvantPlein)) ?? nil
        interne = (try? c.decodeIfPresent(Bool.self, forKey: .interne)) ?? false
    }
}

/// Le partage iPhone : ce Mac seulement, base 1000 comme les opérateurs.
struct ForfaitPartage: Codable, Equatable {
    var aujourdhui = "—"
    var aujourdhuiOctets: UInt64 = 0
    var cycle = "—"
    var cycleOctets: UInt64 = 0
    /// « 50 Go » ; nil si le forfait n'est pas réglé (pas de jauge).
    var quota: String?
    /// Consommé sur forfait, de 0 à 1 ; nil sans forfait réglé.
    var fraction: Double?
    /// Le jour où le forfait repart de zéro.
    var renouvellement = Date.distantFuture
    /// « épuisé vers le 24/10 », seulement si c'est avant le renouvellement.
    var echeance: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aujourdhui = (try? c.decodeIfPresent(String.self, forKey: .aujourdhui)) ?? "—"
        aujourdhuiOctets = (try? c.decodeIfPresent(UInt64.self, forKey: .aujourdhuiOctets)) ?? 0
        cycle = (try? c.decodeIfPresent(String.self, forKey: .cycle)) ?? "—"
        cycleOctets = (try? c.decodeIfPresent(UInt64.self, forKey: .cycleOctets)) ?? 0
        quota = (try? c.decodeIfPresent(String.self, forKey: .quota)) ?? nil
        fraction = (try? c.decodeIfPresent(Double.self, forKey: .fraction)) ?? nil
        renouvellement = (try? c.decodeIfPresent(Date.self, forKey: .renouvellement)) ?? .distantFuture
        echeance = (try? c.decodeIfPresent(String.self, forKey: .echeance)) ?? nil
    }
}

/// Une valeur qui se décode ou s'efface sans faire échouer son tableau.
struct Tolerant<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

extension EtatPartage {
    /// Où l'app l'écrit et où le widget le lit. Chemin RÉEL du dossier
    /// personnel : dans le bac à sable du widget, `NSHomeDirectory()` pointe
    /// vers son conteneur.
    static func url(home: String = EtatPartage.realHome) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Pulse", isDirectory: true)
            .appendingPathComponent("etat-partage.json")
    }

    static var realHome: String {
        // `CFFIXED_USER_HOME` (./verifie.sh) redirige l'app vers une maison de
        // rechange : le widget suit la même règle que le reste de Pulse.
        if let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !fixed.isEmpty { return fixed }
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    static func read(from url: URL = EtatPartage.url()) -> EtatPartage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(EtatPartage.self, from: data)
    }

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Les mêmes valeurs à la date près : rien à réécrire.
    func sameValues(as other: EtatPartage) -> Bool {
        var a = self, b = other
        a.date = .distantPast
        b.date = .distantPast
        return a == b
    }
}

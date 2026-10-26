import Foundation

/// Une ville : son fuseau, pour l'heure, et ses coordonnées, pour le lever et
/// le coucher du soleil et pour la météo. Aucune localisation n'est demandée
/// à macOS (elle ferait surgir une demande d'autorisation) : la ville se
/// choisit, et celle d'ici se déduit du fuseau du Mac.
struct Ville: Hashable, Identifiable {
    /// Clé stable, persistée dans `reglages.json` (« casablanca »).
    let cle: String
    let nom: String
    let pays: String
    /// Identifiant IANA (« Africa/Casablanca »).
    let fuseau: String
    let latitude: Double
    let longitude: Double

    var id: String { cle }
    var timeZone: TimeZone { TimeZone(identifier: fuseau) ?? .current }
    /// « Casablanca · Maroc », pour les menus.
    var libelle: String { pays.isEmpty ? nom : "\(nom) · \(pays)" }
}

enum Villes {
    /// Les villes proposées : celles du Maroc et de France d'abord présentes,
    /// puis les grandes villes du monde. Coordonnées du centre, au centième
    /// de degré : assez pour le soleil (une minute d'écart pour ~15 km), et
    /// c'est tout ce que la météo reçoit.
    static let toutes: [Ville] = [
        // Maroc
        Ville(cle: "casablanca", nom: "Casablanca", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 33.57, longitude: -7.59),
        Ville(cle: "rabat", nom: "Rabat", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 34.02, longitude: -6.84),
        Ville(cle: "marrakech", nom: "Marrakech", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 31.63, longitude: -8.01),
        Ville(cle: "fes", nom: "Fès", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 34.03, longitude: -5.00),
        Ville(cle: "tanger", nom: "Tanger", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 35.76, longitude: -5.83),
        Ville(cle: "agadir", nom: "Agadir", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 30.43, longitude: -9.60),
        Ville(cle: "meknes", nom: "Meknès", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 33.90, longitude: -5.55),
        Ville(cle: "oujda", nom: "Oujda", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 34.68, longitude: -1.91),
        Ville(cle: "tetouan", nom: "Tétouan", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 35.57, longitude: -5.37),
        Ville(cle: "kenitra", nom: "Kénitra", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 34.26, longitude: -6.58),
        Ville(cle: "el-jadida", nom: "El Jadida", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 33.25, longitude: -8.51),
        Ville(cle: "essaouira", nom: "Essaouira", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 31.51, longitude: -9.77),
        Ville(cle: "nador", nom: "Nador", pays: "Maroc", fuseau: "Africa/Casablanca", latitude: 35.17, longitude: -2.93),
        Ville(cle: "laayoune", nom: "Laâyoune", pays: "", fuseau: "Africa/El_Aaiun", latitude: 27.15, longitude: -13.20),
        Ville(cle: "dakhla", nom: "Dakhla", pays: "", fuseau: "Africa/El_Aaiun", latitude: 23.68, longitude: -15.96),
        // France et outre-mer
        Ville(cle: "paris", nom: "Paris", pays: "France", fuseau: "Europe/Paris", latitude: 48.86, longitude: 2.35),
        Ville(cle: "lyon", nom: "Lyon", pays: "France", fuseau: "Europe/Paris", latitude: 45.76, longitude: 4.84),
        Ville(cle: "marseille", nom: "Marseille", pays: "France", fuseau: "Europe/Paris", latitude: 43.30, longitude: 5.37),
        Ville(cle: "lille", nom: "Lille", pays: "France", fuseau: "Europe/Paris", latitude: 50.63, longitude: 3.06),
        Ville(cle: "toulouse", nom: "Toulouse", pays: "France", fuseau: "Europe/Paris", latitude: 43.60, longitude: 1.44),
        Ville(cle: "bordeaux", nom: "Bordeaux", pays: "France", fuseau: "Europe/Paris", latitude: 44.84, longitude: -0.58),
        Ville(cle: "nice", nom: "Nice", pays: "France", fuseau: "Europe/Paris", latitude: 43.71, longitude: 7.26),
        Ville(cle: "nantes", nom: "Nantes", pays: "France", fuseau: "Europe/Paris", latitude: 47.22, longitude: -1.55),
        Ville(cle: "strasbourg", nom: "Strasbourg", pays: "France", fuseau: "Europe/Paris", latitude: 48.57, longitude: 7.75),
        Ville(cle: "fort-de-france", nom: "Fort-de-France", pays: "Martinique", fuseau: "America/Martinique", latitude: 14.62, longitude: -61.06),
        Ville(cle: "pointe-a-pitre", nom: "Pointe-à-Pitre", pays: "Guadeloupe", fuseau: "America/Guadeloupe", latitude: 16.24, longitude: -61.53),
        Ville(cle: "saint-denis-reunion", nom: "Saint-Denis", pays: "La Réunion", fuseau: "Indian/Reunion", latitude: -20.88, longitude: 55.45),
        // Europe
        Ville(cle: "bruxelles", nom: "Bruxelles", pays: "Belgique", fuseau: "Europe/Brussels", latitude: 50.85, longitude: 4.35),
        Ville(cle: "geneve", nom: "Genève", pays: "Suisse", fuseau: "Europe/Zurich", latitude: 46.20, longitude: 6.14),
        Ville(cle: "londres", nom: "Londres", pays: "Royaume-Uni", fuseau: "Europe/London", latitude: 51.51, longitude: -0.13),
        Ville(cle: "dublin", nom: "Dublin", pays: "Irlande", fuseau: "Europe/Dublin", latitude: 53.35, longitude: -6.26),
        Ville(cle: "madrid", nom: "Madrid", pays: "Espagne", fuseau: "Europe/Madrid", latitude: 40.42, longitude: -3.70),
        Ville(cle: "barcelone", nom: "Barcelone", pays: "Espagne", fuseau: "Europe/Madrid", latitude: 41.39, longitude: 2.17),
        Ville(cle: "lisbonne", nom: "Lisbonne", pays: "Portugal", fuseau: "Europe/Lisbon", latitude: 38.72, longitude: -9.14),
        Ville(cle: "amsterdam", nom: "Amsterdam", pays: "Pays-Bas", fuseau: "Europe/Amsterdam", latitude: 52.37, longitude: 4.90),
        Ville(cle: "berlin", nom: "Berlin", pays: "Allemagne", fuseau: "Europe/Berlin", latitude: 52.52, longitude: 13.41),
        Ville(cle: "rome", nom: "Rome", pays: "Italie", fuseau: "Europe/Rome", latitude: 41.90, longitude: 12.50),
        Ville(cle: "milan", nom: "Milan", pays: "Italie", fuseau: "Europe/Rome", latitude: 45.46, longitude: 9.19),
        Ville(cle: "stockholm", nom: "Stockholm", pays: "Suède", fuseau: "Europe/Stockholm", latitude: 59.33, longitude: 18.07),
        Ville(cle: "athenes", nom: "Athènes", pays: "Grèce", fuseau: "Europe/Athens", latitude: 37.98, longitude: 23.73),
        Ville(cle: "istanbul", nom: "Istanbul", pays: "Turquie", fuseau: "Europe/Istanbul", latitude: 41.01, longitude: 28.98),
        Ville(cle: "moscou", nom: "Moscou", pays: "Russie", fuseau: "Europe/Moscow", latitude: 55.76, longitude: 37.62),
        // Afrique
        Ville(cle: "alger", nom: "Alger", pays: "Algérie", fuseau: "Africa/Algiers", latitude: 36.75, longitude: 3.06),
        Ville(cle: "tunis", nom: "Tunis", pays: "Tunisie", fuseau: "Africa/Tunis", latitude: 36.81, longitude: 10.18),
        Ville(cle: "le-caire", nom: "Le Caire", pays: "Égypte", fuseau: "Africa/Cairo", latitude: 30.04, longitude: 31.24),
        Ville(cle: "dakar", nom: "Dakar", pays: "Sénégal", fuseau: "Africa/Dakar", latitude: 14.72, longitude: -17.47),
        Ville(cle: "abidjan", nom: "Abidjan", pays: "Côte d'Ivoire", fuseau: "Africa/Abidjan", latitude: 5.36, longitude: -4.01),
        Ville(cle: "lagos", nom: "Lagos", pays: "Nigeria", fuseau: "Africa/Lagos", latitude: 6.52, longitude: 3.38),
        Ville(cle: "kinshasa", nom: "Kinshasa", pays: "RD Congo", fuseau: "Africa/Kinshasa", latitude: -4.44, longitude: 15.27),
        Ville(cle: "nairobi", nom: "Nairobi", pays: "Kenya", fuseau: "Africa/Nairobi", latitude: -1.29, longitude: 36.82),
        Ville(cle: "johannesburg", nom: "Johannesburg", pays: "Afrique du Sud", fuseau: "Africa/Johannesburg", latitude: -26.20, longitude: 28.05),
        // Moyen-Orient et Asie
        Ville(cle: "dubai", nom: "Dubaï", pays: "Émirats", fuseau: "Asia/Dubai", latitude: 25.20, longitude: 55.27),
        Ville(cle: "doha", nom: "Doha", pays: "Qatar", fuseau: "Asia/Qatar", latitude: 25.29, longitude: 51.53),
        Ville(cle: "riyad", nom: "Riyad", pays: "Arabie saoudite", fuseau: "Asia/Riyadh", latitude: 24.71, longitude: 46.68),
        Ville(cle: "la-mecque", nom: "La Mecque", pays: "Arabie saoudite", fuseau: "Asia/Riyadh", latitude: 21.39, longitude: 39.86),
        Ville(cle: "beyrouth", nom: "Beyrouth", pays: "Liban", fuseau: "Asia/Beirut", latitude: 33.89, longitude: 35.50),
        Ville(cle: "bombay", nom: "Bombay", pays: "Inde", fuseau: "Asia/Kolkata", latitude: 19.08, longitude: 72.88),
        Ville(cle: "new-delhi", nom: "New Delhi", pays: "Inde", fuseau: "Asia/Kolkata", latitude: 28.61, longitude: 77.21),
        Ville(cle: "bangkok", nom: "Bangkok", pays: "Thaïlande", fuseau: "Asia/Bangkok", latitude: 13.76, longitude: 100.50),
        Ville(cle: "singapour", nom: "Singapour", pays: "", fuseau: "Asia/Singapore", latitude: 1.35, longitude: 103.82),
        Ville(cle: "bali", nom: "Bali", pays: "Indonésie", fuseau: "Asia/Makassar", latitude: -8.65, longitude: 115.22),
        Ville(cle: "hong-kong", nom: "Hong Kong", pays: "", fuseau: "Asia/Hong_Kong", latitude: 22.32, longitude: 114.17),
        Ville(cle: "pekin", nom: "Pékin", pays: "Chine", fuseau: "Asia/Shanghai", latitude: 39.90, longitude: 116.41),
        Ville(cle: "shanghai", nom: "Shanghai", pays: "Chine", fuseau: "Asia/Shanghai", latitude: 31.23, longitude: 121.47),
        Ville(cle: "seoul", nom: "Séoul", pays: "Corée du Sud", fuseau: "Asia/Seoul", latitude: 37.57, longitude: 126.98),
        Ville(cle: "tokyo", nom: "Tokyo", pays: "Japon", fuseau: "Asia/Tokyo", latitude: 35.68, longitude: 139.65),
        // Océanie
        Ville(cle: "sydney", nom: "Sydney", pays: "Australie", fuseau: "Australia/Sydney", latitude: -33.87, longitude: 151.21),
        Ville(cle: "melbourne", nom: "Melbourne", pays: "Australie", fuseau: "Australia/Melbourne", latitude: -37.81, longitude: 144.96),
        Ville(cle: "auckland", nom: "Auckland", pays: "Nouvelle-Zélande", fuseau: "Pacific/Auckland", latitude: -36.85, longitude: 174.76),
        // Amériques
        Ville(cle: "montreal", nom: "Montréal", pays: "Canada", fuseau: "America/Toronto", latitude: 45.50, longitude: -73.57),
        Ville(cle: "toronto", nom: "Toronto", pays: "Canada", fuseau: "America/Toronto", latitude: 43.65, longitude: -79.38),
        Ville(cle: "vancouver", nom: "Vancouver", pays: "Canada", fuseau: "America/Vancouver", latitude: 49.28, longitude: -123.12),
        Ville(cle: "new-york", nom: "New York", pays: "États-Unis", fuseau: "America/New_York", latitude: 40.71, longitude: -74.01),
        Ville(cle: "miami", nom: "Miami", pays: "États-Unis", fuseau: "America/New_York", latitude: 25.76, longitude: -80.19),
        Ville(cle: "chicago", nom: "Chicago", pays: "États-Unis", fuseau: "America/Chicago", latitude: 41.88, longitude: -87.63),
        Ville(cle: "denver", nom: "Denver", pays: "États-Unis", fuseau: "America/Denver", latitude: 39.74, longitude: -104.99),
        Ville(cle: "los-angeles", nom: "Los Angeles", pays: "États-Unis", fuseau: "America/Los_Angeles", latitude: 34.05, longitude: -118.24),
        Ville(cle: "san-francisco", nom: "San Francisco", pays: "États-Unis", fuseau: "America/Los_Angeles", latitude: 37.77, longitude: -122.42),
        Ville(cle: "honolulu", nom: "Honolulu", pays: "États-Unis", fuseau: "Pacific/Honolulu", latitude: 21.31, longitude: -157.86),
        Ville(cle: "mexico", nom: "Mexico", pays: "Mexique", fuseau: "America/Mexico_City", latitude: 19.43, longitude: -99.13),
        Ville(cle: "bogota", nom: "Bogotá", pays: "Colombie", fuseau: "America/Bogota", latitude: 4.71, longitude: -74.07),
        Ville(cle: "lima", nom: "Lima", pays: "Pérou", fuseau: "America/Lima", latitude: -12.05, longitude: -77.04),
        Ville(cle: "sao-paulo", nom: "São Paulo", pays: "Brésil", fuseau: "America/Sao_Paulo", latitude: -23.55, longitude: -46.63),
        Ville(cle: "rio", nom: "Rio de Janeiro", pays: "Brésil", fuseau: "America/Sao_Paulo", latitude: -22.91, longitude: -43.17),
        Ville(cle: "buenos-aires", nom: "Buenos Aires", pays: "Argentine", fuseau: "America/Argentina/Buenos_Aires", latitude: -34.60, longitude: -58.38),
        Ville(cle: "santiago", nom: "Santiago", pays: "Chili", fuseau: "America/Santiago", latitude: -33.45, longitude: -70.67),
    ]

    /// Triées par nom, à la française, pour les menus.
    static let parNom: [Ville] = toutes.sorted {
        $0.nom.compare($1.nom, locale: Locale(identifier: "fr_FR")) == .orderedAscending
    }

    private static let parCle: [String: Ville] = Dictionary(toutes.map { ($0.cle, $0) }, uniquingKeysWith: { a, _ in a })

    /// Une clé de la table, ou un identifiant IANA écrit à la main
    /// (« America/Toronto ») : la ville principale de ce fuseau, prise dans
    /// la table, sinon dans `zone.tab` du système. Inconnu : nil.
    static func ville(_ cle: String) -> Ville? {
        let cle = cle.trimmingCharacters(in: .whitespaces)
        if let ville = parCle[cle] ?? parCle[cle.lowercased()] { return ville }
        guard TimeZone(identifier: cle) != nil else { return nil }
        return toutes.first { $0.fuseau == cle } ?? ZoneTab.ville(fuseau: cle)
    }

    /// La ville d'ici, déduite du fuseau du Mac : sa ville principale dans la
    /// table (Africa/Casablanca → Casablanca), sinon celle de `zone.tab`.
    static func ici(_ fuseau: TimeZone = .current) -> Ville? {
        toutes.first { $0.fuseau == fuseau.identifier } ?? ZoneTab.ville(fuseau: fuseau.identifier)
    }

    /// La ville choisie dans un réglage (« auto » : celle d'ici).
    static func choisie(_ cle: String?) -> Ville? {
        guard let cle, !cle.isEmpty, cle != "auto" else { return ici() }
        return ville(cle) ?? ici()
    }

    /// Les choix d'un menu « Ville » : d'abord « selon le fuseau du Mac ».
    static func choix() -> [(value: String, label: String)] {
        let auto = ici().map { "Selon le fuseau du Mac (\($0.nom))" } ?? "Selon le fuseau du Mac"
        return [(value: "auto", label: auto)] + parNom.map { (value: $0.cle, label: $0.libelle) }
    }
}

/// `/usr/share/zoneinfo/zone.tab` : pour chaque fuseau, les coordonnées de
/// sa ville principale (« +3339-00735 Africa/Casablanca »). Le repli quand un
/// fuseau n'est pas dans la table — un Mac réglé sur un fuseau rare, un
/// identifiant écrit à la main. Lu une fois, au premier besoin.
enum ZoneTab {
    nonisolated(unsafe) private static var lu: [String: (Double, Double)]?
    private static let verrou = NSLock()

    static func ville(fuseau: String) -> Ville? {
        verrou.lock(); defer { verrou.unlock() }
        if lu == nil {
            let texte = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
            lu = parse(texte)
        }
        guard let (lat, lon) = lu?[fuseau] else { return nil }
        let nom = fuseau.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? fuseau
        return Ville(cle: fuseau, nom: nom, pays: "", fuseau: fuseau, latitude: lat, longitude: lon)
    }

    /// Les lignes « pays coordonnées fuseau [commentaire] », tabulées.
    static func parse(_ texte: String) -> [String: (Double, Double)] {
        var out: [String: (Double, Double)] = [:]
        for ligne in texte.split(separator: "\n") where !ligne.hasPrefix("#") {
            let champs = ligne.split(separator: "\t", omittingEmptySubsequences: false)
            guard champs.count >= 3, let coords = coordonnees(String(champs[1])) else { continue }
            out[String(champs[2])] = coords
        }
        return out
    }

    /// « +3339-00735 » → (33,65, −7,58) ; « +403251-0740023 » avec secondes.
    static func coordonnees(_ texte: String) -> (Double, Double)? {
        guard let coupe = texte.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let lat = String(texte[..<coupe]), lon = String(texte[coupe...])
        guard let la = angle(lat, degres: 2), let lo = angle(lon, degres: 3) else { return nil }
        return (la, lo)
    }

    private static func angle(_ texte: String, degres: Int) -> Double? {
        guard let signe = texte.first, signe == "+" || signe == "-" else { return nil }
        let chiffres = Array(texte.dropFirst())
        guard chiffres.count == degres + 2 || chiffres.count == degres + 4,
              chiffres.allSatisfy(\.isNumber) else { return nil }
        let d = Double(String(chiffres[0..<degres]))!
        let m = Double(String(chiffres[degres..<(degres + 2)]))!
        let s = chiffres.count == degres + 4 ? Double(String(chiffres[(degres + 2)...]))! : 0
        let valeur = d + m / 60 + s / 3600
        return signe == "-" ? -valeur : valeur
    }
}

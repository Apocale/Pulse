import Foundation

enum Fmt {
    /// En français quelle que soit la région du Mac, comme `SensorFormat` et
    /// `PowerFormat` : sur un Mac réglé en région États-Unis, Pulse écrivait
    /// « 24.5 Go » à côté de « 34,2 °C » (26/10).
    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        return f
    }()

    /// Le formateur est partagé par le main thread et la file
    /// d'échantillonnage, où s'écrivent les phrases du verdict : sans verrou,
    /// deux appels simultanés se volaient leurs décimales — « 0,0 o/s » au
    /// lieu de « 0 o/s », relevé par les tests parallèles le 11/10.
    private static let numberLock = NSLock()

    private static func decimal(_ value: Double, digits: Int) -> String {
        numberLock.lock()
        defer { numberLock.unlock() }
        number.minimumFractionDigits = digits
        number.maximumFractionDigits = digits
        return number.string(from: NSNumber(value: value)) ?? "—"
    }

    /// Stockage, en unités DÉCIMALES : c'est la convention d'Apple pour les
    /// disques, celle du Finder et d'Utilitaire de disque.
    static func bytes(_ value: UInt64, digits: Int? = nil) -> String {
        bytes(Double(value), digits: digits)
    }

    /// Mémoire, en unités BINAIRES.
    ///
    /// Apple mélange les deux conventions et il faut les suivre : décimal pour
    /// le stockage, binaire pour la mémoire. `hw.memsize` vaut 34 359 738 368,
    /// que `system_profiler` annonce « 32 GB » et que `top` divise par 1024.
    /// Afficher 34,4 Go de RAM face aux 32 Go du Moniteur d'activité, pour la
    /// même machine, était un écart constant de 7,4 %.
    ///
    /// Base 1024, mais l'unité s'écrit « Go », comme le Moniteur d'activité en
    /// français — et comme iStat Menus. « Gio » était exact et illisible pour
    /// qui n'est pas ingénieur. La règle dure n°3 porte sur la BASE, qui ne
    /// change pas.
    static func memory(_ value: UInt64, digits: Int? = nil) -> String {
        memory(Double(value), digits: digits)
    }

    static func memory(_ value: Double, digits: Int? = nil) -> String {
        let units: [(Double, String)] = [(1099511627776, "To"), (1073741824, "Go"), (1048576, "Mo"), (1024, "ko")]
        for (scale, suffix) in units where abs(value) >= scale {
            let scaled = value / scale
            let d = digits ?? (abs(scaled) >= 100 ? 0 : 1)
            return "\(decimal(scaled, digits: d))\u{00A0}\(suffix)"
        }
        return "\(decimal(value, digits: 0))\u{00A0}o"
    }

    static func bytes(_ value: Double, digits: Int? = nil) -> String {
        let units: [(Double, String)] = [(1e12, "To"), (1e9, "Go"), (1e6, "Mo"), (1e3, "ko")]
        for (scale, suffix) in units where abs(value) >= scale {
            let scaled = value / scale
            let d = digits ?? (abs(scaled) >= 100 ? 0 : 1)
            return "\(decimal(scaled, digits: d))\u{00A0}\(suffix)"
        }
        return "\(decimal(value, digits: 0))\u{00A0}o"
    }

    /// Espace INSÉCABLE avant le signe pourcent, comme l'exige la typographie
    /// française et comme le produit le formateur fr_FR. Une espace ordinaire
    /// autorise une coupure entre le nombre et son signe.
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))\u{00A0}%"
    }

    /// Charge d'une application : « 134 % », en pourcentage d'UN cœur, comme
    /// le Moniteur d'activité. Peut donc dépasser 100 %.
    static func cpu(_ percent: Double) -> String {
        "\(Int(percent.rounded()))\u{00A0}%"
    }

    /// Durées de travail : « 3 h 36 », « 45 min », « 8 min ».
    /// Pas de secondes — à cette échelle elles n'apportent rien.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "< 1 min" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, remainder)
    }

    /// Le nom d'application sans éditeur ni millésime. « Adobe Premiere Pro
    /// 2026 » ne tient pas dans les 88 pt d'une colonne de nom, ni dans les
    /// 30 caractères d'une phrase de verdict. Et ni « Adobe » ni « 2026 »
    /// n'apprennent quoi que ce soit sur une ligne qui dit déjà de quoi il
    /// s'agit. Partagé : le verdict écrivait « Adobe Premier… » là où le
    /// panneau écrivait « Premiere ».
    static func appName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("Adobe ") { name.removeFirst(6) }
        if let year = name.range(of: #" 20\d\d$"#, options: .regularExpression) {
            name.removeSubrange(year)
        }
        return name
    }

    /// Un débit selon le réglage d'Isma : en octets (« 2,4 Mo/s », base 1000,
    /// comme le Moniteur d'activité) ou en bits (« 19,2 Mbit/s », comme un
    /// test de débit ou un forfait).
    static func rate(_ bytesPerSecond: Double, _ unit: DisplaySettings.RateUnit) -> String {
        guard unit == .bits else { return "\(bytes(bytesPerSecond))/s" }
        let bits = bytesPerSecond * 8
        for (scale, suffix) in [(1e9, "Gbit/s"), (1e6, "Mbit/s"), (1e3, "kbit/s")] where abs(bits) >= scale {
            let scaled = bits / scale
            return "\(decimal(scaled, digits: abs(scaled) >= 100 ? 0 : 1))\u{00A0}\(suffix)"
        }
        return "\(decimal(bits, digits: 0))\u{00A0}bit/s"
    }

    /// « 1,5 s », « 5 s » : une cadence de relevé.
    static func decimalSeconds(_ value: Double) -> String {
        "\(decimal(value, digits: value == value.rounded() ? 0 : 1))\u{00A0}s"
    }

    /// Un débit en quatre caractères au plus, pour la barre de menus :
    /// « 0k », « 6,1k », « 40k », « 1,2M », « 120M ». Base 1000, comme les
    /// opérateurs. Complété à gauche par des espaces de chiffre (U+2007), aussi
    /// larges qu'un chiffre en chasse fixe.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        let text: String
        switch v {
        case ..<1e3:         text = "0k"
        case ..<9_950:       text = decimal(v / 1e3, digits: 1) + "k"
        case ..<999_500:     text = "\(Int((v / 1e3).rounded()))k"
        case ..<9_950_000:   text = decimal(v / 1e6, digits: 1) + "M"
        case ..<999_500_000: text = "\(Int((v / 1e6).rounded()))M"
        default:             text = decimal(v / 1e9, digits: 1) + "G"
        }
        return String(repeating: "\u{2007}", count: max(0, 4 - text.count)) + text
    }

    /// Le nom d'un processus hors bundle, lisible. Les services XPC portent un
    /// identifiant à l'envers en guise de nom : « com.apple.WebKit.WebContent »
    /// ne dit rien, « Pages web (WebKit) » si. Les inconnus gardent leur
    /// dernier segment, sans le préfixe de l'éditeur.
    static func processName(_ raw: String) -> String {
        let known = ["com.apple.WebKit.WebContent": "Pages web (WebKit)",
                     "com.apple.WebKit.GPU": "Rendu web (WebKit)",
                     "com.apple.WebKit.Networking": "Réseau web (WebKit)",
                     "com.apple.Virtualization.VirtualMachine": "Machine virtuelle"]
        if let name = known[raw] { return name }
        // Seulement un vrai identifiant à l'envers : « python3.13 » se coupait
        // en « 13 » (relevé au rendu du 11/10).
        let parts = raw.split(separator: ".")
        guard parts.count >= 3, !raw.contains(" "),
              ["com", "org", "net", "io", "app", "fr", "de"].contains(parts[0].lowercased()),
              let last = parts.last else { return raw }
        return String(last)
    }

    /// L'occupation d'un volume, arrondie VERS LE BAS : le seuil de 95 % du
    /// verdict ne s'affiche qu'une fois franchi. Partagée par l'anneau et la
    /// barre de menus, qui disaient « 83 » et « 84 % » pour le même disque.
    static func occupancy(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))\u{00A0}%"
    }

    /// L'échéance d'un disque : « plein vers lundi » dans la semaine — un jour
    /// se lit mieux que « ~2 jours » —, « plein dans ~3 mois » au-delà.
    /// Partagée par le verdict et la carte des disques, qui disaient l'une
    /// « ~2 jours », l'autre « lundi », pour le même fait.
    static func fullBy(days: Double, from now: Date = Date()) -> String {
        if days < 1 { return "plein avant demain" }
        guard days < 7, let date = Calendar.current.date(byAdding: .second, value: Int(days * 86_400), to: now)
        else { return "plein dans \(Self.days(days))" }
        return "plein vers \(weekday.string(from: date))"
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE"
        return f
    }()

    static func days(_ value: Double) -> String {
        if value < 1 { return "moins d'un jour" }
        if value < 60 { return "~\(Int(value.rounded())) jours" }
        let months = value / 30.4
        return months < 24 ? "~\(Int(months.rounded())) mois" : "plus de 2 ans"
    }
}

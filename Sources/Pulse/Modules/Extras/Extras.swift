import Foundation

// Les modules extras (chantier 18) : horloges, calendrier, météo. Tous
// DÉSACTIVÉS par défaut : tant qu'Isma ne les active pas, rien ne change dans
// le panneau, rien ne tourne, rien ne coûte.

/// Ce que les trois modules extras partagent : savoir s'ils tournent dans
/// l'app installée — seule autorisée à demander l'accès au calendrier et à
/// sortir sur Internet —, et l'heure à la française.
enum Extras {
    /// Vrai seulement dans l'app installée : le bundle `.app`, persistance
    /// active, aucune option de diagnostic.
    ///
    /// `--snapshot`, `--probe`, `--banc` et `--rendus` lisent les VRAIS
    /// réglages d'Isma. S'il a activé le calendrier, un rendu lancé par un
    /// chantier appellerait sinon la demande d'autorisation de macOS — depuis
    /// un binaire nu, que macOS ne connaît pas : une fenêtre sur son écran
    /// pendant qu'il monte. Et la météo sortirait sur Internet à chaque
    /// `./verifie.sh`. `swift test` tourne dans un `.xctest` : faux aussi.
    static var appReelle: Bool {
        guard Persistence.enabled, Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return !CommandLine.arguments.contains { diagnostics.contains($0) }
    }

    static let diagnostics: Set<String> = ["--snapshot", "--probe", "--banc", "--rendus"]

    /// `--exemple`, sous `--snapshot` ou `--banc` : des personnes, un agenda
    /// simulé et une réponse Open-Meteo d'exemple, écrits d'après la
    /// documentation. Les cartes se rendent et se mesurent ainsi sans rien
    /// demander à macOS ni à Internet.
    static var exemple: Bool {
        CommandLine.arguments.contains("--exemple") && !appReelle
    }

    // MARK: - L'heure

    nonisolated(unsafe) private static var formateurs: [String: DateFormatter] = [:]
    private static let verrou = NSLock()

    /// Un formateur fr_FR par motif et par fuseau, gardé : en créer un coûte
    /// plus que de l'utiliser, et la carte des horloges en sert huit par
    /// minute.
    static func formateur(_ motif: String, _ fuseau: TimeZone) -> DateFormatter {
        verrou.lock(); defer { verrou.unlock() }
        let cle = motif + "|" + fuseau.identifier
        if let f = formateurs[cle] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.timeZone = fuseau
        f.dateFormat = motif
        formateurs[cle] = f
        return f
    }

    /// « 14:05 », à l'heure du fuseau donné.
    static func heure(_ date: Date, _ fuseau: TimeZone = .current) -> String {
        formateur("HH:mm", fuseau).string(from: date)
    }

    /// « 9 h 40 » ou « 45 min » : une durée de jour, d'attente.
    static func duree(_ secondes: TimeInterval) -> String {
        let minutes = Int((secondes / 60).rounded())
        if minutes < 60 { return "\(max(0, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : String(format: "%d h %02d", h, m)
    }
}

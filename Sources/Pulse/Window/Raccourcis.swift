import Foundation
import AppIntents

// Les actions Raccourcis (App Intents) : « Pulse est-il calme ? »,
// « Combien reste-t-il sur Ssd 2 ? », « Consommation iPhone du jour ».
//
// Elles ne mesurent rien : elles lisent le relevé de l'app en cours
// (`SharedStateWriter.current`), sinon le dernier état écrit pour les
// widgets. Les phrases sont fabriquées par `Reponses`, pur et testé, et
// `--probe` imprime exactement ce qu'elles diraient (section WIDGETS ET
// RACCOURCIS).

/// Les réponses, en français, à partir de l'état partagé.
enum Reponses {
    /// « Pulse est-il calme ? » : oui tant qu'aucune règle d'avertissement
    /// ni d'alerte ne tient. La phrase du verdict, et sa preuve.
    static func calme(_ etat: EtatPartage) -> (calme: Bool, phrase: String) {
        let v = etat.verdict
        let preuve = v.preuve.isEmpty ? "" : " (\(v.preuve))"
        if etat.date == .distantPast || v.phrase.isEmpty {
            return (false, "Pulse n'a pas encore de relevé.")
        }
        return v.calme
            ? (true, "Oui. \(v.phrase)\(preuve).")
            : (false, "Non : \(v.phrase)\(preuve).")
    }

    /// « Combien reste-t-il sur … ? » : le disque nommé, sinon le disque
    /// de rushes. Le nom se compare sans casse ni accents (« ssd 2 »).
    static func disque(_ etat: EtatPartage, nom: String?) -> (disque: DisquePartage?, phrase: String) {
        let demande = nom?.trimmingCharacters(in: .whitespaces) ?? ""
        let trouve = demande.isEmpty ? etat.disqueDeRushes : etat.disque(demande)
        guard let d = trouve else {
            let branches = etat.disques.map(\.nom).joined(separator: ", ")
            let quoi = demande.isEmpty ? "Aucun disque relevé." : "\(demande) n'est pas branché."
            return (nil, branches.isEmpty ? quoi : "\(quoi) Disques branchés : \(branches).")
        }
        var phrase = "Il reste \(d.libre) sur \(d.nom), occupé à \(d.occupationTexte)"
        if let tendance = d.tendance { phrase += " — \(tendance)" }
        return (d, phrase + ".")
    }

    /// « Consommation iPhone du jour » : ce Mac, par le partage iPhone.
    static func iphone(_ etat: EtatPartage) -> (octets: UInt64, phrase: String) {
        guard let f = etat.forfait else {
            return (0, "Le partage iPhone n'a pas encore été compté.")
        }
        var phrase = "\(f.aujourdhui) aujourd'hui par le partage iPhone, \(f.cycle) depuis le début du cycle"
        if let quota = f.quota { phrase += " sur \(quota)" }
        if let echeance = f.echeance { phrase += " — \(echeance)" }
        return (f.aujourdhuiOctets, phrase + ". Ce Mac seulement.")
    }

    /// L'état du moment : le relevé de l'app en cours, sinon le dernier
    /// écrit pour les widgets.
    @MainActor
    static func etat() -> EtatPartage? {
        SharedStateWriter.shared.current ?? EtatPartage.read()
    }
}

enum RaccourciErreur: Error, CustomLocalizedStringResourceConvertible {
    case aucunReleve

    var localizedStringResource: LocalizedStringResource {
        "Pulse n'a pas encore de relevé : est-il lancé ?"
    }
}

/// « Pulse est-il calme ? » — vrai ou faux, à brancher sur un « Si ».
struct CalmeIntent: AppIntent {
    static let title: LocalizedStringResource = "Pulse est-il calme ?"
    static let description = IntentDescription(
        "Vrai si aucun avertissement ni alerte ne tient. Dit la phrase du verdict et le chiffre qui l'a produite.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard let etat = Reponses.etat() else { throw RaccourciErreur.aucunReleve }
        let reponse = Reponses.calme(etat)
        return .result(value: reponse.calme, dialog: IntentDialog(stringLiteral: reponse.phrase))
    }
}

/// « Combien reste-t-il sur Ssd 2 ? » — l'espace libre en Go (base 1000,
/// comme le Finder), et la phrase de la carte Disques.
struct EspaceLibreIntent: AppIntent {
    static let title: LocalizedStringResource = "Espace libre sur un disque"
    static let description = IntentDescription(
        "Combien reste-t-il sur un disque, en Go, et quand il sera plein. Sans disque choisi : le disque de rushes.")
    static let openAppWhenRun = false

    @Parameter(title: "Disque",
               description: "Son nom dans le Finder (« Ssd 2 »). Vide : le disque de rushes, l'externe le plus rempli.",
               optionsProvider: DisquesBranches())
    var disque: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Espace libre sur \(\.$disque)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        guard let etat = Reponses.etat() else { throw RaccourciErreur.aucunReleve }
        let reponse = Reponses.disque(etat, nom: disque)
        let go = reponse.disque.map { (Double($0.libreOctets) / 1e9 * 10).rounded() / 10 } ?? 0
        return .result(value: go, dialog: IntentDialog(stringLiteral: reponse.phrase))
    }
}

/// Les disques branchés, proposés dans Raccourcis.
struct DisquesBranches: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        (Reponses.etat()?.disques ?? []).map(\.nom)
    }
}

/// « Consommation iPhone du jour » — en Mo (base 1000, comme les
/// opérateurs), et le cumul du cycle.
struct ConsommationIPhoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Consommation iPhone du jour"
    static let description = IntentDescription(
        "Ce que ce Mac a échangé aujourd'hui par le partage de connexion de l'iPhone, en Mo, et le cumul du forfait.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        guard let etat = Reponses.etat() else { throw RaccourciErreur.aucunReleve }
        let reponse = Reponses.iphone(etat)
        let mo = (Double(reponse.octets) / 1e6 * 10).rounded() / 10
        return .result(value: mo, dialog: IntentDialog(stringLiteral: reponse.phrase))
    }
}

/// Les phrases que Siri et Spotlight reconnaissent sans réglage.
struct PulseRaccourcis: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CalmeIntent(),
                    phrases: ["\(.applicationName) est-il calme ?",
                              "Est-ce que \(.applicationName) est calme ?"],
                    shortTitle: "Pulse est-il calme ?",
                    systemImageName: "checkmark.seal")
        AppShortcut(intent: EspaceLibreIntent(),
                    phrases: ["Combien reste-t-il sur le disque de rushes avec \(.applicationName) ?",
                              "Espace libre avec \(.applicationName)"],
                    shortTitle: "Espace libre",
                    systemImageName: "externaldrive")
        AppShortcut(intent: ConsommationIPhoneIntent(),
                    phrases: ["Consommation iPhone du jour avec \(.applicationName)",
                              "Combien de partage iPhone aujourd'hui avec \(.applicationName) ?"],
                    shortTitle: "Consommation iPhone",
                    systemImageName: "personalhotspot")
    }
}

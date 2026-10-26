import Foundation

/// Les réglages du réseau : le forfait iPhone, et les deux mesures qui
/// sortiraient sur Internet — désactivées tant qu'Isma ne les a pas cochées.
///
/// Rangés avec ceux des autres modules, dans `reglages.json` du socle
/// (`modules.reseau.options`) : la fenêtre Réglages les dessine depuis
/// `ReseauModule.options`, et la carte les modifie au même endroit. Une valeur
/// absente, d'un autre type ou hors bornes retombe sur sa valeur par défaut,
/// sans emporter les autres (règle dure n°2).
struct ReglagesReseau: Equatable {
    static let module = "reseau"

    /// Le forfait mensuel, en gigaoctets DÉCIMAUX, comme les opérateurs.
    /// `nil` : pas réglé — et alors pas de jauge, faute de dénominateur réel
    /// (règle dure n°7). Une valeur par défaut serait un total inventé.
    var forfaitGo: Double? = nil
    /// Le jour du mois où le forfait repart de zéro, 1 à 31. Un 31 tombe le
    /// dernier jour des mois plus courts.
    var jourRenouvellement: Int = 1
    /// L'adresse IP publique, demandée à un service extérieur : elle sort sur
    /// Internet. Désactivée par défaut.
    var ipPublique: Bool = false
    /// Un ping vers un serveur d'Internet (1.1.1.1), une fois par minute,
    /// panneau ouvert : 64 octets, mais qui sortent. Désactivé par défaut —
    /// la latence Internet se lit alors sur le trafic déjà en cours.
    var sondeInternet: Bool = false
    /// Deux pings de la passerelle toutes les 10 s, panneau ouvert. Réseau
    /// local seulement, mais depuis macOS 15 un accès au réseau local peut
    /// faire afficher par macOS la demande d'autorisation « Réseau local » :
    /// désactivé par défaut, comme tout ce qui ferait surgir une fenêtre.
    var pingPasserelle: Bool = false

    init() {}

    /// Les tailles de forfait proposées, en Go : celles des opérateurs. La
    /// fenêtre Réglages en fait un menu — un clic pour 50 Go, au lieu de
    /// cinquante sur un compteur — et l'éditeur de la carte les parcourt.
    static let paliers: [Int] = [1, 2, 3, 5, 8, 10, 15, 20, 25, 30, 35, 40, 50, 60, 70, 80, 90, 100,
                                 110, 120, 130, 140, 150, 160, 200, 250, 300, 350, 500]

    init(options: [String: OptionValue]) {
        // Texte (menu de la fenêtre Réglages) ou nombre (fichier édité à la
        // main) : les deux se relisent.
        let go = options["forfaitGo"]?.int ?? options["forfaitGo"]?.text.flatMap { Int($0) }
        // Plafonné : au-delà de ~1,8e10 Go, la conversion en octets
        // (`UInt64`) déborde et arrête Pulse.
        if let go, go > 0 { forfaitGo = Double(min(go, 100_000)) }
        if let jour = options["jourRenouvellement"]?.int { jourRenouvellement = min(31, max(1, jour)) }
        ipPublique = options["ipPublique"]?.bool ?? false
        sondeInternet = options["sondeInternet"]?.bool ?? false
        pingPasserelle = options["pingPasserelle"]?.bool ?? false
    }

    /// Les options d'origine, les miennes remplacées.
    func options(fusionnees avec: [String: OptionValue] = [:]) -> [String: OptionValue] {
        var out = avec
        out["forfaitGo"] = .text(String(Int((forfaitGo ?? 0).rounded())))
        out["jourRenouvellement"] = .int(jourRenouvellement)
        out["ipPublique"] = .bool(ipPublique)
        out["sondeInternet"] = .bool(sondeInternet)
        out["pingPasserelle"] = .bool(pingPasserelle)
        return out
    }

    /// Les réglages d'Isma, tels que le socle les a lus.
    @MainActor
    static var actuels: ReglagesReseau {
        ReglagesReseau(options: SettingsStore.shared.settings.module(module).options)
    }

    /// Écrits par le socle (jamais sous `--snapshot` ni `--probe`, où
    /// `SettingsStore` lit sans écrire).
    @MainActor
    static func enregistrer(_ reglages: ReglagesReseau) {
        var tout = SettingsStore.shared.settings
        var mien = tout.module(module)
        mien.options = reglages.options(fusionnees: mien.options)
        tout.modules[module] = mien
        SettingsStore.shared.settings = tout
    }
}

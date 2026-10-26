import SwiftUI

/// Réseau, chantier 07 : la carte du socle (débit, miroir, cumul du jour)
/// plus la connexion, le Wi-Fi, le forfait iPhone et le débit par app.
///
/// Même identifiant que la carte qu'elle remplace, « reseau » : la place et
/// les choix d'Isma dans `reglages.json` sont gardés.
struct ReseauModule: PulseModule {
    let id = ReglagesReseau.module
    let name = "Réseau"
    let symbol = "wifi"
    var summary: String {
        "Le débit, la connexion et le Wi-Fi, le forfait iPhone du mois, les apps qui transfèrent."
    }
    var defaultColumn: Int { 0 }

    /// Mesuré au banc (`PULSE_BANC_RESEAU=60 swift test --filter
    /// BancReseau`) : temps processeur du processus sur une minute, relevé
    /// des sockets toutes les 2 s, Wi-Fi, adresses et ping toutes les 10 s.
    var cost: ModuleCost {
        ModuleCost(closed: 0, open: 0.26,
                   note: "réseau : banc de 60 s du 11/10 ; panneau fermé, rien ne tourne")
    }

    var options: [ModuleOption] {
        [ModuleOption(id: "forfaitGo", label: "Forfait iPhone",
                      help: "Le forfait mensuel de l'iPhone. Sans forfait suivi, pas de jauge : seulement la consommation du mois.",
                      kind: .choice([(value: "0", label: "pas de forfait suivi")]
                                    + ReglagesReseau.paliers.map { (value: String($0), label: "\($0) Go") },
                                    default: "0")),
         ModuleOption(id: "jourRenouvellement", label: "Renouvelé le",
                      help: "Le jour du mois où le forfait repart de zéro.",
                      kind: .number(range: 1...31, default: 1, unit: "")),
         ModuleOption(id: "ipPublique", label: "Afficher l'IP publique",
                      help: "Demandée à \(IPPublique.service.host ?? "un service extérieur") : sort sur Internet.",
                      kind: .toggle(default: false)),
         ModuleOption(id: "pingPasserelle", label: "Ping de la passerelle",
                      help: "Réseau local seulement, mais macOS peut demander l'autorisation « Réseau local » la première fois. Sinon, la passerelle n'est pas mesurée.",
                      kind: .toggle(default: false)),
         ModuleOption(id: "sondeInternet", label: "Ping Internet chaque minute",
                      help: "Vers \(MoniteurReseau.cibleSonde), panneau ouvert : sort sur Internet. Sinon, la latence se lit sur le trafic déjà en cours.",
                      kind: .toggle(default: false))]
    }

    func card(_ context: CardContext) -> AnyView {
        AnyView(CarteReseau(sampler: context.sampler, context: context))
    }

    /// Le moniteur tourne carte affichée et panneau ouvert, jamais autrement.
    func stateDidChange(_ state: ModuleState) {
        MoniteurReseau.shared.regler(actif: state.enabled && state.panelOpen)
        // `--snapshot … --forfait 20` : un forfait d'essai, en mémoire — sous
        // `--snapshot`, le socle lit les réglages sans jamais les écrire.
        if !Persistence.enabled, let go = Snapshot.value(after: "--forfait").flatMap(Int.init) {
            var essai = ReglagesReseau.actuels
            essai.forfaitGo = go > 0 ? Double(go) : nil
            ReglagesReseau.enregistrer(essai)
        }
    }

    /// Hors ligne, pas de segment : un « 0k » se lirait comme une mesure.
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        let net = sampler.network
        guard net.connected else { return nil }
        return MenuBarSegment(label: "↑" + Fmt.compactRate(net.txRate), value: "↓" + Fmt.compactRate(net.rxRate),
                              spoken: "reçu \(Fmt.bytes(net.rxRate))/s · envoyé \(Fmt.bytes(net.txRate))/s")
    }
}

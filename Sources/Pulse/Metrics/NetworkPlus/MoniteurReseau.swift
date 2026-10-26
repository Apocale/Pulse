import Foundation
import Combine

/// La latence d'un côté du réseau : la passerelle, ou Internet.
struct Latence: Equatable {
    /// Dernière mesure, en millisecondes.
    var ms: Double?
    /// Sur les derniers essais : combien sont restés sans réponse.
    var perdus = 0
    var essais = 0
    /// D'où vient le chiffre : « ping » ou « trafic en cours ».
    var source = ""
    /// Combien de connexions ont servi à la mesure passive.
    var connexions = 0
    /// A-t-elle répondu au moins une fois sur ce réseau ? Une box qui ne
    /// répond jamais au ping (ICMP filtré) n'est pas une box en panne.
    var aRepondu = false
}

/// Ce que la carte Réseau ajoute au débit et au cumul du `Sampler` :
/// connexion, Wi-Fi, adresses, apps. Tourne SEULEMENT carte affichée et
/// panneau ouvert : `ReseauModule.stateDidChange` le règle à chaque
/// ouverture et fermeture (et la carte, à son apparition, par sûreté).
/// Panneau fermé, rien ne tourne : le budget de 1 % d'un cœur est intact.
///
/// Rythmes : les sockets toutes les 2 s, comme le débit du `Sampler` (débit
/// par app, RTT passif) ; le Wi-Fi et les adresses toutes les 10 s, avec un
/// ping de la passerelle si Isma l'a coché ; la sonde Internet active, si
/// Isma l'a cochée, toutes les 60 s. Par défaut, rien n'est envoyé.
@MainActor
final class MoniteurReseau: ObservableObject {
    static let shared = MoniteurReseau()

    @Published private(set) var wifi: SignalWiFi?
    @Published private(set) var adresses: AdressesLocales?
    @Published private(set) var passerelle = Latence(source: "ping")
    @Published private(set) var internet = Latence(source: "trafic en cours")
    @Published private(set) var apps: [SuiviSockets.DebitApp] = []
    @Published private(set) var sockets = 0
    @Published private(set) var ipPublique: String?
    /// Vrai une fois le premier relevé des sockets arrivé : avant, une liste
    /// vide ne veut pas dire « aucune app ne transfère ».
    @Published private(set) var appsMesurees = false

    nonisolated static let rythmeSockets: TimeInterval = 2
    nonisolated static let rythmeLiaison: TimeInterval = 10
    nonisolated static let rythmeSonde: TimeInterval = 60
    /// Un serveur d'Internet qui répond au ping : 1.1.1.1 (Cloudflare).
    nonisolated static let cibleSonde = "1.1.1.1"
    private static let fenetre = 10

    private let suivi = SuiviSockets()
    private let file = DispatchQueue(label: "com.isma.pulse.reseau-plus", qos: .utility)
    private var minuteries: [DispatchSourceTimer] = []
    private var historiquePasserelle: [Double?] = []
    private var passerelleSuivie: String?
    private var historiqueSonde: [Double?] = []
    private var sequence: UInt16 = 0
    private var signatureIP: String?

    private var actif = false

    /// Banc d'essai (chantier 03) : un état figé, que rien ne relance —
    /// ni la carte à son apparition, ni le module : pour les images de
    /// référence de `--rendus`, sans rien mesurer ni envoyer.
    func figer(wifi: SignalWiFi?, adresses: AdressesLocales?, passerelle: Latence, internet: Latence,
               apps: [SuiviSockets.DebitApp]) {
        regler(actif: false)
        fige = true
        self.wifi = wifi
        self.adresses = adresses
        self.passerelle = passerelle
        self.internet = internet
        self.apps = apps
        appsMesurees = true
    }

    private var fige = false

    /// Allume ou éteint le moniteur ; sans effet s'il est déjà dans cet état.
    func regler(actif voulu: Bool) {
        guard !fige, voulu != actif else { return }
        actif = voulu
        if voulu {
            suivi.demarrer()
            // Premier relevé des sockets à 0,2 s : il sert de référence, et
            // le premier débit par app arrive 2 s plus tard.
            minuteries = [
                minuterie(Self.rythmeSockets, delai: 0.2) { [weak self] in self?.releverSockets() },
                minuterie(Self.rythmeLiaison, delai: 0) { [weak self] in self?.releverLiaison() },
                minuterie(Self.rythmeSonde, delai: 1) { [weak self] in self?.sonder() },
            ]
        } else {
            minuteries.forEach { $0.cancel() }
            minuteries = []
            suivi.arreter()
            // Rien de périmé à la prochaine ouverture : une latence d'il y a
            // dix minutes se lirait comme celle de maintenant.
            wifi = nil; adresses = nil; apps = []; sockets = 0; appsMesurees = false
            passerelle = Latence(source: "ping"); internet = Latence(source: "trafic en cours")
            historiquePasserelle = []; historiqueSonde = []; passerelleSuivie = nil
        }
    }

    /// Les minuteries battent sur le fil principal, où vivent l'état et les
    /// réglages ; le travail bloquant (ping, CoreWLAN, sockets) part sur la
    /// file du moniteur et revient publier ici.
    private func minuterie(_ rythme: TimeInterval, delai: TimeInterval,
                           _ action: @escaping @MainActor () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + delai, repeating: rythme, leeway: .milliseconds(300))
        t.setEventHandler { MainActor.assumeIsolated { action() } }
        t.resume()
        return t
    }

    // MARK: - Relevés

    private func releverSockets() {
        suivi.relever { releve in
            Task { @MainActor in MoniteurReseau.shared.publier(releve) }
        }
    }

    private func publier(_ releve: SuiviSockets.Releve) {
        guard actif else { return }
        sockets = releve.sockets
        guard releve.intervalle > 0 else { return }
        apps = releve.apps
        appsMesurees = true
        // Le plus court des RTT : le serveur le plus proche, donc l'accès
        // lui-même — box, Starlink ou réseau mobile. Les serveurs lointains
        // ajoutent leur distance, pas la qualité de la connexion.
        if !ReglagesReseau.actuels.sondeInternet {
            internet = Latence(ms: releve.rttInternet.first, source: "trafic en cours",
                               connexions: releve.rttInternet.count)
        }
    }

    private func releverLiaison() {
        let seq = prochaineSequence()
        // Le ping de la passerelle sur réglage seulement : un accès au réseau
        // local peut déclencher la demande d'autorisation de macOS 15.
        let ping = ReglagesReseau.actuels.pingPasserelle
        file.async {
            let wifi = LecteurWiFi.lire()
            let adresses = LecteurAdresses.lire()
            let ms = ping ? adresses?.passerelle.flatMap { Ping.meilleur(vers: $0, sequence: seq) } : nil
            Task { @MainActor in MoniteurReseau.shared.publierLiaison(wifi: wifi, adresses: adresses, ms: ms) }
        }
    }

    private func publierLiaison(wifi: SignalWiFi?, adresses: AdressesLocales?, ms: Double?) {
        guard actif else { return }
        guard ReglagesReseau.actuels.pingPasserelle else {
            self.wifi = wifi
            self.adresses = adresses
            historiquePasserelle = []
            passerelle = Latence(source: "ping")
            rafraichirIPPublique(signature: adresses.map { "\($0.interface)|\($0.passerelle ?? "")" })
            return
        }
        self.wifi = wifi
        self.adresses = adresses
        // Autre réseau, autre passerelle : les pertes de l'ancienne ne
        // jugent pas la nouvelle.
        if adresses?.passerelle != passerelleSuivie {
            passerelleSuivie = adresses?.passerelle
            historiquePasserelle = []
        }
        if adresses?.passerelle != nil {
            historiquePasserelle = Array((historiquePasserelle + [ms]).suffix(Self.fenetre))
        }
        passerelle = Self.latence(historiquePasserelle, derniere: ms, source: "ping")
        rafraichirIPPublique(signature: adresses.map { "\($0.interface)|\($0.passerelle ?? "")" })
    }

    /// Ce qui sort sur Internet (sonde 1.1.1.1, IP publique) : coché par
    /// Isma ET dans l'app installée. La garde était `Persistence.enabled`,
    /// que `--banc --ecrit` rallume : `./verifie.sh`, qui le lance avec une
    /// copie des vrais réglages, aurait interrogé api.ipify.org et pingué
    /// 1.1.1.1 à chaque vérification, option cochée (17-audit-code). La même
    /// garde que la météo (`Extras.appReelle`).
    nonisolated static func sortiePermise(_ cochee: Bool) -> Bool {
        cochee && Extras.appReelle
    }

    /// La sonde active : seulement si Isma l'a cochée, dans l'app installée.
    private func sonder() {
        guard Self.sortiePermise(ReglagesReseau.actuels.sondeInternet) else { return }
        let seq = prochaineSequence()
        file.async {
            let ms = Ping.echo(vers: Self.cibleSonde, delai: 2, sequence: seq)
            Task { @MainActor in MoniteurReseau.shared.publierSonde(ms) }
        }
    }

    private func publierSonde(_ ms: Double?) {
        guard actif else { return }
        historiqueSonde = Array((historiqueSonde + [ms]).suffix(Self.fenetre))
        internet = Self.latence(historiqueSonde, derniere: ms, source: "ping \(Self.cibleSonde)")
    }

    private func prochaineSequence() -> UInt16 {
        sequence &+= 2
        return sequence
    }

    nonisolated static func latence(_ historique: [Double?], derniere: Double?, source: String) -> Latence {
        Latence(ms: derniere, perdus: historique.filter { $0 == nil }.count,
                essais: historique.count, source: source, aRepondu: historique.contains { $0 != nil })
    }

    /// L'IP publique, si Isma l'a cochée : demandée à l'ouverture et à chaque
    /// changement de réseau, pas plus.
    private func rafraichirIPPublique(signature: String?) {
        guard Self.sortiePermise(ReglagesReseau.actuels.ipPublique) else {
            ipPublique = nil
            signatureIP = nil
            return
        }
        guard let signature, signature != signatureIP else { return }
        signatureIP = signature
        IPPublique.demander { ip in
            Task { @MainActor in MoniteurReseau.shared.ipPublique = ip }
        }
    }
}

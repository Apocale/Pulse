import Foundation
import Testing
@testable import Pulse

/// Les compteurs 32 bits de l'interface, sur le code même de l'app
/// (`CompteursReseau.ecart`, appelé par `NetworkTracker.sample`).
@Suite struct CompteursReseauTests {
    /// Le compteur passe par zéro entre deux relevés : l'écart est celui du
    /// trafic réel, pas un nombre négatif ni un plantage.
    @Test func unRebouclageDonneLeVraiEcart() {
        let ecart = CompteursReseau.ecart(avant: (rx: 4_294_000_000, tx: 4_294_967_000),
                                          apres: (rx: 1_000_000, tx: 500), secondes: 2)
        #expect(ecart?.rx == 1_967_296)
        #expect(ecart?.tx == 796)
    }

    /// Un compteur remis à zéro (interface recréée) : le modulo donnerait
    /// 1,3 Go en une demi-seconde. Invraisemblable, donc écarté.
    @Test func unCompteurRemisAZeroNInventePasDeGigaoctets() {
        let ecart = CompteursReseau.ecart(avant: (rx: 3_000_000_000, tx: 0),
                                          apres: (rx: 1_000, tx: 0), secondes: 0.5)
        #expect(ecart == nil)
    }

    @Test func uneDureeNulleNeDonneRien() {
        #expect(CompteursReseau.ecart(avant: (rx: 0, tx: 0), apres: (rx: 10, tx: 10), secondes: 0) == nil)
    }

    /// Veille d'une heure, interface recréée au réveil (partage iPhone par
    /// USB, pilote relancé) : le compteur repart de zéro. Le modulo en
    /// ferait 1,8 Go « reçus » pendant la veille — 0,5 Mo/s, plausible pour
    /// la seule borne de débit — et le forfait iPhone les compterait.
    @Test func unReveilApresRemiseAZeroNInventePasDeTrafic() {
        let ecart = CompteursReseau.ecart(avant: (rx: 2_500_000_000, tx: 300_000_000),
                                          apres: (rx: 1_000_000, tx: 200_000), secondes: 3600)
        #expect(ecart == nil)
    }

    /// La même veille sans remise à zéro : le trafic de la veille (Power
    /// Nap, sauvegardes) est compté normalement.
    @Test func unReveilSansRemiseAZeroCompteLeTrafic() {
        let ecart = CompteursReseau.ecart(avant: (rx: 1_000_000_000, tx: 300_000_000),
                                          apres: (rx: 1_100_000_000, tx: 300_500_000), secondes: 3600)
        #expect(ecart?.rx == 100_000_000)
        #expect(ecart?.tx == 500_000)
    }

    /// Au rythme ordinaire (2 s), un vrai passage par zéro reste compté.
    @Test func unRebouclageAuRythmeOrdinaireResteCompte() {
        let ecart = CompteursReseau.ecart(avant: (rx: 4_290_000_000, tx: 0),
                                          apres: (rx: 30_000_000, tx: 0), secondes: 2)
        #expect(ecart?.rx == 34_967_296)
    }

    /// La sonde Starlink se tait quand 192.168.100.1 est sur le réseau même
    /// du Mac : macOS 15 y verrait un accès au « réseau local » et le ferait
    /// autoriser à l'écran (TN3179). Derrière un routeur, elle passe.
    @Test func laSondeStarlinkNeFrappeQuAuDelaDUnRouteur() {
        let antenne = NetworkMonitor.dishAddress
        let surUneBox: UInt32 = 192 << 24 | 168 << 16 | 100 << 8 | 23    // 192.168.100.23
        let derriereStarlink: UInt32 = 192 << 24 | 168 << 16 | 1 << 8 | 12   // 192.168.1.12
        let slash24: UInt32 = 0xFFFF_FF00
        #expect(NetworkMonitor.sameSubnet(surUneBox, antenne, mask: slash24))
        #expect(!NetworkMonitor.sameSubnet(derriereStarlink, antenne, mask: slash24))
        #expect(!NetworkMonitor.sameSubnet(derriereStarlink, antenne, mask: 0))
    }
}

/// Le forfait iPhone : le cycle, la consommation, les seuils du chantier 11.
@Suite struct ForfaitTests {
    static let paris: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        paris.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    static func jour(_ y: Int, _ m: Int, _ d: Int) -> Date { paris.startOfDay(for: date(y, m, d)) }

    static func usage(iphone: Double, wifi: Double = 0) -> [NetworkTracker.Usage] {
        var u: [NetworkTracker.Usage] = []
        if iphone > 0 { u.append(.init(label: "partage iPhone", kind: .hotspot, rx: UInt64(iphone * 0.9e9), tx: UInt64(iphone * 0.1e9))) }
        if wifi > 0 { u.append(.init(label: "Wi-Fi", kind: .wifi, rx: UInt64(wifi * 1e9), tx: 0)) }
        return u
    }

    @Test func leCycleCommenceAuJourDeRenouvellement() {
        let avant = Forfait.cycle(contenant: Self.date(2026, 10, 11), jour: 12, calendrier: Self.paris)
        #expect(avant.debut == Self.jour(2026, 9, 12))
        #expect(avant.fin == Self.jour(2026, 10, 12))
        let jourJ = Forfait.cycle(contenant: Self.date(2026, 10, 12, 0), jour: 12, calendrier: Self.paris)
        #expect(jourJ.debut == Self.jour(2026, 10, 12))
        #expect(jourJ.fin == Self.jour(2026, 11, 12))
    }

    /// Un renouvellement le 31 tombe le 28 février, puis revient au 31 mars.
    @Test func unTrenteEtUnTombeEnFinDeMoisCourt() {
        let milieu = Forfait.cycle(contenant: Self.date(2027, 2, 15), jour: 31, calendrier: Self.paris)
        #expect(milieu.debut == Self.jour(2027, 1, 31))
        #expect(milieu.fin == Self.jour(2027, 2, 28))
        let fin = Forfait.cycle(contenant: Self.date(2027, 2, 28), jour: 31, calendrier: Self.paris)
        #expect(fin.debut == Self.jour(2027, 2, 28))
        #expect(fin.fin == Self.jour(2027, 3, 31))
    }

    @Test func leCyclePasseLAnnee() {
        let c = Forfait.cycle(contenant: Self.date(2027, 1, 3), jour: 15, calendrier: Self.paris)
        #expect(c.debut == Self.jour(2026, 12, 15))
        #expect(c.fin == Self.jour(2027, 1, 15))
    }

    /// Seul le partage iPhone compte, et seulement depuis le renouvellement.
    @Test func seulLePartageIPhoneDuCycleCompte() {
        let historique: [(day: Date, usage: [NetworkTracker.Usage])] = [
            (Self.jour(2026, 10, 9), Self.usage(iphone: 4)),            // cycle précédent
            (Self.jour(2026, 10, 10), Self.usage(iphone: 1.5, wifi: 300)),
            (Self.jour(2026, 10, 11), Self.usage(iphone: 0.5, wifi: 2)),
        ]
        var reglages = ReglagesReseau()
        reglages.forfaitGo = 20
        reglages.jourRenouvellement = 10
        let etat = Forfait.etat(historique: historique, reglages: reglages,
                                maintenant: Self.date(2026, 10, 11), calendrier: Self.paris)
        #expect(etat.consomme == 2_000_000_000)
        #expect(etat.parJour.map(\.octets) == [1_500_000_000, 500_000_000])
        #expect(etat.quota == 20_000_000_000)
        #expect(etat.niveau == .normal)
        #expect(etat.rythme == nil, "un rythme sur deux jours")
    }

    /// Les deux seuils exposés au chantier 11, et le forfait non réglé.
    @Test func lesSeuilsSontCeuxDuChantierOnze() {
        func niveau(_ go: Double, forfait: Double?) -> NiveauForfait {
            var reglages = ReglagesReseau()
            reglages.forfaitGo = forfait
            reglages.jourRenouvellement = 1
            return Forfait.etat(historique: [(Self.jour(2026, 10, 5), Self.usage(iphone: go))],
                                reglages: reglages, maintenant: Self.date(2026, 10, 11),
                                calendrier: Self.paris).niveau
        }
        #expect(niveau(7.9, forfait: 10) == .normal)
        #expect(niveau(8, forfait: 10) == .proche)
        #expect(niveau(10, forfait: 10) == .depasse)
        #expect(niveau(12, forfait: 10) == .depasse)
        #expect(niveau(12, forfait: nil) == .nonRegle)
    }

    /// 5 Go en 10 jours sur un forfait de 10 Go : épuisé dans 10 jours, avant
    /// la fin du cycle. Le même rythme sur 40 Go ne finit pas avant.
    @Test func leRythmeAnnonceLEpuisementDansLeCycle() {
        let historique = (1...10).map { d in (day: Self.jour(2026, 10, d), usage: Self.usage(iphone: 0.5)) }
        var reglages = ReglagesReseau()
        reglages.forfaitGo = 10
        reglages.jourRenouvellement = 1
        let maintenant = Self.date(2026, 10, 11, 0)
        let etat = Forfait.etat(historique: historique, reglages: reglages,
                                maintenant: maintenant, calendrier: Self.paris)
        #expect(abs((etat.rythme ?? 0) - 0.5e9) < 1e6)
        let jours = (etat.epuiseVers?.timeIntervalSince(maintenant) ?? 0) / 86_400
        #expect(abs(jours - 10) < 0.01, "épuisé dans \(jours) jours au lieu de 10")

        reglages.forfaitGo = 40
        let large = Forfait.etat(historique: historique, reglages: reglages,
                                 maintenant: maintenant, calendrier: Self.paris)
        #expect(large.epuiseVers == nil)
    }

    /// Le cas du 11/10 : cycle ouvert le 01/10, cumul commencé le 07/10. Le
    /// rythme se divise par les jours comptés, pas par les jours du cycle.
    @Test func leRythmeNeCompteQueLesJoursObserves() {
        let historique: [(day: Date, usage: [NetworkTracker.Usage])] =
            (1...6).map { (Self.jour(2026, 10, $0), []) }
            + [(Self.jour(2026, 10, 7), Self.usage(iphone: 2.3, wifi: 0.3)),
               (Self.jour(2026, 10, 8), Self.usage(iphone: 0, wifi: 300)),
               (Self.jour(2026, 10, 9), Self.usage(iphone: 0, wifi: 5)),
               (Self.jour(2026, 10, 10), Self.usage(iphone: 3.5, wifi: 350))]
        var reglages = ReglagesReseau()
        reglages.jourRenouvellement = 1
        let maintenant = Self.date(2026, 10, 11, 0)
        let etat = Forfait.etat(historique: historique, reglages: reglages,
                                maintenant: maintenant, calendrier: Self.paris)
        #expect(etat.observeDepuis == Self.jour(2026, 10, 7))
        let parJour = (etat.rythme ?? 0) / 1e9
        #expect(abs(parJour - 5.8 / 4) < 0.01, "\(parJour) Go par jour au lieu de 1,45")
    }

    /// Un réglage abîmé ne coûte que lui-même : type faux, hors bornes, ou
    /// absent, il retombe sur sa valeur par défaut.
    @Test func lesReglagesSeRelisentDeFaconTolerante() {
        let abimes: [String: OptionValue] = ["forfaitGo": .text("beaucoup"), "jourRenouvellement": .int(45),
                                             "ipPublique": .bool(true), "sondeInternet": .int(1)]
        let lus = ReglagesReseau(options: abimes)
        #expect(lus.forfaitGo == nil)
        #expect(lus.jourRenouvellement == 31)
        #expect(lus.ipPublique == true)
        #expect(lus.sondeInternet == false)
        #expect(ReglagesReseau(options: [:]) == ReglagesReseau())
        #expect(ReglagesReseau(options: ["jourRenouvellement": .int(-3), "forfaitGo": .int(0)]).jourRenouvellement == 1)
        // Le menu de la fenêtre Réglages écrit du texte ; un fichier édité à
        // la main, un nombre : les deux se relisent.
        #expect(ReglagesReseau(options: ["forfaitGo": .text("50")]).forfaitGo == 50)
        #expect(ReglagesReseau(options: ["forfaitGo": .int(50)]).forfaitGo == 50)
        #expect(ReglagesReseau(options: ["forfaitGo": .text("0")]).forfaitGo == nil)
        // Aller-retour : ce qui s'écrit se relit à l'identique, et les
        // options étrangères au forfait restent en place.
        var r = ReglagesReseau()
        r.forfaitGo = 50; r.jourRenouvellement = 12; r.sondeInternet = true
        let options = r.options(fusionnees: ["autre": .text("garde")])
        #expect(ReglagesReseau(options: options) == r)
        #expect(options["autre"] == .text("garde"))
    }
}

/// Le suivi des sockets sur le vrai cadre NetworkStatistics, sans rien
/// envoyer : une lecture du noyau, une demi-seconde.
@Suite struct SuiviSocketsTests {
    /// Le plantage du 11/10 à 04:41 (rapport `Pulse-2026-10-11-044150.ips`,
    /// EXC_BREAKPOINT dans `closure #1 in SuiviSockets.demarrer()`) : les
    /// blocs passés aux fonctions trouvées par `dlsym` étaient déclarés non
    /// échappants ; NetworkStatistics les retient, et Swift arrête le
    /// processus dès le premier socket (« closure argument passed as
    /// @noescape to Objective-C has escaped »). Sans `@escaping`, ce test
    /// tue le processus de test au démarrage du suivi.
    @Test func leSuiviDemarreReleveEtSArreteSansPlanter() {
        guard SuiviSockets.disponible else { return }   // macOS sans le cadre : la carte le dit
        let suivi = SuiviSockets()
        suivi.demarrer()
        Thread.sleep(forTimeInterval: 0.3)
        let attente = DispatchSemaphore(value: 0)
        let recu = Verrouille(SuiviSockets.Releve())
        suivi.relever { _ in attente.signal() }
        #expect(attente.wait(timeout: .now() + 3) == .success, "le premier relevé n'est jamais revenu")
        Thread.sleep(forTimeInterval: 0.5)
        suivi.relever { recu.pose($0); attente.signal() }
        #expect(attente.wait(timeout: .now() + 3) == .success, "le second relevé n'est jamais revenu")
        suivi.arreter()
        let releve = recu.lue
        #expect(releve.sockets > 0, "aucun socket vu : NetworkStatistics a changé ?")
        #expect(releve.intervalle > 0)
    }
}

/// Ce qui trie, lit et juge la connexion : chaque cas vient d'un réseau
/// qu'Isma utilise (Starlink et opérateurs mobiles en CGNAT, partage iPhone,
/// portail captif d'hôtel).
@Suite struct ConnexionTests {
    static func sockaddr4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Data {
        Data([16, UInt8(AF_INET), 1, 187, a, b, c, d] + [UInt8](repeating: 0, count: 8))
    }

    static func sockaddr6(_ adresse: [UInt8]) -> Data {
        Data([28, UInt8(AF_INET6), 1, 187, 0, 0, 0, 0] + adresse + [0, 0, 0, 0])
    }

    /// Le CGNAT (100.64/10) est celui de Starlink et des opérateurs : une
    /// connexion vers lui n'est pas Internet, elle ne doit pas donner la
    /// latence Internet.
    @Test func lesAdressesPriveesNeSontPasInternet() {
        #expect(!LecteurAdresses.estPublique(ipv4: [10, 0, 0, 1]))
        #expect(!LecteurAdresses.estPublique(ipv4: [172, 20, 10, 1]))      // partage iPhone
        #expect(LecteurAdresses.estPublique(ipv4: [172, 32, 0, 1]))
        #expect(!LecteurAdresses.estPublique(ipv4: [192, 168, 1, 2]))
        #expect(!LecteurAdresses.estPublique(ipv4: [100, 64, 0, 1]))       // CGNAT
        #expect(!LecteurAdresses.estPublique(ipv4: [100, 127, 255, 254]))
        #expect(LecteurAdresses.estPublique(ipv4: [100, 128, 0, 1]))
        #expect(!LecteurAdresses.estPublique(ipv4: [169, 254, 3, 4]))
        #expect(!LecteurAdresses.estPublique(ipv4: [224, 0, 0, 251]))      // mDNS
        #expect(LecteurAdresses.estPublique(ipv4: [160, 79, 104, 10]))
    }

    @Test func unSockaddrBrutSeClasseCommeSonAdresse() {
        #expect(LecteurAdresses.estPublique(sockaddr: Self.sockaddr4(142, 251, 140, 227)))
        #expect(!LecteurAdresses.estPublique(sockaddr: Self.sockaddr4(192, 168, 1, 2)))
        let mappee = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 1, 2]
        #expect(!LecteurAdresses.estPublique(sockaddr: Self.sockaddr6(mappee)))
        let lienLocal: [UInt8] = [0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1]
        #expect(!LecteurAdresses.estPublique(sockaddr: Self.sockaddr6(lienLocal)))
        let uniqueLocale: [UInt8] = [0xFD, 0x12] + [UInt8](repeating: 0, count: 13) + [1]
        #expect(!LecteurAdresses.estPublique(sockaddr: Self.sockaddr6(uniqueLocale)))
        let globale: [UInt8] = [0x2A, 0x01, 0x0E, 0x0A] + [UInt8](repeating: 0, count: 11) + [1]
        #expect(LecteurAdresses.estPublique(sockaddr: Self.sockaddr6(globale)))
        #expect(!LecteurAdresses.estPublique(sockaddr: Self.sockaddr6([UInt8](repeating: 0, count: 15) + [1])))
        #expect(!LecteurAdresses.estPublique(sockaddr: Data([16])))
    }

    /// Un portail captif rend une page HTML à la place de l'adresse : elle
    /// ne doit jamais s'afficher comme une IP.
    @Test func lIPPubliqueNeLitQueDesAdresses() {
        #expect(IPPublique.lire(reponse: Data("203.0.113.7\n".utf8)) == "203.0.113.7")
        #expect(IPPublique.lire(reponse: Data("2001:db8::1".utf8)) == "2001:db8::1")
        #expect(IPPublique.lire(reponse: Data("<html><body>Connectez-vous</body></html>".utf8)) == nil)
        #expect(IPPublique.lire(reponse: Data()) == nil)
    }

    /// Une réponse d'écho telle que la rend un socket ICMP en datagramme :
    /// en-tête IP de 20 octets, puis l'ICMP.
    @Test func laReponseDEchoSeReconnait() {
        let requete = Ping.requete(sequence: 0x1234)
        #expect(Ping.checksum(requete) == 0, "somme de contrôle fausse : la passerelle jetterait le paquet")
        var reponse = requete
        reponse[0] = 0   // type 0 : réponse d'écho
        let ip: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        #expect(Ping.estReponse(ip + reponse, sequence: 0x1234))
        #expect(!Ping.estReponse(ip + reponse, sequence: 0x1235))
        #expect(!Ping.estReponse(ip + requete, sequence: 0x1234), "notre propre requête n'est pas une réponse")
        #expect(Ping.estReponse(reponse, sequence: 0x1234), "sans en-tête IP")
        #expect(!Ping.estReponse(Array(ip.prefix(10)), sequence: 0x1234))
    }

    @Test func lIndicateurDitLeProblemeEnMots() {
        let calme = Latence(ms: 3.4, perdus: 0, essais: 10, source: "ping", aRepondu: true)
        let internet = Latence(ms: 23, source: "trafic en cours")
        #expect(EtatConnexion.juger(connecte: false, passerelle: calme, internet: internet).niveau == .alerte)
        #expect(EtatConnexion.juger(connecte: true, passerelle: calme, internet: internet).phrase == "Connexion stable")
        // Elle répondait, elle se tait : alerte.
        let tue = MoniteurReseau.latence([3.1, 2.9, nil, nil, nil], derniere: nil, source: "ping")
        #expect(EtatConnexion.juger(connecte: true, passerelle: tue, internet: internet).phrase
                == "La passerelle ne répond plus")
        // Elle n'a jamais répondu : une box qui filtre le ping, pas une
        // panne — Internet passe, le trafic en cours le prouve.
        let muette = MoniteurReseau.latence([nil, nil, nil], derniere: nil, source: "ping")
        #expect(EtatConnexion.juger(connecte: true, passerelle: muette, internet: internet).niveau == .calme)
        let instable = Latence(ms: 4, perdus: 2, essais: 10, source: "ping", aRepondu: true)
        #expect(EtatConnexion.juger(connecte: true, passerelle: instable, internet: internet).niveau == .avertissement)
        let lent = Latence(ms: 240, source: "trafic en cours")
        #expect(EtatConnexion.juger(connecte: true, passerelle: calme, internet: lent).phrase
                == "Internet lent : 240 ms d'aller-retour")
        // Un seul ping perdu, la passerelle répond : rien à signaler.
        let unePerte = Latence(ms: 5, perdus: 1, essais: 10, source: "ping", aRepondu: true)
        #expect(EtatConnexion.juger(connecte: true, passerelle: unePerte, internet: internet).niveau == .calme)
    }

    @Test func unDebitMinusculeNeSAfficheJamaisZero() {
        #expect(LigneAppReseau.compact(0) == "—")
        #expect(LigneAppReseau.compact(500) == "<1k")
        #expect(LigneAppReseau.compact(1_500) == "1,5k")
        #expect(LigneAppReseau.compact(2_400_000) == "2,4M")
        #expect(CarteReseau.dbm(-67) == "\u{2212}67 dBm")
        #expect(CarteReseau.ms(3.44) == "3,4 ms")
        #expect(CarteReseau.ms(70.4) == "70 ms")
    }
}

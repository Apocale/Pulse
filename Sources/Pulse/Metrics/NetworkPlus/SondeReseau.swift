import Foundation

/// Les sections réseau de `--probe` propres au chantier 07 : chaque chiffre
/// de la carte Réseau s'y retrouve, mesuré par le même code.
///
/// Lecture seule, comme le reste de `--probe` : rien ne s'écrit, et rien ne
/// sort sur Internet — la sonde active et l'IP publique ne sont jamais
/// lancées ici, même cochées : on dit seulement qu'elles le sont.
enum SondeReseau {
    static func lignes() -> [String] {
        var out: [String] = []
        out += forfait()
        out += connexionEtApps()
        return out
    }

    /// Temps processeur du processus entier, en millisecondes : le travail
    /// des sockets se fait sur une autre file que celle qui mesure.
    private static func cpuMs() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000
            + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
    }

    private static func mesurer<T>(_ travail: () -> T) -> (T, Double) {
        let avant = cpuMs()
        let resultat = travail()
        return (resultat, cpuMs() - avant)
    }

    /// Connexion, Wi-Fi, apps : les mêmes lecteurs que la carte, une fois.
    /// Le ping de la passerelle reste sur le réseau local ; la sonde
    /// Internet et l'IP publique ne partent JAMAIS d'ici.
    static func connexionEtApps() -> [String] {
        let reglages = MainActor.assumeIsolated { ReglagesReseau.actuels }
        var out = ["", "CONNEXION · mesurée sur place, rien ne sort sur Internet"]
        let (adresses, coutAdresses) = mesurer { LecteurAdresses.lire() }
        guard let adresses else {
            out.append("  hors ligne — aucun réseau principal")
            return out
        }

        // Le débit par app et le RTT passif : deux relevés à 2 s d'écart.
        let suivi = SuiviSockets()
        var releve = SuiviSockets.Releve()
        var coutSockets = 0.0
        if SuiviSockets.disponible {
            suivi.demarrer()
            Thread.sleep(forTimeInterval: 0.5)
            let attente = DispatchSemaphore(value: 0)
            suivi.relever { _ in attente.signal() }
            _ = attente.wait(timeout: .now() + 3)
            Thread.sleep(forTimeInterval: 2)
            (releve, coutSockets) = mesurer {
                // Le relevé arrive sur la file du suivi : rangé sous verrou
                // (Swift 6), même s'il arrive après les 3 s d'attente.
                final class Boite: @unchecked Sendable {
                    private let verrou = NSLock()
                    private var valeur = SuiviSockets.Releve()
                    func poser(_ v: SuiviSockets.Releve) { verrou.lock(); valeur = v; verrou.unlock() }
                    var lu: SuiviSockets.Releve { verrou.lock(); defer { verrou.unlock() }; return valeur }
                }
                let boite = Boite()
                suivi.relever { boite.poser($0); attente.signal() }
                _ = attente.wait(timeout: .now() + 3)
                return boite.lu
            }
            suivi.arreter()
        }

        // Comme la carte : pas de ping de la passerelle sans le réglage
        // (demande d'autorisation « Réseau local » possible sous macOS 15).
        let (ping, coutPing) = mesurer {
            reglages.pingPasserelle ? adresses.passerelle.flatMap { Ping.meilleur(vers: $0, sequence: 1) } : nil
        }
        var passerelle = Latence(ms: ping, perdus: ping == nil ? 1 : 0, essais: 1, source: "ping", aRepondu: ping != nil)
        if adresses.passerelle == nil || !reglages.pingPasserelle { passerelle = Latence(source: "ping") }
        let internet = Latence(ms: releve.rttInternet.first, source: "trafic en cours",
                               connexions: releve.rttInternet.count)
        let etat = EtatConnexion.juger(connecte: true, passerelle: passerelle, internet: internet)
        out.append("  indicateur       \(etat.phrase)")
        out.append("  passerelle       \(adresses.passerelle ?? "aucune") : "
                   + (!reglages.pingPasserelle ? "non mesurée (réglage « Ping de la passerelle » désactivé)"
                      : ping.map { "\(CarteReseau.ms($0)) (2 échos ICMP, le plus court)" } ?? "sans réponse"))
        if let plusCourt = releve.rttInternet.first {
            let mediane = releve.rttInternet[releve.rttInternet.count / 2]
            out.append("  Internet         ~\(CarteReseau.ms(plusCourt)) : le plus court des RTT de \(releve.rttInternet.count) connexion\(releve.rttInternet.count > 1 ? "s" : "") TCP actives (médiane \(CarteReseau.ms(mediane)))")
        } else {
            out.append("  Internet         rien à mesurer : aucune connexion TCP active vers Internet pendant les 2 s")
        }
        out.append("  sonde active     \(reglages.sondeInternet ? "cochée" : "désactivée") (ping \(MoniteurReseau.cibleSonde) chaque minute, panneau ouvert ; jamais lancée par --probe)")
        out.append("  IP locale        \(adresses.ipv4 ?? "aucune") (\(adresses.interface)) · IPv6 \(adresses.ipv6 ?? "aucune routable")")
        out.append("  DNS              \(adresses.dns.isEmpty ? "aucun" : adresses.dns.joined(separator: ", "))")
        out.append("  IP publique      \(reglages.ipPublique ? "cochée" : "désactivée") (\(IPPublique.service.host ?? "") ; sort sur Internet, jamais lancée par --probe)")

        let (wifi, coutWiFi) = mesurer { LecteurWiFi.lire() }
        out.append("")
        out.append("WI-FI · CoreWLAN, sans autorisation de localisation")
        if let wifi {
            out.append("  signal           \(CarteReseau.dbm(wifi.rssi)) · \(wifi.qualite) (\(wifi.barres)/4) · bruit \(CarteReseau.dbm(wifi.bruit)) · rapport \(wifi.snr) dB")
            out.append("  liaison          \(Int(wifi.debitLiaison)) Mbit/s · " + [wifi.canal.map { "canal \($0)" }, wifi.bande,
                                                    wifi.largeurMHz.map { "\($0) MHz" }, wifi.norme].compactMap { $0 }.joined(separator: " · "))
            out.append("  nom du réseau    non lu : macOS le réserve aux apps autorisées à localiser, Pulse ne le demande pas")
        } else {
            out.append("  pas de Wi-Fi associé (filaire, USB, ou carte éteinte)")
        }

        out.append("")
        if !SuiviSockets.disponible {
            out.append("APPS · NetworkStatistics introuvable sur ce macOS — débit par app indisponible")
        } else {
            out.append(String(format: "APPS · NetworkStatistics, %d sockets, débit sur %.1f s", releve.sockets, releve.intervalle)
                .replacingOccurrences(of: ".", with: ","))
            let actives = releve.apps.filter { $0.total >= 500 }
            if actives.isEmpty { out.append("  aucune app au-dessus de 500 o/s") }
            for app in actives.prefix(8) {
                let nom = app.id.hasPrefix("exec:") ? Fmt.processName(app.nom) : Fmt.appName(app.nom)
                out.append("  \(nom.padding(toLength: 22, withPad: " ", startingAt: 0)) ↑ \(Fmt.bytes(app.envoye))/s  ↓ \(Fmt.bytes(app.recu))/s")
            }
        }

        // Le coût, mesuré ici, ramené aux rythmes de la carte.
        let parSeconde = coutSockets / MoniteurReseau.rythmeSockets
            + (coutWiFi + coutAdresses + coutPing) / MoniteurReseau.rythmeLiaison
        out.append("")
        out.append("COÛT · temps processeur de ce relevé unique, à froid (régime établi : banc, voir le README)")
        out.append(String(format: "  sockets %.2f ms (toutes les %.0f s) · Wi-Fi %.2f ms · adresses %.2f ms · ping %.2f ms (toutes les %.0f s)",
                          coutSockets, MoniteurReseau.rythmeSockets, coutWiFi, coutAdresses, coutPing, MoniteurReseau.rythmeLiaison)
            .replacingOccurrences(of: ".", with: ","))
        out.append(String(format: "  à ces rythmes ≈ %.3f %% d'un cœur panneau ouvert ; panneau fermé : rien ne tourne", parSeconde / 10)
            .replacingOccurrences(of: ".", with: ","))
        return out
    }

    private static let jourMois: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM"
        return f
    }()

    static func forfait(maintenant: Date = Date()) -> [String] {
        let reglages = MainActor.assumeIsolated { ReglagesReseau.actuels }
        let jours = Forfait.joursALire(maintenant: maintenant, jour: reglages.jourRenouvellement)
        let etat = Forfait.etat(historique: NetworkTracker().history(days: jours, from: maintenant),
                                reglages: reglages, maintenant: maintenant)
        var out = ["", "FORFAIT IPHONE · ce Mac à travers le partage de connexion"]
        let fichier = "reglages.json, modules.reseau"
        if let go = reglages.forfaitGo {
            out.append("  réglages         \(Fmt.bytes(go * 1e9)), renouvelé le \(reglages.jourRenouvellement) (\(fichier))")
        } else {
            out.append("  réglages         forfait non réglé — pas de jauge sans dénominateur (\(fichier))")
        }
        let derniers = Calendar.current.date(byAdding: .day, value: -1, to: etat.fin) ?? etat.fin
        out.append("  cycle            du \(jourMois.string(from: etat.debut)) au \(jourMois.string(from: derniers)) inclus, jour \(etat.parJour.count)")
        var consomme = "  consommé         \(Fmt.bytes(etat.consomme))"
        if let fraction = etat.fraction, let reste = etat.reste {
            consomme += " · \(Fmt.percent(fraction)) du forfait · reste \(Fmt.bytes(reste))"
        }
        out.append(consomme)
        out.append("  niveau           \(etat.niveau.libelle) (seuils du chantier 11 : \(Fmt.percent(Forfait.seuilProche)) et \(Fmt.percent(Forfait.seuilDepasse)))")
        let observe = etat.observeDepuis.map { "compté depuis le \(jourMois.string(from: $0))" } ?? "rien de compté sur ce cycle"
        if let rythme = etat.rythme {
            var ligne = "  rythme           \(Fmt.bytes(rythme)) par jour, \(observe)"
            if let budget = etat.budgetParJour { ligne += " · budget \(Fmt.bytes(budget)) par jour" }
            out.append(ligne)
            if etat.quota != nil {
                out.append("  épuisé vers      " + (etat.epuiseVers.map { "le \(jourMois.string(from: $0)), à ce rythme" } ?? "pas avant la fin du cycle"))
            }
        } else {
            out.append("  rythme           après \(Int(Forfait.joursAvantRythme)) jours observés — \(observe)")
        }
        let actifs = etat.parJour.filter { $0.octets > 0 }
        out.append("  par jour         " + (actifs.isEmpty ? "aucun octet par le partage iPhone sur ce cycle"
                     : actifs.map { "\(jourMois.string(from: $0.jour)) \(Fmt.bytes($0.octets))" }.joined(separator: " · ")))
        return out
    }
}

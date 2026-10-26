import Foundation
import Darwin
import SystemConfiguration

/// Les adresses du Mac sur son réseau principal, lues sur place
/// (`getifaddrs`, SystemConfiguration) : rien ne sort.
struct AdressesLocales: Equatable {
    var interface: String
    var ipv4: String?
    /// La première adresse IPv6 routable — ni locale au lien (fe80::), ni
    /// unique locale (fd00::/8).
    var ipv6: String?
    var passerelle: String?
    var dns: [String] = []
}

enum LecteurAdresses {
    static func lire() -> AdressesLocales? {
        guard let principal = NetworkMonitor.primary() else { return nil }
        var adresses = AdressesLocales(interface: principal.interface, passerelle: principal.router)
        var liste: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&liste) == 0, let premiere = liste else { return adresses }
        defer { freeifaddrs(liste) }
        var courant: UnsafeMutablePointer<ifaddrs>? = premiere
        while let entree = courant {
            defer { courant = entree.pointee.ifa_next }
            guard String(cString: entree.pointee.ifa_name) == principal.interface,
                  let sa = entree.pointee.ifa_addr else { continue }
            var hote = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hote, socklen_t(hote.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let texte = String(nulTerminated: hote)
            switch Int32(sa.pointee.sa_family) {
            case AF_INET where adresses.ipv4 == nil:
                adresses.ipv4 = texte
            case AF_INET6 where adresses.ipv6 == nil && estRoutable(ipv6: texte):
                adresses.ipv6 = texte
            default:
                break
            }
        }
        adresses.dns = serveursDNS()
        return adresses
    }

    static func estRoutable(ipv6 texte: String) -> Bool {
        let bas = texte.lowercased()
        return !bas.hasPrefix("fe80") && !bas.hasPrefix("fd") && !bas.hasPrefix("fc") && bas != "::1"
    }

    private static func serveursDNS() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Pulse" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        else { return [] }
        return dns["ServerAddresses"] as? [String] ?? []
    }

    /// Adresse privée, locale ou réservée : RFC 1918, 100.64/10 (le CGNAT de
    /// Starlink et des opérateurs mobiles), lien local, bouclage. Sert à
    /// trier les connexions qui vont vraiment sur Internet.
    static func estPublique(ipv4 octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (0, _): return false
        case (172, 16...31), (192, 168), (169, 254): return false
        case (100, 64...127): return false
        case (224..., _): return false
        default: return true
        }
    }
}

extension LecteurAdresses {
    /// Une adresse distante telle que la livre NetworkStatistics : un
    /// `sockaddr` brut (longueur, famille, port, adresse). IPv6 compte comme
    /// publique sauf lien local (fe80::/10), unique locale (fc00::/7),
    /// bouclage et adresse nulle ; une IPv4 mappée (::ffff:a.b.c.d) suit les
    /// règles IPv4.
    static func estPublique(sockaddr data: Data) -> Bool {
        let octets = [UInt8](data)
        guard octets.count >= 2 else { return false }
        let famille = Int32(octets[1])
        if famille == AF_INET, octets.count >= 8 {
            return estPublique(ipv4: Array(octets[4..<8]))
        }
        if famille == AF_INET6, octets.count >= 24 {
            let a = Array(octets[8..<24])
            if a[0..<10].allSatisfy({ $0 == 0 }), a[10] == 0xFF, a[11] == 0xFF {
                return estPublique(ipv4: Array(a[12..<16]))
            }
            if a[0] == 0xFE && (a[1] & 0xC0) == 0x80 { return false }
            if (a[0] & 0xFE) == 0xFC { return false }
            if a[0..<15].allSatisfy({ $0 == 0 }) { return false }   // :: et ::1
            return true
        }
        return false
    }
}

/// L'adresse IP publique, demandée à un service extérieur : la seule mesure
/// de la carte qui sorte sur Internet. Désactivée par défaut
/// (`ReglagesReseau.ipPublique`) ; jamais lancée par `--probe` ni
/// `--snapshot`.
enum IPPublique {
    /// Réponse en texte brut, l'adresse seule.
    static let service = URL(string: "https://api.ipify.org")!

    /// Une adresse IPv4 ou IPv6 plausible, ou `nil` : une page d'erreur d'un
    /// portail captif ne doit pas s'afficher comme une adresse.
    static func lire(reponse: Data) -> String? {
        guard let texte = String(data: reponse, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), texte.count <= 45 else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, texte, &v4) == 1 || inet_pton(AF_INET6, texte, &v6) == 1 { return texte }
        return nil
    }

    static func demander(_ fin: @escaping @Sendable (String?) -> Void) {
        var requete = URLRequest(url: service, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        requete.httpMethod = "GET"
        URLSession.shared.dataTask(with: requete) { data, _, _ in
            fin(data.flatMap(lire(reponse:)))
        }.resume()
    }
}

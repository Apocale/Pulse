import Foundation
import Darwin

/// Un écho ICMP, sans root : socket `SOCK_DGRAM` / `IPPROTO_ICMP`, celui
/// que macOS ouvre aux apps ordinaires (vérifié le 11/10 sur un binaire
/// compilé : la passerelle répond en 3,5 à 7 ms).
///
/// 24 octets d'ICMP, 44 avec l'en-tête IP. Vers la passerelle, rien ne
/// quitte le réseau local — sur le partage de connexion, la passerelle EST
/// l'iPhone : le ping ne touche pas au forfait.
enum Ping {
    /// Le temps d'aller-retour en millisecondes, ou `nil` sans réponse dans
    /// le délai. Bloquant : jamais sur le fil principal.
    static func echo(vers adresse: String, delai: TimeInterval = 1, sequence: UInt16 = 1) -> Double? {
        var cible = sockaddr_in()
        cible.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        cible.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, adresse, &cible.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let paquet = requete(sequence: sequence)
        let depart = DispatchTime.now().uptimeNanoseconds
        let envoye = withUnsafePointer(to: &cible) { pointeur in
            pointeur.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, paquet, paquet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard envoye == paquet.count else { return nil }

        var tampon = [UInt8](repeating: 0, count: 256)
        while true {
            let ecoule = Double(DispatchTime.now().uptimeNanoseconds - depart) / 1e9
            let reste = Int32(max(0, (delai - ecoule) * 1000))
            var attente = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard reste > 0, poll(&attente, 1, reste) == 1 else { return nil }
            let lus = recv(fd, &tampon, tampon.count, 0)
            guard lus > 0 else { return nil }
            if estReponse(Array(tampon.prefix(lus)), sequence: sequence) {
                return Double(DispatchTime.now().uptimeNanoseconds - depart) / 1e6
            }
        }
    }

    /// Deux échos à 100 ms d'écart, le plus court retenu ; `nil` si aucun ne
    /// revient. Le premier paquet après un silence réveille la radio Wi-Fi
    /// de son économie d'énergie : relevé le 11/10, la même passerelle a
    /// répondu en 3,4 ms puis en 70 ms d'un relevé à l'autre. Le second
    /// écho mesure la liaison, pas le réveil.
    static func meilleur(vers adresse: String, delai: TimeInterval = 1, sequence: UInt16) -> Double? {
        let premier = echo(vers: adresse, delai: delai, sequence: sequence)
        usleep(100_000)
        let second = echo(vers: adresse, delai: delai, sequence: sequence &+ 1)
        return plusCourt(premier, second)
    }

    /// Le plus court des deux échos qui sont revenus.
    static func plusCourt(_ premier: Double?, _ second: Double?) -> Double? {
        [premier, second].compactMap { $0 }.min()
    }

    /// Les 8 octets d'en-tête ICMP (écho, identifiant « PU », séquence), puis
    /// 16 octets de charge qui disent d'où vient le paquet.
    static func requete(sequence: UInt16) -> [UInt8] {
        var paquet: [UInt8] = [8, 0, 0, 0, 0x50, 0x55, UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        paquet += Array("Pulse-latence---".utf8)
        let somme = checksum(paquet)
        paquet[2] = UInt8(somme >> 8)
        paquet[3] = UInt8(somme & 0xFF)
        return paquet
    }

    /// Sur macOS, un socket ICMP en datagramme rend l'en-tête IP devant
    /// l'ICMP : on le saute, puis on vérifie type (réponse d'écho) et
    /// séquence.
    static func estReponse(_ recu: [UInt8], sequence: UInt16) -> Bool {
        guard let premier = recu.first else { return false }
        let entete = (premier >> 4) == 4 ? Int(premier & 0x0F) * 4 : 0
        guard recu.count >= entete + 8, recu[entete] == 0 else { return false }
        return UInt16(recu[entete + 6]) << 8 | UInt16(recu[entete + 7]) == sequence
    }

    static func checksum(_ octets: [UInt8]) -> UInt16 {
        var somme: UInt32 = 0
        var i = 0
        while i + 1 < octets.count {
            somme += UInt32(octets[i]) << 8 | UInt32(octets[i + 1])
            i += 2
        }
        if i < octets.count { somme += UInt32(octets[i]) << 8 }
        while somme >> 16 != 0 { somme = (somme & 0xFFFF) + (somme >> 16) }
        return ~UInt16(somme)
    }
}

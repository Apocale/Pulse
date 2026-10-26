import Foundation
import Testing
@testable import Pulse

/// Le coût du moniteur réseau panneau ouvert, mesuré en régime établi : les
/// mêmes lecteurs, à la même cadence, pendant une minute. Temps processeur
/// du processus entier (`getrusage`), jamais un `top` instantané.
///
/// Désactivé par défaut — une minute de plus à chaque `swift test` coûterait
/// à tout le monde. À lancer à la main :
///
///     PULSE_BANC_RESEAU=60 swift test --filter BancReseau
///
/// Compilé en debug par `swift test` : c'est un plafond. L'essentiel du
/// travail est dans les cadres d'Apple, que le mode de compilation ne change
/// pas.
@Suite struct BancReseau {
    static var secondes: Double? {
        ProcessInfo.processInfo.environment["PULSE_BANC_RESEAU"].flatMap(Double.init)
    }

    static func cpuMs() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000
            + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
    }

    @Test(.enabled(if: BancReseau.secondes != nil))
    func coutPanneauOuvert() {
        let duree = Self.secondes ?? 60
        let suivi = SuiviSockets()
        suivi.demarrer()
        Thread.sleep(forTimeInterval: 0.5)
        let attente = DispatchSemaphore(value: 0)
        // Premier relevé, la référence, et la première lecture à froid :
        // hors mesure, comme l'ouverture du panneau.
        suivi.relever { _ in attente.signal() }
        _ = attente.wait(timeout: .now() + 3)
        _ = LecteurWiFi.lire()

        let debut = Self.cpuMs()
        let depart = Date()
        var tour = 0
        // Écrit sur la file du suivi, lu ici : sous verrou (Swift 6).
        final class Compte: @unchecked Sendable {
            private let verrou = NSLock()
            private var n = 0
            var valeur: Int {
                get { verrou.lock(); defer { verrou.unlock() }; return n }
                set { verrou.lock(); n = newValue; verrou.unlock() }
            }
        }
        let compte = Compte()
        while Date().timeIntervalSince(depart) < duree {
            Thread.sleep(forTimeInterval: MoniteurReseau.rythmeSockets)
            suivi.relever { releve in compte.valeur = releve.sockets; attente.signal() }
            _ = attente.wait(timeout: .now() + 3)
            tour += 1
            if tour % Int(MoniteurReseau.rythmeLiaison / MoniteurReseau.rythmeSockets) == 0 {
                let adresses = LecteurAdresses.lire()
                _ = LecteurWiFi.lire()
                if let passerelle = adresses?.passerelle { _ = Ping.meilleur(vers: passerelle, sequence: UInt16(tour)) }
            }
        }
        let cpu = Self.cpuMs() - debut
        let ecoule = Date().timeIntervalSince(depart)
        suivi.arreter()
        let part = cpu / 1000 / ecoule * 100
        print(String(format: "BANC RÉSEAU : %.1f ms de processeur en %.0f s, %d relevés de %d sockets → %.3f %% d'un cœur panneau ouvert",
                     cpu, ecoule, tour, compte.valeur, part))
        #expect(part < 1, "le moniteur réseau coûte \(part) % d'un cœur panneau ouvert")
    }
}

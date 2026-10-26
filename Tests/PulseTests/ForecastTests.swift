import Foundation
import Testing
@testable import Pulse

/// La prévision de remplissage (`HistoryStore.forecast(points:…)`), sur des
/// relevés fabriqués toutes les 10 min comme le vrai historique.
@Suite struct ForecastTests {
    static let go = 1e9
    static let ssd: UInt64 = 2_000_000_000_000

    /// Un point toutes les 10 min ; `free(h)` donne l'espace libre à l'heure h.
    static func points(hours: Double, _ free: (Double) -> Double) -> [DiskPoint] {
        stride(from: 0.0, through: hours, by: 1.0 / 6).map { h in
            let f = free(h)
            return DiskPoint(t: 1_791_000_000 + h * 3600, free: f, freeStrict: f)
        }
    }

    /// Le cas du 09/10 sur Ssd 2, reconstitué depuis history.json : stable
    /// 32 h, deux ingestions brutales puis 7 h de téléchargement à ~7 Go les
    /// 10 min, 596 Go effacés d'un coup, puis immobile 30 h.
    @Test func uneRafaleFinieNAnnoncePlusUnDisquePlein() {
        let pts = Self.points(hours: 72) { h in
            switch h {
            case ..<32: return 729 * Self.go
            case ..<32.5: return 340 * Self.go                         // ingestions brutales
            case ..<39.5: return (340 - (h - 32.5) * 37) * Self.go    // téléchargement, 6 Go / 10 min
            case ..<42: return 80 * Self.go
            default: return 676 * Self.go                             // effacement, puis plus rien
            }
        }
        let forecast = HistoryStore.forecast(points: pts, capacity: Self.ssd, free: UInt64(676 * Self.go))
        #expect(forecast != nil)
        #expect(forecast?.daysUntilFull == nil, "annonce encore « plein dans \(forecast?.daysUntilFull ?? 0) jours »")
        #expect(forecast?.window == HistoryStore.recentWindow)
        #expect(abs(forecast?.bytesPerDay ?? 1e12) < 1 * Self.go)
    }

    /// Un disque qui se remplit vraiment, tous les jours : l'alerte reste.
    @Test func unRemplissageQuiDureGardeSonEcheance() {
        let pts = Self.points(hours: 72) { h in (400 - h / 24 * 60) * Self.go }   // 60 Go par jour
        let forecast = HistoryStore.forecast(points: pts, capacity: Self.ssd, free: UInt64(220 * Self.go))
        let days = forecast?.daysUntilFull ?? .infinity
        #expect(abs(days - 220.0 / 60) < 0.1, "échéance \(days) au lieu de ~3,7 jours")
    }

    /// Le piège documenté dans le README : 207 Go effacés en une fois, puis un
    /// remplissage lent. La pente ne doit jamais changer de signe.
    @Test func unEffacementEnMasseNInversePasLaPente() {
        let pts = Self.points(hours: 72) { h in
            h < 58 ? 300 * Self.go : (507 - (h - 58) / 24 * 3) * Self.go   // +207 Go, puis 3 Go par jour
        }
        let forecast = HistoryStore.forecast(points: pts, capacity: Self.ssd, free: UInt64(505 * Self.go))
        #expect((forecast?.bytesPerDay ?? 0) < 0, "le volume se remplit et la pente dit qu'il se vide")
        #expect((forecast?.ruptures ?? 0) >= 1)
    }

    /// Une rafale récente, plus rapide que la moyenne des 72 h : rien ne
    /// change par rapport à avant, c'est le rythme des 72 h qui parle.
    @Test func uneRafaleRecenteNeFaitPasCrierPlusFortQuAvant() {
        let pts = Self.points(hours: 72) { h in h < 48 ? 600 * Self.go : (600 - (h - 48) / 24 * 90) * Self.go }
        let forecast = HistoryStore.forecast(points: pts, capacity: Self.ssd, free: UInt64(510 * Self.go))
        #expect(forecast?.window == HistoryStore.trendWindow)
        let perDay = -(forecast?.bytesPerDay ?? 0) / Self.go
        #expect(abs(perDay - 30) < 1, "\(perDay) Go par jour au lieu de 30, la moyenne des 72 h")
    }
}

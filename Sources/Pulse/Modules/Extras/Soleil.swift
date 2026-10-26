import Foundation

/// Lever et coucher du soleil, calculés sur place : rien ne sort, rien n'est
/// demandé. Algorithme de la NOAA (Global Monitoring Laboratory, « Solar
/// Calculation Details »), précis à la minute aux latitudes habitées ; le
/// soleil est levé quand son bord supérieur passe l'horizon, réfraction
/// comprise (90,833°), comme dans les éphémérides publiées.
enum Soleil {
    struct Journee: Equatable {
        /// Nil les jours où le soleil ne se lève pas ou ne se couche pas.
        var lever: Date?
        var coucher: Date?
        /// Jour polaire (le soleil ne se couche pas), nuit polaire, ou rien.
        var polaire: Polaire?

        enum Polaire: Equatable { case jour, nuit }

        /// Durée du jour, en secondes.
        var duree: TimeInterval? {
            if polaire == .jour { return 86_400 }
            if polaire == .nuit { return 0 }
            guard let lever, let coucher else { return nil }
            return coucher.timeIntervalSince(lever)
        }

        /// Le soleil est-il levé à cet instant ?
        func fait(jour instant: Date) -> Bool {
            switch polaire {
            case .jour?: return true
            case .nuit?: return false
            case nil:
                guard let lever, let coucher else { return false }
                return instant >= lever && instant < coucher
            }
        }
    }

    /// Le lever et le coucher du jour civil qui contient `instant` dans
    /// `fuseau`, au lieu donné.
    static func journee(_ instant: Date, latitude: Double, longitude: Double, fuseau: TimeZone) -> Journee {
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = fuseau
        let jour = calendrier.dateComponents([.year, .month, .day], from: instant)
        guard let annee = jour.year, let mois = jour.month, let quantieme = jour.day else { return Journee() }

        // Minuit UTC de cette date civile : l'origine des minutes calculées.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let minuitUTC = utc.date(from: DateComponents(year: annee, month: mois, day: quantieme)) else { return Journee() }

        // Siècle julien au midi solaire approximatif du lieu.
        let jourJulien = minuitUTC.timeIntervalSince1970 / 86_400 + 2_440_587.5 + 0.5 - longitude / 360
        let t = (jourJulien - 2_451_545) / 36_525

        let l0 = fmod(280.46646 + t * (36000.76983 + t * 0.0003032), 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t)
            + sin(rad(3 * m)) * 0.000289
        let longitudeVraie = l0 + c
        let omega = 125.04 - 1934.136 * t
        let longitudeApparente = longitudeVraie - 0.00569 - 0.00478 * sin(rad(omega))
        let obliquiteMoyenne = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquite = obliquiteMoyenne + 0.00256 * cos(rad(omega))
        let declinaison = asin(sin(rad(obliquite)) * sin(rad(longitudeApparente)))
        let y = pow(tan(rad(obliquite / 2)), 2)
        // Équation du temps, en minutes.
        let equation = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m))
                               + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
                               - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))

        let phi = rad(latitude)
        let cosAngle = cos(rad(90.833)) / (cos(phi) * cos(declinaison)) - tan(phi) * tan(declinaison)
        if cosAngle > 1 { return Journee(polaire: .nuit) }
        if cosAngle < -1 { return Journee(polaire: .jour) }
        let angleHoraire = deg(acos(cosAngle))
        let midiSolaire = 720 - 4 * longitude - equation          // minutes après minuit UTC
        let lever = midiSolaire - angleHoraire * 4
        let coucher = midiSolaire + angleHoraire * 4
        return Journee(lever: minuitUTC.addingTimeInterval(lever * 60),
                       coucher: minuitUTC.addingTimeInterval(coucher * 60))
    }

    static func journee(_ instant: Date, ville: Ville) -> Journee {
        journee(instant, latitude: ville.latitude, longitude: ville.longitude, fuseau: ville.timeZone)
    }

    private static func rad(_ degres: Double) -> Double { degres * .pi / 180 }
    private static func deg(_ radians: Double) -> Double { radians * 180 / .pi }
}

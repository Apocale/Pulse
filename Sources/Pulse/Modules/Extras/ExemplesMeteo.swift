import Foundation

/// Des réponses d'Open-Meteo écrites d'après sa documentation
/// (open-meteo.com/en/docs : structure, noms des variables, codes OMM), SANS
/// appel à l'API : en appeler une, même pour l'enregistrer, enverrait une
/// position sur Internet. Elles servent aux tests de décodage et à la carte
/// sous `--exemple`.
enum ExemplesMeteo {
    /// Casablanca, `timeformat` par défaut (ISO 8601 à l'heure du lieu),
    /// `timezone=auto`, 24 heures et 7 jours, comme la requête de Pulse.
    static let casablanca = #"""
{"latitude":33.5625,"longitude":-7.625,"generationtime_ms":0.1220703125,"utc_offset_seconds":0,"timezone":"Africa/Casablanca","timezone_abbreviation":"GMT","elevation":27.0,"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","weather_code":"wmo code","is_day":""},"current":{"time":"2026-10-11T07:00","interval":900,"temperature_2m":17.8,"weather_code":1,"is_day":1},"hourly_units":{"time":"iso8601","temperature_2m":"°C","precipitation_probability":"%","weather_code":"wmo code","is_day":""},"hourly":{"time":["2026-10-11T07:00","2026-10-11T08:00","2026-10-11T09:00","2026-10-11T10:00","2026-10-11T11:00","2026-10-11T12:00","2026-10-11T13:00","2026-10-11T14:00","2026-10-11T15:00","2026-10-11T16:00","2026-10-11T17:00","2026-10-11T18:00","2026-10-11T19:00","2026-10-11T20:00","2026-10-11T21:00","2026-10-11T22:00","2026-10-11T23:00","2026-10-12T00:00","2026-10-12T01:00","2026-10-12T02:00","2026-10-12T03:00","2026-10-12T04:00","2026-10-12T05:00","2026-10-12T06:00"],"temperature_2m":[18.0,19.0,20.0,21.0,22.0,22.8,23.5,23.9,24.0,23.9,23.5,22.8,22.0,21.0,20.0,19.0,18.0,17.2,16.5,16.1,16.0,16.1,16.5,17.2],"precipitation_probability":[0,0,0,0,0,5,10,10,10,10,10,10,35,35,55,55,55,60,60,60,60,0,0,0],"weather_code":[1,1,1,1,1,1,2,2,2,2,2,2,3,3,61,61,61,61,61,61,61,1,1,1],"is_day":[1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0]},"daily_units":{"time":"iso8601","weather_code":"wmo code","temperature_2m_max":"°C","temperature_2m_min":"°C","precipitation_probability_max":"%","sunrise":"iso8601","sunset":"iso8601"},"daily":{"time":["2026-10-11","2026-10-12","2026-10-13","2026-10-14","2026-10-15","2026-10-16","2026-10-17"],"weather_code":[61,63,3,0,1,80,95],"temperature_2m_max":[24.1,21.3,22.0,25.4,26.2,23.0,20.5],"temperature_2m_min":[15.8,16.2,14.9,15.1,16.8,17.0,15.5],"precipitation_probability_max":[60,85,20,0,5,60,75],"sunrise":["2026-10-11T06:32","2026-10-12T06:33","2026-10-13T06:34","2026-10-14T06:35","2026-10-15T06:35","2026-10-16T06:36","2026-10-17T06:37"],"sunset":["2026-10-11T18:02","2026-10-12T18:01","2026-10-13T18:00","2026-10-14T17:58","2026-10-15T17:57","2026-10-16T17:56","2026-10-17T17:55"]}}
"""#

    /// Paris en `timeformat=unixtime` (secondes UTC, `utc_offset_seconds`
    /// à 7200), avec des `null` là où un modèle n'a pas de valeur.
    static let parisUnixtime = #"""
{"latitude":48.86,"longitude":2.3399997,"generationtime_ms":0.08,"utc_offset_seconds":7200,"timezone":"Europe/Paris","timezone_abbreviation":"GMT+2","elevation":43.0,"current":{"time":1791698400,"interval":900,"temperature_2m":12.4,"weather_code":3,"is_day":1},"hourly":{"time":[1791698400,1791702000,1791705600],"temperature_2m":[12.4,13.1,null],"precipitation_probability":[null,10,20],"weather_code":[3,3,61],"is_day":[1,1,1]},"daily":{"time":[1791669600,1791756000],"weather_code":[3,61],"temperature_2m_max":[15.2,14.0],"temperature_2m_min":[9.8,null],"precipitation_probability_max":[20,null],"sunrise":[1791698700,1791785160],"sunset":[1791738540,1791824820]}}
"""#

    /// L'erreur que décrit la documentation : HTTP 400 et une raison.
    static let erreur = #"{"error":true,"reason":"Cannot initialize WeatherVariable from invalid String value tempeture_2m for key hourly"}"#

    /// L'exemple de Casablanca recalé sur l'heure du rendu : les heures
    /// commencent à l'heure entamée, les jours à aujourd'hui.
    static func recalee(_ maintenant: Date) -> PrevisionMeteo? {
        guard let p = try? OpenMeteo.decode(Data(casablanca.utf8)), let premiere = p.heures.first,
              let premierJour = p.jours.first else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = p.fuseau
        let heure = cal.dateInterval(of: .hour, for: maintenant)?.start ?? maintenant
        let ecartHeures = heure.timeIntervalSince(premiere.date)
        let jours = cal.dateComponents([.day], from: premierJour.date, to: cal.startOfDay(for: maintenant)).day ?? 0
        var r = p.decalee(de: ecartHeures)
        r.jours = p.decalee(de: TimeInterval(jours) * 86_400).jours
        return r
    }
}

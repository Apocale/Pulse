import Foundation
import CoreWLAN

/// Le signal Wi-Fi, lu par CoreWLAN SANS autorisation de localisation.
///
/// Relevé le 11/10 sur un binaire compilé et signé comme l'app : RSSI, bruit,
/// débit de liaison, canal, bande, largeur et norme reviennent ; le nom du
/// réseau (SSID) et l'adresse du point d'accès (BSSID) reviennent `nil` —
/// macOS les réserve aux apps autorisées à localiser l'utilisateur. Pulse
/// ne demande pas cette autorisation : le nom du Wi-Fi n'apprend rien sur la
/// qualité de la liaison, et la demande ferait peur pour rien.
struct SignalWiFi: Equatable {
    /// Puissance reçue, en dBm (−30 excellent, −90 inutilisable).
    var rssi: Int
    /// Bruit de fond, en dBm.
    var bruit: Int
    /// Débit de liaison négocié, en Mbit/s — un plafond théorique, pas le
    /// débit d'Internet.
    var debitLiaison: Double
    var canal: Int?
    var bande: String?
    var largeurMHz: Int?
    var norme: String?

    /// Rapport signal sur bruit, en dB : c'est lui qui fait le débit réel.
    var snr: Int { rssi - bruit }

    /// Barres de signal, 0 à 4, sur les repères usuels du RSSI — posés, pas
    /// mesurés ici : −60 dBm et mieux, −67 (le plancher couramment conseillé
    /// pour la visio et le streaming), −75, −85.
    var barres: Int {
        switch rssi {
        case (-60)...: return 4
        case (-67)...: return 3
        case (-75)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }

    var qualite: String {
        switch barres {
        case 4: return "excellent"
        case 3: return "bon"
        case 2: return "moyen"
        case 1: return "faible"
        default: return "très faible"
        }
    }
}

enum LecteurWiFi {
    /// `nil` hors Wi-Fi : carte éteinte, ou Mac branché en filaire ou en USB
    /// sur l'iPhone.
    static func lire() -> SignalWiFi? {
        guard let carte = CWWiFiClient.shared().interface(), carte.powerOn() else { return nil }
        let rssi = carte.rssiValue()
        // 0 dBm : pas associé à un réseau. Un vrai signal est toujours négatif.
        guard rssi < 0 else { return nil }
        var signal = SignalWiFi(rssi: rssi, bruit: carte.noiseMeasurement(),
                                debitLiaison: carte.transmitRate())
        if let canal = carte.wlanChannel() {
            signal.canal = canal.channelNumber
            switch canal.channelBand {
            case .band2GHz: signal.bande = "2,4 GHz"
            case .band5GHz: signal.bande = "5 GHz"
            case .band6GHz: signal.bande = "6 GHz"
            default: break
            }
            switch canal.channelWidth {
            case .width20MHz: signal.largeurMHz = 20
            case .width40MHz: signal.largeurMHz = 40
            case .width80MHz: signal.largeurMHz = 80
            case .width160MHz: signal.largeurMHz = 160
            default: break
            }
        }
        signal.norme = norme(carte.activePHYMode())
        return signal
    }

    /// Le nom commercial d'abord : « Wi-Fi 6 » se lit, « 802.11ax » se
    /// vérifie.
    static func norme(_ mode: CWPHYMode) -> String? {
        switch mode.rawValue {
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "Wi-Fi 4 (802.11n)"
        case 5: return "Wi-Fi 5 (802.11ac)"
        case 6: return "Wi-Fi 6 (802.11ax)"
        case 7: return "Wi-Fi 7 (802.11be)"
        default: return nil
        }
    }
}

import Foundation

/// L'écart entre deux relevés des compteurs d'octets de l'interface.
///
/// macOS ne livre à une app tierce que les 32 bits de poids faible : le
/// compteur repasse à zéro tous les 4,29 Go (piège du README). Seul l'écart
/// entre deux relevés rapprochés a un sens, calculé modulo 2³² — un passage
/// par zéro entre les deux donne le bon nombre, pas un nombre négatif.
///
/// Sorti de `NetworkTracker` pour être testé tel que l'app l'exécute : un
/// test lancé par l'interpréteur `swift` voit les vrais 64 bits et ne
/// rencontrerait jamais le rebouclage.
enum CompteursReseau {
    /// Au-delà, un écart n'est pas du trafic mais un compteur remis à zéro
    /// (interface recréée), que le modulo changerait en gigaoctets fantômes.
    /// 2 Go/s, c'est 16 Gbit/s — hors de portée de ce Mac en Wi-Fi.
    static let debitMaxPlausible: Double = 2e9

    /// Au-delà de cet écart entre deux relevés — une veille, une app
    /// suspendue —, un passage par zéro ne se distingue plus d'un compteur
    /// remis à zéro : après une heure de veille, 1,8 Go fantômes ne font que
    /// 0,5 Mo/s, et la borne de débit les laissait passer dans le forfait
    /// iPhone (15-audit-perf, 11/10, `unReveilApresRemiseAZeroNInventePasDeTrafic`).
    /// Le relevé du débit tombe toutes les 2 s : 30 s, c'est quinze relevés
    /// manqués. Un compteur qui a seulement avancé reste compté.
    static let ecartMaxPourUnRebouclage: Double = 30

    /// Octets reçus et envoyés entre `avant` et `apres`, ou `nil` si l'écart
    /// est impossible : durée nulle, débit invraisemblable, ou compteur
    /// revenu en arrière après une longue absence.
    static func ecart(avant: (rx: UInt32, tx: UInt32), apres: (rx: UInt32, tx: UInt32),
                      secondes: Double) -> (rx: UInt64, tx: UInt64)? {
        guard secondes > 0 else { return nil }
        if secondes > ecartMaxPourUnRebouclage, apres.rx < avant.rx || apres.tx < avant.tx { return nil }
        let rx = UInt64(apres.rx &- avant.rx)
        let tx = UInt64(apres.tx &- avant.tx)
        guard Double(rx) / secondes < debitMaxPlausible,
              Double(tx) / secondes < debitMaxPlausible else { return nil }
        return (rx, tx)
    }
}

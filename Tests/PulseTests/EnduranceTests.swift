import Foundation
import Testing
@testable import Pulse

/// Situations dures simulées (chantier 15) : ce qu'aucun relevé ordinaire ne
/// rencontre, mais que des jours d'usage finissent par produire. Les
/// compteurs réseau après une veille sont dans `CompteursReseauTests`.
@Suite struct EnduranceTests {
    static func volume(_ name: String, path: String, uuid: String?, libre: UInt64) -> VolumeSample {
        VolumeSample(name: name, path: path, total: 2_000_000_000_000, available: libre,
                     isInternal: false, uuid: uuid, availableStrict: libre)
    }

    /// Ssd 2 débranché puis rebranché : macOS le remonte en « /Volumes/Ssd 2 »
    /// quand l'ancien dossier traîne, ou sous un autre nom s'il a été
    /// renommé. Son historique (tendance de remplissage, séries de la base)
    /// doit suivre le disque, pas le point de montage.
    @Test func unDisqueRebrancheSousUnAutreNomGardeSonHistorique() {
        let avant = Self.volume("Ssd", path: "/Volumes/Ssd", uuid: "UUID-SSD", libre: 300_000_000_000)
        let apres = Self.volume("Rushes", path: "/Volumes/Rushes 1", uuid: "UUID-SSD", libre: 290_000_000_000)
        #expect(avant.historyKey == apres.historyKey)
        #expect(SeriesCatalog.volumeKey(avant.historyKey) == SeriesCatalog.volumeKey(apres.historyKey))
    }

    /// Deux disques différents montés tour à tour au même endroit ne
    /// mélangent pas leurs historiques.
    @Test func deuxDisquesAuMemeEndroitNeSeMelangentPas() {
        let a = Self.volume("Ssd", path: "/Volumes/Ssd", uuid: "UUID-A", libre: 1)
        let b = Self.volume("Ssd", path: "/Volumes/Ssd", uuid: "UUID-B", libre: 1)
        #expect(a.historyKey != b.historyKey)
    }

    /// Panneau fermé, l'espace « pour usage important » (purgeable compris)
    /// n'est relu que toutes les 10 min : entre-temps, le libre strict lu à
    /// chaque balayage, plus le purgeable du dernier balayage complet. Une
    /// copie de 50 Go se voit donc tout de suite, purgeable inchangé.
    @Test func lePurgeableConnuSuitLeLibreStrict() {
        // Lu : jamais moins que le strict (la clé rend parfois 0).
        #expect(DiskMonitor.disponible(strict: 100, pourUsageImportant: 130, purgeableConnu: nil) == 130)
        #expect(DiskMonitor.disponible(strict: 100, pourUsageImportant: 0, purgeableConnu: 30) == 100)
        // Pas lu : strict du moment + purgeable connu.
        let avant = Self.volume("Ssd 2", path: "/Volumes/Ssd 2", uuid: "U", libre: 0)
        var connu = avant
        connu.availableStrict = 300_000_000_000
        connu.available = 330_000_000_000
        #expect(connu.purgeable == 30_000_000_000)
        #expect(DiskMonitor.disponible(strict: 250_000_000_000, pourUsageImportant: nil,
                                       purgeableConnu: connu.purgeable) == 280_000_000_000)
        // Volume jamais lu en entier : le strict seul, jamais un purgeable inventé.
        #expect(DiskMonitor.disponible(strict: 250, pourUsageImportant: nil, purgeableConnu: nil) == 250)
    }

    /// Sans UUID (partage réseau), la clé retombe sur le chemin : un
    /// remontage ailleurs repart de zéro. Limite connue, écrite ici pour
    /// qu'elle ne change pas sans qu'on le voie.
    @Test func sansUUIDLaCleEstLeChemin() {
        let partage = Self.volume("NAS", path: "/Volumes/NAS", uuid: nil, libre: 1)
        #expect(partage.historyKey == "/Volumes/NAS")
    }
}

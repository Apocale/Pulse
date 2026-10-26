import Foundation
import IOKit

/// Un disque physique : ce qui se branche, pas ce qui se monte. « Ssd 2 » est
/// un volume ; le disque qui le porte est un boîtier USB « ASMT ASM246X ».
/// Les octets lus et écrits se comptent ici, au niveau du pilote : un volume
/// APFS ne publie aucun compteur.
struct PhysicalDisk: Identifiable, Equatable, Sendable {
    /// Identifiant d'entrée du pilote dans l'IORegistry. Stable tant que le
    /// disque reste branché ; un rebranchement en donne un nouveau, et repart
    /// donc proprement de compteurs neufs.
    var id: UInt64
    /// « disk10 ». Lisible par `diskutil`, mais réattribué au rebranchement.
    var bsdName: String
    /// « ASMT ASM246X », « APPLE SSD AP1024Z » : ce que le contrôleur annonce.
    var model: String
    /// « USB », « Apple Fabric », « Secure Digital », « Thunderbolt »…
    var interconnect: String
    var isInternal: Bool
    /// Support amovible : une carte SD, une clé. C'est ce qui distingue une
    /// copie DE CARTE d'une copie entre deux disques.
    var isRemovable: Bool
    /// Le contrôleur publie son journal SMART NVMe (voir `DiskHealth`).
    var smartCapable: Bool
    /// Taille du support entier, en octets.
    var size: UInt64
}

/// Compteurs cumulés depuis le branchement, tels que le pilote les publie.
struct DiskCounters: Equatable, Sendable {
    var read: UInt64
    var written: UInt64
}

/// Lecture des pilotes de stockage par l'IORegistry, sans aucun privilège.
///
/// Chaque `IOBlockStorageDriver` publie un dictionnaire « Statistics » :
/// octets et opérations, en lecture et en écriture, cumulés. C'est la source
/// d'`iostat` et du Moniteur d'activité. Le pilote a pour enfant le support
/// entier (« disk10 ») et pour parent le périphérique, qui dit son modèle et
/// sa liaison.
enum DiskIO {
    /// Les disques branchés et leurs compteurs. `known` sert de cache
    /// d'identité : un disque ne change pas de modèle entre deux relevés, et
    /// relire trois dictionnaires par disque toutes les 5 s ne servirait à rien.
    /// Un pilote sans support (lecteur de carte vide) est ignoré.
    static func read(known: [UInt64: PhysicalDisk]) -> [(disk: PhysicalDisk, counters: DiskCounters)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var out: [(PhysicalDisk, DiskCounters)] = []
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            defer { IOObjectRelease(driver); driver = IOIteratorNext(iterator) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &entryID) == KERN_SUCCESS else { continue }
            guard let disk = known[entryID] ?? identity(of: driver, id: entryID),
                  let stats = property(driver, "Statistics") as? [String: Any] else { continue }
            let counters = DiskCounters(read: number(stats["Bytes (Read)"]),
                                        written: number(stats["Bytes (Write)"]))
            out.append((disk, counters))
        }
        return out
    }

    /// Point de montage → nom BSD du support (« /Volumes/Ssd 2 » → « disk11s1 »),
    /// pour les systèmes de fichiers LOCAUX seulement.
    ///
    /// `getmntinfo` en `MNT_NOWAIT` rend la table que le noyau tient déjà :
    /// aucun appel ne part vers un volume. Un `statfs` par volume, lui,
    /// attendrait sans borne un partage réseau qui ne répond plus — et
    /// bloquerait la file d'échantillonnage avec lui.
    static func mountedDevices() -> [String: String] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else { return [:] }
        var out: [String: String] = [:]
        for i in 0..<Int(count) {
            let fs = table[i]
            guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            let from = withUnsafeBytes(of: fs.f_mntfromname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let on = withUnsafeBytes(of: fs.f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard from.hasPrefix("/dev/") else { continue }
            out[on] = String(from.dropFirst(5))
        }
        return out
    }

    /// Le disque physique qui porte un support (« disk11s1 »), par son
    /// identifiant de pilote. Remonte l'IORegistry : volume APFS → conteneur
    /// → partition → disque entier → pilote. `nil` pour une image disque ou
    /// tout support sans pilote de bloc au-dessus de lui.
    static func driverID(forBSDName bsd: String) -> UInt64? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }

        // Vingt niveaux suffisent largement : la chaîne la plus longue relevée
        // ici (racine scellée, instantané APFS) en compte une dizaine.
        for _ in 0..<20 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                var id: UInt64 = 0
                let ok = IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS
                IOObjectRelease(entry)
                return ok ? id : nil
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    // MARK: - Identité

    private static func identity(of driver: io_registry_entry_t, id: UInt64) -> PhysicalDisk? {
        // Le support entier, enfant du pilote : son nom BSD et son caractère
        // amovible. Absent quand le lecteur est vide.
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &child) == KERN_SUCCESS, child != 0 else { return nil }
        defer { IOObjectRelease(child) }
        guard IOObjectConformsTo(child, "IOMedia") != 0,
              let bsd = property(child, "BSD Name") as? String else { return nil }
        let removable = (property(child, "Removable") as? Bool) ?? false
        let size = number(property(child, "Size"))

        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS, device != 0 else { return nil }
        defer { IOObjectRelease(device) }
        let characteristics = property(device, "Device Characteristics") as? [String: Any] ?? [:]
        let proto = property(device, "Protocol Characteristics") as? [String: Any] ?? [:]
        let vendor = (characteristics["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let product = (characteristics["Product Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let model = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        let interconnect = proto["Physical Interconnect"] as? String ?? "?"
        let location = proto["Physical Interconnect Location"] as? String ?? ""

        return PhysicalDisk(id: id,
                            bsdName: bsd,
                            model: model.isEmpty ? bsd : model,
                            interconnect: interconnect,
                            isInternal: location == "Internal",
                            isRemovable: removable || interconnect == "Secure Digital",
                            smartCapable: (property(device, "NVMe SMART Capable") as? Bool) ?? false,
                            size: size)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

/// Débits tirés de deux relevés successifs des compteurs.
///
/// Les compteurs du pilote sont cumulés depuis le branchement : seul l'écart
/// entre deux relevés a un sens. Un compteur qui recule (pilote recréé sous le
/// même identifiant, ce qui ne devrait pas arriver) ne produit aucun débit
/// plutôt qu'un débit négatif ou un pic de plusieurs exaoctets.
struct DiskRateMeter {
    struct Rate: Equatable, Sendable {
        var read: Double      // octets par seconde
        var write: Double
        /// Octets effectivement écrits pendant l'intervalle.
        var written: Double
        var interval: Double
    }

    private var previous: [UInt64: (t: Double, counters: DiskCounters)] = [:]

    /// Un relevé : `now` en secondes (horloge monotone), compteurs par disque.
    /// Rend le débit de chaque disque déjà vu au relevé précédent. Les disques
    /// absents du relevé sont oubliés : rebranchés, ils repartent de zéro.
    mutating func update(now: Double, readings: [UInt64: DiskCounters]) -> [UInt64: Rate] {
        var rates: [UInt64: Rate] = [:]
        for (id, counters) in readings {
            if let old = previous[id], now > old.t,
               counters.read >= old.counters.read, counters.written >= old.counters.written {
                let dt = now - old.t
                let written = Double(counters.written - old.counters.written)
                rates[id] = Rate(read: Double(counters.read - old.counters.read) / dt,
                                 write: written / dt,
                                 written: written,
                                 interval: dt)
            }
        }
        previous = readings.mapValues { (now, $0) }
        return rates
    }
}

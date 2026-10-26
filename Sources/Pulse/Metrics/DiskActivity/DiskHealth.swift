import Foundation
import IOKit

/// La santé d'un SSD, lue dans son journal SMART NVMe (page 02h, 512 octets).
///
/// Lisible SANS root par le plug-in `NVMeSMARTLib` d'IOKit, sur tout
/// contrôleur qui publie « NVMe SMART Capable » : le SSD interne et, relevé
/// le 11/10, le SanDisk Extreme Pro malgré sa liaison USB. Les boîtiers qui
/// ne relaient pas les commandes NVMe (ASMedia ASM246X de Ssd 2, Lexar E300)
/// n'en disent rien — et Pulse le dit tel quel, sans inventer d'état.
struct DiskHealth: Equatable, Sendable {
    /// Bits d'alerte du contrôleur : réserve, température, fiabilité,
    /// lecture seule, sauvegarde. Zéro quand tout va bien.
    var criticalWarning: UInt8
    /// Température composite, en °C. `nil` si le contrôleur rend 0 K.
    var temperature: Int?
    /// Blocs de réserve restants, en % ; et le seuil sous lequel le
    /// contrôleur lève lui-même l'alerte.
    var availableSpare: Int
    var spareThreshold: Int
    /// Usure estimée par le fabricant, en % de l'endurance nominale. Peut
    /// dépasser 100.
    var percentUsed: Int
    /// Octets lus et écrits depuis la mise en service.
    var dataRead: Double
    var dataWritten: Double
    var powerCycles: Double
    var powerOnHours: Double
    /// Coupures sans arrêt propre : débranché sans éjecter, panne de courant.
    var unsafeShutdowns: Double
    /// Erreurs d'intégrité des données : une seule mérite d'être vue.
    var mediaErrors: Double

    enum Status: Equatable { case good, watch, failing }

    /// Bon, à surveiller, défaillant — sur les seuls critères du contrôleur et
    /// de la norme, sans seuil maison.
    var status: Status {
        if criticalWarning != 0 { return .failing }
        if availableSpare <= spareThreshold || percentUsed >= 90 || mediaErrors > 0 { return .watch }
        return .good
    }

    var statusLabel: String {
        switch status {
        case .good:    return "bon"
        case .watch:   return "à surveiller"
        case .failing: return "alerte du contrôleur"
        }
    }

    /// Décodage de la page SMART, offsets de la norme NVMe (§ 5.14.1.2) et de
    /// `NVMeSMARTData` : compteurs sur 128 bits petit-boutistes, unités de
    /// données de 1000 secteurs de 512 octets.
    static func parse(_ page: [UInt8]) -> DiskHealth? {
        guard page.count >= 192 else { return nil }
        func u128(_ offset: Int) -> Double {
            var low: UInt64 = 0, high: UInt64 = 0
            for i in 0..<8 {
                low |= UInt64(page[offset + i]) << (8 * UInt64(i))
                high |= UInt64(page[offset + 8 + i]) << (8 * UInt64(i))
            }
            return Double(low) + Double(high) * 18_446_744_073_709_551_616
        }
        let kelvin = Int(page[1]) | Int(page[2]) << 8
        return DiskHealth(criticalWarning: page[0],
                          temperature: kelvin > 0 ? kelvin - 273 : nil,
                          availableSpare: Int(page[3]),
                          spareThreshold: Int(page[4]),
                          percentUsed: Int(page[5]),
                          dataRead: u128(32) * 512_000,
                          dataWritten: u128(48) * 512_000,
                          powerCycles: u128(112),
                          powerOnHours: u128(128),
                          unsafeShutdowns: u128(144),
                          mediaErrors: u128(160))
    }
}

/// Lecture du journal SMART par le plug-in d'IOKit, sur le périphérique parent
/// d'un pilote de stockage. 1 à 4 ms par disque, mesuré le 11/10.
enum SMARTReader {
    private static func uuid(_ b: [UInt8]) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                       b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
    /// `kIONVMeSMARTUserClientTypeID`, `kIONVMeSMARTInterfaceID` et
    /// `kIOCFPlugInInterfaceID` : des macros C que Swift n'importe pas,
    /// recopiées de NVMeSMARTLibExternal.h et IOCFPlugIn.h.
    // Des constantes CFUUID, immuables : `nonisolated(unsafe)` dit au
    // compilateur ce que Core Foundation ne déclare pas (Swift 6).
    nonisolated(unsafe) private static let userClientType = uuid([0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
                                              0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F])
    nonisolated(unsafe) private static let smartInterface = uuid([0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
                                              0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6])
    nonisolated(unsafe) private static let plugInInterface = uuid([0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                               0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F])

    /// La santé du disque dont le pilote a l'identifiant `driverID`, ou `nil`
    /// si le contrôleur ne la publie pas ou qu'un autre processus la lit.
    ///
    /// Le client SMART est EXCLUSIF : relevé le 11/10, trois lecteurs lancés
    /// ensemble (`./verifie.sh` lance `--probe` et deux rendus en parallèle),
    /// un seul lit ; pour les autres, la création du plug-in échoue en
    /// `kIOReturnNoResources` (0xe00002be) — et non `kIOReturnExclusiveAccess`
    /// comme on l'attendrait. Une lecture le tient 1 à 4 ms (voir
    /// `IODestroyPlugInInterface` plus bas) ; sur une machine chargée le
    /// lecteur peut être suspendu plus longtemps. Jusqu'à quatre nouvelles
    /// tentatives, espacées de 50 à 200 ms — seulement quand le client est pris.
    static func read(driverID: UInt64) -> DiskHealth? {
        let waits = [0.05, 0.1, 0.15, 0.2]
        for attempt in 0...waits.count {
            switch readOnce(driverID: driverID) {
            case .health(let h): return h
            case .unavailable: return nil
            case .busy:
                if attempt < waits.count { Thread.sleep(forTimeInterval: waits[attempt]) }
            }
        }
        return nil
    }

    private enum Outcome { case health(DiskHealth), busy, unavailable }

    /// Ce que rend IOKit quand un autre processus tient le client SMART :
    /// `kIOReturnNoResources` mesuré ici ; les deux autres par prudence.
    private static let taken: Set<kern_return_t> = [kIOReturnNoResources, kIOReturnExclusiveAccess, kIOReturnBusy]

    private static func readOnce(driverID: UInt64) -> Outcome {
        let unavailable = Outcome.unavailable
        guard let matching = IORegistryEntryIDMatching(driverID) else { return unavailable }
        let driver = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard driver != 0 else { return unavailable }
        defer { IOObjectRelease(driver) }
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS, device != 0 else { return unavailable }
        defer { IOObjectRelease(device) }
        let capable = IORegistryEntryCreateCFProperty(device, "NVMe SMART Capable" as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        guard capable == true else { return unavailable }

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = IOCreatePlugInInterfaceForService(device, userClientType, plugInInterface, &plugin, &score)
        if Self.taken.contains(created) { return .busy }
        guard created == KERN_SUCCESS, let plugin, let vtable = plugin.pointee else { return unavailable }
        // `IODestroyPlugInInterface`, pas `Release` : relevé le 11/10, après
        // un simple `Release` le client exclusif reste tenu jusqu'à la fin du
        // processus — Pulse, qui ne finit jamais, aurait privé de SMART tout
        // autre outil (DriveDx, smartctl) et ses propres relectures.
        defer { _ = IODestroyPlugInInterface(plugin) }

        var raw: UnsafeMutableRawPointer?
        guard vtable.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &raw) == S_OK,
              let raw else { return unavailable }
        // `raw` désigne un `IONVMeSMARTInterface **`. La table de fonctions
        // suit l'en-tête IUnknown (4 pointeurs) et deux UInt16 : version et
        // révision à l'octet 32, `SMARTReadData` à l'octet 40, `Release` à 24.
        let table = raw.load(as: UnsafeRawPointer.self)
        typealias ReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        defer { _ = table.load(fromByteOffset: 24, as: Release.self)(raw) }
        let readData = table.load(fromByteOffset: 40, as: ReadData.self)

        var page = [UInt8](repeating: 0, count: 512)
        let result = page.withUnsafeMutableBytes { readData(raw, $0.baseAddress) }
        if Self.taken.contains(result) { return .busy }
        guard result == kIOReturnSuccess, let health = DiskHealth.parse(page) else { return unavailable }
        return .health(health)
    }
}

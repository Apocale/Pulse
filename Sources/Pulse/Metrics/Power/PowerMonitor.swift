import Foundation
import IOKit
import IOKit.ps

/// Les lectures système de la carte Énergie. Aucune ne demande de droit
/// particulier ni d'autorisation : l'IORegistry et `IOPowerSources` sont
/// lisibles par tout processus de l'utilisateur.
///
/// Le Bluetooth n'est JAMAIS interrogé directement. `IOBluetooth` et
/// `CoreBluetooth` déclenchent la demande d'autorisation Bluetooth de macOS ;
/// les niveaux des AirPods et des accessoires viennent de `powerd`, qui les
/// publie pour le widget Batteries (`IOPSCopyPowerSourcesByType`), et ceux des
/// souris, claviers et trackpads Apple de l'IORegistry.
enum PowerMonitor {
    /// Une lecture complète de la batterie et de l'alimentation. `smc` : la
    /// connexion de l'appelant, qui en est le seul propriétaire
    /// (`SMCReader` n'est pas thread-safe).
    static func read(smc: SMCReader? = nil) -> PowerSample {
        var sample = PowerReader.sample(raw())
        sample.liveSystemWatts = liveSystemWatts(smc)
        return sample
    }

    /// La puissance de la machine entière au SMC (`PSTR`), lecteur du
    /// chantier 04. Nil sans SMC ou hors des bornes d'un portable.
    static func liveSystemWatts(_ smc: SMCReader?) -> Double? {
        guard let watts = smc?.value("PSTR"), watts > 0, watts < 500 else { return nil }
        return watts
    }

    static func raw() -> PowerReader.Raw {
        var raw = PowerReader.Raw()
        raw.registry = smartBattery() ?? [:]
        raw.source = internalBatterySource()
        raw.adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        raw.preferences = activePreferences()
        raw.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        return raw
    }

    /// Les propriétés de l'`AppleSmartBattery`, en entier : un seul aller-retour
    /// avec le noyau (0,2 ms mesuré, voir le journal du chantier).
    static func smartBattery() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    static func internalBatterySource() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return d }
        }
        return nil
    }

    // MARK: - Fonctions privées d'IOKit

    // Exportées par IOKit mais absentes des en-têtes publics : résolues à
    // l'exécution. Si macOS les retire, la lecture rend nil et la carte le dit
    // (« source indisponible ») au lieu de planter.

    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyPreferences = @convention(c) () -> Unmanaged<CFDictionary>?

    /// La poignée de `dlopen`, jamais modifiée ni libérée.
    nonisolated(unsafe) private static let handle = dlopen(nil, RTLD_NOW)

    private static let copyByType: CopyByType? = {
        guard let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return nil }
        return unsafeBitCast(symbol, to: CopyByType.self)
    }()

    private static let copyActivePreferences: CopyPreferences? = {
        guard let symbol = dlsym(handle, "IOPMCopyActivePMPreferences") else { return nil }
        return unsafeBitCast(symbol, to: CopyPreferences.self)
    }()

    /// `kIOPSSourceForAccessories` dans IOPowerSourcesPrivate.h.
    private static let accessoriesType: Int32 = 4

    /// Les profils « AC Power » et « Battery Power » de pmset.
    static func activePreferences() -> [String: Any]? {
        copyActivePreferences?()?.takeRetainedValue() as? [String: Any]
    }

    /// Nil quand la fonction n'existe plus : à distinguer d'une liste vide.
    static var accessoriesAvailable: Bool { copyByType != nil }

    /// Les descriptions des accessoires que connaît `powerd`.
    static func accessorySources() -> [[String: Any]] {
        guard let copy = copyByType, let blob = copy(accessoriesType)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// Les appareils HID qui publient leur charge : Magic Mouse, Magic
    /// Keyboard, Magic Trackpad. Le clavier et le trackpad intégrés n'en ont
    /// pas.
    static func hidBatteries() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = property("BatteryPercent") else { continue }
            var d: [String: Any] = ["BatteryPercent": percent]
            for key in ["Product", "DeviceAddress", "SerialNumber"] {
                if let value = property(key) { d[key] = value }
            }
            result.append(d)
        }
        return result
    }

    static func accessories() -> [PowerAccessory] {
        PowerReader.accessories(sources: accessorySources(), hid: hidBatteries())
    }

    // MARK: - Santé selon macOS

    /// La « capacité maximale » des Réglages Système, par `system_profiler` :
    /// powerd la lisse dans le temps et ne la donne directement qu'aux
    /// binaires d'Apple (`IOPSCopyPowerSourcesByTypePrecise` rend
    /// `kIOReturnNotPrivileged`). 0,09 s de processeur par appel, d'où une
    /// lecture toutes les 6 h au plus. Bloquant : jamais sur le main thread.
    static func healthReport(timeout: TimeInterval = 15) -> BatteryHealthReport? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // « mini » : sans numéros de série ; la santé y est quand même.
        process.arguments = ["-json", "-detailLevel", "mini", "-timeout", "10", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // La lecture se fait à côté, pour pouvoir abandonner un
        // `system_profiler` qui ne répondrait plus ; la boîte porte le
        // résultat d'un fil à l'autre, le sémaphore ordonne les deux.
        final class Output: @unchecked Sendable { var data = Data() }
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return PowerReader.healthReport(json: output.data)
    }
}

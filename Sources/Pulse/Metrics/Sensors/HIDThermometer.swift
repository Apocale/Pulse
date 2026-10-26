import Foundation
import IOKit

/// Les températures publiées par le système d'événements HID : la voie
/// qu'empruntent Stats et iStat sur Apple Silicon, sans root.
///
/// Les fonctions `IOHIDEventSystemClient…` sont exportées par IOKit mais
/// absentes de ses en-têtes publics : on les résout par `dlsym`. Si l'une
/// manque — un macOS futur —, le lecteur ne se crée pas et Pulse s'en passe,
/// sans planter.
///
/// Sur ce M2 Max (relevé du 11/10), 64 capteurs : 46 « PMU tdie/tdev/TP »
/// (la puce vue par ses deux contrôleurs d'alimentation, chacun publié deux
/// fois), « NAND CH0 temp » (le SSD) et six « gas gauge battery ». Aucun nom
/// de cœur : sur M2, le détail par cœur ne se lit qu'au SMC. Ici, HID sert de
/// SECONDE source, pour recouper le SMC.
final class HIDThermometer {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`, et le champ de sa valeur (type << 16).
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let client: AnyObject
    /// Nom de produit de chaque service, lu une fois.
    private let services: [(name: String, service: AnyObject)]

    init?() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(iokit, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(iokit, "IOHIDEventGetFloatValue") else { return nil }
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)

        guard let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        self.client = client
        // Page 0xff00 (Apple), usage 5 : les capteurs de température.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, matching)
        let list = (unsafeBitCast(copyServices, to: CopyServicesFn.self)(client)?
            .takeRetainedValue() as? [AnyObject]) ?? []
        let property = unsafeBitCast(copyProperty, to: CopyPropertyFn.self)
        services = list.compactMap { service in
            guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String
            else { return nil }
            return (name, service)
        }
        guard !services.isEmpty else { return nil }
    }

    /// Chaque capteur et sa valeur en °C. Les valeurs hors de −40…150 °C sont
    /// écartées : un capteur éteint rend parfois 0 ou une valeur absurde.
    func read() -> [(name: String, celsius: Double)] {
        services.compactMap { entry in
            guard let event = copyEvent(entry.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue()
            else { return nil }
            let value = getFloat(event, Self.temperatureField)
            guard value.isFinite, value > -40, value < 150, value != 0 else { return nil }
            return (entry.name, value)
        }
    }
}

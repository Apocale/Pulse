import Foundation
import IOKit

/// Un canal IOReport, lu sur l'écart entre deux échantillons.
struct IOReportChannel {
    var group: String
    var subgroup: String
    var name: String
    var unit: String
    /// Format « simple » : un compteur (énergie consommée dans l'intervalle).
    var value: Int64
    /// Format « état » : le temps passé dans chaque état (résidence).
    var states: [(name: String, ticks: Int64)]
}

/// IOReport, la bibliothèque de compteurs qu'utilise `powermetrics` — mais
/// lue SANS root, comme le font macmon et asitop : l'abonnement aux groupes
/// « Energy Model », « CPU Stats » et « GPU Stats » est ouvert à tout
/// processus de l'utilisateur. Vérifié sur la machine le 11/10.
///
/// La bibliothèque est privée (`/usr/lib/libIOReport.dylib`) : symboles
/// résolus par `dlsym`, et un lecteur qui ne se crée pas s'il en manque un.
///
/// L'échantillonneur garde le relevé précédent : chaque appel rend l'écart
/// depuis le dernier, sans jamais dormir. La puissance est donc la moyenne
/// sur l'intervalle entre deux lectures — 1,5 s panneau ouvert, 30 s fermé.
final class IOReportSampler {
    private typealias CopyGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CopyAllFn = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias MergeFn = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias SubscribeFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                    UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                                                    UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias SamplesFn = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias DeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias CountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private let createSamples: SamplesFn
    private let createDelta: DeltaFn
    private let getGroup: StringFn
    private let getSubgroup: StringFn
    private let getName: StringFn
    private let getUnit: StringFn
    private let getInteger: IntegerFn
    private let getStateCount: CountFn
    private let getStateName: StateNameFn
    private let getResidency: IntegerFn

    /// Gardé tel quel, jamais libéré : un abonnement par lecteur, et le
    /// lecteur vit autant que l'app. Pas de retain/release sur un objet dont
    /// la nature n'est pas documentée.
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: (sample: CFDictionary, time: UInt64)?

    /// `groups` : (groupe, sous-groupe ou nil pour tout le groupe).
    init?(groups: [(String, String?)]) {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyGroup = symbol("IOReportCopyChannelsInGroup", CopyGroupFn.self),
              let merge = symbol("IOReportMergeChannels", MergeFn.self),
              let subscribe = symbol("IOReportCreateSubscription", SubscribeFn.self),
              let createSamples = symbol("IOReportCreateSamples", SamplesFn.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", DeltaFn.self),
              let getGroup = symbol("IOReportChannelGetGroup", StringFn.self),
              let getSubgroup = symbol("IOReportChannelGetSubGroup", StringFn.self),
              let getName = symbol("IOReportChannelGetChannelName", StringFn.self),
              let getUnit = symbol("IOReportChannelGetUnitLabel", StringFn.self),
              let getInteger = symbol("IOReportSimpleGetIntegerValue", IntegerFn.self),
              let getStateCount = symbol("IOReportStateGetCount", CountFn.self),
              let getStateName = symbol("IOReportStateGetNameForIndex", StateNameFn.self),
              let getResidency = symbol("IOReportStateGetResidency", IntegerFn.self)
        else { return nil }
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getGroup = getGroup
        self.getSubgroup = getSubgroup
        self.getName = getName
        self.getUnit = getUnit
        self.getInteger = getInteger
        self.getStateCount = getStateCount
        self.getStateName = getStateName
        self.getResidency = getResidency

        // Les canaux voulus. Chaque `IOReportCopyChannelsInGroup` parcourt
        // TOUS les pilotes : 130 ms de CPU par groupe, 390 ms pour les trois
        // (mesuré le 11/10). Un seul parcours de tous les canaux (10 092 ici,
        // 145 ms), filtré ensuite, coûte une fois. Repli par groupe si la
        // copie complète manque ou n'a pas la forme attendue.
        func wanted(_ item: CFDictionary) -> Bool {
            let group = (getGroup(item)?.takeUnretainedValue() as String?) ?? ""
            let subgroup = (getSubgroup(item)?.takeUnretainedValue() as String?) ?? ""
            return groups.contains { $0.0 == group && ($0.1 == nil || $0.1 == subgroup) }
        }
        var selected: CFMutableDictionary?
        if let copyAll = symbol("IOReportCopyAllChannels", CopyAllFn.self),
           let all = copyAll(0, 0)?.takeRetainedValue() as NSDictionary?,
           let items = all["IOReportChannels"] as? [CFDictionary] {
            let kept = items.filter(wanted)
            if !kept.isEmpty {
                let dictionary = NSMutableDictionary(dictionary: all)
                dictionary["IOReportChannels"] = kept
                selected = dictionary as CFMutableDictionary
            }
        }
        if selected == nil {
            var merged: CFMutableDictionary?
            for (group, subgroup) in groups {
                guard let found = copyGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue()
                else { continue }
                if let merged { merge(merged, found, nil) } else { merged = found }
            }
            selected = merged.flatMap { CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, $0) }
        }
        guard let mutable = selected else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, mutable, &subscribed, 0, nil) else { return nil }
        subscribed?.release()
        self.subscription = subscription
        self.channels = mutable
    }

    /// L'écart depuis l'appel précédent et sa durée en secondes. Le premier
    /// appel ne fait que poser la référence et rend nil.
    ///
    /// Un écart de moins d'une demi-seconde n'est pas rendu : la référence
    /// est gardée et l'écart suivant part d'elle. Vu au rendu du 11/10 : à
    /// froid, la création du lecteur a pris 1,3 s, la lecture suivante est
    /// tombée 0,2 s après, et la carte affichait une puissance moyennée sur
    /// 0,2 s — juste, mais bruitée au point de ne rien dire.
    func sample() -> (channels: [IOReportChannel], seconds: Double)? {
        guard let now = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let time = DispatchTime.now().uptimeNanoseconds
        guard let previous else {
            previous = (now, time)
            return nil
        }
        let seconds = Double(time - previous.time) / 1e9
        guard seconds >= Self.minimumInterval else { return nil }
        self.previous = (now, time)
        guard let delta = createDelta(previous.sample, now, nil)?.takeRetainedValue(),
              let items = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        return (items.map(channel), seconds)
    }

    static let minimumInterval: Double = 0.5

    /// Oublie la référence : la prochaine lecture en repose une. Panneau
    /// fermé, IOReport n'est pas lu du tout (`SensorMonitor.sample`) ; à la
    /// réouverture, un écart sur toute la fermeture serait une moyenne de
    /// plusieurs minutes affichée comme la puissance du moment.
    func reset() { previous = nil }

    private func channel(_ item: CFDictionary) -> IOReportChannel {
        func text(_ fn: StringFn) -> String {
            (fn(item)?.takeUnretainedValue() as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let count = getStateCount(item)
        let states: [(String, Int64)] = count > 0 && count < 512
            ? (0..<count).map { i in
                ((getStateName(item, i)?.takeUnretainedValue() as String?) ?? "", getResidency(item, i))
            }
            : []
        return IOReportChannel(group: text(getGroup), subgroup: text(getSubgroup), name: text(getName),
                               unit: text(getUnit), value: states.isEmpty ? getInteger(item, 0) : 0,
                               states: states)
    }
}

/// Les calculs, séparés de la lecture pour être testés sur des valeurs fixes.
enum IOReportMath {
    /// Une énergie mesurée sur `seconds`, en watts. L'unité vient du canal :
    /// mJ pour le processeur, nJ pour la carte graphique sur ce M2 Max. Une
    /// unité inconnue rend nil plutôt qu'un chiffre faux d'un facteur 1000.
    static func watts(energy: Int64, unit: String, seconds: Double) -> Double? {
        guard seconds > 0 else { return nil }
        let joules: Double
        switch unit {
        case "J":  joules = Double(energy)
        case "mJ": joules = Double(energy) / 1e3
        case "uJ", "µJ": joules = Double(energy) / 1e6
        case "nJ": joules = Double(energy) / 1e9
        default: return nil
        }
        return joules / seconds
    }

    /// États où le bloc ne calcule pas.
    static let inactiveStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    /// Fréquence moyenne pendant le temps ACTIF, et part du temps actif.
    ///
    /// Les états actifs, dans l'ordre où le noyau les énumère, correspondent
    /// un à un aux lignes de la table DVFS du `pmgr` (`DVFSTables`) : six pour
    /// les cœurs efficacité du M2 Max, dix-neuf pour les cœurs performance.
    /// La carte graphique déclare quinze états (P1…P15) pour huit fréquences :
    /// les sept de trop n'ont jamais de temps. On l'accepte, mais seulement
    /// tant qu'ils restent vides ; sinon nil — on ne devine pas quel état
    /// vaut quelle fréquence.
    static func frequency(states: [(name: String, ticks: Int64)], table: [Double]) -> (mhz: Double, active: Double)? {
        let total = states.reduce(0.0) { $0 + Double(max(0, $1.ticks)) }
        let all = states.filter { !inactiveStates.contains($0.name) }
        guard total > 0, !table.isEmpty, all.count >= table.count,
              all.dropFirst(table.count).allSatisfy({ $0.ticks <= 0 }) else { return nil }
        let active = Array(all.prefix(table.count))
        let activeTicks = active.reduce(0.0) { $0 + Double(max(0, $1.ticks)) }
        guard activeTicks > 0 else { return (0, 0) }
        let mhz = zip(active, table).reduce(0.0) { $0 + Double(max(0, $1.0.ticks)) * $1.1 } / activeTicks
        return (mhz, activeTicks / total)
    }

    /// Plusieurs grappes de cœurs (les deux grappes performance du M2 Max) :
    /// moyenne pondérée par le temps actif de chacune.
    static func combine(_ clusters: [(mhz: Double, active: Double)]) -> (mhz: Double, active: Double)? {
        guard !clusters.isEmpty else { return nil }
        let weight = clusters.reduce(0) { $0 + $1.active }
        let active = weight / Double(clusters.count)
        guard weight > 0 else { return (0, 0) }
        return (clusters.reduce(0) { $0 + $1.mhz * $1.active } / weight, active)
    }
}

/// Les tables fréquence/tension du contrôleur d'alimentation (`pmgr` dans
/// l'IORegistry) : des paires (fréquence en Hz, tension en mV), 4 octets
/// petit-boutistes chacune. Les clés sont celles qu'emploie macmon ; les
/// longueurs relevées sur ce M2 Max collent aux états IOReport (6, 19 et 8
/// après le zéro de la carte graphique), ce que `IOReportMath.frequency`
/// revérifie à chaque lecture.
enum DVFSTables {
    struct Tables {
        var efficiency: [Double] = []
        var performance: [Double] = []
        var gpu: [Double] = []
    }

    static func read() -> Tables {
        var tables = Tables()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"),
                                           &iterator) == KERN_SUCCESS else { return tables }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
                  String(nulTerminated: name) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data else { return [] }
                return megahertz(data)
            }
            tables.efficiency = table("voltage-states1-sram")
            tables.performance = table("voltage-states5-sram")
            tables.gpu = table("voltage-states9").filter { $0 > 0 }
        }
        return tables
    }

    /// Paires (Hz, mV) → fréquences en MHz.
    static func megahertz(_ data: Data) -> [Double] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 7, by: 8).map { i in
            let hertz = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i + $1]) << (8 * UInt32($1)) }
            return Double(hertz) / 1e6
        }
    }
}

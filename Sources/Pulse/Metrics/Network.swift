import Foundation
import Darwin
import SystemConfiguration

/// Le réseau principal du Mac et ses compteurs.
///
/// Ce qui est compté : les octets qui passent par l'interface du réseau
/// principal — CE Mac seulement. Les autres appareils branchés sur la même box,
/// le même Starlink ou le même partage de connexion ne passent pas par ici.
/// Seul le routeur, ou l'espace client de l'opérateur, connaît leur total.
enum NetworkMonitor {
    struct Primary: Equatable {
        var interface: String
        var router: String?
        /// « IPv4.Router=…;IPv4.RouterHardwareAddress=… », publié par macOS
        /// pour chaque réseau. Lisible sans autorisation de localisation, là
        /// où le nom du Wi-Fi (SSID) revient « <redacted> ».
        var signature: String?
        var isWiFi: Bool
    }

    static func primary() -> Primary? {
        guard let store = SCDynamicStoreCreate(nil, "Pulse" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String else { return nil }
        var signature: String?
        if let service = global["PrimaryService"] as? String,
           let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any] {
            signature = ipv4["NetworkSignature"] as? String
        }
        let isWiFi = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/AirPort" as CFString) != nil
        return Primary(interface: interface, router: global["Router"] as? String,
                       signature: signature, isWiFi: isWiFi)
    }

    /// Compteurs d'octets reçus et envoyés de l'interface, sur 32 BITS.
    ///
    /// macOS ne livre les compteurs complets qu'à ses propres outils. Relevé
    /// le 07/10 : `netstat` et un script lancé par l'outil `swift` lisent
    /// 12,7 Go reçus ; le même code compilé — optimisé ou non, comme l'app —
    /// lit 4,15 Go, soit les 32 bits de poids faible, arrondis au kilo-octet.
    /// Le compteur repasse donc à zéro tous les 4,29 Go.
    ///
    /// D'où l'usage : seuls les ÉCARTS entre deux relevés ont un sens, calculés
    /// modulo 2³² (`&-` sur UInt32). Entre deux relevés espacés de 5 s au plus,
    /// il passe toujours moins de 4 Go — il faudrait 7 Gbit/s soutenus.
    static func counters(_ name: String) -> (rx: UInt32, tx: UInt32)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        let wanted = if_nametoindex(name)
        guard wanted != 0,
              let indexOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_index),
              let dataOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_data),
              let rxOffset = MemoryLayout<if_data64>.offset(of: \if_data64.ifi_ibytes),
              let txOffset = MemoryLayout<if_data64>.offset(of: \if_data64.ifi_obytes)
        else { return nil }
        return buffer.withUnsafeBytes { raw -> (UInt32, UInt32)? in
            var offset = 0
            while offset + 4 <= length {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let type = raw.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                if Int32(type) == RTM_IFINFO2,
                   offset + dataOffset + txOffset + 8 <= length,
                   UInt32(raw.loadUnaligned(fromByteOffset: offset + indexOffset, as: UInt16.self)) == wanted {
                    let rx = raw.loadUnaligned(fromByteOffset: offset + dataOffset + rxOffset, as: UInt64.self)
                    let tx = raw.loadUnaligned(fromByteOffset: offset + dataOffset + txOffset, as: UInt64.self)
                    return (UInt32(truncatingIfNeeded: rx), UInt32(truncatingIfNeeded: tx))
                }
                guard messageLength > 0 else { break }
                offset += messageLength
            }
            return nil
        }
    }

    /// Le réseau principal et son débit mesuré sur `interval`, sans rien
    /// compter ni écrire : pour `--probe` et `--snapshot`, qui tournent à côté
    /// de l'app pendant qu'elle tient reseau.json.
    static func measure(over interval: TimeInterval = 1) -> (primary: Primary, sample: NetworkSample)? {
        guard let primary = primary(), let first = counters(primary.interface) else { return nil }
        let kind: NetworkKind
        if primary.router?.hasPrefix("172.20.10.") == true { kind = .hotspot }
        else if starlinkDishReachable() { kind = .starlink }
        else { kind = primary.isWiFi ? .wifi : .wired }
        Thread.sleep(forTimeInterval: interval)
        guard let second = counters(primary.interface) else { return nil }
        // Modulo 2³² : macOS ne livre que 32 bits à une app tierce.
        return (primary, NetworkSample(connected: true, kind: kind, label: kind.label,
                                       rxRate: Double(second.rx &- first.rx) / interval,
                                       txRate: Double(second.tx &- first.tx) / interval))
    }

    /// L'antenne Starlink répond-elle ?
    ///
    /// Elle écoute toujours en 192.168.100.1, port 9200, derrière le routeur
    /// Starlink comme derrière une box tierce. Une connexion locale de
    /// 300 ms au plus, tentée seulement quand le réseau change : rien ne
    /// sort de la maison.
    ///
    /// Jamais quand 192.168.100.1 est sur le réseau même du Mac (une box qui
    /// sert 192.168.100.0/24) : ce n'est alors pas une antenne, que le Mac
    /// joint toujours à travers un routeur, et macOS 15 compte une connexion
    /// directe comme un accès au « réseau local », qu'il fait autoriser à
    /// l'écran (TN3179). Routée, elle ne demande rien — d'où le silence de
    /// la sonde chez Isma, derrière son routeur Starlink.
    static func starlinkDishReachable(timeout: Int32 = 300) -> Bool {
        guard !onLink(dishAddress) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9200).bigEndian
        inet_pton(AF_INET, "192.168.100.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, timeout) == 1 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
        return error == 0
    }

    /// 192.168.100.1, dans l'ordre des octets de l'hôte.
    static let dishAddress: UInt32 = 192 << 24 | 168 << 16 | 100 << 8 | 1

    /// `address` est-elle sur le sous-réseau d'une interface IPv4 active du
    /// Mac, donc jointe sans routeur ?
    static func onLink(_ address: UInt32) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
            guard let pointer, pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let own = ipv4(entry.pointee.ifa_addr) else { continue }
            // Le masque n'a pas toujours sa famille posée : lu tel quel.
            guard let raw = entry.pointee.ifa_netmask else { continue }
            let mask = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if sameSubnet(own, address, mask: mask) { return true }
        }
        return false
    }

    /// Un masque nul (aucun sous-réseau) ne range rien avec rien.
    static func sameSubnet(_ a: UInt32, _ b: UInt32, mask: UInt32) -> Bool {
        mask != 0 && a & mask == b & mask
    }
}

/// Ce qu'on sait reconnaître d'un réseau, et donc compter à part.
enum NetworkKind: String {
    /// Partage de connexion d'un iPhone : forfait mobile, chaque Go compte.
    case hotspot
    case starlink
    case wifi
    case wired

    var label: String {
        switch self {
        case .hotspot:  return "partage iPhone"
        case .starlink: return "Starlink"
        case .wifi:     return "Wi-Fi"
        case .wired:    return "Ethernet"
        }
    }
}

/// L'état réseau publié à chaque relevé.
struct NetworkSample: Equatable {
    var connected = false
    var kind: NetworkKind = .wifi
    var label = ""
    /// Octets par seconde sur le dernier intervalle.
    var rxRate: Double = 0
    var txRate: Double = 0
    /// Ce réseau, aujourd'hui.
    var todayRx: UInt64 = 0
    var todayTx: UInt64 = 0
}

/// Le cumul journalier, par réseau.
///
/// Persisté dans reseau.json, à part de history.json : relu de façon
/// tolérante, il ne peut pas coûter l'historique s'il s'abîme (règle dure
/// n°2). 90 jours, comme le temps par application.
///
/// Muté sur la file d'échantillonnage, lu depuis le fil principal par le
/// dépliant : d'où le verrou.
final class NetworkTracker {
    struct Usage { var label: String; var kind: NetworkKind; var rx: UInt64; var tx: UInt64 }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("reseau.json")
    }
    private static let retentionDays = 90

    private let lock = NSLock()
    /// jour ("2026-10-07") → clé de réseau → cumul
    private var days: [String: [String: Usage]] = [:]
    private var previous: (interface: String, rx: UInt32, tx: UInt32, time: Double, key: String)?
    /// Résultat de la sonde Starlink, par signature : elle ne se rejoue qu'au
    /// changement de réseau.
    private var dishBySignature: [String: Bool] = [:]
    private var lastSave: Double = 0
    /// reseau.json ; un autre fichier pour les tests.
    private let url: URL

    init(url: URL = NetworkTracker.url) {
        self.url = url
        load()
    }

    /// Un relevé : identifie le réseau, ajoute l'écart des compteurs au cumul
    /// du jour, et rend l'état à publier.
    ///
    /// Le trafic passé pendant que Pulse est fermé n'est pas compté : avec des
    /// compteurs 32 bits, on ne sait pas combien de tours ils ont faits entre
    /// deux lancements. Pulse se lance à l'ouverture de session, le trou se
    /// limite donc aux relances.
    func sample(now: Date = Date()) -> NetworkSample {
        guard let primary = NetworkMonitor.primary(),
              let counters = NetworkMonitor.counters(primary.interface) else {
            previous = nil
            return NetworkSample()
        }
        let (key, kind) = identify(primary)
        let t = now.timeIntervalSince1970
        var drx: UInt64 = 0, dtx: UInt64 = 0, dt: Double = 0

        // Modulo 2³², débit invraisemblable écarté : voir CompteursReseau,
        // testé sur un rebouclage.
        if let previous, previous.interface == primary.interface,
           let delta = CompteursReseau.ecart(avant: (previous.rx, previous.tx), apres: counters,
                                             secondes: t - previous.time) {
            drx = delta.rx; dtx = delta.tx; dt = t - previous.time
        }
        // Interface changée ou compteur remis à zéro : on repart de là, sans
        // inventer d'écart.
        previous = (primary.interface, counters.rx, counters.tx, t, key)
        add(rx: drx, tx: dtx, key: key, kind: kind, day: HistoryStore.dayKey(now))
        if t - lastSave > 60 { save(); lastSave = t }

        lock.lock(); defer { lock.unlock() }
        let today = days[HistoryStore.dayKey(now)]?[key]
        return NetworkSample(connected: true, kind: kind, label: kind.label,
                             rxRate: dt > 0 ? Double(drx) / dt : 0,
                             txRate: dt > 0 ? Double(dtx) / dt : 0,
                             todayRx: today?.rx ?? 0, todayTx: today?.tx ?? 0)
    }

    /// Les `count` derniers jours, du plus ancien au plus récent, UN cumul par
    /// sorte de réseau. Un jour sans trafic rend une liste vide plutôt que
    /// d'être absent.
    ///
    /// Le fichier garde un cumul par réseau, mais tous les Wi-Fi ordinaires
    /// portent le même nom et la même teinte : rien ne les distingue à
    /// l'écran. Les rendre séparés donnait plusieurs entrées « Wi-Fi » le même
    /// jour — quatre le 08/10, derrière quatre routeurs différents — et le
    /// dépliant, qui les identifiait par leur nom, répétait quatre fois la
    /// plus grosse : la colonne débordait de 150 pt sur les lignes du dessus.
    func history(days count: Int, from today: Date = Date()) -> [(day: Date, usage: [Usage])] {
        lock.lock(); defer { lock.unlock() }
        let calendar = Calendar.current
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            var byKind: [NetworkKind: Usage] = [:]
            for usage in (days[HistoryStore.dayKey(date)] ?? [:]).values {
                var total = byKind[usage.kind] ?? Usage(label: usage.kind.label, kind: usage.kind, rx: 0, tx: 0)
                total.rx += usage.rx
                total.tx += usage.tx
                byKind[usage.kind] = total
            }
            let usage = byKind.values.sorted { ($0.rx + $0.tx) > ($1.rx + $1.tx) }
            return (calendar.startOfDay(for: date), usage)
        }
    }

    func flush() { save() }

    /// Banc (`--banc`) : reseau.json est réécrit au relevé suivant, comme
    /// chaque minute. Sur la file d'échantillonnage, comme `sample`.
    func rendSauvegardeDue() { lastSave = 0 }


    // MARK: - Identification

    private func identify(_ primary: NetworkMonitor.Primary) -> (key: String, kind: NetworkKind) {
        // Le partage de connexion iOS sert toujours 172.20.10.0/28, passerelle
        // en .1 — l'adresse matérielle, elle, change d'un iPhone à l'autre.
        if primary.router?.hasPrefix("172.20.10.") == true { return ("partage-iphone", .hotspot) }
        if let signature = primary.signature {
            let dish = dishBySignature[signature] ?? {
                let reachable = NetworkMonitor.starlinkDishReachable()
                dishBySignature[signature] = reachable
                return reachable
            }()
            if dish { return ("starlink", .starlink) }
            return (signature, primary.isWiFi ? .wifi : .wired)
        }
        return (primary.interface, primary.isWiFi ? .wifi : .wired)
    }

    // MARK: - Cumul et persistance

    private func add(rx: UInt64, tx: UInt64, key: String, kind: NetworkKind, day: String) {
        guard rx > 0 || tx > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var usage = days[day, default: [:]][key] ?? Usage(label: kind.label, kind: kind, rx: 0, tx: 0)
        usage.rx += rx
        usage.tx += tx
        days[day, default: [:]][key] = usage
    }


    private func save() {
        guard Persistence.enabled else { return }
        lock.lock()
        let horizon = HistoryStore.dayKey(Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        days = days.filter { $0.key >= horizon }
        var out: [String: Any] = ["version": 1]
        out["days"] = days.mapValues { networks in
            networks.mapValues { ["label": $0.label, "kind": $0.kind.rawValue, "rx": $0.rx, "tx": $0.tx] as [String: Any] }
        }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Lecture tolérante : un champ manquant ou d'un autre type est sauté, pas
    /// fatal. Le même principe que les décodeurs manuels de history.json.
    ///
    /// Jour par jour, réseau par réseau (17-audit-code) : la lecture d'un
    /// bloc — `as? [String: [String: [String: Any]]]` — rendait TOUT vide à
    /// la première valeur d'une autre forme, et le premier relevé, deux
    /// secondes après le lancement, réécrivait le fichier : 90 jours de
    /// forfait effacés. Un fichier qui n'est pas du JSON, ou dont `days`
    /// n'a pas la forme attendue, est mis de côté (reseau.illisible.json)
    /// plutôt qu'écrasé.
    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            setAside()
            return
        }
        // Un compteur négatif (fichier édité à la main) se lirait 1,8e19 par
        // `uint64Value`, et le premier ajout déborderait : écarté.
        func number(_ any: Any?) -> UInt64 {
            guard let n = any as? NSNumber, n.doubleValue >= 0, n.doubleValue < 1e15 else { return 0 }
            return n.uint64Value
        }
        guard let stored = root["days"] else { return }
        guard let byDay = stored as? [String: Any] else {
            setAside()
            return
        }
        for (day, networks) in byDay {
            guard let networks = networks as? [String: Any] else { continue }
            for (key, entry) in networks {
                guard let value = entry as? [String: Any] else { continue }
                let kind = NetworkKind(rawValue: value["kind"] as? String ?? "") ?? .wifi
                days[day, default: [:]][key] = Usage(label: value["label"] as? String ?? kind.label,
                                                     kind: kind, rx: number(value["rx"]), tx: number(value["tx"]))
            }
        }
    }

    /// Comme history.json : illisible, le fichier est mis de côté plutôt
    /// qu'écrasé à la prochaine sauvegarde. Jamais sous `--probe`,
    /// `--snapshot` ni `--banc` (persistance coupée).
    private func setAside() {
        guard Persistence.enabled else { return }
        Persistence.setAside(url)
    }
}

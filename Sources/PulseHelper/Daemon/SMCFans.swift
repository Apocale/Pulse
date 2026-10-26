import Foundation
import IOKit
import PulseFanKit

/// Les ventilateurs au SMC, en lecture ET en écriture : le SEUL endroit de
/// Pulse où la commande d'écriture (6) existe. L'app, elle, n'a que le
/// lecteur du chantier 04 (`SMCCommand` sans écriture).
///
/// N'écrit que quatre familles de clés — `F<n>Md` (mode) et `F<n>Tg`
/// (consigne) —, jamais une clé venue d'un message : les noms sont formés
/// ici à partir d'un indice de ventilateur que `FanController` a vérifié
/// contre `FNum`. Écrire exige root ; ouvert sans, le SMC refuse
/// (`kIOReturnNotPrivileged`).
final class SMCFans: FanHardware {
    private var connection: io_connect_t = 0
    private var infos: [String: (size: UInt32, type: String)] = [:]

    private enum Command: UInt8 {
        case read = 5
        case write = 6
        case info = 9
    }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    // MARK: Message SMCKeyData_t (80 octets, offsets du chantier 04)

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    private func call(_ key: String, _ command: Command, size: UInt32 = 0, bytes: [UInt8] = []) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80)
        Self.put(Self.fourCC(key), into: &input, at: 0)
        Self.put(size, into: &input, at: 28)
        input[42] = command.rawValue
        for (i, byte) in bytes.prefix(32).enumerated() { input[48 + i] = byte }
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let status = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outputSize)
        guard status == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }

    private func info(_ key: String) -> (size: UInt32, type: String)? {
        if let known = infos[key] { return known }
        guard let out = call(key, .info) else { return nil }
        let code = Self.uint32(out, at: 32)
        let type = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) },
                          encoding: .ascii) ?? "????"
        let found = (size: Self.uint32(out, at: 28), type: type)
        infos[key] = found
        return found
    }

    private func read(_ key: String) -> Double? {
        guard let info = info(key), info.size > 0, info.size <= 32,
              let out = call(key, .read, size: info.size) else { return nil }
        return FanBytes.decode(type: info.type, bytes: Array(out[48..<48 + Int(info.size)]))
    }

    private func write(_ key: String, _ value: Double) -> Bool {
        guard let info = info(key),
              let bytes = FanBytes.encode(value, type: info.type, size: Int(info.size)) else { return false }
        return call(key, .write, size: info.size, bytes: bytes) != nil
    }

    // MARK: FanHardware

    func readFans() -> [FanReading]? {
        guard let count = read("FNum"), count >= 1, count <= Double(FanProtocol.maxFans) else { return nil }
        var fans: [FanReading] = []
        for i in 0..<Int(count) {
            guard let actual = read("F\(i)Ac"), let lo = read("F\(i)Mn"), let hi = read("F\(i)Mx") else { return nil }
            fans.append(FanReading(index: i, actual: max(0, actual), min: lo, max: hi,
                                   target: read("F\(i)Tg"), manual: (read("F\(i)Md") ?? 0) == 1))
        }
        return fans
    }

    func setManual(_ manual: Bool, fan: Int) -> Bool {
        guard (0..<FanProtocol.maxFans).contains(fan) else { return false }
        return write("F\(fan)Md", manual ? 1 : 0)
    }

    func setTarget(_ rpm: Double, fan: Int) -> Bool {
        guard (0..<FanProtocol.maxFans).contains(fan) else { return false }
        return write("F\(fan)Tg", rpm)
    }
}

import Foundation
import IOKit

// Le SMC (System Management Controller), en LECTURE SEULE.
//
// Le pilote AppleSMC répond à un message de 80 octets, `SMCKeyData_t` dans
// les en-têtes d'Apple, envoyé par `IOConnectCallStructMethod` (sélecteur 2).
// Le neuvième octet de commande dit quoi faire : lire les infos d'une clé (9),
// lire sa valeur (5), donner la clé de rang n (8) — ou ÉCRIRE (6), ce qui
// pilote les ventilateurs et exige root. Pulse ne connaît que les trois
// premières : `SMCCommand` n'a pas de cas pour l'écriture, elle est donc
// impossible à exprimer, pas seulement absente (`SensorDecodingTests` le
// vérifie). Le contrôle des ventilateurs est le chantier 14, sur accord.
//
// Ouvrir la connexion et lire ne demande aucun privilège : vérifié sur la
// machine (M2 Max, macOS 26), depuis le binaire compilé et signé ad hoc.

/// Les seules commandes que Pulse envoie au SMC. Aucune n'écrit.
enum SMCCommand: UInt8, CaseIterable {
    case readBytes = 5
    case keyFromIndex = 8
    case keyInfo = 9
}

/// Le message `SMCKeyData_t`, octet par octet. Offsets de la structure C
/// (alignements compris), vérifiés sur la machine : la lecture de `FNum`
/// rend bien 2 ventilateurs, celle de `#KEY` 2 410 clés.
enum SMCMessage {
    static let size = 80
    static let keyOffset = 0          // UInt32, ordre de l'hôte
    static let dataSizeOffset = 28    // keyInfo.dataSize
    static let dataTypeOffset = 32    // keyInfo.dataType (code à 4 lettres)
    static let resultOffset = 40      // 0 = succès
    static let commandOffset = 42     // data8 : la commande
    static let indexOffset = 44       // data32 : rang pour keyFromIndex
    static let bytesOffset = 48       // 32 octets de valeur

    static func request(key: UInt32, command: SMCCommand, dataSize: UInt32 = 0, index: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        put(key, into: &bytes, at: keyOffset)
        put(dataSize, into: &bytes, at: dataSizeOffset)
        put(index, into: &bytes, at: indexOffset)
        bytes[commandOffset] = command.rawValue
        return bytes
    }

    /// Ordre de l'hôte, c'est-à-dire petit-boutiste : Apple Silicon et Intel
    /// le sont tous deux.
    static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}

/// Codes à quatre lettres et décodage des valeurs.
enum SMCCode {
    /// « F0Ac » → 0x46304163 : les quatre lettres empaquetées, la première en
    /// poids fort.
    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// La valeur d'une clé selon son type. Sur Apple Silicon les mesures sont
    /// des `flt ` : un Float32 en PETIT-boutiste. Les entiers restent en
    /// GRAND-boutiste, comme sur Intel, où températures et ventilateurs
    /// étaient en virgule fixe (`sp78`, `fpe2`). Un type inconnu rend nil :
    /// mieux vaut un capteur absent qu'un chiffre inventé.
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be(_ n: Int) -> UInt64? {
            guard bytes.count >= n else { return nil }
            return bytes.prefix(n).reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        case "ui8 ", "flag": return be(1).map { Double($0) }
        case "ui16":         return be(2).map { Double($0) }
        case "ui32":         return be(4).map { Double($0) }
        case "si8 ":         return be(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "si16":         return be(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "fpe2":         return be(2).map { Double($0) / 4 }
        case "sp78":         return be(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        default:             return nil
        }
    }
}

/// Une connexion au SMC, gardée ouverte. Pas thread-safe : un seul
/// propriétaire, la file des capteurs.
final class SMCReader {
    private var connection: io_connect_t = 0
    /// Type et taille de chaque clé, lus une fois : la lecture d'une valeur
    /// coûte alors un seul aller-retour au pilote au lieu de deux.
    private var infos: [UInt32: (size: UInt32, type: String)] = [:]
    private var absent: Set<UInt32> = []

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: SMCMessage.size)
        var outputSize = SMCMessage.size
        let status = IOConnectCallStructMethod(connection, 2, &input, SMCMessage.size, &output, &outputSize)
        guard status == KERN_SUCCESS, output[SMCMessage.resultOffset] == 0 else { return nil }
        return output
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: String)? {
        if let known = infos[key] { return known }
        if absent.contains(key) { return nil }
        guard let out = call(SMCMessage.request(key: key, command: .keyInfo)) else {
            absent.insert(key)
            return nil
        }
        let found = (size: SMCMessage.uint32(out, at: SMCMessage.dataSizeOffset),
                     type: SMCCode.string(SMCMessage.uint32(out, at: SMCMessage.dataTypeOffset)))
        infos[key] = found
        return found
    }

    /// Les octets bruts d'une clé et son type.
    func raw(_ name: String) -> (type: String, bytes: [UInt8])? {
        let key = SMCCode.fourCC(name)
        guard let info = info(key), info.size > 0, info.size <= 32,
              let out = call(SMCMessage.request(key: key, command: .readBytes, dataSize: info.size))
        else { return nil }
        let start = SMCMessage.bytesOffset
        return (info.type, Array(out[start..<start + Int(info.size)]))
    }

    /// La valeur décodée d'une clé, nil si elle n'existe pas sur ce Mac.
    func value(_ name: String) -> Double? {
        raw(name).flatMap { SMCCode.decode(type: $0.type, bytes: $0.bytes) }
    }

    /// Toutes les clés du SMC (2 410 sur ce M2 Max). Coûteux — un appel par
    /// clé — : à ne faire qu'une fois, pour le relevé.
    func allKeys() -> [String] {
        guard let count = value("#KEY"), count > 0 else { return [] }
        return (0..<UInt32(count)).compactMap { index in
            call(SMCMessage.request(key: 0, command: .keyFromIndex, index: index))
                .map { SMCCode.string(SMCMessage.uint32($0, at: SMCMessage.keyOffset)) }
        }
    }
}

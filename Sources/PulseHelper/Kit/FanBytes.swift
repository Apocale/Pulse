import Foundation

/// Les octets d'une valeur du SMC, dans les deux sens. Pur, testé : le
/// helper n'écrit que ce que ces fonctions produisent.
///
/// Relevé sur ce M2 Max (11/10, lecture seule) : `F0Md` est un `ui8`
/// inscriptible (0 automatique, 1 imposé), `F0Tg` un `flt` inscriptible —
/// un Float32 PETIT-boutiste sur Apple Silicon —, `F0Mn` et `F0Mx` des `flt`
/// en lecture seule. Sur Intel, les vitesses étaient en `fpe2` (virgule
/// fixe 14.2, grand-boutiste).
public enum FanBytes {
    public static func float32LE(_ value: Double) -> [UInt8] {
        let bits = Float32(value).bitPattern
        return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
    }

    public static func fpe2(_ value: Double) -> [UInt8] {
        let raw = UInt16(clamping: Int((max(0, value) * 4).rounded()))
        return [UInt8(raw >> 8), UInt8(truncatingIfNeeded: raw)]
    }

    /// Une valeur selon son type, pour une ÉCRITURE : seuls les types des
    /// clés de ventilateur sont pris en charge, tout autre rend nil.
    public static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        guard value.isFinite else { return nil }
        switch (type, size) {
        case ("flt ", 4):           return float32LE(value)
        case ("fpe2", 2):           return fpe2(value)
        case ("ui8 ", 1), ("flag", 1):
            guard value >= 0, value <= 255 else { return nil }
            return [UInt8(value)]
        default:                    return nil
        }
    }

    /// Lecture des mêmes types (le helper relit ce qu'il borne).
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ", "flag":
            return bytes.first.map { Double($0) }
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }
}

import Foundation

/// Les unités de la carte Énergie, à la française : virgule décimale, espace
/// fine insécable avant l'unité et entre les milliers (« 8 694 mAh »).
enum PowerFmt {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        return f
    }()

    private static let lock = NSLock()

    static func number(_ value: Double, digits: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    /// « 77 W », « 8,4 W » : une décimale sous 10 W, où elle se lit encore.
    static func watts(_ value: Double) -> String {
        "\(number(value, digits: abs(value) < 10 ? 1 : 0))\u{00A0}W"
    }

    static func celsius(_ value: Double) -> String {
        "\(number(value, digits: 1))\u{00A0}°C"
    }

    static func volts(_ value: Double) -> String {
        "\(number(value, digits: 2))\u{00A0}V"
    }

    static func amps(_ value: Double) -> String {
        "\(number(value, digits: 2))\u{00A0}A"
    }

    static func mAh(_ value: Int) -> String {
        "\(number(Double(value), digits: 0))\u{00A0}mAh"
    }

    static func count(_ value: Int) -> String {
        number(Double(value), digits: 0)
    }

    /// Les parties d'un accessoire : « 100 % · boîtier 50 % », gauche et
    /// droite fondues quand elles disent la même chose.
    static func parts(_ accessory: PowerAccessory) -> String {
        var parts = accessory.parts
        if let l = parts.first(where: { $0.role == .left }), let r = parts.first(where: { $0.role == .right }),
           Fmt.percent(l.level) == Fmt.percent(r.level), l.charging == r.charging {
            parts.removeAll { $0.role == .right }
            if let i = parts.firstIndex(where: { $0.role == .left }) { parts[i].role = .single }
        }
        return parts.map { part in
            let value = Fmt.percent(part.level) + (part.charging ? " en charge" : "")
            return part.role.label.isEmpty ? value : "\(part.role.label) \(value)"
        }.joined(separator: " · ")
    }
}

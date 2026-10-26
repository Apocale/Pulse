import SwiftUI
import AppKit

/// La section HISTORIQUE de `--probe` : l'état de la base, ce que l'import a
/// repris, ce que coûte l'enregistrement, et les chiffres exacts que
/// montrent les graphiques (échelle, moyenne, pointe) pour chaque plage.
///
/// Lecture seule : `--probe` tourne à côté de l'app qui écrit la base.
enum HistoryProbe {
    static func lines(now: Date = Date(), url: URL = SeriesRecorder.defaultURL) -> [String] {
        var out: [String] = []
        let db = SeriesDatabase(url: url, readOnly: true)
        let nowT = Int64(now.timeIntervalSince1970)
        out.append("  fichier          \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")

        switch db.state {
        case .missing:
            out.append("  état             pas encore de base — elle naît au lancement de Pulse")
            return out
        case .unavailable(let reason):
            out.append("  état             illisible : \(reason)")
            return out
        case .newerSchema(let version):
            out.append("  état             schéma \(version), plus récent que ce Pulse : lu, jamais écrit")
        case .ready:
            out.append("  état             lisible · schéma \(db.meta("schema") ?? "?")"
                       + (db.meta("creee").flatMap { Int64($0) }.map { " · créée le \(stamp($0))" } ?? ""))
        }
        let size = db.fileBytes
        out.append("  taille           \(Fmt.bytes(UInt64(size.main)))"
                   + (size.wal > 0 ? " + journal \(Fmt.bytes(UInt64(size.wal)))" : "")
                   + " · plafond visé 50 Mo à 90 jours")
        out.append("  étages           bruts 10 s gardés 24 h · minutes 7 j · tranches de 10 min 90 j")

        if let report = LegacyImport.stored(in: db) {
            let state = report["etat"] as? String ?? "?"
            let date = (report["t"] as? Double).map { stamp(Int64($0)) } ?? "?"
            if state == "importé" {
                out.append("  import           history.json repris le \(date) : \(report["serie"] ?? 0) points de série, "
                           + "\(report["disque"] ?? 0) points de disque sur \(report["volumes"] ?? 0) volumes, "
                           + "\(report["ecrits"] ?? 0) valeurs écrites")
            } else {
                out.append("  import           \(state) (\(date))")
            }
        } else {
            out.append("  import           pas encore fait")
        }

        if let text = db.meta("cout"), let data = text.data(using: .utf8),
           let cost = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
           let cpu = cost["cpu"], let since = cost["depuis"], let updated = cost["maj"], updated > since {
            let share = cpu / (updated - since)
            out.append("  coût mesuré      \(String(format: "%.4f", share * 100).replacingOccurrences(of: ".", with: ",")) % d'un cœur "
                       + "(\(String(format: cpu < 0.01 ? "%.1f" : "%.0f", cpu * 1000).replacingOccurrences(of: ".", with: ",")) ms "
                       + "de CPU en \(Fmt.duration(updated - since)) de fonctionnement, "
                       + "relevé le \(stamp(Int64(updated)))) · budget 0,05 %")
        }

        let folder = url.deletingLastPathComponent()
        let aside = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("historique.illisible-") && $0.hasSuffix(".sqlite") }.sorted()
        out.append("  mis de côté      " + (aside.isEmpty ? "aucune base illisible" : aside.joined(separator: ", ")))

        let keys = db.keys
        guard !keys.isEmpty else {
            out.append("  aucune série enregistrée pour l'instant")
            return out
        }
        out.append("  série                         bruts  minutes  10 min  depuis        dernier point")
        let all = db.allStats()
        for key in orderedKeys(keys) {
            guard let stats = all[key] else { continue }
            let info = SeriesCatalog.info(key, label: stats.label, bound: db.bound(key), unit: db.unit(key))
            let name = name(key, db).column(28)
            func count(_ tier: SeriesDatabase.Tier) -> String {
                String(stats.rows[tier] ?? 0).leftPad(7)
            }
            let first = stats.first.map { stamp($0) } ?? "—"
            // Au-delà de deux jours, « 386 h 23 » ne se lit plus (comme VOLUMES).
            func ago(_ t: Int64) -> String {
                let age = Double(nowT - t)
                return age < 48 * 3600 ? Fmt.duration(age) : Fmt.days(age / 86_400)
            }
            let last = stats.last.map { "il y a \(ago($0)) · \(info.unit.format(stats.lastValue ?? 0))" } ?? "—"
            out.append("  \(name)\(count(.raw))\(count(.minute)) \(count(.tenmin))  \(first.column(13)) \(last)")
        }

        // Les chiffres des graphiques, plage par plage : le résumé au-dessus
        // du tracé (moyenne / pointe). L'échelle est le total réel entre
        // parenthèses, ou à défaut la pointe elle-même — « max … ».
        out.append("  graphiques       moyenne / pointe, par plage · échelle : (total réel), sinon la pointe")
        out.append(("    " + "".column(34)
                    + HistoryRange.allCases.map { $0.rawValue.column(24) }.joined())
                   .trimmingTrailingSpaces)
        // Une lecture par plage, toutes séries ensemble : cinq parcours.
        let ordered = orderedKeys(keys)
        let readings = HistoryRange.allCases.map { range in
            SeriesRecorder.reading(database: db, keys: ordered, range: range, now: now)
        }
        for (index, key) in ordered.enumerated() {
            var cells: [String] = []
            var scale = ""
            for full in readings {
                let line = full.lines[index]
                guard let stats = HistoryPlot.stats(line) else { cells.append("—"); continue }
                // La même lecture qu'un graphique de cette seule série.
                let reading = HistoryReading(range: full.range, from: full.from, to: full.to,
                                             bucket: full.bucket, lines: [line])
                let unit = line.info.unit
                if let bound = reading.bound { scale = " (\(unit.format(bound)))" }
                cells.append("\(unit.format(stats.average)) / \(unit.format(stats.peak))")
            }
            guard cells.contains(where: { $0 != "—" }) else { continue }
            out.append(("    " + (name(key, db) + scale).column(34)
                        + cells.map { $0.column(24) }.joined())
                       .trimmingTrailingSpaces)
        }
        return out
    }

    /// Un volume par son nom quand l'app l'a vu monté, sinon par le début de
    /// son UUID — les points repris de history.json n'ont pas de nom.
    private static func name(_ key: String, _ db: SeriesDatabase) -> String {
        guard key.hasPrefix("disque.") else { return key }
        if let label = db.label(key) { return "disque \(label)" }
        let uuid = key.dropFirst("disque.".count).prefix(8)
        return "disque \(uuid)…"
    }

    /// Les séries de base dans l'ordre du catalogue, puis les autres.
    private static func orderedKeys(_ keys: [String]) -> [String] {
        let order = SeriesCatalog.builtIn.map(\.key)
        return keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
    }

    private static func stamp(_ t: Int64) -> String { HistoryPlot.clock(t, "dd/MM HH:mm") }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    /// Une colonne de `width` signes au moins, JAMAIS tronquée :
    /// `padding(toLength:)` coupait « 4 671 tr/min » en « 4 671 tr/ » — un
    /// chiffre faux dans `--probe` vaut mieux absent que mal lu.
    func column(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }

    var trimmingTrailingSpaces: String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}

/// L'exemple du composant, pour `--snapshot x.png --historique` : les séries de
/// base dans une colonne de carte, chaque mode d'échelle représenté — barres
/// sur un total réel, courbe sur un maximum observé, deux séries.
@MainActor
enum HistoryGallery {
    static func view(now: Date = Date()) -> some View {
        let recorder = SeriesRecorder.shared
        func read(_ keys: [String], _ range: HistoryRange) -> HistoryReading {
            recorder.readingNow(keys: keys, range: range, now: now)
        }
        let cpu = read(["cpu.total"], .day)
        // Le survol figé sur la tranche la plus haute : la bulle se voit.
        let peak = cpu.lines.first?.buckets.max { $0.avg < $1.avg }?.t
        return VStack(spacing: 10) {
            Card {
                CardTitle(title: "Historique", symbol: "clock.arrow.circlepath")
                HistoryChart(keys: ["cpu.total"], title: "Processeur", preloaded: cpu, frozenHover: peak)
                HistoryChart(keys: ["memoire.utilisee"], title: "Mémoire utilisée",
                             preloaded: read(["memoire.utilisee"], .week))
                HistoryChart(keys: ["memoire.swap"], title: "Swap", preloaded: read(["memoire.swap"], .day))
                HistoryChart(keys: ["reseau.envoi", "reseau.reception"], title: "Débit",
                             preloaded: read(["reseau.envoi", "reseau.reception"], .hour))
                if let disk = firstVolumeKey(now: now) {
                    let reading = read([disk], .quarter)
                    HistoryChart(keys: [disk], title: "Libre · \(reading.lines.first?.info.label ?? "volume")",
                                 preloaded: reading)
                }
            }
        }
        .padding(12)
        .frame(width: PopoverView.columnWidth + 24)
        .background(PopoverBackground())
    }

    /// Le volume qui a le plus de points : le disque de rushes, en général.
    private static func firstVolumeKey(now: Date) -> String? {
        let db = SeriesDatabase(url: SeriesRecorder.defaultURL, readOnly: true)
        return db.keys.filter { $0.hasPrefix("disque.") }
            .max { [all = db.allStats()] in (all[$0]?.rows[.tenmin] ?? 0) < (all[$1]?.rows[.tenmin] ?? 0) }
    }
}

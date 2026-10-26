import Foundation

/// Le journal du panneau : une ligne à chaque ouverture ou fermeture demandée,
/// au raccourci ⌃⌥M ou au clic sur l'icône.
///
/// « Il ne s'ouvre pas tout le temps » ne se vérifie pas en ouvrant le panneau
/// en boucle sur l'écran de quelqu'un qui monte — c'est une règle de
/// l'utilisateur. Chaque appui RÉEL note donc l'état d'avant, ce qui a été
/// fait, l'ancrage utilisé (l'icône, ou la fenêtre de secours en haut à droite
/// quand l'icône est cachée) et si le panneau était bien visible 0,4 s après.
/// `--probe` en tire le bilan : une ouverture « INVISIBLE » est un échec.
///
/// Utilisé uniquement sur le fil principal, d'où l'absence de verrou.
enum HotKeyLog {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("raccourci.log")
    }

    /// Au-delà, on ne garde que la seconde moitié : quelques centaines
    /// d'appuis suffisent à un diagnostic.
    private static let maxBytes = 100_000

    static func record(source: String, before: (shown: Bool, onScreen: Bool),
                       action: String, anchor: String?, after: Bool?) {
        let fields = [
            String(Int(Date().timeIntervalSince1970)),
            source,
            action,
            "avant:" + (before.shown ? "ouvert" : "fermé") + "/" + (before.onScreen ? "visible" : "invisible"),
            "ancrage:" + (anchor ?? "-"),
            "après:" + (after.map { $0 ? "visible" : "INVISIBLE" } ?? "-"),
        ]
        let line = Data((fields.joined(separator: "\t") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            if end > maxBytes, let all = try? Data(contentsOf: url) {
                try? Data(all.suffix(maxBytes / 2)).write(to: url, options: .atomic)
                if let fresh = try? FileHandle(forWritingTo: url) {
                    _ = try? fresh.seekToEnd(); try? fresh.write(contentsOf: line); try? fresh.close()
                }
                return
            }
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? line.write(to: url, options: .atomic)
        }
    }

    struct Summary {
        var opens = 0
        var failures = 0
        var reopenedHidden = 0
        var lastFailure: Date?
    }

    /// Bilan sur `days` jours : ouvertures, échecs (panneau invisible 0,4 s
    /// après l'ouverture), et panneaux trouvés « ouverts mais invisibles » —
    /// le cas que l'ancienne bascule refermait au lieu de les montrer.
    static func summary(days: Double, now: Date = Date()) -> Summary {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Summary() }
        let horizon = now.timeIntervalSince1970 - days * 86_400
        var s = Summary()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 6, let t = Double(f[0]), t >= horizon, f[2] == "ouvert" else { continue }
            s.opens += 1
            if f[3] == "avant:ouvert/invisible" { s.reopenedHidden += 1 }
            if f[5] == "après:INVISIBLE" {
                s.failures += 1
                s.lastFailure = Date(timeIntervalSince1970: t)
            }
        }
        return s
    }
}

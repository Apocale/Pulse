import Foundation

/// Le journal des règles : une ligne JSON par début, fin, notification,
/// retenue… (`EntreeJournal.Genre`). Il dit pourquoi une notification est
/// partie, ou pourquoi elle n'est pas partie — « hors plage », « retenue :
/// Premiere au premier plan », « autorisation refusée ».
///
/// Fichier à part, relu de façon tolérante (une ligne illisible est sautée),
/// comme `verdicts.jsonl` : un journal abîmé ne coûte jamais les règles.
/// Trente jours. N'est écrit que par l'app (`Persistence`) ; `--probe` le lit.
enum JournalRegles {
    static let retention: TimeInterval = 30 * 86_400

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("regles.jsonl")
    }

    static func ecrire(_ entrees: [EntreeJournal], vers url: URL = url) {
        guard !entrees.isEmpty else { return }
        let texte = entrees.compactMap(ligne).joined()
        let bytes = Data(texte.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? bytes.write(to: url, options: .atomic)
        }
    }

    static func lire(depuis url: URL = url, apres horizon: Date = .distantPast) -> [EntreeJournal] {
        guard let texte = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return texte.split(separator: "\n").compactMap { ligne in
            guard let data = ligne.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = o["t"] as? Double, t >= horizon.timeIntervalSince1970,
                  let genre = (o["genre"] as? String).flatMap(EntreeJournal.Genre.init(rawValue:)),
                  let regle = o["regle"] as? String else { return nil }
            return EntreeJournal(date: Date(timeIntervalSince1970: t), genre: genre, regle: regle,
                                 nom: o["nom"] as? String ?? regle, sujet: o["sujet"] as? String ?? "",
                                 sujetNom: o["sujetNom"] as? String ?? "", texte: o["texte"] as? String ?? "")
        }
    }

    /// Réécrit le fichier seulement s'il y a quelque chose à retirer.
    static func elaguer(maintenant: Date = Date(), url: URL = url) {
        guard let texte = try? String(contentsOf: url, encoding: .utf8) else { return }
        let horizon = maintenant.timeIntervalSince1970 - retention
        let lignes = texte.split(separator: "\n")
        let gardees = lignes.filter { ligne in
            guard let data = ligne.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = o["t"] as? Double else { return false }
            return t >= horizon
        }
        guard gardees.count != lignes.count else { return }
        try? Data((gardees.joined(separator: "\n") + (gardees.isEmpty ? "" : "\n")).utf8)
            .write(to: url, options: .atomic)
    }

    private static func ligne(_ e: EntreeJournal) -> String? {
        var o: [String: Any] = ["t": e.date.timeIntervalSince1970, "genre": e.genre.rawValue,
                                "regle": e.regle, "nom": e.nom]
        if !e.sujet.isEmpty { o["sujet"] = e.sujet }
        if !e.sujetNom.isEmpty { o["sujetNom"] = e.sujetNom }
        if !e.texte.isEmpty { o["texte"] = e.texte }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s + "\n"
    }
}

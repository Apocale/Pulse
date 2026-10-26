import Foundation

/// Le journal des verdicts : une ligne à chaque changement de verdict publié.
///
/// Les seuils des règles 7, 9 et 10 sont posés, pas mesurés — `--probe` le dit
/// lui-même. Et le verdict a changé trois fois en vingt minutes le jour de sa
/// mise en service. Pour trancher entre « il suit la machine » et « il crie au
/// loup », il faut compter, pas se souvenir : combien de changements par jour,
/// quelle règle tient combien de temps. `--probe` en imprime le bilan.
///
/// Fichier à part, en lignes JSON, relu de façon tolérante — une ligne
/// illisible est sautée, pas fatale. Surtout pas un champ de history.json : un
/// champ ajouté là passe par la règle dure n°2, et un journal abîmé ne doit
/// jamais pouvoir coûter l'historique de l'utilisateur.
///
/// `record` tourne sur la file d'échantillonnage, `markStop` sur le fil
/// principal à la fermeture — `Sampler.flush` refuse d'attendre la file, pour
/// ne pas bloquer l'arrêt sur un volume réseau muet. Les deux se croisent donc,
/// d'où le verrou : sans lui, deux lignes pourraient s'entrelacer dans le
/// fichier.
final class VerdictJournal {
    struct Entry {
        var t: Double
        /// `nil` pour les marques de démarrage et d'arrêt.
        var rule: Int?
        var name: String
        var event: String?
    }

    /// Trente jours : de quoi calibrer sur plusieurs semaines de travail, et
    /// une taille qui reste négligeable — quelques dizaines de lignes par jour.
    static let retention: TimeInterval = 30 * 86_400

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("verdicts.jsonl")
    }

    private let lock = NSLock()
    private var lastRule: Int?
    private var started = false

    /// Appelé à chaque relevé ; n'écrit que sur un changement de règle.
    func record(_ verdict: Verdict, now: Date = Date()) {
        // Règle 0 : le verdict d'attente, avant le premier relevé stable.
        guard verdict.rule != 0, Persistence.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        // Marque de démarrage posée au premier verdict réel, pas à la
        // création : une seconde instance, qui se ferme d'elle-même aussitôt
        // lancée, laisserait sinon une fausse marque à chaque tentative.
        // L'élagage attend lui aussi : l'instance jumelle ne doit pas pouvoir
        // réécrire le fichier sous les pieds de celle qui tourne.
        if !started {
            started = true
            Self.prune(now: now)
            Self.append(["t": now.timeIntervalSince1970, "event": "start"])
        }
        guard verdict.rule != lastRule else { return }
        lastRule = verdict.rule
        // La preuve aussi : le chiffre qui a fait basculer (« +1,1 Go en une
        // heure », « plein dans ~13 jours »). Sans elle, le journal disait
        // quand une règle gagnait, jamais de combien — et un seuil ne se
        // calibre pas sans la valeur qui l'a franchi (chantier 12).
        Self.append(["t": now.timeIntervalSince1970,
                     "rule": verdict.rule,
                     "name": verdict.ruleName,
                     "level": verdict.level.rawValue,
                     "phrase": verdict.phrase,
                     "evidence": verdict.evidence])
    }

    /// Les VRAIS changements de verdict d'une suite d'entrées : une règle
    /// différente de la précédente, arrêts et redémarrages traversés.
    ///
    /// Chaque lancement de Pulse réécrit la règle du moment ; les compter
    /// comme des changements gonflait le bilan de `--probe`. Relevé le 11/10 :
    /// « 38,8 par jour » sur 7 jours, quand les 42 lignes de règle écrites
    /// depuis le délai de tenue (09/10, 21 h 58 UTC) ne comptaient que 13
    /// changements — les autres étaient des relances après fusion.
    static func changes(_ entries: [Entry]) -> (changes: Int, restarts: Int) {
        var changes = 0, restarts = 0
        var previous: Int?
        var afterStart = false
        for entry in entries {
            if entry.event == "start" { afterStart = true; continue }
            guard let rule = entry.rule else { continue }
            if let previous, previous != rule {
                changes += 1
            } else if previous != nil, afterStart {
                restarts += 1
            }
            previous = rule
            afterStart = false
        }
        return (changes, restarts)
    }

    /// Posée à la fermeture normale. Sans elle, la dernière règle d'une
    /// journée paraîtrait durer jusqu'au lancement du lendemain.
    func markStop(now: Date = Date()) {
        guard Persistence.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        Self.append(["t": now.timeIntervalSince1970, "event": "stop"])
    }

    // MARK: - Lecture

    static func read() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = object["t"] as? Double else { return nil }
            return Entry(t: t,
                         rule: object["rule"] as? Int,
                         name: object["name"] as? String ?? "",
                         event: object["event"] as? String)
        }
    }

    // MARK: - Écriture

    private static func append(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        let bytes = Data((line + "\n").utf8)
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

    /// Réécrit le fichier seulement s'il y a quelque chose à retirer.
    private static func prune(now: Date = Date()) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let horizon = now.timeIntervalSince1970 - retention
        let lines = text.split(separator: "\n")
        let kept = lines.filter { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = object["t"] as? Double else { return false }
            return t >= horizon
        }
        guard kept.count != lines.count else { return }
        try? Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8)
            .write(to: url, options: .atomic)
    }
}

import Foundation

/// La section MÉDIAS de `--probe` : tout chiffre de la carte Montage et de
/// la carte graphique se retrouve ici, mesuré par le même code.
enum MediaProbe {
    /// Les lignes de la section, sans en-tête. Deux relevés à 1 s d'écart :
    /// puissance et temps GPU sont des écarts de compteurs.
    static func lines() -> [String] {
        var out: [String] = []
        let monitor = MediaMonitor()
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = monitor.sample()
        let cost = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        Thread.sleep(forTimeInterval: 1.0)
        guard monitor.available, let media = monitor.sample() else {
            out.append("  IOReport indisponible — puissance et fréquence non lues")
            return out
        }
        let watts: (Double?) -> String = { $0.map { String(format: "%.2f W", $0).replacingOccurrences(of: ".", with: ",") } ?? "non publié" }

        out.append("  carte graphique")
        out.append("    occupation      \(media.gpuUtilization.map(Fmt.percent) ?? "non disponible")")
        if let frequency = media.gpuFrequency {
            out.append("    fréquence       \(Int(frequency.rounded())) MHz en moyenne quand il est allumé"
                       + (media.gpuMaxFrequency.map { " (max \(Int($0)) MHz)" } ?? ""))
        } else {
            out.append("    fréquence       GPU éteint sur l'intervalle")
        }
        out.append("    puissance       \(watts(media.gpuPower))")
        out.append("    mémoire tenue   \(media.gpuMemory.map { Fmt.memory($0) } ?? "non publiée") (prise sur la mémoire unifiée)")
        out.append("  moteurs médias")
        out.append("    encodeur vidéo  \(watts(media.encoderPower)) — seuil « au travail » posé à \(watts(MediaSample.encoderBusyWatts)), non calibré")
        out.append("    scaler          \(watts(media.scalerPower))")
        out.append("    moteur neuronal \(watts(media.neuralPower))")
        out.append("    décodeur, ProRes non mesurables sans root (aucun canal IOReport)")
        if media.gpuApps.isEmpty {
            out.append("  GPU par application : aucune sur l'intervalle")
        } else {
            out.append("  GPU par application, 1 % et plus (% du temps GPU, la somme peut dépasser 100 %)")
            for app in media.gpuApps.filter({ $0.share >= 0.01 }).prefix(6) {
                out.append("    \(Fmt.cpu(app.share * 100).padding(toLength: 7, withPad: " ", startingAt: 0))\(app.bundleId.hasPrefix("exec:") ? Fmt.processName(app.name) : Fmt.appName(app.name))")
            }
        }
        // Les sorties en cours, comme la carte : fichiers média ouverts en
        // écriture par TOUS les processus des apps de montage et d'export.
        let groups = ProcessMonitor().sample().filter {
            let kind = AppKind.of(bundleId: $0.bundleId)
            return (kind == .editing || kind == .encoding) && $0.bundlePath != nil
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let pids = MediaTracker.pids(of: groups)
        let t2 = DispatchTime.now().uptimeNanoseconds
        let writing = pids.flatMap { pid, group in
            OpenFiles.mediaWritten(by: pid).map { (Fmt.appName(group.name), $0) }
        }
        let scanCost = Double(t2 - t1) / 1e6
        let filesCost = Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e6
        if groups.isEmpty {
            out.append("  sorties en cours  aucune app de montage ni d'export lancée")
        } else if writing.isEmpty {
            out.append("  sorties en cours  aucun fichier média ouvert en écriture ("
                       + Set(groups.map { Fmt.appName($0.name) }).sorted().joined(separator: ", ") + ")")
        } else {
            for (app, path) in writing {
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
                out.append("  sortie en cours   \(app) écrit \((path as NSString).lastPathComponent), \(Fmt.bytes(size))")
            }
        }
        out.append(String(format: "  coût d'un relevé ouvert : %.1f ms (moteurs, GPU) + %.1f ms (fichiers de %d processus)",
                          cost, filesCost, pids.count).replacingOccurrences(of: ".", with: ","))
        out.append(String(format: "                    + %.1f ms toutes les 30 s pour retrouver ces processus", scanCost)
                   .replacingOccurrences(of: ".", with: ","))
        out += exportLines()
        out += cacheLines()
        return out
    }

    /// Lecture seule : `--probe` ne réécrit jamais exports.json, que l'app
    /// en cours tient à jour.
    static func exportLines(now: Date = Date()) -> [String] {
        var out = ["  exports terminés"]
        guard let journal = AMEJournal.url() else {
            out.append("    journal d'AME introuvable (~/Documents/Adobe/Adobe Media Encoder/<version>/)")
            return out
        }
        let history = ExportHistory(journal: nil)
        let started = Date()
        let parsed = AMEJournal.read(journal).map(AMEJournal.parse) ?? []
        let seconds = Date().timeIntervalSince(started)
        history.ingest(parsed, now: now)
        // Panneau fermé, le module ne fait que ceci à chaque relevé : un
        // `stat` du journal, pour savoir s'il faut le relire.
        let probes = 500
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<probes { _ = try? FileManager.default.attributesOfItem(atPath: journal.path) }
        let perTick = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(probes) / 1000
        out.append("    journal d'AME   \(journal.path)")
        out.append(String(format: "                    %d exports lus en %.0f ms, %d gardés sur 90 jours avec ceux vus par Pulse",
                          parsed.count, seconds * 1000, history.count))
        out.append("    coût fermé      aucun : ni stat, ni IOReport — la fin du journal se relit à l'ouverture")
        out.append(String(format: "    coût ouvert     %.0f µs par relevé (un stat du journal)", perTick)
            .replacingOccurrences(of: ".", with: ","))
        let today = history.today(now: now)
        let ok = today.filter { $0.outcome != .failure }
        out.append("    aujourd'hui     \(Self.countText(ok.count)), \(Fmt.duration(ok.totalDuration)) d'encodage"
                   + (today.count > ok.count ? " · \(today.count - ok.count) en échec" : ""))
        // La même fenêtre que le graphique de la carte : sept jours civils,
        // aujourd'hui compris.
        let week = history.exports(since: MediaDetail.startOfWeek(now: now))
        out.append("    7 jours civils  \(Self.countText(week.filter { $0.outcome != .failure }.count)), "
                   + "\(Fmt.duration(week.filter { $0.outcome != .failure }.totalDuration)) d'encodage")
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "fr_FR")
        stamp.dateFormat = "dd/MM HH:mm"
        for record in history.exports(since: now.addingTimeInterval(-ExportHistory.retention)).prefix(3) {
            let name = record.output.map { ($0 as NSString).lastPathComponent } ?? "fichier inconnu"
            let size = record.bytes.map { ", \(Fmt.bytes($0))" } ?? ""
            out.append("    \(stamp.string(from: Date(timeIntervalSince1970: record.end)))     \(name) — "
                       + "\(Fmt.duration(record.duration)), \(Self.outcomeText(record.outcome))\(size) [\(record.source)]")
        }
        return out
    }

    static func cacheLines() -> [String] {
        let measure = MediaCache.measure()
        let location = measure.location
        var out = ["  cache média (Adobe, partagé par Premiere et AME)"]
        out.append("    fichiers        \(location.files.path)")
        out.append("    base            \(location.database.path)")
        out.append("    emplacement     " + (location.fromPreferences ? "lu dans com.Adobe.Common › Media Cache"
                                                                    : "défaut d'Adobe, aucune préférence trouvée"))
        if !measure.found {
            out.append("    introuvable     aucun des deux dossiers n'existe (Adobe jamais lancé, ou disque débranché)")
        }
        out.append("    taille          \(Fmt.bytes(measure.bytes)), \(measure.fileCount) fichiers · "
                   + "dont \(Fmt.bytes(measure.staleBytes)) dormants (non modifiés depuis 30 jours)")
        out.append(String(format: "    mesuré en %.1f s — refait au plus toutes les 30 min, panneau ouvert", measure.seconds)
            .replacingOccurrences(of: ".", with: ","))
        out.append("    Pulse ne supprime jamais rien : Premiere › Réglages › Cache des médias")
        return out
    }

    static func countText(_ n: Int) -> String {
        n == 0 ? "aucun export" : n == 1 ? "1 export" : "\(n) exports"
    }

    static func outcomeText(_ outcome: ExportRecord.Outcome) -> String {
        switch outcome {
        case .success: return "réussi"
        case .warning: return "réussi avec avertissement"
        case .failure: return "échec"
        }
    }
}

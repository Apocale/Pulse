import Foundation

/// La section DISQUES de `--probe` : chaque chiffre de la carte Disques s'y
/// retrouve, mesuré indépendamment de l'app en cours.
///
/// Lecture seule, comme tout `--probe` : rien n'est écrit, aucun fichier du
/// disque de rushes n'est ouvert.
enum DiskProbe {
    /// `groups` : un balayage des processus fait sur au moins une seconde,
    /// qui porte donc déjà les débits disque par application.
    static func lines(volumes: [VolumeSample], groups: [ProcessGroup]) -> [String] {
        var out: [String] = []
        var meter = DiskRateMeter()
        let first = DiskIO.read(known: [:])
        let t0 = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        _ = meter.update(now: t0, readings: Dictionary(first.map { ($0.disk.id, $0.counters) },
                                                         uniquingKeysWith: { a, _ in a }))
        // La seconde de mesure du réseau sert aussi aux disques : le
        // détecteur d'ingestion compare les deux sur le même intervalle.
        let network = NetworkMonitor.measure()?.sample
        let second = DiskIO.read(known: Dictionary(first.map { ($0.disk.id, $0.disk) },
                                                   uniquingKeysWith: { a, _ in a }))
        let t1 = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let rates = meter.update(now: t1, readings: Dictionary(second.map { ($0.disk.id, $0.counters) },
                                                                uniquingKeysWith: { a, _ in a }))
        let map = DiskActivity.map(volumes)
        var lines = DiskActivity.lines(disks: second.map(\.disk), volumes: volumes, map: map, rates: rates)
        for i in lines.indices where lines[i].disk.smartCapable {
            lines[i].health = SMARTReader.read(driverID: lines[i].id)
        }

        out.append("  débits mesurés sur \(decimal(t1 - t0)) s, compteurs des pilotes de stockage (IOKit)")
        for line in lines {
            let d = line.disk
            let place = d.isInternal ? "interne" : "externe"
            let removable = d.isRemovable ? ", amovible" : ""
            let mounted = line.volumes.isEmpty ? "aucun volume monté" : line.volumes.map(\.name).joined(separator: ", ")
            out.append("  \(d.bsdName.padding(toLength: 7, withPad: " ", startingAt: 0))\(d.model) — \(place), \(d.interconnect)\(removable), \(Fmt.bytes(d.size)) · \(mounted)")
            let read = line.read.map { "\(Fmt.bytes($0))/s" } ?? "—"
            let write = line.write.map { "\(Fmt.bytes($0))/s" } ?? "—"
            out.append("         lecture \(read) · écriture \(write)")
            out.append("         santé : " + healthText(line))
        }
        // Les deux grands chiffres de la carte : la somme des disques physiques.
        let totalRead = rates.values.reduce(0) { $0 + $1.read }
        let totalWrite = rates.values.reduce(0) { $0 + $1.write }
        out.append("  total (chiffres de la carte) : écriture \(Fmt.bytes(totalWrite))/s · lecture \(Fmt.bytes(totalRead))/s")
        let unmapped = volumes.filter { map[$0.path] == nil }
        if !unmapped.isEmpty {
            out.append("  sans disque physique identifié : \(unmapped.map(\.name).joined(separator: ", "))")
        }

        let floor = DiskActivity.appFloor
        let writers = groups.filter { $0.diskWrite >= floor }.sorted { $0.diskWrite > $1.diskWrite }.prefix(5)
        let readers = groups.filter { $0.diskRead >= floor }.sorted { $0.diskRead > $1.diskRead }.prefix(5)
        out.append("  apps qui écrivent (≥ \(Fmt.bytes(floor))/s) : "
                   + (writers.isEmpty ? "aucune" : writers.map { "\(appLabel($0)) \(Fmt.bytes($0.diskWrite))/s" }.joined(separator: " · ")))
        out.append("  apps qui lisent : "
                   + (readers.isEmpty ? "aucune" : readers.map { "\(appLabel($0)) \(Fmt.bytes($0.diskRead))/s" }.joined(separator: " · ")))
        out.append("  (les processus d'un autre compte — noyau, swap, Spotlight — sont illisibles sans root :")
        out.append("   l'écart entre le débit des disques et celui des apps leur revient)")

        // Ingestion : un relevé unique ne peut pas faire un épisode (il en
        // faut 1 Go écrit) ; on rapporte la nature instantanée et les seuils,
        // puis le journal que tient l'app.
        out.append("  ingestion — instantané sur ce relevé (un épisode exige \(Fmt.bytes(IngestionDetector.massive)) écrits à \(Fmt.bytes(IngestionDetector.activeRate))/s ou plus) :")
        let input = DiskActivity.ingestionInput(lines: lines, interval: max(t1 - t0, 0.001),
                                                networkRx: network?.rxRate ?? 0,
                                                processes: groups, exporting: false,
                                                devices: { WrittenDevices.devices(of: $0.pids) })
        let writing = input.disks.filter { !$0.isInternal && $0.write >= IngestionDetector.activeRate }
        if writing.isEmpty {
            out.append("    aucun disque externe n'écrit à \(Fmt.bytes(IngestionDetector.activeRate))/s ou plus")
        }
        for disk in writing {
            let (kind, source) = IngestionDetector.classify(disk, in: input)
            let label = Ingestion(kind: kind, target: disk.name, targetKey: nil, source: source, app: nil,
                                  start: Date(), lastActive: Date(), bytes: 0).label
            let writer = IngestionDetector.writer(for: disk, in: input)
                ?? "aucune des 3 apps qui écrivent le plus n'y tient de fichier ouvert"
            out.append("    \(disk.name) écrit \(Fmt.bytes(disk.write))/s → « \(label) » · écrivain : \(writer) · réseau ↓ \(Fmt.bytes(input.networkRx))/s")
            let held = input.apps.compactMap { app -> String? in
                guard let devices = app.devices else { return nil }
                let here = !devices.isDisjoint(with: disk.devices)
                return "\(app.name) \(here ? "oui" : "non")"
            }
            out.append("      fichier ouvert en écriture sur \(disk.name) (dev \(disk.devices.sorted().map(String.init).joined(separator: ", "))) : \(held.joined(separator: " · "))")
        }
        out.append(contentsOf: fillLines(volumes: volumes))
        let episodes = DiskJournal.read().filter { Date().timeIntervalSince($0.lastActive) <= DiskActivity.recentWindow }
        if episodes.isEmpty {
            out.append("  journal (disques.json, 7 j) : aucun épisode — il se remplit à la première écriture massive")
        } else {
            out.append("  journal (disques.json, 7 j) :")
            for e in episodes.reversed().prefix(8) { out.append("    " + episodeText(e)) }
        }
        return out
    }

    /// « Ce qui remplit » : le dernier bilan de l'app (disques.json) — les
    /// chiffres mêmes de la carte. Avec `--remplissage`, la même requête
    /// Spotlight est refaite ici, bornée à 20 s pour tous les volumes
    /// ensemble : sur une machine chargée, `mds` a mis 89 s à répondre, et le
    /// relevé passait de 13 à 53 s — trop pour `./verifie.sh`, qui le borne.
    static func fillLines(volumes: [VolumeSample]) -> [String] {
        var out: [String] = []
        let external = volumes.filter { !$0.isInternal }
        let saved = Dictionary(DiskJournal.readFill().map { ($0.volumeKey, $0) }, uniquingKeysWith: { a, _ in a })
        let hour = DateFormatter()
        hour.locale = Locale(identifier: "fr_FR")
        hour.dateFormat = "EEE dd/MM HH:mm"
        let ask = CommandLine.arguments.contains("--remplissage")

        final class Box: @unchecked Sendable { var reports: [String: FillReport] = [:]; let lock = NSLock() }
        let box = Box()
        let group = DispatchGroup()
        for volume in external where ask {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                guard let arrivals = SpotlightArrivals.query(volumePath: volume.path) else { return }
                let report = FillReport.build(volumeKey: volume.historyKey, volumeName: volume.name,
                                              arrivals: arrivals, now: Date())
                box.lock.lock(); box.reports[volume.historyKey] = report; box.lock.unlock()
            }
        }
        let finished = group.wait(timeout: .now() + 20) == .success
        box.lock.lock(); let live = box.reports; box.lock.unlock()

        out.append("  ce qui remplit — octets ARRIVÉS par dossier (date d'ajout, index Spotlight), 24 h · 7 j :")
        for volume in external {
            if let report = saved[volume.historyKey] {
                out.append("    \(volume.name), bilan de l'app (\(hour.string(from: report.at))) : " + fillSummary(report))
                out.append(contentsOf: folderLines(report))
            }
            if let report = live[volume.historyKey] {
                out.append("    \(volume.name), requête de ce relevé : " + fillSummary(report))
                out.append(contentsOf: folderLines(report))
            } else if ask {
                out.append("    \(volume.name) : " + (finished ? "requête Spotlight refusée (index désactivé ?)"
                                                             : "requête Spotlight inachevée en 20 s (machine chargée)"))
            } else if saved[volume.historyKey] == nil {
                out.append("    \(volume.name) : aucun bilan de l'app — "
                           + (DiskActivity.fillAutomatic
                              ? "première requête 2 min après son lancement"
                              : "requête automatique coupée, faute de savoir si macOS demanderait l'accès au volume")
                           + " ; `--probe --remplissage` la fait ici")
            }
        }
        return out
    }

    private static func folderLines(_ report: FillReport) -> [String] {
        report.week.prefix(5).map { folder in
            let day = report.day.first { $0.path == folder.path }?.bytes ?? 0
            return "      \(folder.label) — \(day > 0 ? Fmt.bytes(day) : "—") · \(Fmt.bytes(folder.bytes)) (\(folder.files) fichier\(folder.files > 1 ? "s" : ""))"
        }
    }

    private static func fillSummary(_ r: FillReport) -> String {
        "24 h \(Fmt.bytes(r.dayBytes)) (\(r.dayFiles) fichiers) · 7 j \(Fmt.bytes(r.weekBytes)) (\(r.weekFiles) fichiers)"
            + (r.week.first.map { " · surtout \($0.label)" } ?? "")
    }

    static func appLabel(_ group: ProcessGroup) -> String {
        group.bundleId.hasPrefix("exec:") ? Fmt.processName(group.name) : Fmt.appName(group.name)
    }

    /// « bon · usure 3 % · 33 °C · 71,8 To écrits · 1 802 h allumé · 53 coupures »
    static func healthText(_ line: DiskLine) -> String {
        guard let h = line.health else {
            return line.disk.smartCapable
                ? "journal SMART illisible à ce relevé (client exclusif tenu par un autre outil ?)"
                : "non publiée — ce contrôleur ne relaie pas le journal SMART (sans root)"
        }
        var parts = ["\(h.statusLabel)", "usure \(h.percentUsed) %"]
        if let t = h.temperature { parts.append("\(t) °C") }
        parts.append("réserve \(h.availableSpare) % (seuil \(h.spareThreshold) %)")
        parts.append("\(Fmt.bytes(h.dataWritten)) écrits, \(Fmt.bytes(h.dataRead)) lus à vie")
        parts.append("\(Int(h.powerOnHours)) h allumé, \(Int(h.powerCycles)) démarrages, \(Int(h.unsafeShutdowns)) coupures")
        parts.append("\(Int(h.mediaErrors)) erreur\(h.mediaErrors > 1 ? "s" : "") média")
        return parts.joined(separator: " · ")
    }

    /// « dim. 11/10 04:12 → 04:58 · Téléchargement → Ssd 2 · 45,2 Go · Vivaldi »
    static func episodeText(_ e: Ingestion) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "fr_FR")
        day.dateFormat = "EEE dd/MM HH:mm"
        let hour = DateFormatter()
        hour.dateFormat = "HH:mm"
        let span = e.active ? "en cours depuis \(Fmt.duration(e.duration))" : "→ \(hour.string(from: e.lastActive))"
        let rate = e.active ? " · \(Fmt.bytes(e.rate))/s" : ""
        return "\(day.string(from: e.start)) \(span) · \(e.label) → \(e.target) · \(Fmt.bytes(e.bytes))\(rate) · \(e.app ?? "écrivain non identifié")"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

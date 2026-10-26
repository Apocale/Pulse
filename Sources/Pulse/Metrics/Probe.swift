import Foundation
import AppKit
import ServiceManagement

/// Relevé texte de tous les capteurs. Permet de valider les mesures
/// indépendamment de l'interface : si un chiffre est faux, il est faux ici aussi.
enum Probe {
    /// Écrit et lu sur le fil principal seulement : `--probe` est un relevé
    /// d'un seul fil, qui se termine avant toute autre chose.
    nonisolated(unsafe) private static var lines: [String] = []

    private static func emit(_ text: String = "") { lines.append(text) }

    /// Le bilan qui sert à calibrer le verdict : combien de fois il change, et
    /// quelle règle occupe combien de temps. Un verdict qui change toutes les
    /// dix minutes ne se lit plus ; une règle qui tient 80 % du temps est soit
    /// l'état réel de la machine, soit un seuil trop bas.
    private static func journalSummary(now: Date = Date()) {
        let horizon = now.timeIntervalSince1970 - 7 * 86_400
        let entries = VerdictJournal.read().filter { $0.t >= horizon }
        let changes = entries.filter { $0.rule != nil }
        guard let first = entries.first, !changes.isEmpty else {
            emit("  journal vide — il se remplit à chaque changement de verdict")
            return
        }
        // Un rythme quotidien calculé sur quelques minutes serait une
        // extrapolation : sous un jour de journal, on donne le compte brut.
        // Seuls les VRAIS changements comptent : une relance de Pulse réécrit
        // la règle du moment sans que le verdict ait changé (chantier 12).
        let (real, restarts) = VerdictJournal.changes(entries)
        let span = now.timeIntervalSince1970 - first.t
        if span < 86_400 {
            emit("  changements      \(real) depuis \(Fmt.duration(span)) — rythme quotidien après un jour de journal")
        } else {
            let days = span / 86_400
            emit(String(format: "  changements      %d sur %.1f jours · %.1f par jour",
                        real, days, Double(real) / days)
                 .replacingOccurrences(of: ".", with: ","))
        }
        if restarts > 0 {
            emit("  relances         \(restarts) lancement\(restarts > 1 ? "s" : "") de Pulse sur le même verdict, non comptés")
        }

        // Durée de chaque règle jusqu'à l'entrée suivante. Une règle suivie
        // d'un démarrage sans arrêt s'est terminée à une heure inconnue —
        // plantage ou arrêt forcé : on ne compte pas sa durée plutôt que de
        // l'inventer. La dernière règle court jusqu'à maintenant.
        var time: [Int: Double] = [:], count: [Int: Int] = [:], names: [Int: String] = [:]
        var shown: Int?
        for (i, e) in entries.enumerated() {
            guard let rule = e.rule else { continue }
            // Une relance sur la même règle prolonge l'épisode, n'en ouvre pas un.
            if rule != shown { count[rule, default: 0] += 1 }
            shown = rule
            names[rule] = e.name
            let next = i + 1 < entries.count ? entries[i + 1] : nil
            if next?.event == "start" { continue }
            time[rule, default: 0] += (next?.t ?? now.timeIntervalSince1970) - e.t
        }
        let observed = time.values.reduce(0, +)
        for rule in count.keys.sorted(by: { (time[$0] ?? 0) > (time[$1] ?? 0) }) {
            let share = observed > 0 ? Fmt.percent((time[rule] ?? 0) / observed) : "—"
            let name = (names[rule] ?? "").padding(toLength: 32, withPad: " ", startingAt: 0)
            emit("  \(String(rule).padding(toLength: 3, withPad: " ", startingAt: 0))\(name)"
                 + "\(String(count[rule] ?? 0).padding(toLength: 4, withPad: " ", startingAt: 0))×   \(share) du temps")
        }
    }

    /// Lecture seule : `--probe` ne doit jamais écrire dans reseau.json, où
    /// l'app en cours compte déjà le même trafic.
    private static func networkSection() {
        guard let (primary, live) = NetworkMonitor.measure() else {
            emit("  hors ligne — aucun réseau principal")
            return
        }
        emit("  réseau actuel    \(live.label) (\(primary.interface), passerelle \(primary.router ?? "?"))")
        emit("  débit            ↓ \(Fmt.bytes(live.rxRate))/s · ↑ \(Fmt.bytes(live.txRate))/s, mesuré sur 1 s")
        // Isma lit le débit en bits dans le panneau : le même chiffre ici.
        if MainActor.assumeIsolated({ SettingsStore.shared.settings.display.rateUnit }) == .bits {
            emit("                   soit ↓ \(Fmt.rate(live.rxRate, .bits)) · ↑ \(Fmt.rate(live.txRate, .bits))")
        }

        let history = NetworkTracker().history(days: 7)
        if history.allSatisfy({ $0.usage.isEmpty }) {
            emit("  cumul journalier vide — il se remplit tant que Pulse tourne")
            return
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE dd/MM"
        for (day, usage) in history.reversed() where !usage.isEmpty {
            let parts = usage.map { "\($0.label) ↓ \(Fmt.bytes($0.rx)) ↑ \(Fmt.bytes($0.tx))" }
            emit("  \(f.string(from: day).padding(toLength: 12, withPad: " ", startingAt: 0))\(parts.joined(separator: " · "))")
        }
    }

    /// Le registre des modules et la disposition que les réglages en tirent,
    /// puis la section propre de chaque module qui en fournit une.
    @MainActor
    private static func moduleSection() {
        let settings = SettingsStore.shared.settings
        let columns = Layout.columns(settings)
        emit("\nMODULES · registre et réglages (reglages.json)")
        emit("  disposition      \(columns.count) colonne\(columns.count > 1 ? "s" : "") — "
             + columns.map { $0.isEmpty ? "(vide)" : $0.joined(separator: ", ") }.joined(separator: " | "))
        for module in ModuleRegistry.all {
            let mine = settings.module(module.id)
            let shown = Layout.isEnabled(module, in: settings)
            var detail = shown ? "affichée, colonne \(Layout.column(of: module, in: settings) + 1)" : "masquée"
            if mine.compact { detail += ", compacte" }
            if let apps = mine.appCount { detail += ", \(apps) apps" }
            emit("  \(module.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(module.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(detail)")
        }
        let refresh = settings.refresh.sanitized
        let seconds = { (value: Double) in Fmt.decimalSeconds(value) }
        emit("  cadence          \(seconds(refresh.openInterval)) panneau ouvert · \(seconds(refresh.closedInterval)) fermé")
        emit("  débit            en \(settings.display.rateUnit == .bits ? "bits (Mbit/s)" : "octets (Mo/s)")")
        for module in ModuleRegistry.all {
            for (series, raw) in settings.module(module.id).tints.sorted(by: { $0.key < $1.key }) {
                let choice = TintChoice(raw: raw)
                let ratios = choice.ratios.map { "\(Contrast.text($0.dark)) sombre · \(Contrast.text($0.light)) clair" } ?? "illisible"
                emit("  teinte           \(module.id).\(series) : \(TintChoice.name(of: raw)), \(ratios)"
                     + (choice.passes ? "" : " — REFUSÉE, teinte du module"))
            }
        }
        let costs = Set(ModuleRegistry.all.map(\.cost.note))
        for note in costs.sorted() { emit("  coût : \(note)") }
        for module in ModuleRegistry.all {
            guard let section = module.probeSection() else { continue }
            emit("\n\(section.title)")
            for line in section.lines { emit("  \(line)") }
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM HH:mm"
        return f.string(from: date)
    }

    static func run() {
        // Lecture seule, d'un bout à l'autre. La coupure n'était posée qu'à
        // la dernière section (barre de menus) : avant elle, un history.json
        // ou un reseau.json illisible aurait été MIS DE CÔTÉ par un simple
        // relevé, et `--probe --forfait 20` écrivait le forfait d'essai
        // dans reglages.json (17-audit-code). `--audit` écrit probe.txt
        // quand même : c'est sa raison d'être.
        Persistence.enabled = false
        lines.removeAll()
        let monitor = CPUMonitor()
        _ = monitor.sample()                 // premier appel = référence de ticks
        Thread.sleep(forTimeInterval: 1.0)
        let cpu = monitor.sample()
        let mem = MemoryMonitor.sample()
        let gpu = GPUMonitor.utilization()
        let volumes = DiskMonitor.volumes()

        // En tête : si Pulse ne se lance pas seul, tout ce qui suit repose
        // sur un historique à trous.
        //
        // `SMAppService.mainApp` désigne le bundle du processus courant. Lancé
        // en binaire nu depuis .build/, il n'y en a aucun, et le statut vaut
        // `.notFound` même quand l'élément est bel et bien enregistré — un faux
        // négatif vérifié. Mieux vaut dire qu'on ne sait pas.
        let login: String
        if Bundle.main.bundleURL.pathExtension != "app" {
            login = "invérifiable hors du bundle — lancer ./Pulse.app/Contents/MacOS/Pulse --probe"
        } else {
        switch SMAppService.mainApp.status {
        case .enabled:          login = "activé"
        case .requiresApproval: login = "en attente d'approbation (Réglages Système › Général › Ouverture)"
        case .notRegistered:    login = "non enregistré"
        case .notFound:         login = "introuvable"
        @unknown default:       login = "état inconnu"
        }
        }
        emit("LANCEMENT À L'OUVERTURE DE SESSION : \(login)\n")

        emit("MÉMOIRE")
        emit("  totale        \(Fmt.memory(mem.total))")
        emit("  utilisée      \(Fmt.memory(mem.used))  (\(Fmt.percent(mem.usedFraction)))")
        emit("    app         \(Fmt.memory(mem.app))")
        emit("    wired       \(Fmt.memory(mem.wired))")
        emit("    compressée  \(Fmt.memory(mem.compressed))")
        emit("  cache fichier \(Fmt.memory(mem.cached))")
        emit("  swap          \(Fmt.memory(mem.swapUsed)) utilisés (fichiers alloués : \(Fmt.memory(mem.swapTotal)))")
        emit("  pression      \(mem.pressureLabel) (niveau noyau \(mem.pressureLevel))"
             + (mem.pressure.map { " · anneau de la carte \(Fmt.percent($0))" } ?? ""))

        emit("\nPROCESSEUR  \(CPUMonitor.performanceCores) P + \(CPUMonitor.efficiencyCores) E")
        emit("  total         \(Fmt.percent(cpu.total))  (user \(Fmt.percent(cpu.user)), système \(Fmt.percent(cpu.system)))")
        emit("  cluster P     \(Fmt.percent(cpu.performance))")
        emit("  cluster E     \(Fmt.percent(cpu.efficiency))")
        emit("  par cœur      " + cpu.perCore.map { Fmt.percent($0) }.joined(separator: " "))
        // La carte Processeur montre aussi la charge et le temps allumé.
        if cpu.load.count == 3 {
            let charge = MainActor.assumeIsolated { cpu.load.map { ProcessorCard.loadFormat($0) } }
            emit("  charge        " + charge.joined(separator: " · ") + "  (1 · 5 · 15 min)")
        }
        if let boot = SystemClock.bootDate {
            let allume = MainActor.assumeIsolated { ProcessorCard.uptime(Date().timeIntervalSince(boot)) }
            emit("  allumé depuis \(allume)")
        }

        emit("\nGPU")
        emit("  occupation    \(gpu.map(Fmt.percent) ?? "non disponible")")

        let processes = ProcessMonitor()
        _ = processes.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let groups = processes.sample()

        emit("\nPAR APPLICATION (cpu = % d'un cœur, plafond \(CPUMonitor.performanceCores + CPUMonitor.efficiencyCores)00 %)")
        for group in groups.prefix(8) where group.cpu > 0.5 || group.footprint > 200_000_000 {
            emit("  \(String(format: "%6.1f %%", group.cpu))  \(Fmt.memory(group.footprint).padding(toLength: 9, withPad: " ", startingAt: 0)) \(group.name)  (\(group.processCount) proc.)")
        }
        // La carte Mémoire classe les apps par empreinte, pas par processeur :
        // un Premiere au repos à 15 Go n'était pas dans les huit ci-dessus.
        emit("  par mémoire : " + groups.sorted { $0.footprint > $1.footprint }.prefix(5)
            .map { "\(DiskProbe.appLabel($0)) \(Fmt.memory($0.footprint))" }.joined(separator: " · "))

        // Le détecteur exige deux relevés consécutifs au-dessus du seuil, et
        // --probe n'en fait qu'un. On rapporte donc la mesure brute et le seuil,
        // sans simuler une décision qu'un relevé unique ne peut pas trancher.
        emit("\nEXPORT")
        let encodeurs = groups.filter { AppKind.of(bundleId: $0.bundleId) == .encoding }
        let actif = encodeurs.max(by: { $0.cpu < $1.cpu })
        if let actif {
            let seuil = Fmt.cpu(ExportDetector.threshold)
            if actif.cpu > ExportDetector.threshold {
                emit("  \(actif.name) à \(Fmt.cpu(actif.cpu)) — au-dessus du seuil de \(seuil)")
                emit("  l'interface confirme sur deux relevés consécutifs, --probe n'en fait qu'un")
            } else {
                emit("  \(actif.name) à \(Fmt.cpu(actif.cpu)) — sous le seuil de \(seuil), pas d'export")
            }
        } else {
            emit("  aucun encodeur lancé (Media Encoder, Compressor)")
        }

        // Instrument, pas détection : la piste de l'export lancé depuis
        // Premiere, à valider sur un export réel. Voir OpenFiles.
        let montage = NSWorkspace.shared.runningApplications
            .filter { AppKind.of(bundleId: $0.bundleIdentifier ?? "") == .editing }
        for app in montage {
            let name = Fmt.appName(app.localizedName ?? app.bundleIdentifier ?? "?")
            let files = OpenFiles.mediaWritten(by: app.processIdentifier)
            if files.isEmpty {
                emit("  \(name) : aucun fichier média ouvert en écriture")
            } else {
                emit("  \(name) écrit \(files.count) fichier\(files.count > 1 ? "s" : "") média :")
                for path in files {
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                    emit("    \((path as NSString).lastPathComponent) — \(Fmt.bytes(size)), \((path as NSString).deletingLastPathComponent)")
                }
            }
        }
        if !montage.isEmpty {
            emit("  (piste d'export depuis Premiere, non validée — voir OpenFiles.swift)")
        }

        let store = HistoryStore()

        // Sans cette section, l'élément le plus important du panneau serait le
        // seul indébogable — et la règle du dépôt (« si un chiffre est faux
        // dans l'interface, il l'est aussi dans --probe ») tomberait justement
        // sur la phrase qui conclut.
        emit("\nVERDICT")
        var forecasts: [String: FillForecast] = [:]
        var ages: [String: TimeInterval] = [:]
        for volume in volumes {
            if let forecast = store.forecast(for: volume.historyKey, capacity: volume.total,
                                             free: volume.available) {
                forecasts[volume.historyKey] = forecast
            }
            if let age = store.lastSampleAge(for: volume.historyKey) {
                ages[volume.historyKey] = age
            }
        }
        let entree = VerdictInput(
            memory: mem,
            cpu: cpu,
            volumes: volumes,
            forecasts: forecasts,
            volumeAges: ages,
            incidents: IncidentLog.recent(since: Date().addingTimeInterval(-14 * 86_400)),
            processes: groups,
            // La règle 11 exige deux relevés consécutifs : on la laisse hors
            // jeu plutôt que de trancher sur une mesure qui ne le permet pas.
            export: nil,
            series: store.series)
        let (verdict, autres) = VerdictEngine.instant(entree)
        emit("  règle retenue   \(verdict.rule) — \(verdict.ruleName)")
        emit("  phrase          \(verdict.phrase)")
        emit("  preuve          \(verdict.evidence)")
        let aussi = autres.map { "\($0.rule) (\($0.short))" }.joined(separator: " · ")
        emit("  aussi actives   \(aussi.isEmpty ? "aucune" : aussi)")
        emit("  sans hystérésis : état instantané, l'interface exige \(Int(VerdictEngine.entryDelay)) s de maintien")
        let mesureEncodeur = actif.map { "\($0.name) à \(Fmt.cpu($0.cpu))" } ?? "aucun encodeur lancé"
        emit("  règle 11 (export) indécidable sur un relevé unique — \(mesureEncodeur), seuil \(Fmt.cpu(ExportDetector.threshold))")
        // Ces trois-là sont des choix, pas des mesures : le dire ici est ce qui
        // empêche de les prendre plus tard pour des bornes établies.
        emit("  seuils provisoires : 7 (1 Gio/h), 10 (\(Fmt.percent(VerdictEngine.busyMachine)) / \(Fmt.cpu(VerdictEngine.busyGroup))) — rejeu : outils/rejoue-seuils.py")
        emit("  seuil calibré : 9 (\(Int(VerdictEngine.forecastSoonDays)) j, prévisions rejouées sur 13 jours le 11/10)")

        emit("\nCONSEIL · la ligne du bandeau, son calcul, son bouton (jamais exécuté ici)")
        AdviceProbe.lines(entree, retained: verdict).forEach { emit($0) }   // chantier 12

        emit("\nDISQUES · activité, santé, ce qui remplit (chantier 05)")
        DiskProbe.lines(volumes: volumes, groups: groups).forEach { emit($0) }

        emit("\nRÉSEAU · ce Mac seulement")
        networkSection()
        SondeReseau.lignes().forEach { emit($0) }   // forfait, connexion, Wi-Fi, apps : chantier 07

        emit("\nWIDGETS ET RACCOURCIS · ce qu'ils diraient maintenant (chantier 13)")
        MainActor.assumeIsolated {
            SurfacesProbe.lines(memory: mem, volumes: volumes, forecasts: forecasts, verdict: verdict).forEach { emit($0) }
        }

        emit("\nPANNEAU · ouvertures des 7 derniers jours")
        let panel = HotKeyLog.summary(days: 7)
        if panel.opens == 0 {
            emit("  aucune ouverture journalisée — le journal se remplit à l'usage")
        } else {
            emit("  ouvertures       \(panel.opens)")
            emit("  sans panneau visible 0,4 s après : \(panel.failures)"
                 + (panel.lastFailure.map { ", la dernière \(Self.stamp($0))" } ?? ""))
            emit("  trouvé ouvert mais invisible, rouvert d'un seul appui : \(panel.reopenedHidden)")
        }

        emit("\nVERDICTS · journal des 7 derniers jours")
        journalSummary()

        emit("\nHISTORIQUE · séries de 10 s à 90 jours (History/)")
        HistoryProbe.lines().forEach { emit($0) }

        emit("\nUSAGE APPLICATIF (aujourd'hui)")
        let usage = store.focusUsage()
        if usage.isEmpty {
            emit("  aucun relevé")
        } else {
            for app in usage {
                let kind: String
                switch AppKind.of(bundleId: app.bundleId) {
                case .editing: kind = "montage"
                case .encoding: kind = "export"
                case .other: kind = "autre"
                }
                emit("  \(Fmt.duration(app.focus).padding(toLength: 10, withPad: " ", startingAt: 0)) \(app.name)  [\(kind)] \(app.bundleId)")
            }
            emit("  total : \(Fmt.duration(store.focusTotal()))")
        }

        emit("\nSESSIONS DE MONTAGE (7 derniers jours)")
        let recent = store.sessions(since: Date().addingTimeInterval(-7 * 86_400))
        if recent.isEmpty {
            emit("  aucune session enregistrée")
        } else {
            for session in recent.prefix(8) {
                let state = session.isOpen ? "en cours" : "terminée"
                emit("  \(session.name) — \(Fmt.duration(session.duration)) (\(state)) · pic \(Fmt.memory(session.peakMemoryBytes)) · swap \(Fmt.memory(session.peakSwap))")
            }
        }

        emit("\nINCIDENTS")
        switch IncidentLog.access() {
        case .denied:
            emit("  accès refusé aux rapports de diagnostic")
        case .granted:
            emit("  rapports système lisibles")
            let incidents = IncidentLog.recent(since: Date().addingTimeInterval(-14 * 86_400))
            if incidents.isEmpty {
                emit("  aucun incident de montage sur 14 jours")
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "dd/MM HH:mm"
                for incident in incidents.prefix(12) {
                    emit("  \(formatter.string(from: incident.date))  \(incident.kind.label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(incident.app)")
                }
                emit("  total sur 14 jours : \(incidents.count)")
            }
        }

        emit("\nVOLUMES")
        for volume in volumes {
            emit("  \(volume.name) [\(volume.path)]\(volume.isInternal ? "" : " — externe")")
            emit("    clé d'historique : \(volume.historyKey)")
            emit("    \(Fmt.bytes(volume.used)) utilisés sur \(Fmt.bytes(volume.total)) · \(Fmt.bytes(volume.available)) libres (\(Fmt.occupancy(volume.usedFraction)))")
            if let forecast = store.forecast(for: volume.historyKey, capacity: volume.total,
                                             free: volume.available) {
                let trend = forecast.bytesPerDay < 0
                    ? "se remplit de \(Fmt.bytes(-forecast.bytesPerDay, digits: 1)) par jour"
                    : "se vide de \(Fmt.bytes(forecast.bytesPerDay, digits: 1)) par jour"
                let eta = forecast.daysUntilFull.map { " · plein dans \(Fmt.days($0))" } ?? ""
                emit("    \(trend)\(eta)")
                // D'où sort la pente : c'est ici qu'on voit qu'une ingestion de
                // carte a été écartée plutôt que moyennée dans la tendance.
                let excluded = forecast.ruptures == 0
                    ? ""
                    : " · \(forecast.ruptures) écartée\(forecast.ruptures > 1 ? "s" : "") (opération en masse)"
                emit("    tendance sur \(Fmt.duration(forecast.calmSeconds)) d'observation calme\(excluded)")
                if forecast.window < HistoryStore.trendWindow {
                    emit("    rythme des \(Int(forecast.window / 3600)) dernières heures, plus lent que celui des \(Int(HistoryStore.trendWindow / 3600)) h : retenu")
                }
            } else if let age = store.lastSampleAge(for: volume.historyKey),
                      age > HistoryStore.maxStaleness {
                // Au-delà de deux jours « 288 h 04 » ne se lit plus.
                let ago = age < 48 * 3600 ? Fmt.duration(age) : Fmt.days(age / 86_400)
                emit("    tendance indisponible (dernier relevé il y a \(ago))")
            } else {
                emit("    tendance indisponible (moins de 6 h d'observation calme)")
            }
        }

        // --probe s'exécute sur le main thread, depuis main().
        MainActor.assumeIsolated { moduleSection() }
        // 14-ventilateurs : lecture seule ; le helper n'est interrogé que s'il est installé.
        emit("\nVENTILATEURS · contrôle sur accord, helper privilégié (chantier 14)")
        for line in MainActor.assumeIsolated({ FanProbe.lines() }) { emit("  \(line)") }

        emit("\nRÈGLES · regles.json, toutes éteintes par défaut (chantier 11)")
        MainActor.assumeIsolated {
            SondeRegles.lignes(memoire: mem, cpu: cpu, volumes: volumes, previsions: forecasts, series: store.series,
                               incidents: IncidentLog.recent(since: Date().addingTimeInterval(-86_400)))
        }.forEach { emit($0) }

        // La barre de menus (chantier 09), en dernier : elle fait tourner un
        // vrai Sampler 4,5 s, écriture coupée.
        emit("\nBARRE DE MENUS · réglages, contenu, place (chantier 09)")
        MainActor.assumeIsolated { MenuBarProbe.lines() }.forEach { emit("  \($0)") }

        let output = lines.joined(separator: "\n")
        // Lancé par LaunchServices (open -a), la sortie standard n'aboutit
        // nulle part : --audit écrit le relevé sur disque à la place.
        if CommandLine.arguments.contains("--audit") {
            let path = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pulse/probe.txt")
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? output.write(to: path, atomically: true, encoding: .utf8)
        } else {
            print(output)
        }
    }
}

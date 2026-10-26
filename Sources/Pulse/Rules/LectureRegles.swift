import Foundation

/// Ce que les règles lisent : des relevés que Pulse fait de toute façon.
/// L'app le remplit depuis le `Sampler`, `--probe` depuis son propre relevé
/// unique — et les deux passent par `valeurs`, le même code : un chiffre de
/// la page Règles se retrouve dans `--probe`.
struct EntreesRegles {
    var memoire = MemorySample()
    var cpu = CPUSample()
    var volumes: [VolumeSample] = []
    var previsions: [String: FillForecast] = [:]
    /// La série des 60 dernières minutes (un point toutes les 10 s).
    var series: [SeriesPoint] = []
    /// `nil` tant que le réseau n'a pas été relevé une première fois : le
    /// `Sampler` démarre « déconnecté », ce qui n'est pas une mesure.
    var reseau: NetworkSample?
    /// Part du forfait iPhone consommée ; `nil` s'il n'est pas réglé.
    var forfait: Double?
}

enum LectureRegles {
    /// Les valeurs du moment, pour les seules mesures demandées.
    static func valeurs(_ e: EntreesRegles, mesures: Set<String>, date: Date) -> [String: [Echantillon]] {
        var out: [String: [Echantillon]] = [:]
        func volumes(_ id: String, _ valeur: (VolumeSample) -> Double?) {
            guard mesures.contains(id) else { return }
            let lus = e.volumes.compactMap { v in
                valeur(v).map { Echantillon(sujet: v.historyKey, nom: v.name, valeur: $0, suiviParDefaut: !v.isInternal) }
            }
            if !lus.isEmpty { out[id] = lus }
        }
        func une(_ id: String, _ valeur: Double?) {
            guard mesures.contains(id), let valeur, valeur.isFinite else { return }
            out[id] = [Echantillon(valeur: valeur)]
        }
        volumes("disques.libre") { Double($0.available) }
        volumes("disques.occupation") { $0.total > 0 ? $0.usedFraction : nil }
        volumes("disques.pleinDans") { e.previsions[$0.historyKey]?.daysUntilFull }
        une("memoire.utilisee", e.memoire.total > 0 ? e.memoire.usedFraction : nil)
        une("memoire.pression", e.memoire.pressure)
        une("memoire.swap", e.memoire.total > 0 ? Double(e.memoire.swapUsed) : nil)
        une("memoire.swapHausse", hausseSwap(series: e.series, swap: e.memoire.swapUsed, date: date))
        une("processeur.total", e.cpu.perCore.isEmpty ? nil : e.cpu.total)
        une("reseau.horsLigne", e.reseau.map { $0.connected ? 0 : 1 })
        une("reseau.forfait", e.forfait)
        return out
    }

    /// La hausse du swap sur la dernière heure, en octets, comparée à la
    /// mesure du moment ; `nil` sous cinq minutes d'historique. Le calcul de
    /// la règle 7 du verdict (`VerdictEngine.swapRise`), à l'identique : la
    /// règle et le verdict ne peuvent pas se contredire.
    static func hausseSwap(series: [SeriesPoint], swap: UInt64, date: Date) -> Double? {
        let t = date.timeIntervalSince1970
        guard let ancien = series.first(where: { $0.t >= t - 3600 }), t - ancien.t >= 300 else { return nil }
        return Double(swap) - ancien.swap
    }

    /// Une app de montage est-elle au premier plan ? Lu sur l'app active,
    /// que macOS tient à jour : aucun relevé de plus.
    static func enMontage(_ bundleId: String?) -> Bool {
        bundleId.map { AppKind.of(bundleId: $0) == .editing } ?? false
    }

    // MARK: - Ce que disent les événements (19-suivis)

    /// « Copie de carte vers Ssd 2 · 128 Go en 14 min ».
    static func texteCopie(_ copie: Ingestion) -> String {
        "\(copie.label) vers \(copie.target) · \(Fmt.bytes(UInt64(max(0, copie.bytes)))) en \(Fmt.duration(copie.duration))"
    }

    /// Les fichiers d'un export fini, d'après le journal d'AME : ceux qui se
    /// sont terminés entre son début (une minute de marge) et sa fin
    /// constatée. Le journal note l'heure de fin à la seconde ; le détecteur
    /// lâche l'export 30 s après la dernière charge de l'encodeur.
    static func fichiersExport(_ journal: [ExportRecord], debut: Date, fin: Date) -> [ExportRecord] {
        journal.filter { $0.source == AMEJournal.source
            && $0.end >= debut.timeIntervalSince1970 - 60 && $0.end <= fin.timeIntervalSince1970 + 60 }
            .sorted { $0.end < $1.end }
    }

    /// Ce que dit la notification « Export terminé » : le fichier et son
    /// issue — « Interview 6.mp4 · réussi · 4,2 Go », « Interview 6.mp4 ·
    /// échec » —, ou pour une file, le compte et les échecs nommés. Sans
    /// fichier au journal (export vu par la charge seule), `repli` : l'app
    /// et la durée, comme avant.
    static func texteExport(_ fichiers: [ExportRecord], repli: String) -> String {
        func nom(_ r: ExportRecord) -> String { r.output.map { ($0 as NSString).lastPathComponent } ?? r.app }
        func issue(_ r: ExportRecord) -> String {
            switch r.outcome {
            case .success: return "réussi"
            case .warning: return "réussi avec avertissement"
            case .failure: return "échec"
            }
        }
        guard let premier = fichiers.first else { return repli }
        if fichiers.count == 1 {
            var parts = [nom(premier), issue(premier)]
            if premier.outcome != .failure, let octets = premier.bytes { parts.append(Fmt.bytes(octets)) }
            return parts.joined(separator: " · ")
        }
        let echecs = fichiers.filter { $0.outcome == .failure }
        let avertis = fichiers.filter { $0.outcome == .warning }
        var texte = "\(fichiers.count) fichiers"
        if echecs.isEmpty {
            texte += avertis.isEmpty ? " · tous réussis" : " · réussis, \(avertis.count) avec avertissement"
            let noms = fichiers.prefix(2).map(nom)
            texte += " · " + noms.joined(separator: ", ") + (fichiers.count > 2 ? " et \(fichiers.count - 2) autre\(fichiers.count > 3 ? "s" : "")" : "")
        } else {
            texte += " · \(echecs.count) échec\(echecs.count > 1 ? "s" : "") : " + echecs.prefix(2).map(nom).joined(separator: ", ")
                + (echecs.count > 2 ? " et \(echecs.count - 2) autre\(echecs.count > 3 ? "s" : "")" : "")
        }
        return texte
    }
}

/// Les faits nouveaux d'un relevé à l'autre : un export qui se termine, un
/// plantage qu'on n'avait pas encore vu.
///
/// Le premier relevé ne fait que poser la référence : allumer la règle
/// « Premiere a planté » à 15 h ne doit pas notifier le plantage de 11 h.
struct DetecteurEvenements {
    private var initialise = false
    private var export: ExportActivity?
    private var vus = Set<String>()
    private var copiesVues = Set<String>()

    /// - Parameter copies: les écritures massives closes que le chantier 05
    ///   publie pour les règles (`DiskActivity.copiesTerminees`), vides tant
    ///   qu'aucune règle ne les demande.
    mutating func observer(export maintenant: ExportActivity?, incidents: [Incident],
                           copies: [Ingestion] = [], date: Date) -> [String: [Evenement]] {
        var out: [String: [Evenement]] = [:]
        // L'export est fini quand le détecteur le lâche, 30 s après la
        // dernière charge de l'encodeur (`ExportDetector.grace`) : une file
        // de trois fichiers fait UN export, et une seule notification. Son
        // début reste attaché : le surveillant y retrouve les fichiers que le
        // journal d'AME a écrits (`LectureRegles.texteExport`).
        if initialise, let fini = export, maintenant == nil {
            out["montage.exportTermine", default: []].append(
                Evenement(sujet: fini.app, date: date,
                          texte: "\(Fmt.appName(fini.app)) · \(Fmt.duration(fini.duration))",
                          debut: fini.began))
        }
        export = maintenant

        // Une copie de rushes : une carte, ou un autre disque, qui lit
        // pendant que le disque externe écrit. Ni téléchargement, ni export,
        // ni écriture d'une app seule.
        for copie in copies where copie.kind == .card || copie.kind == .copy {
            guard copiesVues.insert(copie.id).inserted, initialise else { continue }
            out["disques.copieTerminee", default: []].append(
                Evenement(sujet: copie.target, date: copie.lastActive, texte: LectureRegles.texteCopie(copie),
                          debut: copie.start))
        }

        if initialise {
            for incident in incidents.sorted(by: { $0.date < $1.date }) where !vus.contains(incident.id) {
                let heure = MoteurRegles.heure(incident.date)
                switch incident.kind {
                case .crash:
                    out["montage.plantage", default: []].append(
                        Evenement(sujet: incident.app, date: incident.date,
                                  texte: "\(Fmt.appName(incident.app)) a planté à \(heure)"))
                case .jetsam:
                    out["memoire.processusTue", default: []].append(
                        Evenement(sujet: incident.app, date: incident.date,
                                  texte: "macOS a tué \(Fmt.appName(incident.app)) à \(heure), faute de mémoire"))
                }
            }
        }
        vus.formUnion(incidents.map(\.id))
        initialise = true
        return out
    }
}

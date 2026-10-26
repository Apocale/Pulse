import Foundation

/// Niveau de gravité du verdict.
///
/// Volontairement sans couleur : les teintes vivent dans `UI/Palette.swift`,
/// où chaque ratio de contraste est mesuré. Un enum de métrique qui porterait
/// une `Color` ferait entrer une décision d'affichage dans la couche qui
/// mesure — et la règle dure n°4 deviendrait invérifiable d'un seul endroit.
enum VerdictLevel: String {
    case alert
    case warning
    case data
    case muted
}

/// Série de la ligne de relevé que le verdict désigne nommément.
///
/// Sert au bloc 1 (étape 3) : une seule courbe prend la teinte du verdict,
/// les autres restent en `Palette.data`. « Au plus un signal coloré à l'écran
/// à la fois, et il vient toujours du verdict. »
enum VerdictSeries {
    case memory
    case swap
    case cpu
}

/// Ce dont une règle parle nommément, pour le conseil (`Metrics/Advice/`) :
/// le volume des règles 3, 4, 8 et 9, l'application de la règle 10. Le
/// conseil part du MÊME objet que la phrase, jamais d'une seconde sélection
/// qui pourrait en désigner un autre.
enum VerdictObject: Equatable {
    case volume(key: String)
    case app(bundleId: String)
}

/// Le jugement rendu par l'application, réfutable par construction : la ligne
/// de preuve n'énonce que des grandeurs mesurées, et `--probe` imprime la
/// règle retenue.
struct Verdict: Equatable {
    /// Rang dans le barème, 1 à 12. 0 = aucun relevé encore.
    var rule: Int
    /// Nom de la règle, pour `--probe` uniquement. Jamais affiché.
    var ruleName: String
    var level: VerdictLevel
    /// Symbole SF.
    var symbol: String
    /// 30 caractères au maximum, garantis par construction (voir `shorten`).
    var phrase: String
    /// Faits mesurés séparés par « · ». Jamais une déduction.
    var evidence: String
    /// Libellés courts des autres règles actives, deux au maximum.
    var also: [String]
    /// Le volume ou l'application que la phrase nomme, s'il y en a un.
    var object: VerdictObject? = nil

    /// La série que la phrase nomme. Les règles 1, 2 et 6 parlent de la
    /// mémoire, la 7 du swap, la 10 du processeur ; les autres ne désignent
    /// aucune courbe du relevé — un disque plein n'a pas de sparkline.
    var series: VerdictSeries? {
        switch rule {
        case 1, 2, 6: return .memory
        case 7: return .swap
        case 10: return .cpu
        default: return nil
        }
    }

    /// État avant le premier relevé.
    ///
    /// Ni jugement ni feu vert : une absence de mesure ne doit jamais se lire
    /// comme « tout va bien ». Vit quelques millisecondes — `Sampler` lance un
    /// relevé dès son initialisation — mais il faut bien une valeur initiale.
    static let pending = Verdict(rule: 0,
                                 ruleName: "aucun relevé",
                                 level: .muted,
                                 symbol: "clock",
                                 phrase: "Relevé en cours",
                                 evidence: "aucune mesure encore",
                                 also: [])
}

/// Tout ce dont le barème a besoin, pris à un instant.
///
/// Un agrégat plutôt que dix paramètres : `Sampler` le remplit sur la file
/// d'échantillonnage, `Probe` le remplit à partir d'un relevé unique, et les
/// deux traversent exactement le même code de décision. C'est ce qui rend le
/// verdict débogable par `--probe`.
struct VerdictInput {
    var memory = MemorySample()
    var cpu = CPUSample()
    var volumes: [VolumeSample] = []
    var forecasts: [String: FillForecast] = [:]
    /// Ancienneté du dernier point d'historique par volume. Clé absente =
    /// volume jamais observé, ce qui ne se dit pas comme « relevés trop
    /// anciens ».
    var volumeAges: [String: TimeInterval] = [:]
    var incidents: [Incident] = []
    var processes: [ProcessGroup] = []
    var export: ExportActivity?
    /// Série des 60 dernières minutes, pour la hausse de swap (règle 7).
    var series: [SeriesPoint] = []
}

/// Le barème : douze règles, ordre figé, première règle active gagne.
///
/// Possédé par `Sampler`, muté UNIQUEMENT depuis la file d'échantillonnage,
/// exactement comme `ExportDetector` : l'état d'hystérésis (« la condition
/// tient depuis N secondes ») n'a pas de verrou et ne survivrait pas à deux
/// appelants. Il ne doit jamais être touché depuis le main thread.
final class VerdictEngine {

    // MARK: - Seuils

    /// Une règle devient active quand sa condition tient sans interruption
    /// depuis 3 s, et n'est relâchée qu'après 10 s de condition fausse.
    /// En SECONDES et non en nombre de relevés : la cadence passe de 1,5 s
    /// (popover ouvert) à 5 s, et une hystérésis comptée en relevés serait
    /// trois fois plus longue popover fermé.
    static let entryDelay: TimeInterval = 3
    static let releaseDelay: TimeInterval = 10

    /// Le verdict ne se remplace pas plus d'une fois toutes les 10 s. Sans
    /// cela, deux règles qui s'échangent la tête feraient clignoter la phrase
    /// malgré l'hystérésis de chacune.
    static let minInterval: TimeInterval = 10

    /// Un nouveau verdict ne remplace celui qui est affiché que s'il gagne
    /// depuis 5 min. Sauf s'il est plus GRAVE : une aggravation passe tout de
    /// suite, une alerte n'attend jamais.
    ///
    /// Le journal a tranché. Sur 16 jours (24/09 → 09/10), le verdict
    /// changeait 35,7 fois par jour ; 249 de ces bascules allaient et
    /// venaient entre « La mémoire commence à manquer » et « Le swap monte »,
    /// le même problème sous deux phrases — la pression mémoire élevée tenait
    /// 30 s en médiane. L'hystérésis par règle (3 s / 10 s) ne pouvait rien
    /// contre deux règles VRAIES qui se passent la tête. Rejoué sur ce
    /// journal, ce délai ramène le verdict à 7,3 changements par jour sans
    /// retarder une seule alerte (`outils/rejoue-verdicts.py`).
    ///
    /// Une règle retombée pendant ce délai reste affichée avec ses derniers
    /// chiffres, DATÉS dans la ligne de preuve (« relevé il y a 3 min ») :
    /// jamais présentés comme actuels. L'export fait exception : un export
    /// fini est une nouvelle, sa phrase s'efface aussitôt.
    static let holdDelay: TimeInterval = 300

    // Seuils PROVISOIRES : aucun ne repose sur une mesure comparable aux
    // 68 relevés du détecteur d'export. Ils sont signalés comme tels dans
    // `--probe` pour qu'on sache lesquels sont des choix et non des mesures.
    // Le 11/10, l'historique ne couvrait que 2 h de swap et de processeur, un
    // matin de compilations : rien à en tirer (`outils/rejoue-seuils.py`).
    static let swapRisePerHour: Double = 1_073_741_824      // règle 7 : 1 Gio/h
    static let busyMachine: Double = 0.90                   // règle 10
    static let busyGroup: Double = 200                      // règle 10, % d'UN cœur

    /// Règle 9 : 14 jours, CALIBRÉ le 11/10 sur 13 jours de prévisions du
    /// disque interne rejouées point par point (`outils/rejoue-seuils.py`).
    /// À 30 jours, la règle était vraie 43 % du temps et tenait 38 % du
    /// journal ; or entre 14 et 30 jours l'échéance annoncée avait disparu
    /// 24 h plus tard dans 72 % des cas (145 sur 201), et le disque n'était
    /// plus plein 3 jours après que dans 29 % des cas. Sous 14 jours elle
    /// tient deux fois plus (33 % disparues). À 14 jours : vraie 27 % du
    /// temps, une semaine d'avertissement avant l'alerte des 7 jours.
    static let forecastSoonDays: Double = 14                // règle 9

    // Seuils non provisoires : ce sont ceux du tri des volumes et du
    // remplissage de la barre (bloc 3). Les partager est la garantie que le
    // panneau ne peut pas afficher un verdict serein au-dessus d'une barre en
    // alerte.
    static let volumeAlertFraction: Double = 0.95
    static let volumeWarningFraction: Double = 0.90
    static let forecastAlertDays: Double = 7

    /// Fenêtre des incidents : 24 h GLISSANTES, pas la journée civile. À 9 h
    /// du matin, une frontière de minuit effacerait exactement les plantages
    /// qui expliquent la matinée.
    static let incidentWindow: TimeInterval = 24 * 3600

    // MARK: - État d'hystérésis (mémoire vive, rien de persisté)

    private var trueSince: [Int: Date] = [:]
    private var falseSince: [Int: Date] = [:]
    private var active: Set<Int> = []
    /// Dernier contenu rendu par règle, et son heure. Une règle maintenue
    /// alors que sa condition vient de retomber n'a plus de contenu calculable
    /// à cet instant : on réaffiche le dernier mesuré, daté, plutôt qu'une
    /// phrase inventée.
    private var lastContent: [Int: (candidate: Candidate, at: Date)] = [:]
    private var current: Verdict?
    private var lastChange: Date = .distantPast
    /// La règle qui gagne sans être affichée, et depuis quand (`holdDelay`).
    private var challenger: (rule: Int, since: Date)?

    // MARK: - Évaluation

    /// Rend le verdict hystérisé. À appeler à chaque relevé, depuis la file
    /// d'échantillonnage.
    func evaluate(_ input: VerdictInput, now: Date = Date()) -> Verdict {
        let found = Self.candidates(input, now: now)
        var byRule: [Int: Candidate] = [:]
        for candidate in found {
            byRule[candidate.rule] = candidate
            lastContent[candidate.rule] = (candidate, now)
        }

        // Règles 1 à 10 : entrée à 3 s, sortie à 10 s.
        //
        // Sauf au tout premier relevé. Le délai d'entrée empêche un relevé
        // fugace de CHANGER un verdict établi ; au lancement il n'y a rien à
        // changer, et l'appliquer quand même faisait tomber la liste à vide,
        // donc sur la règle 12. Constaté par le journal dès sa première
        // minute : « La machine suit » à t+0, puis « Macintosh HD est plein à
        // 96 % » à t+5. Une absence de verdict ne doit jamais se lire comme un
        // feu vert.
        let firstEvaluation = current == nil
        for rule in 1...10 {
            if byRule[rule] != nil {
                falseSince[rule] = nil
                let since = trueSince[rule] ?? now
                trueSince[rule] = since
                if firstEvaluation || now.timeIntervalSince(since) >= Self.entryDelay { active.insert(rule) }
            } else {
                trueSince[rule] = nil
                let since = falseSince[rule] ?? now
                falseSince[rule] = since
                if now.timeIntervalSince(since) >= Self.releaseDelay { active.remove(rule) }
            }
        }

        // Règle 11 : elle hérite de l'hystérésis d'`ExportDetector` (deux
        // relevés au-dessus du seuil, 30 s de grâce) et n'est pas ré-hystérisée.
        // La ré-hystériser retarderait de 3 s un état déjà confirmé deux fois.
        if byRule[11] != nil { active.insert(11) } else { active.remove(11) }

        // L'export qualifie et ne concourt pas : quand il tourne, la règle 10
        // est supprimée du barème — le processeur au plafond pendant un export
        // est l'état normal et souhaité.
        var ordered = active.sorted()
        if input.export != nil { ordered.removeAll { $0 == 10 } }

        let winner = ordered.first ?? 12
        var retained = winner
        // Le gagnant ne prend la place de l'affiché que s'il est plus grave,
        // ou s'il gagne depuis `holdDelay` ; et jamais deux fois en 10 s. Le
        // contenu, lui, continue de suivre les mesures : on réaffiche la règle
        // tenue avec les chiffres du relevé courant quand elle en a.
        if let current, current.rule != winner {
            if challenger?.rule != winner { challenger = (winner, now) }
            if content(for: current.rule, byRule, input: input, now: now) != nil {
                let worse = Self.rank(content(for: winner, byRule, input: input, now: now)?.level ?? .muted)
                    > Self.rank(current.level)
                let held = now.timeIntervalSince(challenger?.since ?? now)
                let exportOver = current.rule == 11
                if now.timeIntervalSince(lastChange) < Self.minInterval
                    || (!worse && !exportOver && held < Self.holdDelay) {
                    retained = current.rule
                }
            }
        } else {
            challenger = nil
        }

        guard let candidate = content(for: retained, byRule, input: input, now: now) else {
            // Ne peut arriver que si la règle 12 elle-même ne se rend pas,
            // c'est-à-dire avant le premier relevé.
            return Verdict.pending
        }

        // Deux libellés au maximum, dans l'ordre du barème. La règle 11 n'y
        // figure jamais : l'export est déjà dans la ligne de preuve.
        let also = Self.labels(ordered.filter { $0 != retained && $0 != 11 }
                                      .compactMap { content(for: $0, byRule, input: input, now: now) },
                               besides: candidate.subject)

        let verdict = Self.assemble(candidate, also: also, export: input.export)
        // Le tout premier verdict n'est pas un CHANGEMENT : le compter comme
        // tel verrouillerait « La machine suit » pendant 10 s au lancement,
        // alors même que la ligne « et aussi » nommerait déjà un disque plein.
        if let previous = current, previous.rule != verdict.rule {
            lastChange = now
            challenger = nil
        }
        current = verdict
        return verdict
    }

    /// Gravité, pour décider qu'un verdict en AGGRAVE un autre.
    private static func rank(_ level: VerdictLevel) -> Int {
        switch level {
        case .muted: return 0
        case .data: return 1
        case .warning: return 2
        case .alert: return 3
        }
    }

    /// Le même barème SANS hystérésis, pour `--probe` : un relevé unique ne
    /// peut pas décider d'un maintien de 3 s. Rend aussi les autres règles
    /// actives, avec leur rang, pour que le relevé se compare à l'interface.
    static func instant(_ input: VerdictInput,
                        now: Date = Date()) -> (verdict: Verdict, others: [(rule: Int, short: String)]) {
        let found = candidates(input, now: now)
        var byRule: [Int: Candidate] = [:]
        for candidate in found { byRule[candidate.rule] = candidate }

        var ordered = found.map(\.rule)
        if input.export != nil { ordered.removeAll { $0 == 10 } }

        let retained = ordered.first ?? 12
        guard let candidate = byRule[retained] ?? fallback(input) else {
            return (Verdict.pending, [])
        }
        // `--probe` liste TOUTES les autres règles actives, doublons compris :
        // c'est un relevé de débogage, il doit montrer le barème tel qu'il est.
        let actives = ordered.filter { $0 != retained && $0 != 11 }.compactMap { byRule[$0] }
        let others = actives.map { (rule: $0.rule, short: $0.short) }
        let also = labels(actives, besides: candidate.subject)
        return (assemble(candidate, also: also, export: input.export), others)
    }

    /// Contenu d'une règle, en retombant sur le dernier mesuré si sa condition
    /// vient de retomber pendant le délai de sortie.
    private func content(for rule: Int, _ byRule: [Int: Candidate],
                         input: VerdictInput, now: Date) -> Candidate? {
        if let candidate = byRule[rule] { return candidate }
        if rule == 12 { return Self.fallback(input) }
        guard let kept = lastContent[rule] else { return nil }
        // Maintenue par un délai : ses chiffres datent, et la preuve le dit.
        var candidate = kept.candidate
        let age = now.timeIntervalSince(kept.at)
        if age >= 60 { candidate.evidence += " · relevé il y a \(Fmt.duration(age))" }
        return candidate
    }

    private static func assemble(_ candidate: Candidate,
                                 also: [String],
                                 export: ExportActivity?) -> Verdict {
        var evidence = candidate.evidence
        // L'export s'ajoute à la preuve de N'IMPORTE QUEL verdict : c'est un
        // mode de la journée, pas un rang de gravité. Sauf sur la règle 11,
        // qui le dit déjà.
        if export != nil, candidate.rule != 11 { evidence += " · export en cours" }
        return Verdict(rule: candidate.rule,
                       ruleName: candidate.name,
                       level: candidate.level,
                       symbol: candidate.symbol,
                       phrase: candidate.phrase,
                       evidence: evidence,
                       also: also,
                       object: candidate.object)
    }

    /// Toutes les règles vraies à cet instant, assemblées, dans l'ordre du
    /// barème et sans hystérésis : `--probe` donne ainsi le conseil de
    /// chacune, y compris de celles que la règle retenue masque.
    static func actives(_ input: VerdictInput, now: Date = Date()) -> [Verdict] {
        candidates(input, now: now).map { assemble($0, also: [], export: input.export) }
    }

    // MARK: - Le barème

    private struct Candidate {
        var rule: Int
        var name: String
        var level: VerdictLevel
        var symbol: String
        var phrase: String
        var evidence: String
        /// Libellé court, pour la ligne « et aussi ».
        var short: String
        /// L'objet dont la règle parle. Deux règles peuvent porter sur le même :
        /// un volume à 96 % satisfait la règle 3 ET la règle 8, et « et aussi ·
        /// disque à 96 % » sous « Rushes est plein à 96 % » ne dirait rien de
        /// plus. « Et aussi » existe pour montrer l'AUTRE problème.
        var subject: String
        /// Le volume ou l'application nommés, pour le conseil.
        var object: VerdictObject? = nil
    }

    /// Deux libellés au maximum, un par objet, dans l'ordre du barème.
    private static func labels(_ candidates: [Candidate], besides subject: String) -> [String] {
        var seen: Set<String> = [subject]
        var out: [String] = []
        for candidate in candidates where !seen.contains(candidate.subject) {
            seen.insert(candidate.subject)
            out.append(candidate.short)
            if out.count == 2 { break }
        }
        return out
    }

    /// Les règles dont la condition tient à cet instant, dans l'ordre du
    /// barème. La règle 12 n'y figure pas : c'est le « sinon ».
    private static func candidates(_ input: VerdictInput, now: Date) -> [Candidate] {
        var out: [Candidate] = []

        // 1 — pression mémoire critique.
        if input.memory.pressureLevel == 4 {
            out.append(Candidate(
                rule: 1, name: "pression mémoire critique",
                level: .alert, symbol: "memorychip.fill",
                phrase: "La mémoire est saturée",
                evidence: ["pression critique", swapClause(input.memory), editingClause(input)]
                    .compactMap { $0 }.joined(separator: " · "),
                short: "mémoire saturée", subject: "pression"))
        }

        // 2 — macOS a tué un processus faute de mémoire.
        if let killed = latest(.jetsam, input, now: now) {
            out.append(Candidate(
                rule: 2, name: "processus tué par macOS dans les 24 h",
                level: .alert, symbol: "exclamationmark.triangle.fill",
                phrase: "macOS a tué un processus",
                evidence: "faute de mémoire · \(ago(killed.date, now: now))",
                short: "processus tué", subject: "processus tué"))
        }

        // 3 — un volume occupé à 95 % ou plus.
        //
        // L'occupation entre au barème, et pas seulement la prévision :
        // `HistoryStore.forecast` rend nil sous 6 h d'observation calme, ce qui
        // est le cas courant après un redémarrage ou un remontage du SSD
        // externe. Sans cette règle, un disque à 96 % afficherait « La machine
        // suit ».
        if let volume = fullest(input, atLeast: volumeAlertFraction) {
            out.append(Candidate(
                rule: 3, name: "volume à \(Int(volumeAlertFraction * 100)) % ou plus",
                level: .alert, symbol: "externaldrive.fill.badge.exclamationmark",
                phrase: fullPhrase(volume),
                evidence: "\(Fmt.bytes(volume.available)) libres · \(trendClause(volume, input))",
                short: "disque à \(occupancy(volume.usedFraction))",
                subject: "volume " + volume.historyKey,
                object: .volume(key: volume.historyKey)))
        }

        // 4 — un volume plein dans moins de 7 jours.
        if let (volume, days) = soonest(input, under: forecastAlertDays) {
            out.append(Candidate(
                rule: 4, name: "volume plein dans moins de \(Int(forecastAlertDays)) jours",
                level: .alert, symbol: "externaldrive.fill.badge.exclamationmark",
                phrase: etaPhrase(volume, days: days),
                evidence: "\(Fmt.bytes(volume.available)) libres · \(rateClause(volume, input))",
                short: "disque presque plein", subject: "volume " + volume.historyKey,
                object: .volume(key: volume.historyKey)))
        }

        // 5 — plantage Adobe dans les 24 h glissantes.
        let crashes = recent(.crash, input, now: now)
        if let last = crashes.first {
            let count = crashes.count
            out.append(Candidate(
                rule: 5, name: "plantage Adobe dans les 24 h",
                level: .alert, symbol: "exclamationmark.triangle.fill",
                phrase: crashPhrase(app: last.app, count: count),
                evidence: "dernier \(ago(last.date, now: now)) · \(count) en 24 h",
                short: count > 1 ? "\(count) plantages en 24 h" : "1 plantage en 24 h",
                subject: "plantage"))
        }

        // 6 — pression mémoire élevée.
        if input.memory.pressureLevel == 2 {
            out.append(Candidate(
                rule: 6, name: "pression mémoire élevée",
                level: .warning, symbol: "memorychip",
                phrase: "La mémoire commence à manquer",
                evidence: "pression élevée · \(swapClause(input.memory) ?? "aucun swap")",
                short: "pression élevée", subject: "pression"))
        }

        // 7 — le swap monte.
        if input.memory.swapUsed > 0, let rise = swapRise(input, now: now), rise >= swapRisePerHour {
            out.append(Candidate(
                rule: 7, name: "swap en hausse d'au moins 1 Gio sur l'heure",
                level: .warning, symbol: "memorychip",
                phrase: "Le swap monte",
                evidence: "\(Fmt.memory(input.memory.swapUsed)) sur disque · +\(Fmt.memory(rise)) en une heure",
                short: "swap en hausse", subject: "swap"))
        }

        // 8 — un volume occupé à 90 % ou plus.
        if let volume = fullest(input, atLeast: volumeWarningFraction) {
            out.append(Candidate(
                rule: 8, name: "volume à \(Int(volumeWarningFraction * 100)) % ou plus",
                level: .warning, symbol: "externaldrive",
                phrase: fullPhrase(volume),
                evidence: "\(Fmt.bytes(volume.available)) libres · \(trendClause(volume, input))",
                short: "disque à \(occupancy(volume.usedFraction))",
                subject: "volume " + volume.historyKey,
                object: .volume(key: volume.historyKey)))
        }

        // 9 — un volume plein dans moins de 30 jours.
        if let (volume, days) = soonest(input, under: forecastSoonDays) {
            out.append(Candidate(
                rule: 9, name: "volume plein dans moins de \(Int(forecastSoonDays)) jours",
                level: .warning, symbol: "externaldrive",
                phrase: etaPhrase(volume, days: days),
                evidence: "\(Fmt.bytes(volume.available)) libres · \(rateClause(volume, input))",
                short: "disque bientôt plein", subject: "volume " + volume.historyKey,
                object: .volume(key: volume.historyKey)))
        }

        // 10 — le processeur est pris par autre chose que le montage.
        // Supprimée plus haut quand un export tourne ; la condition la rejette
        // déjà ici pour que `--probe` n'en fasse jamais état non plus.
        if input.export == nil, input.cpu.total > busyMachine,
           let group = input.processes.max(by: { $0.cpu < $1.cpu }),
           AppKind.of(bundleId: group.bundleId) == .other, group.cpu > busyGroup {
            out.append(Candidate(
                rule: 10, name: "processeur occupé hors montage",
                level: .warning, symbol: "cpu",
                phrase: busyPhrase(group.name),
                evidence: "\(Fmt.cpu(group.cpu)) d'un cœur · processeur à \(Fmt.percent(input.cpu.total))",
                short: "processeur occupé", subject: "processeur",
                object: .app(bundleId: group.bundleId)))
        }

        // 11 — export en cours.
        if let export = input.export {
            out.append(Candidate(
                rule: 11, name: "export en cours",
                level: .data, symbol: "film",
                phrase: "Export en cours",
                evidence: "\(export.app) · depuis \(Fmt.duration(export.duration)) · processeur à \(Fmt.percent(input.cpu.total))",
                short: "export en cours", subject: "export"))
        }

        return out
    }

    /// 12 — sinon.
    ///
    /// N'écrit jamais « disques dégagés » : elle nomme l'espace libre du volume
    /// le plus contraint et, si sa tendance manque, elle le dit. Une absence de
    /// mesure ne doit pas se lire comme un feu vert.
    private static func fallback(_ input: VerdictInput) -> Candidate? {
        var facts = [memoryClause(input.memory), swapClause(input.memory) ?? "aucun swap"]
        if let volume = bySeverity(input).first {
            facts.append("\(volume.name) \(Fmt.bytes(volume.available)) libres")
            if input.forecasts[volume.historyKey]?.daysUntilFull == nil {
                facts.append(trendClause(volume, input))
            }
        }
        return Candidate(rule: 12, name: "rien à signaler",
                         level: .muted, symbol: "checkmark.circle",
                         phrase: "La machine suit",
                         evidence: facts.joined(separator: " · "),
                         short: "rien à signaler", subject: "repos")
    }

    // MARK: - Phrases

    /// Coupe un nom variable avant insertion dans la phrase.
    ///
    /// Deux bornes, et la plus serrée gagne : celle du catalogue (14 pour un
    /// volume, 12 pour une application) et les 30 caractères de la phrase
    /// entière, que le bloc 0 affiche sans jamais tronquer. « Macintosh HD
    /// plein dans ~21 jours » tient dans la première et dépasse la seconde.
    private static func shorten(_ name: String, cap: Int, around rest: String) -> String {
        clip(name, to: min(cap, 30 - rest.count))
    }

    /// Coupe avec des points de suspension, jamais au ras du mot : « Adobe
    /// Premie 21,4 Gio » se lit comme un nom d'application inconnu, « Adobe
    /// Premi… » se lit comme un nom tronqué.
    private static func clip(_ name: String, to limit: Int) -> String {
        let limit = max(1, limit)
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)) + "…"
    }

    private static func fullPhrase(_ volume: VolumeSample) -> String {
        let rest = " est plein à \(occupancy(volume.usedFraction))"
        return shorten(volume.name, cap: 14, around: rest) + rest
    }

    private static func etaPhrase(_ volume: VolumeSample, days: Double) -> String {
        // `Fmt.fullBy`, partagé avec la carte des disques : « plein vers
        // lundi » dans la semaine, « plein dans ~N mois » au-delà.
        let rest = " " + Fmt.fullBy(days: days)
        return shorten(volume.name, cap: 14, around: rest) + rest
    }

    private static func crashPhrase(app: String, count: Int) -> String {
        let rest = count > 1 ? " a planté \(count) fois" : " a planté"
        return shorten(Fmt.appName(app), cap: 12, around: rest) + rest
    }

    private static func busyPhrase(_ app: String) -> String {
        let rest = " occupe le processeur"
        return shorten(Fmt.appName(app), cap: 12, around: rest) + rest
    }

    // MARK: - Clauses de preuve

    private static func swapClause(_ memory: MemorySample) -> String? {
        // Base 1024 pour la mémoire et le swap : règle dure n°3.
        memory.swapUsed > 0 ? "swap \(Fmt.memory(memory.swapUsed))" : nil
    }

    /// « 20,9 Gio sur 32 » : l'unité ne s'écrit qu'une fois, comme dans le
    /// catalogue. On ne l'efface du total que si les deux valeurs tombent dans
    /// la même unité — « 900 Mio sur 32 » serait faux d'un facteur 33.
    private static func memoryClause(_ memory: MemorySample) -> String {
        let used = Fmt.memory(memory.used)
        let total = Fmt.memory(memory.total, digits: 0)
        let separator = "\u{00A0}"
        let usedUnit = used.components(separatedBy: separator).last ?? ""
        let totalParts = total.components(separatedBy: separator)
        if totalParts.count == 2, totalParts[1] == usedUnit {
            return "\(used) sur \(totalParts[0])"
        }
        return "\(used) sur \(total)"
    }

    /// La mémoire de l'application de montage, pas celle de la machine : c'est
    /// Premiere qui remplit la RAM, et le dire nommément est ce qui rend le
    /// verdict contestable.
    private static func editingClause(_ input: VerdictInput) -> String? {
        let editing = input.processes
            .filter { AppKind.of(bundleId: $0.bundleId) == .editing }
            .max { $0.footprint < $1.footprint }
        guard let editing, editing.footprint > 0 else { return nil }
        return "\(clip(Fmt.appName(editing.name), to: 14)) \(Fmt.memory(editing.footprint))"
    }

    /// Prévision, ou raison de son absence. Les trois silences de
    /// `HistoryStore.forecast` ne se disent pas de la même façon : ne pas savoir
    /// encore n'est pas la même chose que ne plus savoir.
    private static func trendClause(_ volume: VolumeSample, _ input: VerdictInput) -> String {
        if let forecast = input.forecasts[volume.historyKey] { return forecast.trendText }
        guard let age = input.volumeAges[volume.historyKey] else { return "tendance : premier relevé" }
        return age > HistoryStore.maxStaleness ? "tendance : relevés trop anciens"
                                               : "tendance en cours de calcul"
    }

    /// Le rythme de remplissage. `bytesPerDay` est négatif quand le volume se
    /// remplit. La fenêtre est celle d'où vient ce rythme : 72 h, ou 24 h quand
    /// les dernières 24 h vont moins vite (`HistoryStore.forecast`).
    private static func rateClause(_ volume: VolumeSample, _ input: VerdictInput) -> String {
        guard let forecast = input.forecasts[volume.historyKey], forecast.bytesPerDay < 0 else {
            return trendClause(volume, input)
        }
        return "\(Fmt.bytes(-forecast.bytesPerDay, digits: 1)) par jour sur \(Int(forecast.window / 3600)) h"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        "il y a \(Fmt.duration(now.timeIntervalSince(date)))"
    }

    // MARK: - Sélections

    private static func recent(_ kind: IncidentKind, _ input: VerdictInput, now: Date) -> [Incident] {
        let start = now.addingTimeInterval(-incidentWindow)
        return input.incidents.filter { $0.kind == kind && $0.date >= start }
            .sorted { $0.date > $1.date }
    }

    private static func latest(_ kind: IncidentKind, _ input: VerdictInput, now: Date) -> Incident? {
        recent(kind, input, now: now).first
    }

    private static func fullest(_ input: VerdictInput, atLeast fraction: Double) -> VolumeSample? {
        input.volumes.filter { $0.usedFraction >= fraction }
            .max { $0.usedFraction < $1.usedFraction }
    }

    private static func soonest(_ input: VerdictInput, under days: Double) -> (VolumeSample, Double)? {
        input.volumes
            .compactMap { volume -> (VolumeSample, Double)? in
                guard let d = input.forecasts[volume.historyKey]?.daysUntilFull, d < days else { return nil }
                return (volume, d)
            }
            .min { $0.1 < $1.1 }
    }

    /// L'occupation d'un volume, arrondie VERS LE BAS.
    ///
    /// `Fmt.percent` arrondit au plus proche : un disque à 94,8 % s'affichait
    /// « plein à 95 % » en orange, alors que la règle 3 ne passe au rouge qu'à
    /// partir de 95 %. La phrase annonçait un seuil que le barème ne
    /// considérait pas franchi. Arrondi vers le bas, le chiffre affiché ne
    /// touche 95 — ou 90 — qu'au moment exact où la règle se déclenche.
    private static func occupancy(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))\u{00A0}%"
    }

    /// Le tri du bloc 3, réutilisé ici pour nommer « le volume le plus
    /// contraint ». Indépendant du point de montage, qui n'est pas stable :
    /// le SSD externe remonte tantôt en « Ssd », tantôt en « Ssd 2 ».
    /// Place un volume à 96 % SANS prévision en tête, ce qu'un tri sur la seule
    /// échéance ne fait pas.
    static func bySeverity(_ input: VerdictInput) -> [VolumeSample] {
        func severity(_ volume: VolumeSample) -> Int {
            let days = input.forecasts[volume.historyKey]?.daysUntilFull
            if volume.usedFraction >= volumeAlertFraction || (days.map { $0 < forecastAlertDays } ?? false) { return 0 }
            if volume.usedFraction >= volumeWarningFraction || (days.map { $0 < forecastSoonDays } ?? false) { return 1 }
            return 2
        }
        return input.volumes.sorted { a, b in
            let sa = severity(a), sb = severity(b)
            if sa != sb { return sa < sb }
            let da = input.forecasts[a.historyKey]?.daysUntilFull ?? .greatestFiniteMagnitude
            let db = input.forecasts[b.historyKey]?.daysUntilFull ?? .greatestFiniteMagnitude
            if da != db { return da < db }
            return a.usedFraction > b.usedFraction
        }
    }

    /// Hausse du swap sur la dernière heure, en octets, ou `nil` faute
    /// d'historique. Comparée à la mesure du moment et non au dernier point
    /// enregistré : la série n'avance que toutes les 10 s.
    private static func swapRise(_ input: VerdictInput, now: Date) -> Double? {
        let t = now.timeIntervalSince1970
        guard let oldest = input.series.first(where: { $0.t >= t - 3600 }) else { return nil }
        // Moins de cinq minutes d'historique : parler d'une hausse « en une
        // heure » serait extrapoler, ce que la ligne de preuve s'interdit.
        guard t - oldest.t >= 300 else { return nil }
        return Double(input.memory.swapUsed) - oldest.swap
    }
}

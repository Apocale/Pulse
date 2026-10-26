import Foundation

/// Ce que le verdict conseille : une ligne chiffrée, son détail, et au plus
/// un bouton.
///
/// Le verdict dit ce qui ne va pas, sa ligne de preuve dit pourquoi ; le
/// conseil dit quoi faire, avec un chiffre qu'on retrouve dans `--probe`
/// (section CONSEIL). Il ne déduit rien que les relevés ne montrent : « Vivaldi
/// tient 5,9 Go » est la colonne Mémoire du Moniteur d'activité, « ~8 jours à
/// ce rythme » est l'espace libre d'un disque divisé par la pente de l'autre.
struct Advice: Equatable {
    /// La règle du verdict qui l'a produit.
    var rule: Int
    /// Une seule ligne : le bandeau n'a pas de hauteur à céder (le panneau
    /// fait 1 216 pt sur 1 290 utiles).
    var text: String
    /// Les chiffres et le calcul, pour l'infobulle et `--probe`.
    var detail: String
    /// Le bouton, s'il y en a un.
    var action: AdviceAction?
}

/// Ce que le bouton du conseil ouvre. Trois destinations, toutes sans
/// danger : une fenêtre s'ouvre, rien ne se ferme, rien ne s'efface, aucune
/// application ne quitte. Fermer une app reste le geste d'Isma, dans le
/// Moniteur d'activité ou dans l'app elle-même.
///
/// Rien ici n'agit : l'action ne s'exécute que dans la vue, au clic
/// (`AdviceView`). Les tests et `--probe` ne manipulent que cette valeur.
enum AdviceAction: Equatable {
    /// Le volume, dans une fenêtre du Finder.
    case finder(path: String, name: String)
    /// Le Moniteur d'activité, où l'on voit et ferme ce qui pèse.
    case activityMonitor
    /// Réglages Système › Général › Stockage : ce qui occupe le disque
    /// interne, et les recommandations de macOS.
    case storageSettings

    /// Le libellé du bouton, court : il tient sous le conseil.
    var label: String {
        switch self {
        case .finder(_, let name): return "Ouvrir \(Advisor.clip(name, to: 14))"
        case .activityMonitor:     return "Moniteur d'activité"
        case .storageSettings:     return "Réglages de stockage"
        }
    }

    /// Ce que VoiceOver annonce, et l'infobulle du bouton.
    var spoken: String {
        switch self {
        case .finder(_, let name): return "Ouvrir \(name) dans le Finder"
        case .activityMonitor:     return "Ouvrir le Moniteur d'activité"
        case .storageSettings:     return "Ouvrir les réglages de stockage de macOS"
        }
    }

    /// Ce que ferait le bouton — `--probe` le dit sans jamais le faire.
    var probeText: String {
        switch self {
        case .finder(let path, _): return "ouvrirait \(path) dans le Finder"
        case .activityMonitor:     return "ouvrirait le Moniteur d'activité (com.apple.ActivityMonitor)"
        case .storageSettings:     return "ouvrirait Réglages Système › Général › Stockage"
        }
    }

    /// Symbole SF du bouton.
    var symbol: String {
        switch self {
        case .finder:          return "folder"
        case .activityMonitor: return "gauge.with.dots.needle.67percent"
        case .storageSettings: return "internaldrive"
        }
    }
}

/// Le conseil de chaque règle, calculé sur les relevés que le `Sampler`
/// publie déjà : rien ne tourne panneau fermé. Fonction pure — le panneau,
/// `--probe` et les tests passent par le même code.
enum Advisor {

    // MARK: - Seuils

    /// Une app ne vaut d'être fermée que si elle tient au moins 1 Go : moins
    /// de 3 % de la mémoire de la machine, et bien moins que ce que le swap
    /// gagne ou perd en quelques minutes de montage (relevé du 11/10 dans
    /// l'historique : +6,5 Go en 26 min, Premiere ouvert). Conseiller de
    /// fermer une app de 300 Mo pour une pression mémoire serait un geste
    /// pour rien.
    static let worthClosing: UInt64 = 1 << 30

    /// Le conseil d'un disque vise le seuil d'AVERTISSEMENT du barème (90 %),
    /// pas celui de l'alerte : sous 95 %, la règle 8 prendrait le relais et
    /// le verdict resterait orange. Partagé avec `VerdictEngine`.
    static var targetFraction: Double { VerdictEngine.volumeWarningFraction }

    // MARK: - Entrée

    /// Le conseil du verdict affiché, ou nil s'il n'y a rien à faire (« La
    /// machine suit », un export en cours) ou rien de chiffrable (un volume
    /// démonté entre-temps).
    ///
    /// Tout ce qu'il chiffre se relit dans `--probe`, qui passe par ici avec
    /// son propre relevé : PAR APPLICATION pour les apps, VOLUMES pour les
    /// disques, la section CONSEIL pour le calcul.
    ///
    /// `ingestions` : les écritures massives EN COURS, telles que les détecte
    /// et les nomme le chantier 05 (`DiskActivity`, `disques.json` pour
    /// `--probe`). Leur détection n'est pas refaite ici.
    static func advice(for verdict: Verdict, _ input: VerdictInput,
                       ingestions: [Ingestion] = [], now: Date = Date()) -> Advice? {
        switch verdict.rule {
        case 1, 2, 6, 7: return memory(verdict.rule, input)
        case 3, 8:       return explained(full(verdict, input), verdict, input, ingestions)
        case 4, 9:       return explained(filling(verdict, input), verdict, input, ingestions)
        case 5:          return crash(input, now: now)
        case 10:         return processor(verdict, input)
        default:         return nil
        }
    }

    // MARK: - Mémoire : règles 1, 2, 6, 7

    /// Les applications qu'Isma peut fermer, la plus lourde d'abord : une
    /// app à bundle, hors montage et hors export, hors agents du système
    /// (`/System/Library/`), hors Pulse. Les services sans bundle — décodeurs
    /// vidéo, démons — ne se ferment pas d'un geste.
    static func closable(_ processes: [ProcessGroup]) -> [ProcessGroup] {
        processes
            .filter { group in
                guard let path = group.bundlePath, !path.hasPrefix("/System/Library/") else { return false }
                return AppKind.of(bundleId: group.bundleId) == .other && group.bundleId != "com.isma.pulse"
            }
            .sorted { $0.footprint > $1.footprint }
    }

    private static func memory(_ rule: Int, _ input: VerdictInput) -> Advice? {
        let context = "pression \(input.memory.pressureLabel) · swap \(Fmt.memory(input.memory.swapUsed))"
        if let app = closable(input.processes).first, app.footprint >= worthClosing {
            let name = clip(Fmt.appName(app.name), to: 14)
            // Le geste d'abord, le chiffre ensuite : à côté de « La mémoire
            // commence à manquer », la ligne n'a que 47 caractères (rendu
            // `--conseils`), et « Vivaldi tient 6,0 Go : le fermer en libère
            // autant » se coupait avant son verbe.
            return Advice(
                rule: rule,
                text: "Fermer \(name) libère \(Fmt.memory(app.footprint))",
                detail: "\(Fmt.appName(app.name)) : \(Fmt.memory(app.footprint)) en \(app.processCount) processus, "
                    + "la colonne Mémoire du Moniteur d'activité, la plus lourde des apps hors montage. "
                    + context,
                action: .activityMonitor)
        }
        // Rien à fermer d'utile : le dire, c'est épargner une recherche.
        let editing = input.processes
            .filter { AppKind.of(bundleId: $0.bundleId) == .editing }
            .max { $0.footprint < $1.footprint }
        guard let editing, editing.footprint >= worthClosing else { return nil }
        let name = clip(Fmt.appName(editing.name), to: 14)
        return Advice(
            rule: rule,
            text: "Seul \(name) pèse : \(Fmt.memory(editing.footprint))",
            detail: "Aucune app hors montage ne tient \(Fmt.memory(worthClosing, digits: 0)) ou plus : "
                + "en fermer une ne changerait rien. " + context,
            action: .activityMonitor)
    }

    // MARK: - Disques : règles 3, 4, 8, 9

    /// Où déplacer : un disque EXTERNE, accessible en écriture (les volumes
    /// en lecture seule sont déjà écartés par `DiskMonitor`), qui n'est pas
    /// lui-même au seuil d'avertissement, le plus libre. Jamais le disque
    /// interne : le swap et les caches de Premiere y vivent, y verser des
    /// rushes déplacerait le problème.
    static func destination(excluding volume: VolumeSample, _ input: VerdictInput) -> VolumeSample? {
        input.volumes
            .filter { !$0.isInternal && $0.historyKey != volume.historyKey && $0.usedFraction < targetFraction }
            .max { $0.available < $1.available }
    }

    /// Octets à retirer pour passer SOUS le seuil d'avertissement, arrondis
    /// au Go supérieur : « libérer 43 Go » doit suffire, pas presque.
    static func bytesToFree(_ volume: VolumeSample) -> UInt64 {
        let ceiling = Double(volume.total) * targetFraction
        let excess = Double(volume.used) - ceiling
        guard excess > 0 else { return 0 }
        return UInt64((excess / 1e9).rounded(.down) + 1) * 1_000_000_000
    }

    private static func button(_ volume: VolumeSample) -> AdviceAction {
        volume.isInternal ? .storageSettings : .finder(path: volume.path, name: volume.name)
    }

    private static func subject(_ verdict: Verdict, _ input: VerdictInput) -> VolumeSample? {
        guard case .volume(let key) = verdict.object else { return nil }
        return input.volumes.first { $0.historyKey == key }
    }

    /// Règles 3 et 8 : un volume occupé à 90 % ou plus.
    private static func full(_ verdict: Verdict, _ input: VerdictInput) -> Advice? {
        guard let volume = subject(verdict, input) else { return nil }
        let toFree = bytesToFree(volume)
        let occupied = "\(volume.name) : \(Fmt.bytes(volume.used)) occupés sur \(Fmt.bytes(volume.total)) "
            + "(\(Fmt.occupancy(volume.usedFraction)))"
        guard toFree > 0 else {
            // Verdict tenu par le délai alors que le disque est déjà repassé
            // sous le seuil : rien à libérer, on ne l'invente pas.
            return nil
        }
        let amount = Fmt.bytes(toFree, digits: 0)
        let under = "En retirer \(amount) le ramène sous \(Fmt.percent(targetFraction)), le seuil du verdict."
        if let other = destination(excluding: volume, input), other.available >= toFree {
            // Le geste et son chiffre d'abord : coupée, la ligne perd la
            // parenthèse, pas la quantité.
            return Advice(
                rule: verdict.rule,
                text: "Déplacer \(amount) vers \(clip(other.name, to: 14)) (\(Fmt.bytes(other.available)) libres)",
                detail: "\(occupied). \(under) \(other.name) a \(Fmt.bytes(other.available)) libres.",
                action: button(volume))
        }
        return Advice(
            rule: verdict.rule,
            text: "Libérer \(amount) le ramène sous \(Fmt.percent(targetFraction))",
            detail: "\(occupied). \(under) Aucun autre disque externe n'a cette place.",
            action: button(volume))
    }

    /// Une écriture massive EN COURS sur ce disque dit POURQUOI il se
    /// remplit : « Ssd 2 plein vers mercredi » cesse d'être une alarme
    /// anonyme quand on lit « Copie de carte en cours (ffmpeg, 1,3 Go) ».
    /// Elle prend la ligne — une seule, le bandeau n'en a pas d'autre — et
    /// le geste passe dans le détail. La plus grosse si plusieurs écrivent.
    private static func explained(_ base: Advice?, _ verdict: Verdict, _ input: VerdictInput,
                                  _ ingestions: [Ingestion]) -> Advice? {
        guard let volume = subject(verdict, input),
              let writing = ingestions
                .filter({ $0.active && $0.targetKey == volume.historyKey })
                .max(by: { $0.bytes < $1.bytes }) else { return base }
        let who = [writing.app, Fmt.bytes(writing.bytes)].compactMap { $0 }.joined(separator: ", ")
        var detail = "\(writing.label) vers \(volume.name) depuis \(Fmt.duration(writing.duration)) : "
            + "\(Fmt.bytes(writing.bytes)) écrits"
        if writing.rate > 0 { detail += ", \(Fmt.bytes(writing.rate))/s" }
        if let app = writing.app { detail += ", par \(app)" }
        detail += "."
        if let base { detail += " Ensuite : \(base.text). \(base.detail)" }
        return Advice(rule: verdict.rule, text: "\(writing.label) en cours (\(who))",
                      detail: detail, action: base?.action ?? button(volume))
    }

    /// Règles 4 et 9 : un volume qui sera plein dans moins de 7 ou 30 jours.
    private static func filling(_ verdict: Verdict, _ input: VerdictInput) -> Advice? {
        guard let volume = subject(verdict, input) else { return nil }
        guard let forecast = input.forecasts[volume.historyKey], forecast.bytesPerDay < 0 else {
            return full(verdict, input)
        }
        let perDay = -forecast.bytesPerDay
        let pace = "\(volume.name) se remplit de \(Fmt.bytes(perDay, digits: 1)) par jour "
            + "(rythme des \(Int(forecast.window / 3600)) h) et a \(Fmt.bytes(volume.available)) libres."
        if let other = destination(excluding: volume, input) {
            let days = Double(other.available) / perDay
            return Advice(
                rule: verdict.rule,
                text: "\(clip(other.name, to: 14)) a \(Fmt.bytes(other.available)) libres, \(Fmt.days(days)) à ce rythme",
                detail: "\(pace) \(other.name) a \(Fmt.bytes(other.available)) libres : "
                    + "\(Fmt.bytes(other.available)) ÷ \(Fmt.bytes(perDay, digits: 1)) par jour = \(Fmt.days(days)).",
                action: button(volume))
        }
        // Personne pour accueillir : ce qu'il faut libérer pour une semaine.
        let week = perDay * 7
        return Advice(
            rule: verdict.rule,
            text: "Libérer \(Fmt.bytes(week, digits: 0)) donne une semaine de plus",
            detail: "\(pace) Une semaine à ce rythme : \(Fmt.bytes(perDay, digits: 1)) × 7. "
                + "Aucun autre disque externe n'a de place.",
            action: button(volume))
    }

    // MARK: - Plantage : règle 5

    /// L'état de la mémoire à l'heure du plantage, lu dans la série de
    /// l'heure : si elle était pleine, le conseil le dit ; sinon il le dit
    /// aussi — un plantage sans manque de mémoire ne se soigne pas en
    /// fermant Vivaldi.
    private static func crash(_ input: VerdictInput, now: Date) -> Advice? {
        let horizon = now.addingTimeInterval(-VerdictEngine.incidentWindow)
        guard let last = input.incidents
            .filter({ $0.kind == .crash && $0.date >= horizon })
            .max(by: { $0.date < $1.date }) else { return nil }
        let t = last.date.timeIntervalSince1970
        // Un point de 10 s au plus loin : au-delà, ce n'est plus « au plantage ».
        guard let point = input.series.min(by: { abs($0.t - t) < abs($1.t - t) }),
              abs(point.t - t) <= 30 else {
            return memory(5, input).map {
                Advice(rule: 5, text: $0.text,
                       detail: "Le plantage date de plus d'une heure : la mémoire de ce moment-là n'est plus "
                           + "dans la série. " + $0.detail,
                       action: $0.action)
            }
        }
        let swap = point.swap > 0 ? ", swap \(Fmt.memory(point.swap))" : ", aucun swap"
        return Advice(
            rule: 5,
            text: "Au plantage : mémoire à \(Fmt.percent(point.ram))\(swap)",
            detail: "Relevé de \(clock(point.t)), à \(Int(abs(point.t - t))) s du plantage de "
                + "\(Fmt.appName(last.app)) (\(clock(t))).",
            action: .activityMonitor)
    }

    // MARK: - Processeur : règle 10

    private static func processor(_ verdict: Verdict, _ input: VerdictInput) -> Advice? {
        guard case .app(let id) = verdict.object,
              let group = input.processes.first(where: { $0.bundleId == id }) else { return nil }
        let name = clip(Fmt.appName(group.name), to: 12)
        let cores = Self.cores(group.cpu)
        let editing = input.processes
            .filter { AppKind.of(bundleId: $0.bundleId) == .editing }
            .max { $0.cpu < $1.cpu }
        let text = editing.map { "Fermer \(name) rend \(cores) à \(clip(Fmt.appName($0.name), to: 14))" }
            ?? "Fermer \(name) libère \(cores)"
        return Advice(
            rule: 10, text: text,
            detail: "\(Fmt.appName(group.name)) : \(Fmt.cpu(group.cpu)) d'un cœur en \(group.processCount) processus, "
                + "processeur à \(Fmt.percent(input.cpu.total)).",
            action: .activityMonitor)
    }

    // MARK: - Mise en forme

    /// Coupe un nom avec des points de suspension, comme le verdict — sans
    /// laisser d'espace devant (« Premiere … »).
    static func clip(_ name: String, to limit: Int) -> String {
        let limit = max(1, limit)
        guard name.count > limit else { return name }
        return String(name.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// « 2,5 cœurs » : la charge d'une app en cœurs entiers, ce que l'œil
    /// compare aux 12 de la machine. « 1 cœur » au singulier.
    static func cores(_ percentOfOneCore: Double) -> String {
        let value = (percentOfOneCore / 100 * 10).rounded() / 10
        let text = value == value.rounded()
            ? "\(Int(value))"
            : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
        return value < 2 ? "\(text) cœur" : "\(text) cœurs"
    }

    private static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

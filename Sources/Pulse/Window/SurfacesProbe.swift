import Foundation

/// La section WIDGETS ET RACCOURCIS de `--probe` : ce que les widgets
/// afficheraient et ce que les actions Raccourcis répondraient MAINTENANT,
/// calculé comme l'app le calcule (`EtatBuilder`, `Reponses`) sur les
/// mesures du relevé. Règle du dépôt : chaque chiffre affiché se retrouve
/// ici.
enum SurfacesProbe {
    @MainActor
    static func lines(memory: MemorySample, volumes: [VolumeSample], forecasts: [String: FillForecast],
                      verdict: Verdict, now: Date = Date()) -> [String] {
        let reglages = ReglagesReseau.actuels
        let jours = Forfait.joursALire(maintenant: now, jour: reglages.jourRenouvellement)
        // Lecture seule de reseau.json : `history` ne réécrit rien.
        let forfait = Forfait.etat(historique: NetworkTracker().history(days: jours, from: now),
                                   reglages: reglages, maintenant: now)
        let etat = EtatBuilder.build(memory: memory, volumes: volumes, forecasts: forecasts,
                                     verdict: verdict, forfait: forfait, now: now)
        var out: [String] = []
        let calme = Reponses.calme(etat)
        out.append("  Pulse est-il calme ?     \(calme.calme ? "vrai" : "faux") — « \(calme.phrase) »")
        let disque = Reponses.disque(etat, nom: nil)
        out.append("  Espace libre (rushes)    \(disque.disque.map { Fmt.decimalGo($0.libreOctets) } ?? "—") — « \(disque.phrase) »")
        let iphone = Reponses.iphone(etat)
        out.append("  Consommation iPhone      \(Fmt.decimalMo(iphone.octets)) — « \(iphone.phrase) »")
        if let rushes = etat.disqueDeRushes {
            out.append("  widget disque            \(rushes.nom) (\(rushes.id)) · \(rushes.libre) libres · occupé à \(rushes.occupationTexte)"
                       + (rushes.tendance.map { " · \($0)" } ?? "")
                       + (etat.rushes == nil ? " · aucun disque externe : le disque interne" : ""))
        }
        out.append("  widget mémoire           \(etat.memoire.utilisee) sur \(etat.memoire.totale) · pression \(etat.memoire.pression)"
                   + " · swap \(etat.memoire.swap)")
        if let f = etat.forfait {
            out.append("  widget partage iPhone    \(f.aujourdhui) aujourd'hui · \(f.cycle) ce cycle"
                       + (f.quota.map { " sur \($0)" } ?? " · forfait non réglé") + (f.echeance.map { " · \($0)" } ?? ""))
        }
        let autres = etat.disques.filter { $0.id != etat.disqueDeRushes?.id }
            .map { "\($0.nom) \($0.libre)" }.joined(separator: " · ")
        if !autres.isEmpty { out.append("  autres disques           \(autres) (proposés par l'action « Espace libre »)") }

        // Le fichier que lit l'extension de widgets : son âge dit si l'app
        // l'écrit bien.
        let url = EtatPartage.url()
        if let written = EtatPartage.read(from: url) {
            let age = Int(now.timeIntervalSince(written.date) / 60)
            out.append("  fichier des widgets      \(url.lastPathComponent), relevé il y a \(age) min"
                       + (written.verdict.phrase == etat.verdict.phrase ? "" : " (verdict d'alors : \(written.verdict.phrase))"))
        } else {
            out.append("  fichier des widgets      \(url.lastPathComponent) absent — l'app l'écrit dans la minute qui suit son lancement")
        }
        return out
    }
}

extension Fmt {
    /// « 305,2 Go », la valeur que rend l'action « Espace libre » : base
    /// 1000, une décimale.
    static func decimalGo(_ bytes: UInt64) -> String {
        String(format: "%.1f Go", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",")
    }

    static func decimalMo(_ bytes: UInt64) -> String {
        String(format: "%.1f Mo", Double(bytes) / 1e6).replacingOccurrences(of: ".", with: ",")
    }
}

import Foundation

/// La section RÈGLES de `--probe` : chaque règle, sa condition en clair, la
/// valeur du moment de sa mesure et si la condition tient, puis le journal
/// des 7 derniers jours. Lecture seule : ni `regles.json` ni le journal ne
/// sont écrits, et le centre de notifications n'est pas touché.
@MainActor
enum SondeRegles {
    static func lignes(memoire: MemorySample, cpu: CPUSample, volumes: [VolumeSample],
                       previsions: [String: FillForecast], series: [SeriesPoint],
                       incidents: [Incident], maintenant: Date = Date()) -> [String] {
        let fichier = ReglesStore.charger(ReglesStore.urlParDefaut, mettreDeCote: false)
        let present = FileManager.default.fileExists(atPath: ReglesStore.urlParDefaut.path)
        let actives = fichier.regles.filter(\.active)
        var out: [String] = []
        out.append("  fichier          \(present ? "regles.json" : "regles.json absent : préréglages d'origine, tous éteints")")
        out.append(actives.isEmpty
                   ? "  actives          aucune — rien ne tourne : aucun abonnement au relevé, coût nul"
                   : "  actives          \(actives.count) — évaluées à chaque relevé du Sampler (5 s panneau fermé), sans relevé de plus")
        let a = fichier.alertes
        out.append("  notifications    au plus une toutes les \(Fmt.duration(a.intervalle)), le reste regroupé"
                   + (a.retenirEnMontage ? " · retenues tant qu'une app de montage est au premier plan" : ""))
        let journal = JournalRegles.lire(apres: maintenant.addingTimeInterval(-30 * 86_400))
        let autorisation = journal.last { $0.genre == .autorisation }
        out.append("  autorisation     " + (autorisation.map { "\($0.texte) le \(Self.date($0.date))" }
                                            ?? "jamais demandée par Pulse (elle ne part qu'à l'allumage d'une règle qui notifie)"))

        // Les valeurs du moment, par le même code que l'app.
        let reseau = NetworkMonitor.primary() == nil ? NetworkSample() : NetworkSample(connected: true)
        let reglagesReseau = ReglagesReseau.actuels
        let forfait = Forfait.etat(historique: NetworkTracker().history(days: Forfait.joursALire(jour: reglagesReseau.jourRenouvellement)),
                                   reglages: reglagesReseau).fraction
        let entrees = EntreesRegles(memoire: memoire, cpu: cpu, volumes: volumes, previsions: previsions,
                                    series: series, reseau: reseau, forfait: forfait)
        let valeurs = LectureRegles.valeurs(entrees, mesures: Set(fichier.regles.map(\.mesure)), date: maintenant)

        for regle in fichier.regles {
            guard let mesure = CatalogueMesures.mesure(regle.mesure) else {
                out.append("  [\(regle.active ? "ACTIVE" : "éteinte")] \(regle.nom) — mesure inconnue « \(regle.mesure) », ignorée")
                continue
            }
            out.append("  [\(regle.active ? "ACTIVE" : "éteinte")] \(regle.nom)")
            out.append("      condition    \(condition(regle, mesure))")
            out.append("      actions      \(actions(regle))")
            out.append("      maintenant   \(maintenantTexte(regle, mesure, valeurs, incidents: incidents, date: maintenant))")
        }

        out.append("")
        out.append("JOURNAL DES RÈGLES · 7 derniers jours (regles.jsonl)")
        let semaine = journal.filter { $0.date >= maintenant.addingTimeInterval(-7 * 86_400) }
        if semaine.isEmpty {
            out.append("  aucun déclenchement")
        } else {
            let comptes = EntreeJournal.Genre.allCases.compactMap { genre -> String? in
                let n = semaine.filter { $0.genre == genre }.count
                return n == 0 ? nil : "\(n) \(libelle(genre))"
            }
            out.append("  " + comptes.joined(separator: " · "))
            for e in semaine.suffix(12) {
                let qui = e.sujetNom.isEmpty ? "" : " · \(e.sujetNom)"
                out.append("  \(Self.date(e.date))  \(libelle(e.genre).padding(toLength: 11, withPad: " ", startingAt: 0)) \(e.nom)\(qui)\(e.texte.isEmpty ? "" : " — \(e.texte)")")
            }
        }
        return out
    }

    /// « Espace libre d'un disque sous 100 Go, chaque disque externe —
    /// tenue 1 min ; finit au-dessus de 110 Go tenus 10 min ».
    static func condition(_ regle: Regle, _ mesure: MesureRegle) -> String {
        var sujet = ""
        if mesure.parSujet {
            sujet = regle.sujet == nil ? ", chaque disque externe" : ", \(regle.sujetNom ?? regle.sujet ?? "")"
        } else if mesure.unite == .evenement, let filtre = regle.sujet {
            sujet = " (« \(filtre) »)"
        }
        switch regle.comparaison {
        case .survient:
            return "\(mesure.nom)\(sujet) — une rafale dure \(Fmt.duration(regle.relache)) : une seule notification"
        case .vrai:
            return "\(mesure.nom)\(sujet) — tenu \(duree(regle.duree)) ; finit après \(duree(regle.relache)) de retour"
        case .sous, .atteint:
            let sens = regle.comparaison == .sous ? "sous" : "atteint"
            let retour = regle.comparaison == .sous ? regle.seuil + regle.marge : regle.seuil - regle.marge
            let finit = regle.comparaison == .sous ? "au-dessus de" : "sous"
            return "\(mesure.nom) \(sens) \(mesure.texte(regle.seuil))\(sujet) — tenue \(duree(regle.duree)) ; finit \(finit) \(mesure.texte(retour)) tenus \(duree(regle.relache))"
        }
    }

    static func actions(_ regle: Regle) -> String {
        var parts: [String] = []
        if regle.notification { parts.append(regle.son ? "notification sonore" : "notification") }
        if regle.barre { parts.append("symbole dans la barre") }
        if parts.isEmpty { parts.append("journal seulement") }
        var out = parts.joined(separator: " · ")
        out += regle.plage.map { " ; \($0.texte)" } ?? " ; à toute heure"
        if regle.urgente { out += " ; même en plein montage" }
        return out
    }

    private static func maintenantTexte(_ regle: Regle, _ mesure: MesureRegle, _ valeurs: [String: [Echantillon]],
                                        incidents: [Incident], date: Date) -> String {
        switch mesure.id {
        case "montage.plantage":
            let crash = incidents.filter { $0.kind == .crash && $0.date >= date.addingTimeInterval(-86_400) }
                .filter { regle.sujet.map($0.app.localizedCaseInsensitiveContains) ?? true }
            return crash.isEmpty ? "aucun plantage sur 24 h" : "\(crash.count) plantage(s) sur 24 h, le dernier le \(Self.date(crash[0].date))"
        case "memoire.processusTue":
            let tues = incidents.filter { $0.kind == .jetsam && $0.date >= date.addingTimeInterval(-86_400) }
            return tues.isEmpty ? "aucun sur 24 h" : "\(tues.count) sur 24 h"
        case "montage.exportTermine", "disques.copieTerminee":
            return "un événement : se constate d'un relevé à l'autre, pas sur un relevé unique"
        default:
            break
        }
        guard let lus = valeurs[mesure.id] else {
            return mesure.id == "reseau.forfait" ? "forfait non réglé : rien à comparer (carte Réseau)" : "mesure absente en ce moment"
        }
        let suivis = lus.filter { e in regle.sujet.map { e.sujet == $0 } ?? (mesure.parSujet ? e.suiviParDefaut : true) }
        guard !suivis.isEmpty else { return mesure.parSujet ? "aucun disque suivi n'est branché" : "mesure absente" }
        return suivis.map { e in
            let (entree, _) = MoteurRegles.conditions(regle, e.valeur)
            let nom = e.nom.isEmpty ? "" : "\(e.nom) "
            let valeur = mesure.unite == .etat ? (e.valeur >= 0.5 ? "oui" : "non")
                : mesure.texte(e.valeur) + (mesure.suffixe.isEmpty ? "" : " " + mesure.suffixe)
            return "\(nom)\(valeur) : condition \(entree ? "VRAIE" : "fausse")"
        }.joined(separator: " · ")
    }

    private static func duree(_ secondes: TimeInterval) -> String {
        if secondes <= 0 { return "un relevé" }
        return secondes < 60 ? "\(Int(secondes)) s" : Fmt.duration(secondes)
    }

    static func libelle(_ genre: EntreeJournal.Genre) -> String {
        switch genre {
        case .debut:        return "début"
        case .rafale:       return "rafale"
        case .fin:          return "fin"
        case .notifiee:     return "notifiée"
        case .retenue:      return "retenue"
        case .horsPlage:    return "hors plage"
        case .tombee:       return "tombée"
        case .nonEnvoyee:   return "non envoyée"
        case .autorisation: return "autorisation"
        }
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "dd/MM HH:mm"
        return f.string(from: date)
    }
}

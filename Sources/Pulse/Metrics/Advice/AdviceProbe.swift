import Foundation

/// La section CONSEIL de `--probe` : le conseil de la règle retenue, puis
/// celui de chaque autre règle vraie à cet instant — masquée par la
/// première, elle prendra sa place un jour, et son conseil doit pouvoir se
/// vérifier d'avance. Pour chacun : la ligne du bandeau, le calcul, et ce
/// que ferait le bouton. Le bouton n'est jamais exécuté ici.
enum AdviceProbe {
    static func lines(_ input: VerdictInput, retained: Verdict, now: Date = Date()) -> [String] {
        var out: [String] = []
        let others = VerdictEngine.actives(input, now: now).filter { $0.rule != retained.rule && $0.rule != 11 }
        // Les écritures massives en cours, telles que l'app les tient dans
        // disques.json chaque minute (chantier 05) : le chiffre du panneau,
        // à une minute près.
        let ingestions = DiskJournal.read(now: now).filter(\.active)
        for verdict in [retained] + others {
            let shown = verdict.rule == retained.rule ? " (affichée)" : ""
            guard let advice = Advisor.advice(for: verdict, input, ingestions: ingestions, now: now) else {
                out.append("  règle \(verdict.rule)\(shown) : aucun conseil — \(silence(verdict.rule))")
                continue
            }
            out.append("  règle \(verdict.rule)\(shown) : \(advice.text)")
            out.append("    calcul   \(advice.detail)")
            out.append("    bouton   " + (advice.action.map { "« \($0.label) » \($0.probeText)" } ?? "aucun"))
        }
        out.append("  seuils : une app vaut d'être fermée à partir de \(Fmt.memory(Advisor.worthClosing, digits: 0)) ; "
                   + "un disque se vise sous \(Fmt.percent(Advisor.targetFraction)) ; "
                   + "destination : un disque externe sous ce seuil, jamais l'interne")
        return out
    }

    /// Pourquoi une règle n'a pas de conseil : une raison, pas un blanc.
    private static func silence(_ rule: Int) -> String {
        switch rule {
        case 12:         return "rien à signaler, rien à faire"
        case 11:         return "un export se laisse finir"
        case 1, 2, 6, 7: return "aucune app de \(Fmt.memory(Advisor.worthClosing, digits: 0)) ou plus, montage compris"
        case 3, 8:       return "volume démonté, ou déjà repassé sous le seuil"
        case 4, 9:       return "volume démonté"
        case 5:          return "aucun plantage dans les 24 h"
        case 10:         return "l'application n'est plus dans le relevé"
        default:         return "aucune donnée"
        }
    }
}

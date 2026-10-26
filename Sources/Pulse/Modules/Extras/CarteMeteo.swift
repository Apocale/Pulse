import SwiftUI

/// La carte Météo : le temps du moment, les 12 prochaines heures, les
/// 7 prochains jours, et ce qui sort sur Internet pour les obtenir.
///
/// Une seule teinte : le bleu de `Palette.data` pour la probabilité de pluie,
/// sur son vrai total — 100 % (règle n° 7) — et jamais sur du texte (n° 6).
/// Le temps se lit aux symboles et en toutes lettres pour VoiceOver.
struct CarteMeteo: View {
    @ObservedObject var meteo: Meteo
    let compact: Bool
    /// Carte activée par Isma (sinon : l'aperçu des Réglages, ou un rendu).
    let affichee: Bool

    var body: some View {
        // Les heures passées quittent la bande à la minute près, panneau
        // ouvert seulement : le contenu du panneau n'existe pas fermé.
        TimelineView(.everyMinute) { moment in
            contenu(moment.date)
        }
    }

    private func contenu(_ maintenant: Date) -> some View {
        let p = meteo.prevision
        return Card {
            CardTitle(title: "Météo", symbol: "cloud.sun",
                      trailing: (p?.actuelle?.temperature ?? p?.prochainesHeures(1, depuis: maintenant).first?.temperature).map(Self.degres))
            if let p {
                actuelle(p, maintenant)
                if !compact {
                    heures(p, maintenant)
                    jours(p)
                }
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            pied
        }
    }

    // MARK: - Le moment

    private func actuelle(_ p: PrevisionMeteo, _ maintenant: Date) -> some View {
        let code = p.actuelle?.code ?? p.prochainesHeures(1, depuis: maintenant).first?.code
        let jour = p.actuelle?.jour ?? true
        let aujourdhui = p.jours.first { Calendar.current.isDate($0.date, inSameDayAs: maintenant) } ?? p.jours.first
        return HStack(spacing: 8) {
            Image(systemName: CodeMeteo.symbole(code, jour: jour))
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(.primary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(CodeMeteo.libelle(code)).font(.callout).lineLimit(1)
                Text(meteo.ville?.nom ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let aujourdhui, let min = aujourdhui.minimum, let max = aujourdhui.maximum {
                Text("\(Self.degres(min)) → \(Self.degres(max))")
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Les 12 prochaines heures

    private func heures(_ p: PrevisionMeteo, _ maintenant: Date) -> some View {
        let liste = p.prochainesHeures(12, depuis: maintenant)
        return VStack(alignment: .leading, spacing: 4) {
            CardCaption(text: "12 prochaines heures", trailing: "pluie : probabilité")
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(liste, id: \.date) { h in
                    VStack(spacing: 3) {
                        Text(Extras.formateur("HH", p.fuseau).string(from: h.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: CodeMeteo.symbole(h.code, jour: h.jour ?? true))
                            .symbolRenderingMode(.hierarchical)
                            .font(.caption)
                            .frame(height: 15)
                        Text(h.temperature.map(Self.degres) ?? "–")
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)

                        pluie(h.pluie)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Extras.formateur("H", p.fuseau).string(from: h.date)) heures")
                    .accessibilityValue([h.temperature.map { "\(Int($0.rounded())) degrés" }, CodeMeteo.libelle(h.code),
                                         h.pluie.map { "pluie \(Int($0)) %" }].compactMap { $0 }.joined(separator: ", "))
                }
            }
        }
    }

    /// La probabilité de pluie d'une heure, sur 100 % : une barre de 8 pt
    /// au plus, sur un rail.
    private func pluie(_ probabilite: Double?) -> some View {
        let part = min(1, max(0, (probabilite ?? 0) / 100))
        return ZStack(alignment: .bottom) {
            Capsule().fill(Palette.track).frame(width: 4, height: 8)
            if part > 0 {
                Capsule().fill(Palette.data).frame(width: 4, height: max(2, 8 * part))
            }
        }
        .frame(height: 8)
    }

    // MARK: - Les 7 jours

    private func jours(_ p: PrevisionMeteo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CardCaption(text: "7 jours")
            ForEach(p.jours.prefix(7), id: \.date) { j in
                HStack(spacing: 7) {
                    Text(Extras.formateur("EEE d", p.fuseau).string(from: j.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 66, alignment: .leading)
                    Image(systemName: CodeMeteo.symbole(j.code))
                        .symbolRenderingMode(.hierarchical)
                        .font(.callout)
                        .frame(width: 22)
                    Text(j.pluie.flatMap { $0 >= 10 ? "\(Int($0)) %" : nil } ?? "")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)
                    Spacer(minLength: 4)
                    Text("\(j.minimum.map(Self.degres) ?? "–") → \(j.maximum.map(Self.degres) ?? "–")")
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Extras.formateur("EEEE d MMMM", p.fuseau).string(from: j.date))
                .accessibilityValue([CodeMeteo.libelle(j.code),
                                     j.minimum.map { "minimum \(Int($0.rounded())) degrés" },
                                     j.maximum.map { "maximum \(Int($0.rounded())) degrés" },
                                     j.pluie.map { "pluie \(Int($0)) %" }].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    // MARK: - États et pied

    private var message: String? {
        switch meteo.etat {
        case .desactivee where meteo.prevision == nil:
            return affichee ? nil : "Activée, cette carte demande la prévision à Open-Meteo. Rien ne part tant qu'elle est désactivée."
        case .horsApp where meteo.prevision == nil:
            return "Hors de l'app, aucune requête : pas encore de prévision reçue."
        case .enCours where meteo.prevision == nil:
            return "Demande en cours à Open-Meteo…"
        case .echec(let raison):
            return "Open-Meteo n'a pas répondu (\(raison)). Nouvel essai dans 15 min."
        default:
            return nil
        }
    }

    /// Ce qui sort, en toutes lettres : la mission l'exige, et Isma doit le
    /// savoir sans ouvrir les Réglages.
    private var pied: some View {
        let ville = meteo.ville?.nom ?? "la ville choisie"
        var texte = "Sort sur Internet : la position de \(ville) part vers \(OpenMeteo.hote)."
        if let recue = meteo.recue, meteo.prevision != nil { texte += " Reçue à \(Extras.heure(recue))." }
        return Label {
            Text(texte)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "network")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// « 18° », « −3° » : arrondi au degré, vrai signe moins.
    static func degres(_ valeur: Double) -> String {
        let n = Int(valeur.rounded())
        return n < 0 ? "\u{2212}\(-n)°" : "\(n)°"
    }
}

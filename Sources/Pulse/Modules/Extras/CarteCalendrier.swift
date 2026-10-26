import SwiftUI

/// La carte Calendrier : les prochains événements, groupés par jour, le
/// prochain compté à rebours.
///
/// Les couleurs des calendriers ne sont pas reprises : choisies par Isma ou
/// par un compte, elles n'ont aucun ratio mesuré (règle dure n°4). Le nom du
/// calendrier se lit à VoiceOver.
struct CarteCalendrier: View {
    @ObservedObject var agenda: Agenda
    let reglages: ReglagesCalendrier
    let compact: Bool

    var body: some View {
        // Le compte à rebours suit la minute, panneau ouvert seulement.
        TimelineView(.everyMinute) { moment in
            contenu(moment.date)
        }
    }

    private func contenu(_ maintenant: Date) -> some View {
        let visibles = agenda.evenements.filter { $0.journee || $0.fin > maintenant }
        let liste = Array(visibles.prefix(compact ? min(2, reglages.nombre) : reglages.nombre))
        let prochain = agenda.prochain(maintenant)
        return Card {
            CardTitle(title: "Calendrier", symbol: "calendar",
                      trailing: prochain.flatMap { e in
                          Calendar.current.isDate(e.debut, inSameDayAs: maintenant) ? QuandEvenement.texte(e, maintenant) : nil
                      })
            if let message = etat {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if agenda.acces == .jamaisDemande && !agenda.demandeFaite {
                    // C'est Isma qui demande : jamais au lancement (voir
                    // `Agenda.regler`). Bouton de carte en `.plain` : un
                    // bouton AppKit ne se dessine pas hors écran (README).
                    Button { agenda.demanderAcces() } label: {
                        HStack(spacing: 4) {
                            Text("Autoriser l'accès aux calendriers")
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("macOS demande alors l'accès à vos calendriers")
                }
            } else if liste.isEmpty {
                Text(vide)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let jours = Dictionary(grouping: liste) { Calendar.current.startOfDay(for: max($0.debut, Calendar.current.startOfDay(for: maintenant))) }
                ForEach(jours.keys.sorted(), id: \.self) { jour in
                    if !compact { CardCaption(text: titreJour(jour, maintenant)) }
                    ForEach(jours[jour] ?? []) { e in ligne(e, maintenant) }
                }
            }
        }
    }

    /// Pourquoi il n'y a rien à lister, quand ce n'est pas l'agenda vide.
    private var etat: String? {
        if agenda.horsApp {
            return "Le calendrier ne se lit que dans l'app : ce rendu hors écran ne demande rien à macOS."
        }
        switch agenda.acces {
        case nil:
            return "Activez la carte : macOS demandera alors l'accès à vos calendriers. Rien ne sort du Mac."
        case .jamaisDemande?:
            return agenda.demandeFaite
                ? "macOS demande l'accès à vos calendriers."
                : "macOS n'a pas encore donné à Pulse l'accès à vos calendriers. Rien ne sort du Mac."
        case .refuse?:
            return "Accès refusé. Pour l'accorder : Réglages Système › Confidentialité et sécurité › Calendriers › Pulse."
        case .restreint?:
            return "Accès aux calendriers bloqué par un profil de gestion."
        case .ecritureSeule?:
            return "Accès en écriture seule : Pulse a besoin de lire. Réglages Système › Confidentialité et sécurité › Calendriers › Pulse : accès complet."
        case .accorde?:
            return nil
        }
    }

    private var vide: String {
        switch reglages.horizon {
        case .aujourdhui: return "Plus rien aujourd'hui."
        case .demain: return "Rien d'ici demain soir."
        case .semaine: return "Rien dans les 7 prochains jours."
        }
    }

    /// « Aujourd'hui », « Demain », « Mardi 13 ».
    private func titreJour(_ jour: Date, _ maintenant: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(jour, inSameDayAs: maintenant) { return "Aujourd'hui" }
        if let demain = cal.date(byAdding: .day, value: 1, to: maintenant), cal.isDate(jour, inSameDayAs: demain) { return "Demain" }
        return Extras.formateur("EEEE d", .current).string(from: jour)
    }

    private func ligne(_ e: EvenementAgenda, _ maintenant: Date) -> some View {
        let aujourdhui = Calendar.current.isDate(e.debut, inSameDayAs: maintenant) || e.enCours(maintenant)
        let quand = QuandEvenement.texte(e, maintenant)
        return HStack(spacing: 7) {
            Text(e.journee ? "journée" : Extras.heure(e.debut))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(e.titre)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if aujourdhui, !e.journee, !compact, quand.hasPrefix("dans") || e.enCours(maintenant) {
                Text(quand)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(e.titre)
        .accessibilityValue([e.journee ? "toute la journée" : "à \(Extras.heure(e.debut)), jusqu'à \(Extras.heure(e.fin))",
                             e.journee ? nil : quand, e.calendrier.isEmpty ? nil : "calendrier \(e.calendrier)"]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

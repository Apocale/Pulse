import SwiftUI

/// La carte des horloges : l'heure d'ici et son soleil, puis une ligne par
/// personne — son nom, sa ville, son heure, jour ou nuit, l'écart avec ici.
///
/// Aucune teinte : le jour et la nuit se lisent au symbole (soleil, lune) et
/// en toutes lettres pour VoiceOver, jamais à la couleur (règles n° 4 et 6).
/// Aucune barre : la journée n'a pas de jauge (règle n° 7).
struct CarteHorloges: View {
    let reglages: ReglagesHorloges
    let compact: Bool

    var body: some View {
        // Redessinée à chaque minute tant qu'elle est à l'écran ; le contenu
        // du panneau n'existe que panneau ouvert : fermé, rien ne tourne.
        TimelineView(.everyMinute) { moment in
            contenu(moment.date)
        }
    }

    private func contenu(_ maintenant: Date) -> some View {
        let ici = Villes.choisie(reglages.ville)
        return Card {
            CardTitle(title: "Horloges", symbol: "globe.europe.africa", trailing: Extras.heure(maintenant))
            if let ici, reglages.soleil {
                soleilIci(LigneHorloge.calcule(nom: "Ici", ville: ici, maintenant: maintenant))
            }
            if reglages.personnes.isEmpty {
                Text("Ajoutez les personnes à suivre dans les Réglages de Pulse, page Horloges : un nom, une ville.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: compact ? 5 : 8) {
                    ForEach(Array(reglages.personnes.enumerated()), id: \.offset) { _, personne in
                        if let ville = personne.ville {
                            ligne(LigneHorloge.calcule(nom: personne.affiche, ville: ville, maintenant: maintenant))
                        }
                    }
                }
            }
        }
    }

    /// « Soleil · Casablanca » : lever et coucher d'ici, durée du jour.
    private func soleilIci(_ l: LigneHorloge) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "sun.horizon")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(l.ville.nom).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(soleilCourt(l)).font(.callout.monospacedDigit()).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Soleil à \(l.ville.nom)")
        .accessibilityValue(l.soleilTexte + (l.soleil.duree.map { ", \(Extras.duree($0)) de jour" } ?? ""))
    }

    /// « 07:31 → 19:02 · 11 h 31 ».
    private func soleilCourt(_ l: LigneHorloge) -> String {
        switch l.soleil.polaire {
        case .jour?: return "jour polaire"
        case .nuit?: return "nuit polaire"
        case nil:
            guard let lever = l.soleil.lever, let coucher = l.soleil.coucher else { return "" }
            var texte = "\(Extras.heure(lever, l.ville.timeZone)) → \(Extras.heure(coucher, l.ville.timeZone))"
            if !compact, let duree = l.soleil.duree { texte += " · \(Extras.duree(duree))" }
            return texte
        }
    }

    private func ligne(_ l: LigneHorloge) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: l.faitJour ? "sun.max" : "moon.stars")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.nom).font(.callout).lineLimit(1)
                if !compact {
                    Text(sousTitre(l)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(l.heure)
                    .font((compact ? Font.callout : Font.title3).monospacedDigit().weight(.medium))
                if !compact {
                    Text(l.jourRelatif.map { "\($0), \(l.ecart)" } ?? l.ecart)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(l.nom)
        .accessibilityValue(l.parle)
    }

    /// « Montréal · 07:12 → 18:22 », ou la ville seule sans le soleil.
    private func sousTitre(_ l: LigneHorloge) -> String {
        var parts: [String] = []
        if l.nom != l.ville.nom { parts.append(l.ville.nom) }
        if reglages.soleil {
            switch l.soleil.polaire {
            case .jour?: parts.append("jour polaire")
            case .nuit?: parts.append("nuit polaire")
            case nil:
                if let lever = l.soleil.lever, let coucher = l.soleil.coucher {
                    parts.append("\(Extras.heure(lever, l.ville.timeZone)) → \(Extras.heure(coucher, l.ville.timeZone))")
                }
            }
        }
        return parts.isEmpty ? l.ville.pays : parts.joined(separator: " · ")
    }
}

/// L'éditeur des personnes, dans la page Horloges de la fenêtre Réglages :
/// un nom, une ville, huit personnes au plus. Écrit à la volée dans
/// `reglages.json`, comme le reste de la fenêtre.
struct EditeurPersonnes: View {
    @ObservedObject var store: SettingsStore

    private var reglages: ReglagesHorloges {
        ReglagesHorloges(options: store.settings.module(ReglagesHorloges.module).options)
    }

    var body: some View {
        let personnes = reglages.personnes
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(personnes.enumerated()), id: \.offset) { index, personne in
                HStack(spacing: 8) {
                    TextField("Nom", text: nom(index), prompt: Text("Nom"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .accessibilityLabel("Nom de la personne \(index + 1)")
                    Picker("Ville", selection: lieu(index)) {
                        if Villes.toutes.first(where: { $0.cle == personne.lieu }) == nil, let ville = personne.ville {
                            Text(ville.libelle).tag(personne.lieu)
                        }
                        ForEach(Villes.parNom) { Text($0.libelle).tag($0.cle) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Ville de \(personne.affiche)")
                    Button {
                        modifier { $0.personnes.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Retirer \(personne.affiche)")
                    .accessibilityLabel("Retirer \(personne.affiche)")
                }
            }
            HStack {
                Button {
                    modifier { $0.personnes.append(Personne(nom: "", lieu: Villes.ici()?.cle ?? "paris")) }
                } label: {
                    Label("Ajouter une personne", systemImage: "plus.circle")
                }
                .disabled(personnes.count >= ReglagesHorloges.maximum)
                Spacer()
                Text("\(personnes.count) sur \(ReglagesHorloges.maximum)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("La première personne peut aussi s'afficher dans la barre de menus. Tout est calculé sur le Mac : aucune localisation demandée, rien ne sort.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modifier(_ change: (inout ReglagesHorloges) -> Void) {
        var r = reglages
        change(&r)
        ReglagesHorloges.enregistrer(r, dans: store)
    }

    private func nom(_ index: Int) -> Binding<String> {
        Binding(get: { reglages.personnes.indices.contains(index) ? reglages.personnes[index].nom : "" },
                set: { valeur in modifier { if $0.personnes.indices.contains(index) { $0.personnes[index].nom = valeur } } })
    }

    private func lieu(_ index: Int) -> Binding<String> {
        Binding(get: { reglages.personnes.indices.contains(index) ? reglages.personnes[index].lieu : "" },
                set: { valeur in modifier { if $0.personnes.indices.contains(index) { $0.personnes[index].lieu = valeur } } })
    }
}

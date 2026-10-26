import SwiftUI

/// La page « Règles et alertes » de la fenêtre Réglages : ce qui est en
/// cours, comment Pulse se tait, chaque règle (interrupteur, seuil, disque,
/// durée, plage horaire, actions), l'ajout d'une règle, le journal.
///
/// Tout s'écrit à la volée dans `regles.json`. Allumer une règle qui
/// notifie est la SEULE occasion où macOS demande l'autorisation de
/// notifier — et seulement s'il ne l'a jamais demandée.
struct PageRegles: View {
    let sampler: Sampler
    @ObservedObject private var store: ReglesStore
    @ObservedObject private var surveillant: SurveillantRegles
    @ObservedObject private var notificateur: NotificateurSysteme
    @State private var nouvelle = "processeur.total"
    @State private var journal: [EntreeJournal] = []
    @State private var essai: String?

    init(sampler: Sampler) {
        self.sampler = sampler
        _store = ObservedObject(wrappedValue: .shared)
        _surveillant = ObservedObject(wrappedValue: .shared)
        _notificateur = ObservedObject(wrappedValue: .shared)
    }

    var body: some View {
        Form {
            Section {
                if surveillant.enCours.isEmpty {
                    Text(store.regles.contains(where: \.active) ? "Rien en cours." : "Aucune règle allumée : Pulse ne surveille rien de plus, et ne coûte rien de plus.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(surveillant.enCours) { signal in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signal.nom)
                                Text("\(signal.texte) · depuis \(MoteurRegles.heure(signal.debut))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bell.badge")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Règles et alertes", systemImage: "bell").font(.title3.weight(.semibold))
                    Text("Toutes éteintes à l'origine. Une règle prévient une fois par épisode, jamais par une fenêtre.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }

            Section {
                Picker("Au plus une notification", selection: intervalle) {
                    ForEach(ReglagesAlertes.intervalles, id: \.self) { Text("toutes les \(Fmt.duration($0))").tag($0) }
                }
                Toggle("Retenir pendant le montage", isOn: retenir)
                LabeledContent("Notifications de macOS") {
                    Text(notificateur.statut.texte).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Envoyer une notification d'essai") {
                        SurveillantRegles.shared.essayer { essai = $0 }
                    }
                    if let essai {
                        Text(essai).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Comment Pulse se tait")
            } footer: {
                Text("Ce qui arrive entre deux notifications part regroupé dans la suivante. Tant que Premiere (ou une autre app de montage) est au premier plan, les notifications attendent ; le symbole de la barre, silencieux, s'allume tout de suite. Ne pas déranger et les modes de concentration de macOS s'appliquent à chaque notification.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Section("Règles") {
                ForEach(store.regles) { regle in
                    LigneRegle(regle: binding(regle.id), volumes: sampler.volumes, previsions: sampler.forecasts,
                               allumer: { SurveillantRegles.shared.regleAllumee($0) },
                               supprimer: regle.prereglage == nil ? { supprimer(regle.id) } : nil)
                }
            }

            Section {
                Picker("Mesure", selection: $nouvelle) {
                    ForEach(CatalogueMesures.toutes) { mesure in
                        Text("\(ModuleRegistry.module(mesure.module)?.name ?? mesure.module) · \(mesure.nom)").tag(mesure.id)
                    }
                }
                HStack {
                    Text(CatalogueMesures.mesure(nouvelle)?.source ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ajouter") { ajouter(nouvelle) }
                }
            } header: {
                Text("Ajouter une règle")
            } footer: {
                Text("Une mesure qu'un module publie déjà : la règle ne relève rien de plus. Elle s'ajoute éteinte.")
                    .foregroundStyle(.secondary)
            }

            Section("Journal des 7 derniers jours") {
                if journal.isEmpty {
                    Text("Aucun déclenchement.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(journal.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(SondeRegles.date(e.date)) · \(SondeRegles.libelle(e.genre)) · \(e.nom)")
                            if !e.texte.isEmpty || !e.sujetNom.isEmpty {
                                Text([e.sujetNom, e.texte].filter { !$0.isEmpty }.joined(separator: " — "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Règles et alertes")
        .onAppear {
            notificateur.lireStatut()
            journal = Array(JournalRegles.lire(apres: Date().addingTimeInterval(-7 * 86_400)).suffix(12).reversed())
        }
    }

    // MARK: Liaisons

    private func binding(_ id: String) -> Binding<Regle> {
        Binding(get: { store.regle(id) ?? Prereglages.tous[0] },
                set: { nouvelle in store.modifier(id) { $0 = nouvelle } })
    }

    private var intervalle: Binding<TimeInterval> {
        Binding(get: { store.fichier.alertes.intervalle },
                set: { store.fichier.alertes.intervalle = $0 })
    }

    private var retenir: Binding<Bool> {
        Binding(get: { store.fichier.alertes.retenirEnMontage },
                set: { store.fichier.alertes.retenirEnMontage = $0 })
    }

    private func ajouter(_ id: String) {
        guard let mesure = CatalogueMesures.mesure(id) else { return }
        store.fichier.regles.append(Self.nouvelle(mesure))
    }

    private func supprimer(_ id: String) {
        store.fichier.regles.removeAll { $0.id == id && $0.prereglage == nil }
    }

    /// Une règle neuve, éteinte, aux réglages raisonnables pour sa mesure.
    static func nouvelle(_ mesure: MesureRegle) -> Regle {
        var regle = Regle(id: UUID().uuidString, nom: mesure.nom, mesure: mesure.id,
                          comparaison: mesure.comparaisons[0], duree: 60, relache: 600)
        switch mesure.unite {
        case .stockage: regle.seuil = 100 * Prereglages.go; regle.comparaison = .sous
        case .memoire:  regle.seuil = 4 * Prereglages.gio; regle.comparaison = .atteint
        case .part:     regle.seuil = 0.9; regle.comparaison = .atteint
        case .jours:    regle.seuil = 7; regle.comparaison = .sous
        case .etat:     regle.duree = 30; regle.relache = 30
        case .evenement: regle.duree = 0
        }
        regle.marge = LigneRegle.marge(mesure, regle.seuil)
        return regle
    }
}

/// Une règle : l'interrupteur et sa condition en clair, puis, dépliés, ses
/// réglages.
struct LigneRegle: View {
    @Binding var regle: Regle
    let volumes: [VolumeSample]
    let previsions: [String: FillForecast]
    let allumer: (Regle) -> Void
    let supprimer: (() -> Void)?
    /// `--snapshot x.png --reglages regles --ouvert <id>` : déplié dans le rendu.
    @State private var ouvert: Bool

    init(regle: Binding<Regle>, volumes: [VolumeSample], previsions: [String: FillForecast],
         allumer: @escaping (Regle) -> Void, supprimer: (() -> Void)?) {
        _regle = regle
        self.volumes = volumes
        self.previsions = previsions
        self.allumer = allumer
        self.supprimer = supprimer
        _ouvert = State(initialValue: !Persistence.enabled && Snapshot.value(after: "--ouvert") == regle.wrappedValue.id)
    }

    static let durees: [TimeInterval] = [0, 30, 60, 120, 300, 600, 1800]

    var body: some View {
        let mesure = CatalogueMesures.mesure(regle.mesure)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: actif) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(regle.nom)
                    if let mesure {
                        Text(SondeRegles.condition(regle, mesure)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Réglages", isExpanded: $ouvert) {
                if let mesure { reglages(mesure) }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func reglages(_ mesure: MesureRegle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if regle.prereglage == nil {
                TextField("Nom", text: $regle.nom)
            }
            if mesure.parSujet {
                Picker("Disque", selection: sujet) {
                    Text("chaque disque externe").tag(String?.none)
                    ForEach(choixDisques, id: \.cle) { Text($0.nom).tag(Optional($0.cle)) }
                }
            }
            if mesure.id == "montage.plantage" {
                Picker("App", selection: sujet) {
                    Text("Premiere").tag(Optional("Premiere"))
                    Text("toute app Adobe").tag(String?.none)
                }
            }
            switch mesure.unite {
            case .stockage, .memoire, .part, .jours:
                Picker("Quand la mesure", selection: comparaison) {
                    Text("passe sous").tag(Comparaison.sous)
                    Text("atteint").tag(Comparaison.atteint)
                }
                seuil(mesure)
                duree
            case .etat:
                duree
            case .evenement:
                EmptyView()
            }
            Toggle("Seulement à certaines heures", isOn: avecPlage)
            if let plage = regle.plage {
                HStack {
                    Picker("De", selection: heure(\.debut)) { ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0 * 60) } }
                    Picker("à", selection: heure(\.fin)) { ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0 * 60) } }
                }
                // `plage.texte` commence déjà par « de » : « Hors de de 9 h »
                // s'affichait (chantier 16).
                Text("En dehors de la plage (\(plage.texte)) : un état se dit à l'ouverture de la plage s'il dure encore ; un événement se tait.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Notification", isOn: $regle.notification)
            Toggle("Avec un son", isOn: $regle.son).disabled(!regle.notification)
            Toggle("Symbole dans la barre de menus", isOn: $regle.barre)
            Toggle("Même en plein montage", isOn: $regle.urgente).disabled(!regle.notification)
            Text(mesure.source).font(.caption).foregroundStyle(.secondary)
            if let supprimer {
                Button("Supprimer la règle", role: .destructive) { supprimer() }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func seuil(_ mesure: MesureRegle) -> some View {
        switch mesure.unite {
        case .stockage:
            Stepper("Seuil : \(Fmt.bytes(regle.seuil))", value: seuilValeur(1e9), in: 1...4_000, step: 10)
        case .memoire:
            Stepper("Seuil : \(Fmt.memory(regle.seuil))", value: seuilValeur(Prereglages.gio / 4), in: 1...256, step: 1)
        case .part:
            Stepper("Seuil : \(Fmt.percent(regle.seuil))", value: seuilValeur(0.01), in: 1...100, step: 5)
        case .jours:
            Stepper("Seuil : \(Int(regle.seuil)) jours", value: seuilValeur(1), in: 1...365, step: 1)
        case .etat, .evenement:
            EmptyView()
        }
    }

    private var duree: some View {
        Picker("Tenue au moins", selection: $regle.duree) {
            ForEach(Self.durees, id: \.self) { d in
                Text(d == 0 ? "dès le premier relevé" : d < 60 ? "\(Int(d)) s" : Fmt.duration(d)).tag(d)
            }
        }
    }

    // MARK: Liaisons

    private var actif: Binding<Bool> {
        Binding(get: { regle.active }, set: { allume in
            var r = regle
            r.active = allume
            // Un disque nommé plutôt que « chaque disque externe » : une clé
            // USB de 16 Go est toujours « sous 100 Go ». Le disque de rushes,
            // changeable juste en dessous.
            if allume, r.sujet == nil, CatalogueMesures.mesure(r.mesure)?.parSujet == true,
               let rushes = Self.disqueDeRushes(volumes, previsions) {
                r.sujet = rushes.historyKey
                r.sujetNom = rushes.name
            }
            regle = r
            if allume { allumer(r) }
        })
    }

    private var sujet: Binding<String?> {
        Binding(get: { regle.sujet }, set: { cle in
            regle.sujet = cle
            regle.sujetNom = cle.flatMap { c in volumes.first { $0.historyKey == c }?.name } ?? cle
        })
    }

    private var comparaison: Binding<Comparaison> {
        Binding(get: { regle.comparaison }, set: { regle.comparaison = $0 })
    }

    /// Le seuil dans l'unité affichée (`pas` octets, ou part, par cran).
    private func seuilValeur(_ unite: Double) -> Binding<Double> {
        Binding(get: { (regle.seuil / unite).rounded() }, set: { valeur in
            regle.seuil = valeur * unite
            if let mesure = CatalogueMesures.mesure(regle.mesure) { regle.marge = Self.marge(mesure, regle.seuil) }
        })
    }

    private var avecPlage: Binding<Bool> {
        Binding(get: { regle.plage != nil }, set: { regle.plage = $0 ? PlageHoraire() : nil })
    }

    private func heure(_ champ: WritableKeyPath<PlageHoraire, Int>) -> Binding<Int> {
        Binding(get: { (regle.plage?[keyPath: champ] ?? 0) / 60 * 60 },
                set: { regle.plage?[keyPath: champ] = $0 })
    }

    /// Les disques proposés : ceux qui sont branchés, plus celui que la
    /// règle suit s'il ne l'est pas.
    private var choixDisques: [(cle: String, nom: String)] {
        var out = volumes.map { (cle: $0.historyKey, nom: $0.name + ($0.isInternal ? " (interne)" : "")) }
        if let cle = regle.sujet, !out.contains(where: { $0.cle == cle }) {
            out.append((cle: cle, nom: "\(regle.sujetNom ?? cle) (débranché)"))
        }
        return out
    }

    /// Le disque de rushes : l'externe qui sera plein le plus tôt, sinon le
    /// moins libre. Pas le plus grand — Ssd 2 et Extreme Pro font tous deux
    /// 2 To (relevé du 11/10), et c'est Ssd 2 qui se remplit.
    static func disqueDeRushes(_ volumes: [VolumeSample], _ previsions: [String: FillForecast]) -> VolumeSample? {
        volumes.filter { !$0.isInternal }.min { a, b in
            let da = previsions[a.historyKey]?.daysUntilFull ?? .infinity
            let db = previsions[b.historyKey]?.daysUntilFull ?? .infinity
            return da != db ? da < db : a.available < b.available
        }
    }

    /// L'hystérésis d'une mesure : 10 % du seuil pour une quantité, 5 points
    /// pour une part.
    static func marge(_ mesure: MesureRegle, _ seuil: Double) -> Double {
        switch mesure.unite {
        case .part: return 0.05
        case .stockage, .memoire, .jours: return seuil * 0.1
        case .etat, .evenement: return 0
        }
    }
}

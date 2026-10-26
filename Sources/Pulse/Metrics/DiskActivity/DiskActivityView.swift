import SwiftUI

/// Ce que la carte Disques gagne au chantier 05, sous les volumes : la
/// copie ou le téléchargement en cours, nommé ; une ligne de débit, écriture
/// et lecture, qui s'ouvre sur le miroir des 3 dernières minutes, les
/// applications qui écrivent et la santé des SSD qui la publient.
///
/// Branchée par UNE ligne dans `UI/Cards/DisksCard.swift`. Son modèle est
/// `sampler.disks`, nourri par le relevé commun : la vue ne mesure rien.
///
/// Repliée par défaut, et ce n'est pas un goût : la colonne de droite porte
/// Mémoire, Disques, Montage et Capteurs. Tout déplié en permanence, le
/// panneau mesurait 1457 pt le 11/10, au-delà des 1290 pt utiles de l'écran
/// d'Isma (`./verifie.sh`) ; replié, la section n'ajoute qu'une ligne, plus
/// l'épisode en cours quand il y en a un — ce qu'il faut voir sans cliquer.
struct DiskActivitySection: View {
    @ObservedObject var model: DiskActivity
    /// L'historique ouvert, un seul dans tout le panneau (`CardContext.open`).
    @Binding var open: String?
    /// Carte compacte : l'épisode en cours et la ligne de débit, sans dépliant.
    var compact: Bool = false
    var appCount: Int = 3

    /// Clé du dépliant, dans l'espace partagé des historiques du panneau.
    static let key = "activite-disques"
    /// 60 barres sur 3 min : une toutes les 3 s, plus fin que le relevé
    /// panneau fermé (5 s) et à peine plus large que panneau ouvert (1,5 s).
    static let slots = 60

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 9) {
            ForEach(state.ingestions) { IngestionRow(episode: $0) }
            if state.ingestions.isEmpty, let last = state.recent.first,
               Date().timeIntervalSince(last.lastActive) < 24 * 3600 {
                LastIngestionRow(episode: last)
            }
            if compact {
                rates(state, chevron: false)
            } else {
                Explainable(key: Self.key, label: "de l'activité des disques", spokenName: "activité des disques",
                            spokenValue: spokenRates(state), open: $open) {
                    rates(state, chevron: true).padding(.vertical, 1)
                }
                if open == Self.key {
                    DetailPanel(legende: "Tous les disques physiques : écriture en haut, lecture en bas, "
                                + "chacune à l'échelle de son pic. Santé : journal SMART des SSD qui le publient.",
                                detail: nil) {
                        VStack(alignment: .leading, spacing: 9) {
                            FillSection(reports: Array(model.fill.values))
                            activity(state)
                            writers(state)
                            health(state)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Débit

    /// La ligne repliée : les deux débits du moment, légende du miroir.
    private func rates(_ state: DiskActivityState, chevron: Bool) -> some View {
        let now = state.trail.last
        // « écrit », « lu » : « écriture 13,6 Mo/s · lecture 100 Mo/s » ne
        // tenait pas dans la colonne (tronqué au rendu du 11/10).
        return HStack(spacing: 12) {
            legend("écrit", now.map { "\(Fmt.bytes($0.write))/s" } ?? "—", Palette.data)
            legend("lu", now.map { "\(Fmt.bytes($0.read))/s" } ?? "—", Palette.muted)
            Spacer(minLength: 4)
            if chevron { DisclosureChevron(open: open == Self.key) }
        }
    }

    private func spokenRates(_ state: DiskActivityState) -> String {
        guard let now = state.trail.last else { return "collecte en cours" }
        return "écriture \(Fmt.bytes(now.write)) par seconde, lecture \(Fmt.bytes(now.read)) par seconde"
    }

    private func legend(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func activity(_ state: DiskActivityState) -> some View {
        let bars = Self.resample(state.trail, slots: Self.slots)
        let peakWrite = max(bars.map(\.write).max() ?? 0, Self.floor)
        let peakRead = max(bars.map(\.read).max() ?? 0, Self.floor)
        VStack(spacing: 3) {
            MirrorBars(up: bars.map { $0.write / peakWrite },
                       down: bars.map { $0.read / peakRead },
                       upTint: Palette.data, downTint: Palette.muted,
                       slots: Self.slots,
                       readout: { slot in
                           // Survol : l'heure de la place, à un relevé près,
                           // et ses deux débits (chantier 10).
                           guard slot < bars.count else { return nil }
                           let ago = DiskActivity.trailSpan * (1 - (Double(slot) + 0.5) / Double(Self.slots))
                           return [HoverTime.second(Date().addingTimeInterval(-ago)),
                                   "écriture \(Fmt.bytes(bars[slot].write))/s",
                                   "lecture \(Fmt.bytes(bars[slot].read))/s"]
                       })
                .frame(height: 40)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("débit des disques, 3 dernières minutes")
                .accessibilityValue("pic d'écriture \(Fmt.bytes(bars.map(\.write).max() ?? 0)) par seconde, "
                                    + "pic de lecture \(Fmt.bytes(bars.map(\.read).max() ?? 0)) par seconde")
            HStack {
                Text("max ↑ \(Fmt.bytes(bars.map(\.write).max() ?? 0))/s")
                Spacer()
                // « 3 min » : les pics d'un disque s'écrivent en Mo/s, plus
                // larges que ceux du réseau ; « 3 dernières minutes » se
                // tronquait au rendu du 11/10.
                Text(bars.isEmpty ? "collecte en cours" : "3 min")
                Spacer()
                Text("max ↓ \(Fmt.bytes(bars.map(\.read).max() ?? 0))/s")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
        }
    }

    /// Plancher d'échelle, 1 Mo/s : quelques ko d'un disque au repos ne se
    /// dessinent pas comme des pics.
    static let floor = 1_000_000.0

    // MARK: - Applications

    @ViewBuilder
    private func writers(_ state: DiskActivityState) -> some View {
        if !state.writers.isEmpty {
            CardCaption(text: "Apps qui écrivent", trailing: "par seconde")
            ForEach(Array(state.writers.prefix(appCount))) { group in
                AppRow(group: group, value: "\(Fmt.bytes(group.diskWrite))/s")
            }
        }
    }

    // MARK: - Santé

    @ViewBuilder
    private func health(_ state: DiskActivityState) -> some View {
        let known = state.disks.filter { $0.health != nil }
        // « Non publiée » ne vaut que pour un contrôleur qui ne la publie
        // pas : un SSD compatible dont la lecture a échoué (client SMART
        // tenu par un autre outil) n'est pas un boîtier muet.
        let silent = state.disks.filter { !$0.disk.smartCapable && !$0.disk.isRemovable }
        if !known.isEmpty || !silent.isEmpty {
            CardCaption(text: "Santé", trailing: "SMART")
            ForEach(known) { line in
                if let h = line.health { HealthRow(name: line.name, health: h) }
            }
            if !silent.isEmpty {
                Text("\(silent.map(\.name).joined(separator: ", ")) : non publiée par \(silent.count > 1 ? "leurs boîtiers" : "son boîtier")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Calcul

    /// Le miroir sur une grille fixe : `slots` cases sur les 3 dernières
    /// minutes, chacune prenant le débit du relevé qui la couvre. Les relevés
    /// tombent toutes les 5 s panneau fermé et 1,5 s ouvert ; dessinés tels
    /// quels, l'axe du temps changerait d'échelle à l'ouverture. Une case
    /// que rien ne couvre (avant le premier relevé) reste vide.
    static func resample(_ trail: [DiskTrailPoint], slots: Int,
                         span: Double = DiskActivity.trailSpan) -> [(read: Double, write: Double)] {
        guard let end = trail.last?.t, slots > 0 else { return [] }
        let step = span / Double(slots)
        var out: [(read: Double, write: Double)] = []
        var index = 0
        for slot in 0..<slots {
            let center = end - span + (Double(slot) + 0.5) * step
            while index < trail.count, trail[index].t < center { index += 1 }
            guard index < trail.count, trail[index].t - trail[index].interval <= center else {
                out.append((0, 0))
                continue
            }
            out.append((trail[index].read, trail[index].write))
        }
        // Les cases d'avant le premier relevé sont retirées, pas mises à zéro :
        // `MirrorBars` aligne alors la série à droite, comme le miroir réseau
        // à son ouverture, au lieu de dessiner une minute de « rien écrit ».
        let covered = trail.first.map { $0.t - $0.interval } ?? end
        let start = max(0, Int(((covered - (end - span)) / step - 0.5).rounded(.up)))
        return start < out.count ? Array(out[start...]) : []
    }
}

/// « Ce qui remplit » : pour les deux volumes externes qui ont le plus reçu
/// en 7 jours, les dossiers où les octets sont arrivés, en 24 h et en 7 j.
private struct FillSection: View {
    let reports: [FillReport]

    var body: some View {
        let shown = reports.filter { $0.weekBytes > 0 }.sorted { $0.weekBytes > $1.weekBytes }.prefix(2)
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown), id: \.volumeKey) { report in
                    CardCaption(text: "Arrivé sur \(report.volumeName)", trailing: "24 h · 7 j")
                    ForEach(report.week.prefix(3), id: \.path) { folder in
                        row(folder.label, day: report.day.first { $0.path == folder.path }?.bytes, week: folder.bytes)
                    }
                    row("Total", day: report.dayBytes, week: report.weekBytes, total: true)
                }
                Text("Date d'ajout de chaque fichier, d'après l'index Spotlight · relevé à \(Self.clock(shown.map(\.at).min() ?? Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, day: Double?, week: Double, total: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(total ? .callout : .callout)
                .foregroundStyle(total ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text("\(day.map { $0 > 0 ? Fmt.bytes($0) : "—" } ?? "—") · \(Fmt.bytes(week))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(total ? .primary : .secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%d h %02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Une écriture massive en cours : sa nature, sa cible, son débit, puis ce
/// qu'elle a écrit et depuis quand, et qui l'écrit.
private struct IngestionRow: View {
    let episode: Ingestion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: IngestionRow.symbol(episode.kind))
                .font(.callout)
                .foregroundStyle(Palette.data)
                .frame(width: 15)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(episode.label) → \(episode.target)").font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(Fmt.bytes(episode.rate))/s").font(.callout.monospacedDigit())
                }
                Text("\(Fmt.bytes(episode.bytes)) depuis \(Self.clock(episode.start))" + (episode.app.map { " · \($0)" } ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ kind: Ingestion.Kind) -> String {
        switch kind {
        case .card:     return "sdcard"
        case .copy:     return "doc.on.doc"
        case .download: return "arrow.down.circle"
        case .export:   return "square.and.arrow.up"
        case .write:    return "square.and.pencil"
        }
    }

    /// « 14 h 02 » : l'heure à la française, comme les durées de `Fmt`.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%d h %02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// La dernière écriture massive close, des dernières 24 h : ce qui explique
/// souvent, à lui seul, un « plein vers mardi ».
private struct LastIngestionRow: View {
    let episode: Ingestion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: IngestionRow.symbol(episode.kind))
                .font(.callout)
                .foregroundStyle(Palette.muted)
                .frame(width: 15)
                .accessibilityHidden(true)
            // Deux lignes, comme l'épisode en cours : sur une seule, la plage
            // horaire mangeait le volume écrit (« Téléchargement → Ssd 2… »,
            // rendu du 11/10).
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(episode.label) → \(episode.target)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.bytes(episode.bytes)).font(.callout.monospacedDigit()).lineLimit(1)
                }
                Text(span + (episode.app.map { " · \($0)" } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// « hier 22 h 10 → 5 h 12 », « 3 h 31 → 4 h 31 » : la veille est dite.
    private var span: String {
        let day = Calendar.current.isDateInToday(episode.start) ? "" : "hier "
        return "\(day)\(IngestionRow.clock(episode.start)) → \(IngestionRow.clock(episode.lastActive))"
    }
}

/// Un SSD qui publie son journal SMART : son état en mots, l'usure, la
/// température. Le symbole n'apparaît que quand il y a quelque chose à dire.
private struct HealthRow: View {
    let name: String
    let health: DiskHealth

    var body: some View {
        HStack(spacing: 7) {
            if health.status != .good {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(health.status == .failing ? Palette.alert : Palette.warning)
                    .accessibilityHidden(true)
            }
            Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(value).font(.callout.monospacedDigit()).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var value: String {
        var parts = [health.statusLabel, "usure \(health.percentUsed)\u{00A0}%"]
        if let t = health.temperature { parts.append("\(t)\u{00A0}°C") }
        return parts.joined(separator: " · ")
    }
}

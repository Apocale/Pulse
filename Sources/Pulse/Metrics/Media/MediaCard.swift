import SwiftUI
import AppKit

/// La carte Médias : ce qu'iStat ne sait pas faire pour un monteur.
///
/// L'export en cours et le fichier qu'il écrit, les exports de la semaine, la
/// carte graphique et ses clients, l'encodeur vidéo matériel, le cache média
/// d'Adobe. Chaque chiffre se retrouve dans la section MÉDIAS de `--probe`.
///
/// Inscrite au registre des modules (`MediaModule`), masquée par défaut faute
/// de place ; se rend seule avec `--snapshot x.png --carte medias`. Le même
/// contenu (`MediaDetail`) se déplie sous la ligne « Export » de la carte
/// Montage (`ExportsDisclosure`) : c'est là qu'Isma le trouve d'office.
///
/// Couleurs : uniquement des teintes de `Palette` déjà mesurées, sur des
/// symboles, des barres et des anneaux — jamais sur du texte (règle n°6).
struct MediaCard: View {
    @ObservedObject var sampler: Sampler
    let context: CardContext

    /// Dense, comme les menus d'iStat : une ligne par fait, pas de légende
    /// de section. Relevé le 11/10 : avec les cartes Énergie et Capteurs, la
    /// première version (385 pt) faisait monter le panneau à 1 560 pt, pour
    /// 1 290 utiles sur l'écran d'Isma.
    var body: some View {
        let state = sampler.medias
        let today = state.exportsToday.filter { $0.outcome != .failure }
        Card {
            CardTitle(title: "Médias", symbol: "film.stack",
                      trailing: today.isEmpty ? nil
                        : "\(MediaProbe.countText(today.count)) · \(Fmt.duration(today.totalDuration))")
            if sampler.export != nil || !state.writing.isEmpty {
                liveExport(state)
            }
            MediaDetail(sampler: sampler, compact: context.compact,
                        exportsTint: context.tint("exports"), gpuTint: context.tint("gpu"))
        }
    }

    // MARK: - Export en cours

    /// L'export vu en direct (charge de Media Encoder) et les fichiers média
    /// ouverts en écriture : nom, taille déjà écrite, débit. Pas de
    /// progression : la taille finale n'est connue de personne avant la fin.
    @ViewBuilder
    private func liveExport(_ state: MediaState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let export = sampler.export {
                InfoRow(label: "Export \(Fmt.appName(export.app))",
                        value: "depuis \(Fmt.duration(export.duration))", dot: Palette.data)
            }
            ForEach(state.writing) { file in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(Fmt.bytes(file.bytes) + (file.rate.map { " · \(Fmt.bytes($0))/s" } ?? ""))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Le contenu de la carte Médias, sans son titre : la semaine d'exports, la
/// carte graphique, le cache. Partagé par la carte et par le dépliant de la
/// ligne « Export » de la carte Montage.
struct MediaDetail: View {
    @ObservedObject var sampler: Sampler
    var compact = false
    var exportsTint: Color = Palette.data
    var gpuTint: Color = Palette.data

    var body: some View {
        let state = sampler.medias
        VStack(alignment: .leading, spacing: 9) {
            exports(state)
            gpu(state.engines)
            // Compacte : les dessins, sans les listes.
            if !compact {
                cache(state.cache)
            }
        }
    }

    // MARK: - Exports terminés

    private func exports(_ state: MediaState) -> some View {
        // « Aujourd'hui » : l'heure du relevé figé pour les rendus de
        // référence (19-suivis), sinon l'heure qu'il est.
        let now = sampler.maintenantFige ?? Date()
        let week = sampler.mediaTracker.history.exports(since: Self.startOfWeek(now: now))
        return VStack(alignment: .leading, spacing: 4) {
            ExportWeekChart(records: week, tint: exportsTint, now: now)
            if let last = state.lastExport, !compact {
                InfoRow(label: "Dernier", value: Self.lastText(last, now: now))
            }
        }
    }

    /// Minuit, il y a six jours : sept colonnes, aujourd'hui compris.
    nonisolated static func startOfWeek(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
    }

    /// « 03:54 · Interview 5.mp4 · 4,2 Go », l'heure seule si c'est aujourd'hui.
    static func lastText(_ record: ExportRecord, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: record.end)
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        var parts = [f.string(from: date)]
        if let output = record.output { parts.append((output as NSString).lastPathComponent) }
        if let bytes = record.bytes { parts.append(Fmt.bytes(bytes)) }
        if record.outcome == .failure { parts.append("échec") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Carte graphique

    @ViewBuilder
    private func gpu(_ media: MediaSample?) -> some View {
        if let media {
            HStack(alignment: .center, spacing: 12) {
                Ring(fraction: media.gpuUtilization ?? 0, tint: gpuTint, lineWidth: 6) {
                    RingCenter(value: media.gpuUtilization.map(Fmt.percent) ?? "—", caption: "GPU")
                }
                .frame(width: 64, height: 64)
                // Ni fréquence ni puissance ici : la carte Capteurs (04) les
                // affiche déjà, lues sur un autre intervalle — deux chiffres
                // proches mais différents pour la même grandeur, dans le même
                // panneau, se contrediraient (1 384 MHz contre 1,39 GHz au
                // rendu du 11/10). Ils restent dans `--probe`, section MÉDIAS.
                VStack(spacing: 3) {
                    InfoRow(label: "Mémoire tenue", value: media.gpuMemory.map { Fmt.memory($0) } ?? "—")
                        .help("Mémoire que le GPU tient en ce moment, prise sur la mémoire unifiée — "
                              + "la même que celle des applications.")
                    // Le décodeur et ProRes, non mesurables sans root, sont
                    // dits dans l'infobulle et dans `--probe`, pas à l'écran.
                    InfoRow(label: "Encodeur vidéo", value: Self.engineText(media.encoderPower))
                        .help("L'encodeur vidéo matériel (H.264, HEVC) publie son énergie sans droits "
                              + "administrateur ; le décodeur et les moteurs ProRes ne publient rien. Seuil "
                              + "« au travail » posé à " + Self.watts(MediaSample.encoderBusyWatts)
                              + ", à calibrer sur un export réel.")
                    // L'application qui occupe le plus le GPU, et elle seule :
                    // sous 1 %, une application ne fait que passer.
                    if !compact, let app = media.gpuApps.first(where: { $0.share >= 0.01 }) {
                        HStack(spacing: 7) {
                            AppIcon(path: app.bundlePath).frame(width: 15, height: 15)
                            Text(app.bundleId.hasPrefix("exec:") ? Fmt.processName(app.name) : Fmt.appName(app.name))
                                .font(.callout).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(Fmt.cpu(app.share * 100))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .help("Part du temps GPU sur le dernier relevé. Plusieurs applications peuvent "
                              + "l'occuper en même temps : la somme peut dépasser 100 %.")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } else {
            Text("mesure en cours")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Moteurs

    static func engineText(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        return watts >= MediaSample.encoderBusyWatts ? "au travail · " + Self.watts(watts) : "au repos"
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        let digits = value < 10 ? 2 : 1
        return String(format: "%.\(digits)f W", value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Cache média

    @ViewBuilder
    private func cache(_ measure: MediaCache.Measure?) -> some View {
        HStack(spacing: 7) {
            Text("Cache").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(measure.map { $0.found
                    ? "\(Fmt.bytes($0.bytes, digits: 0)) · \(Fmt.bytes($0.staleBytes, digits: 0)) dormants"
                    : "introuvable" } ?? "mesure en cours")
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .help("Le cache média d'Adobe (Premiere, After Effects, Media Encoder). Dormants : "
                      + "fichiers que rien n'a modifiés depuis 30 jours — ce que l'option « supprimer "
                      + "les fichiers de cache plus anciens que… » de Premiere libérerait.")
            // Un symbole seul, comme la barre de raccourcis : 26 pt de côté,
            // au-dessus du minimum du HIG, et un bouton AppKit ne se dessine
            // pas dans un rendu hors écran (`--snapshot`). Pas de bouton vers
            // un cache introuvable : le Finder n'aurait rien à montrer.
            if measure?.found != false { cacheButton(measure) }
        }
    }

    private func cacheButton(_ measure: MediaCache.Measure?) -> some View {
        Button {
            let location = measure?.location ?? MediaCache.location()
            NSWorkspace.shared.activateFileViewerSelecting([location.files])
        } label: {
            Image(systemName: "folder")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pulseIcon)
        .help("Ouvrir le cache média dans le Finder. Pulse ne supprime rien : "
              + "Premiere › Réglages › Cache des médias.")
        .accessibilityLabel("Ouvrir le cache média dans le Finder")
    }
}

/// La ligne « Export » de la carte Montage, enrichie par le chantier 08 :
/// MÊME hauteur qu'avant (le panneau fait 1 216 pt sur 1 290 utiles), le
/// nombre d'exports du jour en plus, et tout le détail de la carte Médias
/// dans un dépliant — un seul ouvert à la fois, comme les autres.
///
/// Le dépliant ouvert, et lui seul, réveille la lecture du GPU et de
/// l'encodeur quand la carte Médias est masquée (`MediaTracker.addViewer`).
struct ExportsDisclosure: View {
    @ObservedObject var sampler: Sampler
    @Binding var open: String?

    static let key = "exports"

    var body: some View {
        let today = sampler.medias.exportsToday.filter { $0.outcome != .failure }
        HistoryToggle(key: Self.key, label: "des exports et de la carte graphique",
                      spoken: sampler.export.map { "Export \(Fmt.appName($0.app))" } ?? "Export",
                      value: sampler.export.map { "depuis \(Fmt.duration($0.duration))" }
                        ?? (today.isEmpty ? "aucun en cours" : "aucun en cours, \(today.count) aujourd'hui"),
                      open: $open) {
            HStack(spacing: 7) {
                if let export = sampler.export {
                    Circle().fill(Palette.data).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text("Export \(Fmt.appName(export.app))").font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("depuis \(Fmt.duration(export.duration))").font(.callout.monospacedDigit())
                } else {
                    Text("Export").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(today.isEmpty ? "aucun en cours" : "aucun en cours · \(today.count) aujourd'hui")
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                }
                DisclosureChevron(open: open == Self.key)
            }
            // `HistoryToggle` ajoute 1 pt en haut et en bas : rendu au point
            // près, la carte Montage gagnait 2 pt (318 → 322 px au rendu
            // figé). La ligne garde la hauteur de l'ancienne `InfoRow`.
            .padding(.vertical, -1)
        }
        if open == Self.key {
            DetailPanel(legende: "Exports d'après le journal de Media Encoder.", detail: nil) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(sampler.medias.writing) { file in
                        WrittenFileRow(file: file)
                    }
                    MediaDetail(sampler: sampler)
                }
            }
            .onAppear { MediaTracker.addViewer() }
            .onDisappear { MediaTracker.removeViewer() }
        }
    }
}

/// Un fichier média en cours d'écriture : nom, taille écrite, débit. Pas de
/// progression : la taille finale n'est connue de personne avant la fin.
struct WrittenFileRow: View {
    var file: WrittenFile

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Fmt.bytes(file.bytes) + (file.rate.map { " · \(Fmt.bytes($0))/s" } ?? ""))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Les exports des sept derniers jours, une colonne par jour, hauteur =
/// durée d'encodage cumulée, à l'échelle du pic de la semaine (écrit au-dessus,
/// comme dans le dépliant du temps d'écran).
struct ExportWeekChart: View {
    var records: [ExportRecord]
    var tint: Color = Palette.data
    /// Le dernier des sept jours.
    var now = Date()

    var body: some View {
        let days = Self.byDay(records, now: now)
        let peak = days.map(\.seconds).max() ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(days.allSatisfy { $0.count == 0 } ? "aucun export sur 7 jours"
                     : "\(days.reduce(0) { $0 + $1.count }) exports sur 7 jours")
                Spacer()
                if peak > 0 { Text("pic \(Fmt.duration(peak))") }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Canvas { context, size in
                guard peak > 0 else { return }
                // Rail de chaque jour, pour qu'un jour sans export se lise
                // comme une colonne vide et non comme un trou.
                let rail = size.width / CGFloat(days.count)
                for index in days.indices {
                    let rect = CGRect(x: CGFloat(index) * rail + rail * 0.22, y: size.height - 1,
                                      width: rail * 0.56, height: 1)
                    context.fill(Path(rect), with: .color(Palette.track))
                }
                let step = size.width / CGFloat(days.count)
                let width = max(2, step * 0.56)
                for (index, day) in days.enumerated() where day.seconds > 0 {
                    let height = max(2, CGFloat(day.seconds / peak) * size.height)
                    let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2,
                                      y: size.height - height, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(tint))
                }
            }
            .frame(height: 30)
            HStack(spacing: 0) {
                ForEach(Array(Self.initials(now: now).enumerated()), id: \.offset) { _, letter in
                    Text(letter).frame(maxWidth: .infinity)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exports des sept derniers jours")
        // Le jour en toutes lettres avec son nombre : « 0, 2, 1… » ne disait
        // pas à quel jour revenait quel chiffre (chantier 16).
        .accessibilityValue(zip(Self.dayNames(now: now), days)
            .map { "\($0) \($1.count)" }.joined(separator: ", "))
    }

    /// Les sept jours en toutes lettres, du plus ancien à aujourd'hui.
    static func dayNames(now: Date = Date()) -> [String] {
        let calendar = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE"
        return (0..<7).reversed().map { offset in
            offset == 0 ? "aujourd'hui"
                : calendar.date(byAdding: .day, value: -offset, to: now).map { f.string(from: $0) } ?? ""
        }
    }

    /// L'initiale de chaque jour, du plus ancien à aujourd'hui : « L M M J V S D ».
    static func initials(now: Date = Date()) -> [String] {
        let calendar = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEEE"
        return (0..<7).reversed().map { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map { f.string(from: $0).uppercased() } ?? ""
        }
    }

    /// Sept jours, du plus ancien à aujourd'hui, échecs exclus.
    static func byDay(_ records: [ExportRecord], now: Date = Date()) -> [(count: Int, seconds: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return (0, 0) }
            let day = records.filter {
                $0.outcome != .failure && $0.end >= start.timeIntervalSince1970 && $0.end < end.timeIntervalSince1970
            }
            return (day.count, day.totalDuration)
        }
    }
}

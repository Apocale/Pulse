import SwiftUI

/// Disques : chaque volume monté, son occupation en anneau, l'espace libre et
/// l'échéance de remplissage. L'historique des 30 jours s'ouvre depuis le
/// titre.
struct DisksModule: PulseModule {
    let id = "disques"
    let name = "Disques"
    let symbol = "internaldrive"
    var summary: String { "Chaque volume, son espace libre et le jour où il sera plein." }
    var defaultColumn: Int { 1 }

    func card(_ context: CardContext) -> AnyView {
        AnyView(DisksCard(sampler: context.sampler, context: context))
    }

    /// Le disque le plus serré au sens du verdict : celui qui va saturer le
    /// premier passe devant le simplement plein. Mêmes valeurs que la barre
    /// combinée (`MenuBarLabel`).
    func menuBarSegment(_ sampler: Sampler) -> MenuBarSegment? {
        guard let fullest = VerdictEngine.bySeverity(VerdictInput(volumes: sampler.volumes,
                                                                  forecasts: sampler.forecasts)).first
        else { return nil }
        let value = Fmt.occupancy(fullest.usedFraction)
        return MenuBarSegment(label: MenuBarLabel.diskLabel(fullest.name), value: value,
                              spoken: "\(fullest.name) occupé à \(value)", fraction: fullest.usedFraction)
    }
}

struct DisksCard: View {
    @ObservedObject var sampler: Sampler
    let context: CardContext

    var body: some View {
        let sorted = VerdictEngine.bySeverity(VerdictInput(volumes: sampler.volumes,
                                                           forecasts: sampler.forecasts))
        return Card {
            HistoryToggle(key: "volumes", label: "des volumes", spoken: "Disques", heading: true, open: context.open) {
                CardTitle(title: "Disques", symbol: "internaldrive", open: context.open.wrappedValue == "volumes")
            }
            ForEach(sorted) { volume in
                HStack(spacing: 10) {
                    Ring(fraction: volume.usedFraction, tint: volumeTint(volume), lineWidth: context.compact ? 3 : 4) {
                        if !context.compact {
                            Text("\(Int((volume.usedFraction * 100).rounded(.down)))")
                                .font(.caption2.monospacedDigit().weight(.medium))
                        }
                    }
                    .frame(width: context.compact ? 16 : 32, height: context.compact ? 16 : 32)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(volume.name).font(.callout).lineLimit(1)
                            if !volume.isInternal {
                                Image(systemName: "externaldrive").font(.caption2).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        // Compacte : une ligne par volume, l'espace libre à droite.
                        if !context.compact {
                            Text("\(Fmt.bytes(volume.available)) libres · \(volumeCaption(volume))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if context.compact {
                        Text("\(Fmt.bytes(volume.available)) libres")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                // Combinée, la ligne se lisait « 86, Ssd 2, … » : le chiffre
                // de l'anneau sans son unité, avant le nom. Le nom d'abord,
                // puis l'occupation en toutes lettres (chantier 16). `.combine`
                // et non `.ignore`, qui sort en AXUnknown (README).
                .accessibilityElement(children: .combine)
                .accessibilityLabel(volume.isInternal ? volume.name : "\(volume.name), disque externe")
                .accessibilityValue("occupé à \(Fmt.occupancy(volume.usedFraction)), "
                                    + "\(Fmt.bytes(volume.available)) libres, \(volumeCaption(volume))")
            }
            DiskActivitySection(model: sampler.disks, open: context.open, compact: context.compact, appCount: context.appCount) // 05-disques
            HistoryPanel(key: "volumes", open: context.open.wrappedValue) {
                VolumesPanel(sampler: sampler)
            }
        }
    }

    /// Les seuils mêmes des règles 3 et 8 du verdict : l'anneau ne peut pas
    /// virer à l'orange sans que la phrase le dise, ni l'inverse.
    private func volumeTint(_ volume: VolumeSample) -> Color {
        if volume.usedFraction >= VerdictEngine.volumeAlertFraction { return Palette.alert }
        if volume.usedFraction >= VerdictEngine.volumeWarningFraction { return Palette.warning }
        if let days = sampler.forecasts[volume.historyKey]?.daysUntilFull,
           days < VerdictEngine.forecastAlertDays { return Palette.alert }
        return Palette.muted
    }

    /// L'échéance en jour de la semaine quand elle tombe dans la semaine :
    /// « plein vers lundi » se lit mieux que « ~2 jours ».
    private func volumeCaption(_ volume: VolumeSample) -> String {
        guard let forecast = sampler.forecasts[volume.historyKey] else { return "tendance en calcul" }
        guard let days = forecast.daysUntilFull else { return forecast.trendText }
        return Fmt.fullBy(days: days)
    }
}

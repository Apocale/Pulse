import SwiftUI

/// `--snapshot x.png --conseils` : le bandeau du verdict pour chaque sorte de
/// conseil, sur des relevés fabriqués (ceux d'`AdviceTests`), à la largeur
/// du panneau à deux colonnes puis à une. Pour voir, sans attendre que la
/// machine s'y prête, qu'aucun conseil ne déborde ni n'ajoute de ligne.
///
/// Les phrases et les conseils sortent du vrai barème et du vrai `Advisor` ;
/// seul le dessin du bandeau est reproduit, avec les styles de `PopoverView`.
@MainActor
enum AdviceSnapshot {
    static func view() -> AnyView {
        let cases = scenarios()
        return AnyView(
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                    banner(item.verdict, item.advice, stacked: false).frame(width: 594)
                }
                Text("une colonne").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(cases.prefix(2).enumerated()), id: \.offset) { _, item in
                    banner(item.verdict, item.advice, stacked: true).frame(width: 296)
                }
            }
            .padding(16)
            .frame(width: 626, alignment: .leading)
            .background(PopoverBackground()))
    }

    /// Le bandeau, aux styles de `PopoverView.verdictBanner`.
    private static func banner(_ verdict: Verdict, _ advice: Advice?, stacked: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(verdict.level == .alert ? Palette.alert : Palette.warning)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: verdict.symbol)
                    .font(.title2)
                    .foregroundStyle(verdict.level == .alert ? Palette.alert : Palette.warning)
                    .frame(width: 22)
                VerdictLines(advice: advice, stacked: stacked) {
                    Text(verdict.phrase).font(.title2.weight(.semibold)).lineLimit(2)
                } evidence: {
                    Text(verdict.evidence)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func scenarios() -> [(verdict: Verdict, advice: Advice?)] {
        let gio: UInt64 = 1 << 30, go: UInt64 = 1_000_000_000
        func volume(_ name: String, _ total: UInt64, _ free: UInt64, inside: Bool = false) -> VolumeSample {
            VolumeSample(name: name, path: inside ? "/" : "/Volumes/\(name)", total: total * go,
                         available: free * go, isInternal: inside, uuid: name, availableStrict: free * go)
        }
        func app(_ name: String, _ id: String, _ footprint: Double, cpu: Double = 5) -> ProcessGroup {
            ProcessGroup(bundleId: id, name: name, cpu: cpu, footprint: UInt64(footprint * Double(gio)),
                         processCount: 3, bundlePath: "/Applications/\(name).app")
        }
        let calm = MemorySample(total: 32 * gio, app: 14 * gio, wired: 6 * gio, compressed: 5 * gio,
                                cached: 0, swapUsed: 0, swapTotal: 0, pressureLevel: 1)
        var inputs: [VerdictInput] = []

        var memory = VerdictInput()
        memory.memory = calm
        memory.memory.pressureLevel = 2
        memory.memory.swapUsed = 5 * gio
        memory.processes = [app("Adobe Premiere Pro 2026", "com.adobe.PremierePro.26", 21),
                            app("Microsoft Teams (work or school)", "com.microsoft.teams2", 6.2)]
        inputs.append(memory)

        var full = VerdictInput()
        full.memory = calm
        full.volumes = [volume("Macintosh HD", 995, 600, inside: true), volume("Ssd 2", 2_000, 160),
                        volume("Extreme Pro", 2_000, 719)]
        inputs.append(full)

        var filling = VerdictInput()
        filling.memory = calm
        filling.volumes = [volume("Macintosh HD", 995, 600, inside: true), volume("Ssd 2", 2_000, 307),
                           volume("Extreme Pro", 2_000, 719)]
        filling.forecasts = ["Ssd 2": FillForecast(bytesPerDay: -90.1e9, daysUntilFull: 3.4, ruptures: 0,
                                                   calmSeconds: 86_400, window: 86_400)]
        inputs.append(filling)

        var inside = VerdictInput()
        inside.memory = calm
        inside.volumes = [volume("Macintosh HD", 995, 30, inside: true)]
        inputs.append(inside)

        var busy = VerdictInput()
        busy.memory = calm
        busy.cpu.total = 0.95
        busy.processes = [app("Vivaldi", "com.vivaldi.Vivaldi", 2, cpu: 250),
                          app("Adobe Premiere", "com.adobe.PremierePro.26", 21, cpu: 180)]
        inputs.append(busy)

        var out = inputs.map { input in
            let verdict = VerdictEngine.instant(input).verdict
            return (verdict: verdict, advice: Advisor.advice(for: verdict, input))
        }
        // Le même disque qui se remplit, une copie de carte en cours dessus
        // (détection du chantier 05) : la ligne dit pourquoi.
        let now = Date()
        let copy = Ingestion(kind: .card, target: "Ssd 2", targetKey: "Ssd 2", source: "EOS_DIGITAL",
                             app: "ffmpeg", start: now.addingTimeInterval(-300), lastActive: now,
                             bytes: 1.3e9, rate: 4.3e6, active: true)
        let verdict = VerdictEngine.instant(filling).verdict
        out.insert((verdict, Advisor.advice(for: verdict, filling, ingestions: [copy])), at: 3)
        return out
    }
}

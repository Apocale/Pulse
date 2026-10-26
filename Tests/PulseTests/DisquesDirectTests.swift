import Foundation
import Testing
@testable import Pulse

/// Chantier 05 : le détecteur sur la vraie machine, pendant quelques
/// minutes, au rythme de l'app panneau fermé (5 s), avec les mêmes pièces
/// que `DiskActivity.observe`. Lancé à la main seulement —
/// `PULSE_DIRECT=300 swift test --filter DirectDisquesTests` —, jamais par
/// `swift test` ni `./verifie.sh` : il dure, et dépend de ce que la machine
/// écrit à ce moment-là. Rien n'est écrit.
@Suite struct DirectDisquesTests {
    static let seconds = Double(ProcessInfo.processInfo.environment["PULSE_DIRECT"] ?? "") ?? 0

    @Test(.enabled(if: seconds > 0))
    func leDetecteurSurLaVraieMachine() {
        let monitor = ProcessMonitor()
        let volumes = DiskMonitor.volumes()
        let map = DiskActivity.map(volumes)
        var meter = DiskRateMeter()
        var detector = IngestionDetector()
        var seen: [String: Ingestion] = [:]
        let end = Date().addingTimeInterval(Self.seconds)
        _ = monitor.sample()
        while Date() < end {
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
            let readings = DiskIO.read(known: [:])
            let rates = meter.update(now: now, readings: Dictionary(readings.map { ($0.disk.id, $0.counters) },
                                                                    uniquingKeysWith: { a, _ in a }))
            let processes = monitor.sample()
            if let interval = rates.values.map(\.interval).max(), interval > 0 {
                let lines = DiskActivity.lines(disks: readings.map(\.disk), volumes: volumes, map: map, rates: rates)
                let input = DiskActivity.ingestionInput(lines: lines, interval: interval,
                                                        networkRx: NetworkMonitor.measure(over: 0.2)?.sample.rxRate ?? 0,
                                                        processes: processes, exporting: false,
                                                        devices: { WrittenDevices.devices(of: $0.pids) })
                let (open, finished) = detector.observe(input)
                for e in open + finished { seen[e.id] = e }
            }
            Thread.sleep(forTimeInterval: 5)
        }
        for e in seen.values.sorted(by: { $0.start < $1.start }) {
            print("épisode : \(DiskProbe.episodeText(e))")
        }
        if seen.isEmpty { print("aucun épisode en \(Int(Self.seconds)) s") }
    }
}

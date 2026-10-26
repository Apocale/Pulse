import Foundation
import Testing
@testable import Pulse

/// Chantier 05 : ce que coûte un relevé des disques panneau fermé, mesuré
/// sur la vraie machine — compteurs IOKit, débits, détecteur d'ingestion —
/// en temps processeur du fil, pas en temps écoulé.
///
/// Le plafond posé ici (1 ms par relevé, soit 0,02 % d'un cœur au rythme de
/// 5 s) est large exprès : il ne sert pas à mesurer finement, il attrape une
/// régression d'un autre ordre — une requête Spotlight ou un parcours de
/// dossier glissé dans le relevé.
@Suite struct CoutDisquesTests {
    static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    @Test func unReleveDesDisquesPanneauFermeCouteMoinsDUneMilliseconde() {
        let model = DiskActivity()
        let monitor = ProcessMonitor()
        _ = monitor.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let processes = monitor.sample()
        let volumes = DiskMonitor.volumes()
        // Premier passage : carte volume → disque, une fois pour toutes.
        model.observe(processes: processes, volumes: volumes, exporting: false)

        let rounds = 200
        let start = Self.threadCPU()
        for _ in 0..<rounds {
            model.observe(processes: processes, volumes: volumes, exporting: false)
        }
        let perTick = (Self.threadCPU() - start) / Double(rounds)
        print("coût d'un relevé des disques, panneau fermé : \(Int((perTick * 1e6).rounded())) µs "
              + "(\(String(format: "%.4f", perTick / 5 * 100)) % d'un cœur au rythme de 5 s)")
        #expect(perTick < 0.001)
    }
}

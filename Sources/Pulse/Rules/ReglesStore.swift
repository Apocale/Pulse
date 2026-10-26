import Foundation
import Combine

/// Les règles d'Isma, lues au lancement et écrites à chaque changement dans
/// `~/Library/Application Support/Pulse/regles.json`.
///
/// Fichier à part, comme `reglages.json` et `reseau.json` : une règle abîmée
/// ne doit jamais pouvoir coûter les réglages ni l'historique. Illisible
/// malgré le décodage tolérant, il est mis de côté en
/// `regles.illisible.json`, jamais écrasé.
///
/// `Persistence.enabled` faux (`--snapshot`, `--probe`, `--banc`) : lu,
/// jamais écrit.
@MainActor
final class ReglesStore: ObservableObject {
    static let shared = ReglesStore()

    @Published var fichier: FichierRegles {
        didSet { if fichier != oldValue { planifierEcriture() } }
    }

    let url: URL
    let ecrit: Bool
    private var enAttente: DispatchWorkItem?

    nonisolated static var urlParDefaut: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("regles.json")
    }

    init(url: URL = ReglesStore.urlParDefaut, ecrit: Bool? = nil) {
        self.url = url
        let ecrit = ecrit ?? Persistence.enabled
        self.ecrit = ecrit
        fichier = Self.charger(url, mettreDeCote: ecrit)
    }

    /// Absent : les préréglages, tous éteints. Illisible — pas même un objet
    /// JSON — : mis de côté, puis les préréglages.
    nonisolated static func charger(_ url: URL, mettreDeCote: Bool) -> FichierRegles {
        guard let data = try? Data(contentsOf: url) else { return FichierRegles() }
        if let lu = try? JSONDecoder().decode(FichierRegles.self, from: data) { return lu }
        if mettreDeCote { Persistence.setAside(url) }
        return FichierRegles()
    }

    nonisolated static func encoder(_ fichier: FichierRegles) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(fichier)
    }

    /// Les règles du moment.
    var regles: [Regle] { fichier.regles }

    func regle(_ id: String) -> Regle? { fichier.regles.first { $0.id == id } }

    func modifier(_ id: String, _ changement: (inout Regle) -> Void) {
        guard let i = fichier.regles.firstIndex(where: { $0.id == id }) else { return }
        changement(&fichier.regles[i])
    }

    private func planifierEcriture() {
        enAttente?.cancel()
        let travail = DispatchWorkItem { [weak self] in self?.ecrire() }
        enAttente = travail
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: travail)
    }

    func vider() { if enAttente != nil { ecrire() } }

    func ecrire() {
        enAttente?.cancel()
        enAttente = nil
        guard ecrit, let data = try? Self.encoder(fichier) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

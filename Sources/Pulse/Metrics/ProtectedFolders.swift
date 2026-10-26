import Foundation

/// Les dossiers que macOS protège : Bureau, Documents, Téléchargements,
/// iCloud Drive et les autres stockages en ligne, et tout disque externe ou
/// réseau. Y lire un fichier — même l'Info.plist d'une app lancée de là —
/// fait demander à l'écran « Pulse souhaite accéder aux fichiers de votre
/// dossier Téléchargements ».
///
/// Pulse nomme chaque processus d'après l'Info.plist du bundle qui le
/// contient, panneau fermé compris : une seule app lancée depuis
/// Téléchargements aurait fait surgir la demande sur le Mac d'un ami
/// (26/10). Sous ces chemins, rien n'est lu ; l'app garde le nom de son
/// dossier, comme quand la lecture échoue.
enum ProtectedFolders {
    private static let roots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { "\(home)/\($0)/" } + ["/Volumes/"]
    }()

    static func contains(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0) }
    }

    /// L'Info.plist d'un bundle, s'il se lit sans rien demander à macOS.
    static func bundleInfo(_ bundlePath: String) -> [String: Any]? {
        guard !contains(bundlePath) else { return nil }
        let plist = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

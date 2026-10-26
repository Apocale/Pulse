import Foundation

/// Classement des applications par rôle dans une journée de montage.
/// Sert à colorer le classement et, plus tard, à calculer le rapport
/// entre temps créatif et temps administratif.
enum AppKind {
    case editing     // montage et compositing
    case encoding    // export et transcodage
    case other

    /// Les identifiants Adobe portent leur numéro de version
    /// (com.adobe.PremierePro.26), et les versions bêta un suffixe
    /// supplémentaire : on compare donc sur des préfixes, jamais sur l'égalité.
    static func of(bundleId: String) -> AppKind {
        let id = bundleId.lowercased()
        let editing = [
            "com.adobe.premierepro",
            "com.adobe.aftereffects",
            "com.adobe.photoshop",
            "com.blackmagic-design.davinciresolve",
            "com.apple.finalcut",
            "com.apple.motion",
            "com.lemon.lvoverseas",       // CapCut
            "com.bytedance.capcut",
        ]
        let encoding = [
            "com.adobe.ame",
            "com.adobe.mediaencoder",
            "com.apple.compressor",
        ]
        if editing.contains(where: { id.hasPrefix($0) }) { return .editing }
        if encoding.contains(where: { id.hasPrefix($0) }) { return .encoding }
        return .other
    }
}

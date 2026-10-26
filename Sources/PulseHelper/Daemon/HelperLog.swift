import Foundation

/// Le journal des commandes du helper : une ligne par consigne nouvelle, par
/// retour en automatique, par refus, par client refusé.
///
/// `/Library/Logs/PulseHelper.log`, lisible par tous (Pulse l'affiche dans
/// ses Réglages), écrit par root seul. Le dossier n'est inscriptible que par
/// root (relevé le 11/10 : root:wheel 755) ; le fichier s'ouvre quand même
/// sans suivre de lien (`O_NOFOLLOW`) et n'est écrit que s'il est un fichier
/// ordinaire, à root, à un seul lien — sans quoi un lien posé là ferait
/// écrire root ailleurs. Tourne à 256 Ko : une copie `.1`, pas plus.
final class HelperLog {
    static let path = "/Library/Logs/PulseHelper.log"
    static let maxSize: off_t = 256 * 1024

    /// nil : sur la sortie d'erreur (simulation).
    let path: String?

    init(path: String?) { self.path = path }

    func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        guard let path else {
            FileHandle.standardError.write(Data(text.utf8))
            return
        }
        rotateIfNeeded(path)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0, info.st_nlink == 1
        else { return }
        fchmod(fd, 0o644)
        _ = text.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    private func rotateIfNeeded(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_size > Self.maxSize else { return }
        // `rename` ne suit pas les liens : au pire il déplace un lien.
        rename(path, path + ".1")
    }
}

import Foundation
import PulseFanKit

/// Installation et désinstallation du helper, en root, SUR ACCORD.
///
/// `PulseHelper --installe` n'est lancé que par le bouton « Installer le
/// helper… » de Pulse, à travers la demande de mot de passe administrateur
/// de macOS — c'est Isma qui le tape — ou par Isma lui-même dans le
/// Terminal (`sudo …/PulseHelper --installe`). Il copie le binaire hors du
/// bundle, dans des dossiers que seul root peut écrire, écrit le plist et
/// le confie à launchd. `--desinstalle` fait l'inverse ; le bouton
/// « Désinstaller » passe d'abord par le helper lui-même (commande XPC
/// `uninstall`, sans mot de passe : c'est le sens sûr).
///
/// Pourquoi pas `SMAppService.daemon` : avec une signature ad hoc, launchd
/// fige au premier enregistrement une contrainte de lancement sur
/// l'empreinte (`cdhash`) du helper, et chaque recompilation de Pulse.app
/// — une par fusion — donne « Launch Constraint Violation ». Détail et
/// sources : docs/chantiers/14-ventilateurs.md.
enum Installer {
    static func install() -> Int32 {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("--installe exige root (mot de passe administrateur).\n".utf8))
            return 64
        }
        let journal = HelperLog(path: HelperLog.path)
        // PAS `Bundle.main.executablePath` : rangé dans Pulse.app/Contents/MacOS,
        // le helper y verrait l'exécutable PRINCIPAL du bundle — Pulse —, qui
        // aurait été copié et lancé en root. Le chemin réel du processus, et
        // l'identifiant de signature vérifié avant toute copie.
        guard let source = running(), sourceIsHelper(source) else {
            journal.write("installation refusée : la source n'est pas le helper signé \(FanProtocol.label)")
            FileHandle.standardError.write(Data("installation refusée : la source n'est pas le helper.\n".utf8))
            return 65
        }
        let fm = FileManager.default
        let helper = FanProtocol.installedHelper
        let plist = FanProtocol.installedPlist
        do {
            // Une version déjà chargée : sortie de launchd d'abord (elle rend la main).
            _ = launchctl(["bootout", "system/\(FanProtocol.label)"])
            try fm.createDirectory(atPath: (helper as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
            // La signature est revérifiée sur la COPIE, dans un dossier que
            // seul root peut écrire, avant qu'elle ne prenne sa place : le
            // bundle, lui, reste inscriptible par Isma entre la vérification
            // de la source et sa lecture (17-audit-code).
            try place(contentsOf: URL(fileURLWithPath: source), at: helper, mode: 0o755, verify: sourceIsHelper)
            try place(Data(FanProtocol.launchdPlist().utf8), at: plist, mode: 0o644)
        } catch {
            journal.write("installation impossible : \(error.localizedDescription)")
            FileHandle.standardError.write(Data("installation impossible : \(error.localizedDescription)\n".utf8))
            return 73
        }
        let status = launchctl(["bootstrap", "system", plist])
        journal.write("installé depuis \(source) (launchctl bootstrap : \(status))")
        print("PulseHelper installé : \(helper), \(plist).")
        return status == 0 ? 0 : 75
    }

    /// Le chemin absolu, liens résolus, de l'exécutable qui tourne.
    static func running() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Le fichier est-il le helper : signature valide, identifiant
    /// `com.isma.pulse.helper` ?
    static func sourceIsHelper(_ path: String) -> Bool {
        FanSigning.identifier(ofFileAt: path) == FanProtocol.label
    }

    /// `--essai-installation` : ce que ferait `--installe`, sans root, sans
    /// rien écrire — pour vérifier avant l'essai réel.
    static func dryRun() -> Int32 {
        let source = running() ?? "?"
        let identifier = FanSigning.identifier(ofFileAt: source) ?? "illisible"
        print("source        \(source)")
        print("signature     \(identifier)" + (identifier == FanProtocol.label ? " — c'est le helper" : " — REFUSÉE"))
        print("copierait     \(FanProtocol.installedHelper) (root:wheel 755)")
        print("écrirait      \(FanProtocol.installedPlist) (root:wheel 644)")
        print("puis          launchctl bootstrap system \(FanProtocol.installedPlist)")
        print("déjà installé \(FileManager.default.fileExists(atPath: FanProtocol.installedHelper) ? "oui" : "non")")
        return identifier == FanProtocol.label ? 0 : 65
    }

    /// Depuis le Terminal ou la demande de mot de passe : sortie de launchd
    /// (le helper en marche rend la main en s'arrêtant), automatique pour
    /// tous les ventilateurs, puis binaire, plist et compteur effacés.
    static func uninstall() -> Int32 {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("--desinstalle exige root (mot de passe administrateur).\n".utf8))
            return 64
        }
        _ = launchctl(["bootout", "system/\(FanProtocol.label)"])
        if let smc = SMCFans() {
            FanController(hardware: smc, now: 0).stop(now: 0)
        }
        removeFiles(journal: HelperLog(path: HelperLog.path))
        print("PulseHelper désinstallé.")
        return 0
    }

    /// Depuis le helper lui-même (commande XPC `uninstall`, la main déjà
    /// rendue) : fichiers effacés, puis sortie de launchd SANS attendre —
    /// launchd l'arrête aussitôt par SIGTERM.
    static func uninstallFromDaemon(journal: HelperLog) {
        removeFiles(journal: journal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "system/\(FanProtocol.label)"]
        try? process.run()
    }

    private static func removeFiles(journal: HelperLog) {
        for path in [FanProtocol.installedPlist, FanProtocol.installedHelper, WriteLedger.path] {
            unlink(path)
        }
        journal.write("désinstallé : plist, binaire et compteur effacés")
    }

    /// Écrit à côté puis renomme : jamais un fichier à moitié copié à la
    /// place du bon, et jamais à travers un lien posé là. `verify` juge la
    /// copie terminée, avant le renommage : refusée, elle est effacée.
    private static func place(_ data: Data, at path: String, mode: mode_t,
                              verify: ((String) -> Bool)? = nil) throws {
        let temporary = path + ".nouveau"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fchown(fd, 0, 0)
        fchmod(fd, mode)
        close(fd)
        guard written == data.count else {
            unlink(temporary)
            throw POSIXError(.EIO)
        }
        if let verify, !verify(temporary) {
            unlink(temporary)
            throw NotTheHelper()
        }
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw POSIXError(.EIO)
        }
    }

    private static func place(contentsOf url: URL, at path: String, mode: mode_t,
                              verify: ((String) -> Bool)? = nil) throws {
        try place(Data(contentsOf: url), at: path, mode: mode, verify: verify)
    }

    private struct NotTheHelper: LocalizedError {
        var errorDescription: String? { "la copie n'est pas le helper signé \(FanProtocol.label)" }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Le compte des écritures de consigne depuis le démarrage du Mac, gardé
/// d'un helper à l'autre (il sort après 60 s sans client). Dans `/var/db`,
/// que seul root peut écrire ; remis à zéro à chaque démarrage, reconnu
/// par `kern.bootsessionuuid`.
enum WriteLedger {
    static let path = "/private/var/db/com.isma.pulse.helper.ecritures"

    static func bootSession() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func load() -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, String(parts[0]) == bootSession(), let count = Int(parts[1]) else { return 0 }
        return max(0, count)
    }

    static func save(_ count: Int) {
        let temporary = path + ".nouveau"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        let text = "\(bootSession()) \(count)\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        rename(temporary, path)
    }
}

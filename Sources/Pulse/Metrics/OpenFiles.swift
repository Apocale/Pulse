import Foundation
import Darwin

/// Les fichiers média qu'un processus tient ouverts en écriture.
///
/// C'est la piste pour détecter un export lancé DIRECTEMENT depuis Premiere,
/// que Pulse ne voit pas aujourd'hui : un tel export ne démarre pas Media
/// Encoder, et le seul autre signal — la charge des VTEncoderXPCService — ne
/// se rattache à rien (`ppid 1`) ; une visio le fait monter tout autant.
///
/// Un fichier ouvert en écriture, lui, appartient à un processus précis, et
/// libproc le montre pour les processus du même utilisateur, sans droits root.
/// Relevé au repos sur cette machine : Premiere écrit dans ses caches de
/// métadonnées, ses journaux et ses verrous, lit ses rushes, mais ne tient
/// AUCUN fichier média ouvert en écriture. Pendant un export, il devrait
/// tenir le fichier de sortie.
///
/// Hypothèse NON VALIDÉE sur un export réel. Tant qu'elle ne l'est pas, ceci
/// reste un instrument de `--probe` et ne nourrit aucune détection — même
/// méthode que pour Media Encoder, dont le seuil a été posé après mesure.
enum OpenFiles {
    /// Extensions d'un fichier de sortie vidéo ou audio.
    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf", "mkv", "avi", "wav", "aif", "aiff", "mp3", "m4a"]

    /// Ce que Premiere écrit sans exporter : le rendu de la timeline et les
    /// caches. Un rendu de prévisualisation écrit lui aussi des .mov — sans
    /// ce filtre, il passerait pour un export.
    static let excludedFragments = ["Video Previews", "Audio Previews", "Media Cache", "Peak Files",
                                    "/Library/Caches/", "/private/var/folders/"]

    /// Chemins des fichiers média ouverts en écriture par `pid`, filtres
    /// appliqués. Vide si le processus n'en tient aucun, ou n'est pas lisible.
    static func mediaWritten(by pid: pid_t) -> [String] {
        written(by: pid).filter { path in
            mediaExtensions.contains((path as NSString).pathExtension.lowercased())
                && !excludedFragments.contains(where: { path.contains($0) })
        }
    }

    /// TOUS les fichiers que `pid` tient ouverts en écriture, sans filtre :
    /// l'instrument de mesure de l'export direct (`--probe --suivi-export`)
    /// doit voir aussi un fichier temporaire ou une extension inattendue.
    static func written(by pid: pid_t) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                   Int32(count * MemoryLayout<proc_fdinfo>.stride))
        guard written > 0 else { return [] }

        var out: [String] = []
        for fd in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            // FWRITE : ouvert en écriture, seul ou en lecture-écriture.
            guard info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { out.append(path) }
        }
        return Array(Set(out)).sorted()
    }
}

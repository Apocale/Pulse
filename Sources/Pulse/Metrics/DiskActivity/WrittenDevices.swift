import Foundation
import Darwin

/// SUR QUEL volume une application écrit : les fichiers qu'elle tient ouverts
/// en écriture, rapportés au système de fichiers qui les porte.
///
/// Les compteurs `ri_diskio_*` disent combien un processus écrit, pas où.
/// Relevé le 11/10 : Ssd 2 écrivait 5,8 Mo/s (des proxies ffmpeg), Xcode
/// 3,1 Mo/s — sur le disque interne — et ffmpeg 2,5 Mo/s. Rapprocher les
/// débits désignait Xcode. Le fichier ouvert, lui, ne se trompe pas de
/// disque : ffmpeg tient sa sortie ouverte sur Ssd 2.
///
/// `PROC_PIDFDVNODEINFO` rend le périphérique du fichier sans son chemin :
/// pas de chaîne à construire, lisible sans root pour les processus de
/// l'utilisateur.
enum WrittenDevices {
    /// Au-delà, un groupe (un navigateur et ses dizaines de processus) n'est
    /// lu qu'en partie : les premiers PID sont les plus anciens, dont le
    /// processus principal, qui tient les téléchargements.
    static let pidLimit = 48

    /// Identifiants de périphérique (`st_dev`) des fichiers que `pids`
    /// tiennent ouverts en écriture.
    static func devices(of pids: [pid_t]) -> Set<UInt32> {
        var out = Set<UInt32>()
        for pid in pids.prefix(pidLimit) {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
            guard written > 0 else { continue }
            for fd in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride)
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfo()
                let infoSize = Int32(MemoryLayout<vnode_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, infoSize) == infoSize,
                      info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                out.insert(info.pvi.vi_stat.vst_dev)
            }
        }
        return out
    }

    /// Point de montage local → identifiant de périphérique, par la table du
    /// noyau (`MNT_NOWAIT` : aucun appel vers les volumes eux-mêmes).
    static func volumeDevices() -> [String: UInt32] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else { return [:] }
        var out: [String: UInt32] = [:]
        for i in 0..<Int(count) {
            let fs = table[i]
            guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
            let on = withUnsafeBytes(of: fs.f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            out[on] = UInt32(bitPattern: fs.f_fsid.val.0)
        }
        return out
    }
}

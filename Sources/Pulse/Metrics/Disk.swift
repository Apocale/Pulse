import Foundation
import IOKit

struct VolumeSample: Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var total: UInt64
    var available: UInt64
    var isInternal: Bool
    var uuid: String?
    /// Espace libre au sens POSIX, sans le purgeable (instantanés APFS, caches).
    /// C'est lui qui donne l'occupation réelle ; `available` inclut du
    /// purgeable et sous-estimait le remplissage de plusieurs dizaines de Go.
    var availableStrict: UInt64

    /// Clé d'historique stable. Le point de montage ne l'est pas : macOS
    /// remonte un disque externe en « Ssd 2 » si l'ancien dossier traîne,
    /// ce qui suffirait à perdre toute la tendance de remplissage.
    var historyKey: String { uuid ?? path }

    var used: UInt64 { total > availableStrict ? total - availableStrict : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    /// Écart entre les deux mesures : de l'espace récupérable automatiquement
    /// par macOS. Non nul, il explique pourquoi « libres » dépasse la place
    /// réellement disponible tout de suite.
    var purgeable: UInt64 { available > availableStrict ? available - availableStrict : 0 }
}

enum DiskMonitor {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        .volumeUUIDStringKey, .volumeAvailableCapacityKey, .volumeIsReadOnlyKey,
    ]

    /// Volumes visibles par l'utilisateur : le disque de démarrage plus tout
    /// ce qui est monté dans /Volumes. Les partitions système (Preboot, VM,
    /// Update…) sont écartées, elles ne racontent rien d'utile.
    ///
    /// `important` : lire aussi l'espace « pour usage important », purgeable
    /// compris. C'est la clé chère — relevé le 11/10 sur les cœurs E, 105 à
    /// 117 ms de CPU par balayage, contre 1 ms pour toutes les autres : macOS
    /// y calcule le purgeable de chaque volume. Sans elle, le libre strict
    /// est lu comme toujours, et le purgeable reste celui du dernier
    /// balayage complet de ce volume (`connus`) : voir `disponible`.
    /// Un volume compte-t-il ? La racine et `/Volumes` seulement.
    ///
    /// Un volume en lecture seule ne se remplit jamais : c'est une image
    /// disque d'installation, « pleine à 100 % » par construction. Relevé le
    /// 09/10 : « FilmCraft 0.4.0 », 136 Mio, 0 o libres, faisait afficher en
    /// rouge « FilmCraft 0… est plein à 100 % ». La racine reste quoi qu'en
    /// dise la clé (elle rend `false` ici) : c'est par elle qu'on lit
    /// l'espace du disque interne.
    static func counts(path: String, readOnly: Bool?) -> Bool {
        guard path == "/" || path.hasPrefix("/Volumes/") else { return false }
        return readOnly != true || path == "/"
    }

    static func volumes(important: Bool = true, connus: [VolumeSample] = []) -> [VolumeSample] {
        let cles = important ? Self.keys : Self.keys.filter { $0 != .volumeAvailableCapacityForImportantUsageKey }
        let purgeables = Dictionary(connus.map { ($0.historyKey, $0.purgeable) }, uniquingKeysWith: { a, _ in a })
        let urls = localVolumes().filter { !isTimeMachine(bsdName: $0.bsd) }.map(\.url)

        var out: [VolumeSample] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(cles)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }

            // L'espace « pour usage important » contient par définition tout
            // le libre strict, plus le purgeable. Une valeur inférieure est
            // incohérente, et elle arrive : relevé sur SSD 1, un disque APFS
            // externe, la clé rendait 0 par intermittence — « 0 o libres » à
            // l'écran, 240 Go selon df et diskutil, une heure après avoir rendu
            // la bonne valeur. Le libre strict sert donc de plancher.
            //
            // Pas seulement cosmétique : ce « libre » nourrit aussi la
            // prévision, où un 0 fantôme donnerait « plein dans moins d'un
            // jour » — une alerte rouge sur un disque aux trois quarts plein.
            let strict = UInt64(max(0, Int64(values.volumeAvailableCapacity ?? 0)))
            let available = disponible(
                strict: strict,
                pourUsageImportant: important
                    ? UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)) : nil,
                purgeableConnu: purgeables[values.volumeUUIDString ?? url.path])

            let path = url.path
            guard counts(path: path, readOnly: values.volumeIsReadOnly) else { continue }

            let isRoot = values.volumeIsRootFileSystem ?? (path == "/")
            out.append(VolumeSample(
                name: isRoot ? (values.volumeName ?? "Macintosh HD") : (values.volumeName ?? url.lastPathComponent),
                path: path,
                total: UInt64(total),
                available: available,
                isInternal: values.volumeIsInternal ?? isRoot,
                uuid: values.volumeUUIDString,
                availableStrict: strict))
        }
        return out.sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }

    /// L'espace disponible, purgeable compris. Lu (`pourUsageImportant`) :
    /// jamais moins que le libre strict, qui le contient par définition — la
    /// clé rend parfois 0. Pas lu : le libre strict du moment plus le
    /// purgeable du dernier balayage complet, qui bouge à l'échelle de
    /// l'heure quand le libre strict suit chaque copie ; sans balayage
    /// complet connu, le libre strict seul.
    static func disponible(strict: UInt64, pourUsageImportant: UInt64?, purgeableConnu: UInt64?) -> UInt64 {
        if let pourUsageImportant { return max(pourUsageImportant, strict) }
        return strict &+ (purgeableConnu ?? 0)
    }

    /// Les volumes LOCAUX montés à la racine ou sous /Volumes, par la table
    /// du noyau — `getmntinfo` en `MNT_NOWAIT`, comme
    /// `DiskIO.mountedDevices` : aucun appel ne part vers un volume.
    ///
    /// Un partage réseau n'est pas un disque de Pulse. Plein à 96 %, il
    /// faisait dire au verdict « NAS est plein à 96 % » et devenait le
    /// disque le plus plein de la barre de menus ; muet, le `statfs` que
    /// fait `mountedVolumeURLs` l'attendait sans borne, et la file du relevé
    /// avec lui (17-audit-code, 26/10). Les volumes masqués (`nobrowse`)
    /// restent dehors, comme avec `.skipHiddenVolumes`.
    static func localVolumes() -> [(url: URL, bsd: String)] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else { return [] }
        var out: [(url: URL, bsd: String)] = []
        for i in 0..<Int(count) {
            let fs = table[i]
            guard fs.f_flags & UInt32(MNT_LOCAL) != 0, fs.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
            let from = withUnsafeBytes(of: fs.f_mntfromname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let on = withUnsafeBytes(of: fs.f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard on == "/" || on.hasPrefix("/Volumes/") else { continue }
            out.append((URL(fileURLWithPath: on, isDirectory: true),
                        from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : ""))
        }
        return out
    }

    /// Le disque de sauvegarde Time Machine : rôle APFS « Backup » dans
    /// l'IORegistry, lu sans rien ouvrir sur le disque. macOS le garde plein
    /// exprès, en effaçant les plus vieilles sauvegardes : compté, il
    /// faisait un « plein à 98 % » permanent dans le verdict.
    static func isTimeMachine(bsdName: String) -> Bool {
        guard !bsdName.isEmpty else { return false }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard media != 0 else { return false }
        defer { IOObjectRelease(media) }
        let roles = IORegistryEntryCreateCFProperty(media, "Role" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String]
        return roles?.contains("Backup") == true
    }
}

import Foundation
import Darwin

/// `--probe --suivi-export [secondes]` : l'instrument qui doit trancher la
/// question de l'export lancé DIRECTEMENT depuis Premiere, sans la file
/// d'AME — aujourd'hui invisible (voir « Pas fait » dans CLAUDE.md).
///
/// Il ne décide rien : il relève toutes les 2 s, dans un CSV, tout ce qui
/// pourrait séparer un export d'une séance de montage, avec le code même de
/// l'app (mêmes unités, mêmes pièges évités) :
///
/// - la charge de Premiere, de Media Encoder, des `VTEncoderXPCService` et
///   `VTDecoderXPCService` (temps CPU dérivé, % d'un cœur) ;
/// - l'encodeur vidéo matériel (`AVE0`, W), le scaler, le GPU (occupation,
///   puissance) — IOReport, sans root ;
/// - TOUS les fichiers que les processus d'Adobe tiennent ouverts en
///   écriture, sans filtre : un export pourrait écrire d'abord un fichier
///   temporaire, ou sous une extension inattendue. Chaque chemin nouveau est
///   noté dans un second CSV, avec l'heure et le processus ;
/// - la taille du journal d'AME et la date de `AMERequestDB` de Premiere :
///   l'export direct laisse-t-il une trace écrite ?
///
/// Lecture seule pour Pulse : rien n'est écrit dans Application Support, la
/// persistance est coupée. Seuls les deux CSV sont écrits, dans le dossier
/// courant (ou celui donné par `--csv <dossier>`). Rien ne s'ouvre à l'écran.
enum ExportWatch {
    static let interval: TimeInterval = 2

    static func run() {
        Persistence.enabled = false
        let seconds = value(after: "--suivi-export").flatMap(Double.init) ?? 900
        let folder = value(after: "--csv") ?? FileManager.default.currentDirectoryPath
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = (folder as NSString).appendingPathComponent("mesure-export-premiere-\(stamp.string(from: Date()))")
        guard let rows = FileHandle.creating(base + ".csv"),
              let files = FileHandle.creating(base + "-fichiers.csv") else {
            FileHandle.standardError.write(Data("impossible d'écrire dans \(folder)\n".utf8))
            exit(1)
        }
        rows.line("horodatage,ecoule_s,cpu_premiere,cpu_media_encoder,cpu_vtencoder,cpu_vtdecoder,"
                  + "gpu_occupation,gpu_W,encodeur_W,scaler_W,ecrits_adobe,ecrits_media,ecrits_media_filtres,"
                  + "plus_gros_media,taille_o,debit_o_s,journal_ame_o,amerequestdb_modifie")
        files.line("horodatage,ecoule_s,pid,processus,chemin,extension,zone_ecartee_par_openfiles_ou_au_depart")

        let processes = ProcessMonitor()
        _ = processes.sample()
        let monitor = MediaMonitor()
        _ = monitor.sample()
        let journal = AMEJournal.url()
        let requestDB = Self.requestDatabase()
        var seen: Set<String> = []
        var previousSizes: [String: UInt64] = [:]
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let started = Date()

        print("Relevé toutes les \(Int(interval)) s pendant \(Int(seconds)) s → \(base).csv")
        print("Lancer l'export dans Premiere maintenant. Ctrl-C arrête proprement (chaque ligne est écrite aussitôt).\n")
        print("heure      Premiere   AME   VTEnc  VTDec   GPU   GPU W  AVE W  médias écrits  débit")

        while Date().timeIntervalSince(started) < seconds {
            Thread.sleep(forTimeInterval: interval)
            let now = Date()
            let elapsed = now.timeIntervalSince(started)
            let groups = processes.sample()
            let media = monitor.sample()
            func cpu(_ match: (String) -> Bool) -> Double {
                groups.filter { match($0.bundleId) }.reduce(0) { $0 + $1.cpu }
            }
            let premiere = cpu { $0.lowercased().hasPrefix("com.adobe.premierepro") }
            let encoder = cpu { AppKind.of(bundleId: $0) == .encoding }
            let vtEncoder = cpu { $0 == "exec:VTEncoderXPCService" }
            let vtDecoder = cpu { $0 == "exec:VTDecoderXPCService" }

            // Tout ce qu'écrivent les processus d'Adobe, sans filtre.
            var all: [(pid: pid_t, process: String, path: String)] = []
            for (pid, name) in Self.adobeProcesses() {
                for path in OpenFiles.written(by: pid) { all.append((pid, name, path)) }
            }
            // Au premier relevé, ce qui est déjà ouvert (relevé du 11/10 :
            // 427 fichiers — journaux et caches des panneaux CEP) va au CSV
            // sans être imprimé ; ensuite, chaque fichier NOUVEAU s'imprime :
            // c'est parmi eux que doit apparaître la sortie d'un export.
            let first = seen.isEmpty
            var fresh = 0
            for entry in all where !seen.contains(entry.path) {
                seen.insert(entry.path)
                fresh += 1
                let excluded = OpenFiles.excludedFragments.contains { entry.path.contains($0) }
                files.line([clock.string(from: now), String(format: "%.1f", elapsed), "\(entry.pid)",
                            csv(entry.process), csv(entry.path), (entry.path as NSString).pathExtension,
                            first ? "au départ" : (excluded ? "oui" : "non")].joined(separator: ","))
                if !first {
                    print("  + \(entry.process) écrit \(entry.path)\(excluded ? "  (zone écartée par OpenFiles)" : "")")
                }
            }
            if first {
                print("  \(fresh) fichiers déjà ouverts en écriture au départ — liste dans \((base as NSString).lastPathComponent)-fichiers.csv")
            }
            let mediaPaths = all.map(\.path).filter {
                OpenFiles.mediaExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }
            let filtered = mediaPaths.filter { path in !OpenFiles.excludedFragments.contains { path.contains($0) } }
            var biggest: (path: String, bytes: UInt64)?
            var sizes: [String: UInt64] = [:]
            for path in Set(mediaPaths) {
                let bytes = Self.size(path) ?? 0
                sizes[path] = bytes
                if bytes >= (biggest?.bytes ?? 0) { biggest = (path, bytes) }
            }
            let rate: Double? = biggest.flatMap { big in
                previousSizes[big.path].map { Double(big.bytes) - Double($0) }.map { $0 / interval }
            }
            previousSizes = sizes
            let journalBytes = journal.flatMap { Self.size($0.path) }
            let requestDate = requestDB.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }

            rows.line([clock.string(from: now), String(format: "%.1f", elapsed),
                       number(premiere), number(encoder), number(vtEncoder), number(vtDecoder),
                       number(media?.gpuUtilization.map { $0 * 100 }), number(media?.gpuPower, digits: 2),
                       number(media?.encoderPower, digits: 3), number(media?.scalerPower, digits: 3),
                       "\(Set(all.map(\.path)).count)", "\(Set(mediaPaths).count)", "\(Set(filtered).count)",
                       csv(biggest?.path ?? ""), biggest.map { "\($0.bytes)" } ?? "",
                       rate.map { String(format: "%.0f", $0) } ?? "",
                       journalBytes.map { "\($0)" } ?? "",
                       requestDate.map { clock.string(from: $0) } ?? ""].joined(separator: ","))
            print(String(format: "%@  %6.0f %%  %4.0f %%  %4.1f %%  %4.1f %%  %3.0f %%  %5.1f  %5.3f  %d  %@",
                         clock.string(from: now), premiere, encoder, vtEncoder, vtDecoder,
                         (media?.gpuUtilization ?? 0) * 100, media?.gpuPower ?? 0, media?.encoderPower ?? 0,
                         Set(mediaPaths).count, rate.map { Fmt.bytes($0) + "/s" } ?? "—"))
        }
        print("\nFini. \(base).csv et \(base)-fichiers.csv")
    }

    /// Les processus dont l'exécutable vit dans un dossier d'Adobe :
    /// Premiere et ses auxiliaires, Media Encoder, dynamiclinkmanager…
    static func adobeProcesses() -> [(pid_t, String)] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, count)
        guard written > 0 else { return [] }
        var out: [(pid_t, String)] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(written) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(nulTerminated: buffer)
            if path.contains("/Adobe") { out.append((pid, (path as NSString).lastPathComponent)) }
        }
        return out
    }

    /// `~/Documents/Adobe/Premiere Pro/<version la plus récente>/AMERequestDB`.
    static func requestDatabase() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Adobe/Premiere Pro", isDirectory: true)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { Double($0) != nil }
            .sorted { (Double($0) ?? 0) > (Double($1) ?? 0) }
        return versions.first.map { base.appendingPathComponent($0).appendingPathComponent("AMERequestDB") }
    }

    static func size(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count,
              !args[index + 1].hasPrefix("--") else { return nil }
        return args[index + 1]
    }

    private static func number(_ value: Double?, digits: Int = 1) -> String {
        value.map { String(format: "%.\(digits)f", $0) } ?? ""
    }

    /// Un champ CSV : entre guillemets s'il contient une virgule ou un
    /// guillemet — les chemins de dossiers clients en ont (« 03 Exports - Client A »).
    private static func csv(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private extension FileHandle {
    static func creating(_ path: String) -> FileHandle? {
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        return FileHandle(forWritingAtPath: path)
    }

    func line(_ text: String) {
        write(Data((text + "\n").utf8))
    }
}

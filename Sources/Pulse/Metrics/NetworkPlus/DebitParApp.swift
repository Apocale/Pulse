import Foundation
import Darwin

/// Le débit par application, et le temps d'aller-retour des connexions
/// TCP, lus dans le noyau par le cadre PRIVÉ NetworkStatistics — celui
/// qu'utilisent `nettop` et iStat Menus.
///
/// Relevé le 11/10 sur un binaire compilé et signé comme l'app, sans root :
/// 108 sockets décrits en 0,29 s pour ~0 ms de processeur. Chaque socket
/// livre deux dictionnaires : sa DESCRIPTION (qui : `processName`,
/// `processID`, `epid` — l'app pour qui un démon travaille —, l'interface,
/// l'adresse distante, l'état TCP) et ses COMPTES (`rxBytes`, `txBytes`, et
/// pour TCP `rttAverage`, en SECONDES : 0,0895 pour les 89,50 ms que nettop
/// affiche sur la même connexion). Les compteurs de la description sont à
/// zéro : il faut les deux.
///
/// API privée : si un macOS la retire ou la change, `disponible` devient
/// faux et la carte le dit, sans planter (chaque symbole est vérifié).
/// Pas de repli par `nettop` : même source, mais 0,65 s de processeur pour
/// un relevé d'une seconde (mesuré le 11/10), cent fois l'appel direct.
///
/// Ne tourne que panneau ouvert : `demarrer()` à l'apparition de la carte,
/// `arreter()` à sa disparition.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : tout son état vit sur sa file ;
/// NetworkStatistics y rappelle ses blocs.
final class SuiviSockets: @unchecked Sendable {
    struct DebitApp: Equatable, Identifiable {
        var id: String
        var nom: String
        var chemin: String?
        /// Octets par seconde sur le dernier intervalle.
        var recu: Double
        var envoye: Double
        var total: Double { recu + envoye }
    }

    struct Releve: Equatable {
        /// Les applications qui ont échangé quelque chose, la plus active
        /// d'abord.
        var apps: [DebitApp] = []
        /// RTT lissé, en millisecondes, des connexions TCP établies vers une
        /// adresse publique sur l'interface principale et actives pendant
        /// l'intervalle — un RTT de connexion muette est périmé.
        var rttInternet: [Double] = []
        var sockets = 0
        var intervalle: Double = 0
    }

    static var disponible: Bool { API.chargee != nil }

    private let file = DispatchQueue(label: "com.isma.pulse.sockets", qos: .utility)
    private var gestionnaire: OpaquePointer?
    private var sources: [OpaquePointer: Source] = [:]
    private var premierReleveFait = false
    private var dernierReleve: Double?
    private var releves = 0
    static let descriptionsTousLes = 5
    private var identites: [Int32: Identite] = [:]
    private var bundles: [String: (id: String, nom: String)] = [:]

    fileprivate struct Source {
        var pid: Int32 = 0
        var epid: Int32 = 0
        var nom = ""
        var interface = 0
        var tcp = false
        var etabli = false
        var publique = false
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var compte = false
        /// Le socket existait quand le suivi a commencé : ses premiers
        /// comptes couvrent toute sa vie, ils servent de référence et ne
        /// comptent pas comme débit.
        var initiale: Bool
        var drx: UInt64 = 0
        var dtx: UInt64 = 0
        var rtt: Double = 0
    }

    private typealias Identite = (id: String, nom: String, chemin: String?)

    func demarrer() {
        file.async { [self] in
            guard gestionnaire == nil, let api = API.chargee else { return }
            premierReleveFait = false
            dernierReleve = nil
            releves = 0
            guard let m = api.creer(kCFAllocatorDefault, file, { [weak self] source, _ in
                // Après `arreter()`, un ajout encore en file ne doit rien suivre.
                guard let self, let source, self.gestionnaire != nil else { return }
                self.suivre(source, api: api)
            }) else { return }
            gestionnaire = m
            api.toutTCP(m)
            api.toutUDP(m)
        }
    }

    func arreter() {
        file.async { [self] in
            if let m = gestionnaire { API.chargee?.detruire(m) }
            gestionnaire = nil
            sources.removeAll()
            identites.removeAll()
            premierReleveFait = false
            dernierReleve = nil
        }
    }

    /// Un relevé : descriptions puis comptes, et l'écart depuis le relevé
    /// précédent. `fin` est appelé sur la file du suivi.
    func relever(_ fin: @escaping @Sendable (Releve) -> Void) {
        file.async { [self] in
            guard let m = gestionnaire, let api = API.chargee else { fin(Releve()); return }
            // Les comptes à chaque relevé ; les descriptions complètes une
            // fois sur cinq seulement — l'état TCP et l'interface d'un socket
            // changent rarement, et chaque socket est décrit à son arrivée.
            // Relevé le 11/10 au banc : 8,3 ms de processeur par relevé avec
            // les descriptions à chaque fois.
            let comptes = { [weak self] in
                api.comptes(m) { [weak self] in
                    guard let self else { return }
                    fin(self.conclure())
                }
            }
            releves += 1
            if releves % Self.descriptionsTousLes == 1 { api.descriptions(m) { comptes() } } else { comptes() }
        }
    }

    // MARK: - Sources

    private func suivre(_ source: OpaquePointer, api: API) {
        sources[source] = Source(initiale: !premierReleveFait)
        api.blocDescription(source) { [weak self] dico in
            guard let self, let dico, self.sources[source] != nil else { return }
            self.sources[source]?.decrire(dico)
        }
        api.blocComptes(source) { [weak self] dico in
            guard let self, let dico, self.sources[source] != nil else { return }
            self.sources[source]?.compter(dico)
        }
        api.blocRetrait(source) { [weak self] in
            self?.sources[source] = nil
        }
        // Décrit tout de suite : sans quoi un socket ouvert entre deux
        // relevés complets resterait anonyme jusqu'au suivant.
        api.decrireSource(source)
    }

    private func conclure() -> Releve {
        let maintenant = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        let intervalle = dernierReleve.map { maintenant - $0 } ?? 0
        dernierReleve = maintenant
        let boucle = Int(if_nametoindex("lo0"))
        let principale = NetworkMonitor.primary().map { Int(if_nametoindex($0.interface)) } ?? -1

        var parApp: [String: DebitApp] = [:]
        var rtt: [Double] = []
        for (cle, source) in sources {
            defer { sources[cle]?.drx = 0; sources[cle]?.dtx = 0 }
            guard premierReleveFait, intervalle > 0, source.interface != boucle, !source.nom.isEmpty,
                  source.drx > 0 || source.dtx > 0 else { continue }
            let qui = identite(pid: source.epid > 0 ? source.epid : source.pid, nom: source.nom)
            var app = parApp[qui.id] ?? DebitApp(id: qui.id, nom: qui.nom, chemin: qui.chemin, recu: 0, envoye: 0)
            app.recu += Double(source.drx) / intervalle
            app.envoye += Double(source.dtx) / intervalle
            parApp[qui.id] = app
            if source.tcp, source.etabli, source.publique, source.interface == principale,
               source.drx > 0, source.rtt > 0 {
                rtt.append(source.rtt * 1000)
            }
        }
        premierReleveFait = true
        return Releve(apps: parApp.values.sorted { $0.total > $1.total },
                      rttInternet: rtt.sorted(), sockets: sources.count, intervalle: intervalle)
    }

    // MARK: - Qui est derrière un PID

    /// L'application qui englobe l'exécutable, comme le classement processeur
    /// (`ProcessMonitor`) : « Vivaldi Helper » compte pour Vivaldi.
    private func identite(pid: Int32, nom: String) -> Identite {
        if let connue = identites[pid] { return connue }
        var resultat: Identite = (id: "exec:" + nom, nom: nom, chemin: nil)
        var tampon = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &tampon, UInt32(tampon.count)) > 0 {
            let chemin = String(nulTerminated: tampon)
            if let fin = chemin.range(of: ".app/") {
                let bundle = String(chemin[..<fin.lowerBound]) + ".app"
                let lu = infoBundle(bundle)
                resultat = (id: lu.id, nom: lu.nom, chemin: bundle)
            } else {
                let base = (chemin as NSString).lastPathComponent
                resultat = (id: "exec:" + base, nom: base, chemin: nil)
            }
        }
        // Un processus d'un autre utilisateur (root, _mdnsresponder) ne
        // livre pas son chemin : il garde le nom que donne le noyau.
        identites[pid] = resultat
        return resultat
    }

    private func infoBundle(_ chemin: String) -> (id: String, nom: String) {
        if let connu = bundles[chemin] { return connu }
        var lu = (id: chemin, nom: ((chemin as NSString).lastPathComponent as NSString).deletingPathExtension)
        if let info = ProtectedFolders.bundleInfo(chemin) {
            if let id = info["CFBundleIdentifier"] as? String { lu.id = id }
            if let nom = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String, !nom.isEmpty { lu.nom = nom }
        }
        bundles[chemin] = lu
        return lu
    }

    // MARK: - Le cadre privé

    /// Les fonctions de NetworkStatistics, résolues une fois. Signatures
    /// relevées par rétro-ingénierie (outils libres comme Netiquette
    /// d'Objective-See), vérifiées le 11/10 sur macOS 26.6.
    fileprivate struct API {
        typealias BlocSource = @convention(block) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        typealias BlocDico = @convention(block) (NSDictionary?) -> Void
        typealias BlocVide = @convention(block) () -> Void

        let creer: @convention(c) (CFAllocator?, DispatchQueue, @escaping BlocSource) -> OpaquePointer?
        let detruire: @convention(c) (OpaquePointer) -> Void
        let toutTCP: @convention(c) (OpaquePointer) -> Void
        let toutUDP: @convention(c) (OpaquePointer) -> Void
        let descriptions: @convention(c) (OpaquePointer, @escaping BlocVide) -> Void
        let comptes: @convention(c) (OpaquePointer, @escaping BlocVide) -> Void
        let blocDescription: @convention(c) (OpaquePointer, @escaping BlocDico) -> Void
        let blocComptes: @convention(c) (OpaquePointer, @escaping BlocDico) -> Void
        let blocRetrait: @convention(c) (OpaquePointer, @escaping BlocVide) -> Void
        let decrireSource: @convention(c) (OpaquePointer) -> Void

        static let chargee: API? = {
            guard let cadre = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics",
                                     RTLD_LAZY) else { return nil }
            func f<T>(_ nom: String, _: T.Type) -> T? {
                dlsym(cadre, nom).map { unsafeBitCast($0, to: T.self) }
            }
            guard let creer = f("NStatManagerCreate", (@convention(c) (CFAllocator?, DispatchQueue, @escaping BlocSource) -> OpaquePointer?).self),
                  let detruire = f("NStatManagerDestroy", (@convention(c) (OpaquePointer) -> Void).self),
                  let toutTCP = f("NStatManagerAddAllTCP", (@convention(c) (OpaquePointer) -> Void).self),
                  let toutUDP = f("NStatManagerAddAllUDP", (@convention(c) (OpaquePointer) -> Void).self),
                  let descriptions = f("NStatManagerQueryAllSourcesDescriptions", (@convention(c) (OpaquePointer, @escaping BlocVide) -> Void).self),
                  let comptes = f("NStatManagerQueryAllSources", (@convention(c) (OpaquePointer, @escaping BlocVide) -> Void).self),
                  let blocDescription = f("NStatSourceSetDescriptionBlock", (@convention(c) (OpaquePointer, @escaping BlocDico) -> Void).self),
                  let blocComptes = f("NStatSourceSetCountsBlock", (@convention(c) (OpaquePointer, @escaping BlocDico) -> Void).self),
                  let blocRetrait = f("NStatSourceSetRemovedBlock", (@convention(c) (OpaquePointer, @escaping BlocVide) -> Void).self),
                  let decrireSource = f("NStatSourceQueryDescription", (@convention(c) (OpaquePointer) -> Void).self)
            else { return nil }
            return API(creer: creer, detruire: detruire, toutTCP: toutTCP, toutUDP: toutUDP,
                       descriptions: descriptions, comptes: comptes, blocDescription: blocDescription,
                       blocComptes: blocComptes, blocRetrait: blocRetrait, decrireSource: decrireSource)
        }()
    }
}

private extension SuiviSockets.Source {
    mutating func decrire(_ d: NSDictionary) {
        pid = (d["processID"] as? NSNumber)?.int32Value ?? pid
        epid = (d["epid"] as? NSNumber)?.int32Value ?? epid
        if let n = d["processName"] as? String, !n.isEmpty { nom = n }
        interface = (d["interface"] as? NSNumber)?.intValue ?? interface
        tcp = (d["provider"] as? String) == "TCP"
        etabli = (d["TCPState"] as? String) == "Established"
        if let distante = d["remoteAddress"] as? Data { publique = Self.estPublique(distante) }
    }

    /// Les compteurs d'un socket ne reculent jamais : un recul serait un
    /// socket recyclé, compté comme une nouvelle référence.
    mutating func compter(_ d: NSDictionary) {
        let nrx = (d["rxBytes"] as? NSNumber)?.uint64Value ?? rx
        let ntx = (d["txBytes"] as? NSNumber)?.uint64Value ?? tx
        if compte {
            drx += nrx >= rx ? nrx - rx : 0
            dtx += ntx >= tx ? ntx - tx : 0
        } else if !initiale {
            drx += nrx
            dtx += ntx
        }
        rx = nrx
        tx = ntx
        compte = true
        if let valeur = d["rttAverage"] {
            rtt = (valeur as? NSNumber)?.doubleValue ?? Double(valeur as? String ?? "") ?? rtt
        }
    }

    static func estPublique(_ data: Data) -> Bool { LecteurAdresses.estPublique(sockaddr: data) }
}

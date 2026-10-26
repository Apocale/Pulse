import Foundation
// Les objets XPC sont sûrs d'un fil à l'autre (documentation d'Apple), mais
// le module ne le déclare pas encore : sans cette mention, chaque connexion
// capturée dans un gestionnaire serait signalée.
@preconcurrency import XPC

/// Le côté helper de la connexion XPC : accepte un client, décode ses
/// demandes, les passe à `FanController`, répond, et tient le chien de
/// garde. Tout se passe sur UNE file sérielle.
///
/// Dans la bibliothèque et non dans l'exécutable pour que `swift test` le
/// fasse tourner pour de vrai, de bout en bout, sur un écouteur anonyme et
/// un SMC simulé (`FanXPCTests`) : sans root, sans launchd.
/// `@unchecked Sendable` : TOUT l'état du serveur vit sur `queue`, file
/// sérielle — écouteur, clients, chien de garde et contrôleur. Les
/// gestionnaires XPC et les minuteries y sont tous posés.
public final class FanXPCServer: @unchecked Sendable {
    public let controller: FanController
    private let listener: xpc_connection_t
    private let queue: DispatchQueue
    private let clock: () -> Double
    /// Le contrôle d'un nouveau client (utilisateur, signature) : faux, la
    /// connexion est fermée avant tout message.
    private let admit: (xpc_connection_t) -> Bool
    private var peers: [Int: xpc_connection_t] = [:]
    private var nextID = 1
    private var watchdog: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    /// Appelé quand le helper n'a plus rien à faire : en automatique, sans
    /// client, depuis `FanProtocol.idleExit`. Le démon sort alors (launchd le
    /// relance à la prochaine connexion).
    public var onIdle: (() -> Void)?
    /// Appelé après la réponse à une commande `uninstall` (la main déjà
    /// rendue par le contrôleur) : le démon efface ses fichiers et sort.
    public var onUninstall: (() -> Void)?
    /// Une ligne par client accepté ou refusé.
    public var log: (String) -> Void = { _ in }
    /// Intervalle du chien de garde (1 s ; les tests l'accélèrent).
    public var watchdogInterval: TimeInterval = 1
    public var idleDelay: TimeInterval = FanProtocol.idleExit

    public init(listener: xpc_connection_t, controller: FanController, queue: DispatchQueue,
                clock: @escaping () -> Double, admit: @escaping (xpc_connection_t) -> Bool = { _ in true }) {
        self.listener = listener
        self.controller = controller
        self.queue = queue
        self.clock = clock
        self.admit = admit
    }

    public func start() {
        xpc_connection_set_event_handler(listener) { [weak self] object in
            guard let self, xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
            self.accept(object)
        }
        xpc_connection_resume(listener)
        queue.async { [weak self] in self?.scheduleIdle() }
    }

    /// Un événement du système (veille, pression thermique, arrêt), passé
    /// au contrôleur sur la file du helper.
    public func system(_ event: @escaping @Sendable (FanController, Double) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            event(self.controller, self.clock())
            self.armWatchdog()
            self.scheduleIdle()
        }
    }

    public var clientCount: Int { peers.count }

    private func accept(_ peer: xpc_connection_t) {
        let pid = xpc_connection_get_pid(peer)
        let uid = xpc_connection_get_euid(peer)
        guard admit(peer) else {
            log("client refusé : pid \(pid), uid \(uid)")
            xpc_connection_cancel(peer)
            return
        }
        let id = nextID
        nextID += 1
        peers[id] = peer
        idleTimer?.cancel()
        idleTimer = nil
        xpc_connection_set_target_queue(peer, queue)
        xpc_connection_set_event_handler(peer) { [weak self] event in
            guard let self else { return }
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
                self.handle(event, from: peer, client: id)
            } else if xpc_get_type(event) == XPC_TYPE_ERROR {
                // Fermée par le client, client mort, ou signature refusée :
                // dans tous les cas il ne pilote plus rien. Une signature
                // refusée se dit au journal : sinon, un Pulse refusé ne
                // verrait qu'un helper muet, et le journal resterait vide.
                if #available(macOS 15, *), event === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT {
                    self.log("client refusé : signature (pid \(pid), uid \(uid))")
                }
                if self.peers.removeValue(forKey: id) != nil {
                    self.controller.clientGone(id, now: self.clock())
                    self.armWatchdog()
                    self.scheduleIdle()
                }
            }
        }
        xpc_connection_resume(peer)
    }

    private func handle(_ message: xpc_object_t, from peer: xpc_connection_t, client: Int) {
        let request = FanRequest.decode { key in
            guard let value = xpc_dictionary_get_value(message, key),
                  xpc_get_type(value) == XPC_TYPE_INT64 else { return nil }
            return xpc_int64_get_value(value)
        }
        let now = clock()
        let status = request.map { controller.handle($0, client: client, now: now) }
            ?? controller.status(now: now, accepted: false, refusal: .malformed)
        if let reply = xpc_dictionary_create_reply(message) {
            for (key, value) in status.encode() { xpc_dictionary_set_int64(reply, key, value) }
            xpc_connection_send_message(peer, reply)
        }
        armWatchdog()
        if request?.command == .uninstall {
            log("désinstallation demandée par le client \(client)")
            // Le temps que la réponse parte.
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.onUninstall?() }
        }
    }

    /// Le chien de garde ne tourne que pendant une consigne : en
    /// automatique, le helper ne se réveille jamais.
    private func armWatchdog() {
        if controller.needsWatchdog {
            guard watchdog == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.controller.tick(now: self.clock())
                self.armWatchdog()
                self.scheduleIdle()
            }
            timer.resume()
            watchdog = timer
        } else {
            watchdog?.cancel()
            watchdog = nil
        }
    }

    /// Jamais tant qu'une consigne est posée ou qu'un ventilateur reste
    /// imposé malgré un retour en automatique (`pendingRestore`) : le
    /// chien de garde doit pouvoir le retenter.
    private func scheduleIdle() {
        guard peers.isEmpty, !controller.needsWatchdog else {
            idleTimer?.cancel()
            idleTimer = nil
            return
        }
        guard idleTimer == nil, onIdle != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleDelay)
        timer.setEventHandler { [weak self] in
            guard let self, self.peers.isEmpty, !self.controller.needsWatchdog else { return }
            self.onIdle?()
        }
        timer.resume()
        idleTimer = timer
    }
}

/// Le côté Pulse : une connexion au service du helper, ouverte à la
/// première demande, refaite si elle tombe. Réponse attendue 2 s au plus.
/// `@unchecked Sendable` : la connexion est gardée par `lock`, le reste est
/// immuable.
public final class FanXPCClient: @unchecked Sendable {
    private let queue: DispatchQueue
    private let make: () -> xpc_connection_t
    private var connection: xpc_connection_t?
    private let lock = NSLock()

    /// Le helper installé : service Mach du domaine SYSTÈME seulement
    /// (`PRIVILEGED`) — un service du même nom posé par un processus de
    /// l'utilisateur ne peut pas se faire passer pour lui.
    public convenience init(machService: String = FanProtocol.label) {
        let queue = DispatchQueue(label: "com.isma.pulse.ventilateurs.xpc")
        self.init(queue: queue) {
            xpc_connection_create_mach_service(machService, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        }
    }

    /// Pour les tests : un écouteur anonyme du même processus.
    public convenience init(endpoint: xpc_endpoint_t) {
        let queue = DispatchQueue(label: "com.isma.pulse.ventilateurs.xpc.essai")
        self.init(queue: queue) { xpc_connection_create_from_endpoint(endpoint) }
    }

    private init(queue: DispatchQueue, make: @escaping () -> xpc_connection_t) {
        self.queue = queue
        self.make = make
    }

    private func current() -> xpc_connection_t {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let made = make()
        xpc_connection_set_event_handler(made) { [weak self] event in
            // Interrompue ou invalide : la prochaine demande en rouvre une.
            // L'ancienne est annulée : une connexion interrompue reste
            // active, et son gestionnaire la retenait (17-audit-code).
            guard xpc_get_type(event) == XPC_TYPE_ERROR, let self else { return }
            self.lock.lock()
            let dropped = self.connection.map { $0 === made } ?? false
            if dropped { self.connection = nil }
            self.lock.unlock()
            if dropped { xpc_connection_cancel(made) }
        }
        xpc_connection_resume(made)
        connection = made
        return made
    }

    /// Envoie une demande ; `reply` reçoit l'état du helper, ou nil s'il
    /// n'est pas installé, ne répond pas ou a refusé la connexion.
    public func send(_ request: FanRequest, reply: @escaping @Sendable (FanStatus?) -> Void) {
        let message = xpc_dictionary_create(nil, nil, 0)
        for (key, value) in request.encode() { xpc_dictionary_set_int64(message, key, value) }
        xpc_connection_send_message_with_reply(current(), message, queue) { answer in
            guard xpc_get_type(answer) == XPC_TYPE_DICTIONARY else { return reply(nil) }
            reply(FanStatus.decode { key in
                guard let value = xpc_dictionary_get_value(answer, key),
                      xpc_get_type(value) == XPC_TYPE_INT64 else { return nil }
                return xpc_int64_get_value(value)
            })
        }
    }

    /// La même, en attendant la réponse `timeout` secondes au plus : pour la
    /// sortie de l'app et pour `--probe`. Jamais sur le main thread d'une
    /// interface vivante.
    public func sendAndWait(_ request: FanRequest, timeout: TimeInterval = 2) -> FanStatus? {
        let done = DispatchSemaphore(value: 0)
        let box = StatusBox()
        send(request) { status in
            box.set(status)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }

    public func close() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        if let old { xpc_connection_cancel(old) }
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FanStatus?
    func set(_ status: FanStatus?) { lock.lock(); value = status; lock.unlock() }
    func get() -> FanStatus? { lock.lock(); defer { lock.unlock() }; return value }
}

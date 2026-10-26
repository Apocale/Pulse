import Foundation
import AppKit
import CoreGraphics

struct AppUsage: Identifiable {
    var bundleId: String
    var name: String
    var focus: TimeInterval

    var id: String { bundleId }
}

/// Compte le temps passé dans chaque application, au premier plan.
///
/// NSWorkspace suffit : aucune autorisation d'accessibilité n'est demandée,
/// contrairement à la lecture des titres de fenêtres. On n'apprend donc que
/// « Premiere était devant », jamais sur quel projet.
///
/// Trois choses sont volontairement exclues du décompte, sans quoi le chiffre
/// annoncerait des journées de montage qui n'ont pas eu lieu : le sommeil,
/// l'écran verrouillé, et l'inactivité prolongée clavier/souris.
/// `@unchecked Sendable` (Swift 6, 17-audit-code) : vit sur le fil principal —
/// notifications de NSWorkspace et minuterie posées sur `RunLoop.main` —,
/// le magasin qu'il nourrit a son verrou.
final class AppTracker: @unchecked Sendable {
    private static let idleThreshold: TimeInterval = 5 * 60
    private static let commitInterval: TimeInterval = 30

    /// Pulse passe au premier plan chaque fois que le popover s'ouvre.
    /// Se compter soi-même fausserait le classement dès le premier jour.
    private static let selfBundleId = "com.isma.pulse"

    private let store: HistoryStore
    private let onChange: () -> Void

    private var currentBundleId: String?
    private var currentName: String?
    private var since: Date?
    /// Deux sources indépendantes, deux drapeaux. Avec un seul booléen, un
    /// réveil après verrouillage d'écran relançait le décompte alors que la
    /// session était toujours verrouillée.
    private var sleeping = false
    private var locked = false
    private var suspended: Bool { sleeping || locked }
    private var timer: Timer?

    init(store: HistoryStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(activated(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleepBegan),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleepEnded),
                              name: NSWorkspace.didWakeNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(lockBegan),
                                name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(lockEnded),
                                name: .init("com.apple.screenIsUnlocked"), object: nil)

        adopt(NSWorkspace.shared.frontmostApplication)

        let timer = Timer(timeInterval: Self.commitInterval, repeats: true) { [weak self] _ in
            self?.commit()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Événements

    @objc private func activated(_ note: Notification) {
        commit()
        adopt(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    @objc private func sleepBegan() { commit(); sleeping = true; since = nil }
    @objc private func lockBegan() { commit(); locked = true; since = nil }
    @objc private func sleepEnded() { sleeping = false; resumeIfClear() }
    @objc private func lockEnded() { locked = false; resumeIfClear() }

    private func resumeIfClear() {
        guard !suspended else { return }
        since = Date()
    }

    private func adopt(_ app: NSRunningApplication?) {
        guard let app, let bundleId = app.bundleIdentifier, bundleId != Self.selfBundleId else {
            currentBundleId = nil
            currentName = nil
            since = nil
            return
        }
        currentBundleId = bundleId
        currentName = app.localizedName ?? bundleId
        since = Date()
    }

    // MARK: - Comptage

    /// Temps écoulé depuis l'utilisateur, pas depuis l'horloge : au-delà du
    /// seuil d'inactivité l'intervalle entier est jeté plutôt que crédité.
    private static func idleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    private func commit() {
        defer { if !suspended, currentBundleId != nil { since = Date() } }
        guard !suspended,
              let bundleId = currentBundleId,
              let name = currentName,
              let start = since else { return }

        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.5 else { return }
        guard Self.idleSeconds() < Self.idleThreshold else { return }

        store.addFocusTime(bundleId: bundleId, name: name, seconds: elapsed)
        onChange()
    }

    /// Force la comptabilisation en cours, avant lecture ou avant de quitter.
    func flush() { commit() }
}

import Cocoa
import Network
import OverSireCore

// ─── Network path ────────────────────────────────────────────────────────────
// The network path of this Mac (OVERSIRE-431). While it is down, the polls wait and the network errors stay out of
// the log. The footer shows "Offline since 19:38". After a wake, the polls wait for the path.

final class NetworkPath: @unchecked Sendable {
    static let shared = NetworkPath()
    static let changed = Notification.Name("NetworkPath.changed")
    /// The longest wait for the path after a wake.
    static let wakeWait: TimeInterval = 10

    let now: () -> Date
    private let lock = NSLock()
    private var down: Date?
    private var wokeAt: Date?
    private var absent = false
    private var monitor: NWPathMonitor?
    private var watchers: [UUID: () -> Void] = [:]

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    /// The start of the outage. nil: online.
    var offlineSince: Date? { lock.withLock { down } }

    /// False while the path is down, and after a wake until the path answers.
    var isOnline: Bool {
        lock.withLock { down == nil && (wokeAt.map { now().timeIntervalSince($0) >= Self.wakeWait } ?? true) }
    }

    /// No daemon is on this Mac, and the app knows it. Its refused loopback calls are then verbose.
    var localAbsent: Bool {
        get { lock.withLock { absent } }
        set { lock.withLock { absent = newValue } }
    }

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in self?.update(satisfied: p.status == .satisfied) }
        m.start(queue: .main)
        monitor = m
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.woke()
        }
    }

    /// A path update. Each satisfied update runs the watchers.
    func update(satisfied: Bool) {
        let changed: Bool = lock.withLock {
            wokeAt = nil
            if satisfied {
                defer { down = nil }
                return down != nil
            }
            guard down == nil else { return false }
            down = now()
            return true
        }
        if changed { post() }
        if satisfied { runWatchers() }
    }

    /// The path of a Mac that wakes can show satisfied before it works. The polls wait for the next update, at most `wakeWait`.
    func woke() {
        let at = now()
        lock.withLock { wokeAt = at }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeWait) { [weak self] in
            guard let self, self.lock.withLock({ self.wokeAt == at }) else { return }
            self.lock.withLock { self.wokeAt = nil }
            if self.isOnline { self.runWatchers() }
        }
    }

    /// Runs f on the main thread after each satisfied update. Give the id to `remove` to stop it.
    @discardableResult
    func watch(_ f: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { watchers[id] = f }
        return id
    }

    func remove(_ id: UUID) { _ = lock.withLock { watchers.removeValue(forKey: id) } }

    private func runWatchers() {
        let all = lock.withLock { Array(watchers.values) }
        let run = { all.forEach { $0() } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    private func post() {
        let p = { NotificationCenter.default.post(name: Self.changed, object: self) }
        if Thread.isMainThread { p() } else { DispatchQueue.main.async(execute: p) }
    }

    // MARK: Log

    /// The URL errors of a path that does not work.
    static let pathErrors: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                                                 .cannotConnectToHost, .timedOut, .dataNotAllowed, .internationalRoamingOff]

    /// A failed request that is no fault to show: a cancel, a path error while the path is down, or a refused loopback call
    /// on a Mac with no daemon. Its log line is verbose, and it opens no problem.
    func quiet(_ r: URLRequest, _ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let code = (error as? URLError)?.code else { return false }
        if code == .cancelled { return true }
        if Self.pathErrors.contains(code), !isOnline { return true }
        return code == .cannotConnectToHost && localAbsent && r.url?.host == DaemonClient.loopback.host && r.url?.port == DaemonClient.loopback.port
    }

    /// "Offline since 19:38".
    static func offlineText(_ since: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "Offline since \(f.string(from: since))"
    }
}

import Cocoa
import OverSireCore
import OverSireSync
import UserNotifications

// ─── Join and approve ────────────────────────────────────────────────────────
// JoinFlow runs on the Mac that joins a group. ApproveCenter runs on a member that gets a join request.

/// The join of this Mac to the group of a member. Main thread only.
@MainActor final class JoinFlow {
    static let changed = Notification.Name("JoinFlowChanged")

    enum Phase: Equatable {
        case idle
        case sending(host: String)
        case waiting(confirm: String, host: String)
        case joined(machine: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { NotificationCenter.default.post(name: Self.changed, object: self) } }
    }
    /// The end of the open request.
    private(set) var expiresAt: Date?
    private var request: String?
    private var watch: Task<Void, Never>?

    let local: DaemonClient
    /// Keeps the credential of a join of this app (kind app). nil in tests that do not need it.
    let machines: Machines?
    /// The daemon of a member, for a join without a daemon on this Mac.
    let remote: (String) -> DaemonClient
    /// The name of this Mac in a kind-app join.
    let thisMachine: String
    var pollEvery: Duration = .seconds(3)
    var now: () -> Date = Date.init
    /// The group changed: the hub reads it again.
    var onJoined: () -> Void = {}

    init(local: DaemonClient, machines: Machines?, http: any HTTPTransport,
         thisMachine: String = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac",
         remote: ((String) -> DaemonClient)? = nil) {
        self.local = local
        self.machines = machines
        self.thisMachine = thisMachine
        self.remote = remote ?? { host in
            let base = host.contains(":") ? "http://\(host)" : "http://\(host):7690"
            return DaemonClient(base: URL(string: base) ?? DaemonClient.loopback, token: nil, http: http)
        }
    }

    /// Asks a found member to admit the daemon of this Mac. A member approves it, and a joinResult frame tells the end.
    func join(found: DaemonInfo) async {
        let name = found.machine.rawValue
        start(name)
        do {
            let p = try await local.ask(host: found.listen.tailscale ?? name)
            guard phase == .sending(host: name) else { return }
            request = p.request
            expiresAt = p.expiresAt
            phase = .waiting(confirm: p.confirm, host: name)
            watchGroup(host: name)
        } catch {
            if phase == .sending(host: name) { phase = .failed(reason(error, host: name)) }
        }
    }

    /// Joins with a code from "Add machine…" on a member. With a daemon on this Mac, the daemon joins.
    /// Without one, this app joins as a device of kind app.
    func join(host: String, code: String) async {
        let host = host.trimmingCharacters(in: .whitespaces), code = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !host.isEmpty, !code.isEmpty else { phase = .failed("Enter the machine and the code."); return }
        start(host)
        do {
            if (try? await local.whoami()) != nil {
                let g = try await local.enter(host: host, code: code)
                guard phase == .sending(host: host) else { return }
                finish(g.members.first { $0.host == host || $0.addrs.contains(host) }?.machine.rawValue ?? host)
            } else {
                var nonce = [UInt8](repeating: 0, count: 8)
                for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255) }
                let r = try await remote(host).join(JoinRequest(code: code, machine: MachineName(rawValue: thisMachine), host: thisMachine, kind: .app,
                                                                nonce: nonce.map { String(format: "%02x", $0) }.joined()))
                guard phase == .sending(host: host) else { return }
                await machines?.joined(r)
                finish(host)
            }
        } catch {
            if phase == .sending(host: host) { phase = .failed(reason(error, host: host)) }
        }
    }

    /// Stops the wait. The member still holds the request until it expires.
    func cancel() {
        watch?.cancel()
        watch = nil
        request = nil
        expiresAt = nil
        phase = .idle
    }

    /// A joinResult frame of the local daemon.
    func received(_ f: JoinResultFrame) {
        guard f.request == request, case .waiting(_, let host) = phase else { return }
        switch f.status {
        case .approved: finish(host)
        case .denied: end(.failed("\(host) denied the request."))
        case .expired: end(.failed("The request expired. Ask again, and approve it on \(host) within 5 minutes."))
        case .pending: if let e = f.error { end(.failed(e)) }
        }
    }

    private func start(_ host: String) {
        watch?.cancel()
        request = nil
        expiresAt = nil
        phase = .sending(host: host)
    }

    private func finish(_ machine: String) {
        end(.joined(machine: machine))
        onJoined()
    }

    private func end(_ p: Phase) {
        watch?.cancel()
        watch = nil
        request = nil
        phase = p
    }

    /// Without a WebSocket to the local daemon, the group of the local daemon tells the end.
    private func watchGroup(host: String) {
        watch?.cancel()
        let local = local, every = pollEvery
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let self, !Task.isCancelled, case .waiting = self.phase else { return }
                if let g = try? await local.group(), g.members.count > 1 { self.finish(host); return }
                if let e = self.expiresAt, self.now() > e.addingTimeInterval(30) {
                    self.end(.failed("The request expired. Ask again, and approve it on \(host) within 5 minutes."))
                    return
                }
            }
        }
    }

    private func reason(_ e: Error, host: String) -> String {
        if case .transport(let m)? = e as? ProviderError { return "Cannot reach \(host): \(m)" }
        return DaemonClient.reason(e)
    }
}

/// Shows and posts join requests to this member, and sends the decision. Main thread only.
protocol JoinNotifying {
    func post(_ r: JoinRequestFrame, group: String)
    func withdraw(_ request: String)
}

@MainActor final class ApproveCenter {
    static let changed = Notification.Name("ApproveCenterChanged")
    nonisolated static let prefix = "join:"

    /// The open requests, oldest first.
    private(set) var open: [JoinRequestFrame] = []
    let local: DaemonClient
    let notifier: any JoinNotifying
    var groupName: () -> String = { "My machines" }
    var now: () -> Date = Date.init
    /// Shows the dialog when the app is in front.
    var onShow: (JoinRequestFrame) -> Void = { _ in }

    init(local: DaemonClient, notifier: any JoinNotifying) {
        self.local = local
        self.notifier = notifier
    }

    func handle(_ r: JoinRequestFrame) {
        guard r.expiresAt > now(), !open.contains(where: { $0.request == r.request }) else { return }
        open.append(r)
        notifier.post(r, group: groupName())
        onShow(r)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func decide(_ id: String, approve: Bool) async throws {
        do { try await local.decide(id, approve: approve) } catch ProviderError.notFound { }   // gone: it expired
        drop(id)
    }

    /// A failure shows its reason over `window`.
    func decide(_ id: String, approve: Bool, in window: NSWindow?) async {
        do { try await decide(id, approve: approve) } catch {
            AlertConfirm.tell("OverSire could not \(approve ? "approve" : "deny") the Mac", info: (error as? ProviderError)?.message ?? error.localizedDescription, in: window)
        }
    }

    /// Reads the open requests of the local daemon, for a Mac without a WebSocket to it.
    func sync() async {
        guard let list = try? await local.joinRequests() else { return }
        for gone in open where !list.contains(where: { $0.request == gone.request }) { drop(gone.request) }
        list.forEach(handle)
    }

    func request(_ id: String) -> JoinRequestFrame? { open.first { $0.request == id } }

    private func drop(_ id: String) {
        guard open.contains(where: { $0.request == id }) else { return }
        open.removeAll { $0.request == id }
        notifier.withdraw(id)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    nonisolated static func title(_ r: JoinRequestFrame, group: String) -> String { "\(r.machine) wants to join \(group)" }
}

/// The user notification of a join request, with the actions Approve and Deny.
struct UserJoinNotifier: JoinNotifying {
    static let category = "join-request"
    static let approve = "approve"
    static let deny = "deny"

    static func register(on c: UNUserNotificationCenter = .current()) {
        let actions = [UNNotificationAction(identifier: approve, title: "Approve", options: []),
                       UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive])]
        c.setNotificationCategories([UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [], options: [])])
    }

    func post(_ r: JoinRequestFrame, group: String) {
        let c = UNMutableNotificationContent()
        c.title = ApproveCenter.title(r, group: group)
        c.body = "Approve only if \(r.machine) shows the code \(r.confirm)."
        c.sound = .default
        c.categoryIdentifier = Self.category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ApproveCenter.prefix + r.request, content: c, trigger: nil))
    }

    func withdraw(_ request: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [ApproveCenter.prefix + request])
    }
}

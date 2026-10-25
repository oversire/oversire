import Foundation

// ─── Automation owner ────────────────────────────────────────────────────────
// One app of the group runs the automatic actions: auto start, Enhance, cleanup, Plane write-back and the AI jobs.
// The home daemon gives the automations lease (OVERSIRE-319). With no group, the app owns them.

public enum LeaseResult: Hashable, Sendable {
    case held(Lease)       // the caller holds the lease
    case other(Lease)      // another holder has it
}

/// The lease calls of the home daemon. DaemonClient implements it.
public protocol LeaseClient: Sendable {
    /// Throws StoreNotHome when the daemon is not home.
    func acquire(_ name: String, _ r: LeaseRequest) async throws -> LeaseResult
    func release(_ name: String, holder: String) async throws
}

extension DaemonClient: LeaseClient {}

/// Where the lease is. The app gives it from the group and the machine links.
public enum LeaseHome: Sendable {
    case none                                   // no group: this app owns
    case member(String, any LeaseClient)        // the home machine and its client
    case unreachable(String)                    // the home machine has no live link
}

public enum AutomationRole: Hashable, Sendable {
    case solo                  // no group: this app owns
    case owner(Lease)
    case other(Lease)          // another app owns; the UI shows its name
    case paused(String)        // the home daemon cannot be reached; the machine name, "" before the first read of the group

    public var lease: Lease? {
        switch self {
        case .owner(let l), .other(let l): return l
        case .solo, .paused: return nil
        }
    }
}

public final class AutomationOwner: @unchecked Sendable {
    public static let changed = Notification.Name("AutomationOwnerChanged")
    public static let leaseName = "automations"
    /// mayAct is false this long before the end of the lease, so a late renew does not overlap a new owner.
    public static let margin: TimeInterval = 10

    private let home: @Sendable (_ hint: String?) -> LeaseHome
    public let device: String
    private let name: @Sendable () -> String
    public let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    // Until the first refresh, the app does not know the group.
    private var current: AutomationRole = .paused("")
    private var tail: Task<Void, Never>?
    private var loop: Task<Void, Never>?

    /// home: the home of the lease. hint: the home that a 409 named, else nil. name: the machine name that the other apps show.
    public init(home: @escaping @Sendable (_ hint: String?) -> LeaseHome, device: String, name: @escaping @Sendable () -> String,
                ttl: TimeInterval = 90, clock: @escaping @Sendable () -> Date = Date.init) {
        self.home = home
        self.device = device
        self.name = name
        self.ttl = ttl
        self.clock = clock
    }

    public var role: AutomationRole { lock.withLock { current } }

    /// True when this app may run an automatic action now.
    public var mayAct: Bool {
        switch role {
        case .solo: return true
        case .owner(let l): return l.until.timeIntervalSince(clock()) > Self.margin
        case .other, .paused: return false
        }
    }

    /// Gets or renews the lease.
    public func refresh() async { await serial { await self.acquire(take: false) } }

    /// Run them here: takes the lease also when another app has it.
    public func take() async { await serial { await self.acquire(take: true) } }

    /// Gives the lease back, on sleep and on quit. The next refresh asks again.
    public func release() async {
        await serial {
            guard case .owner(let l) = self.role, case .member(_, let c) = self.home(nil) else { return }
            try? await c.release(Self.leaseName, holder: self.device)
            self.set(.other(Lease(name: l.name, holder: l.holder, holderName: l.holderName, epoch: l.epoch, until: self.clock())))
        }
    }

    /// Refreshes now and each ttl / 3 until stop.
    public func start() {
        let every = ttl / 3
        let t = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
        lock.withLock {
            loop?.cancel()
            loop = t
        }
    }

    public func stop() { lock.withLock { loop?.cancel(); loop = nil } }

    // One call at a time, in order.
    private func serial(_ body: @escaping @Sendable () async -> Void) async {
        let t: Task<Void, Never> = lock.withLock {
            let prev = tail
            let t = Task { await prev?.value; await body() }
            tail = t
            return t
        }
        await t.value
    }

    private func acquire(take: Bool) async {
        var target = home(nil)
        for _ in 0..<2 {
            switch target {
            case .none:
                set(.solo)
                return
            case .unreachable(let m):
                failed(m)
                return
            case .member(let m, let c):
                let r = LeaseRequest(holder: device, holderName: name(), ttlSeconds: Int(ttl), take: take)
                do {
                    switch try await c.acquire(Self.leaseName, r) {
                    case .held(let l): set(l.holder == device ? .owner(l) : .other(l))
                    case .other(let l): set(.other(l))
                    }
                    return
                } catch let e as StoreNotHome {
                    guard let h = e.home, h != m else { failed(m); return }
                    target = home(h)
                } catch {
                    failed(m)
                    return
                }
            }
        }
        if case .member(let m, _) = target { failed(m) }
    }

    // A failed call keeps a lease that has not ended. Past its end, the automations pause.
    private func failed(_ machine: String) {
        if let l = role.lease, l.until > clock() { return }
        set(.paused(machine))
    }

    private func set(_ r: AutomationRole) {
        let old: AutomationRole = lock.withLock {
            let o = current
            current = r
            return o
        }
        if !Self.same(old, r) { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    // A renew changes only the end of the lease. It does not post.
    static func same(_ a: AutomationRole, _ b: AutomationRole) -> Bool {
        switch (a, b) {
        case (.owner(let x), .owner(let y)), (.other(let x), .other(let y)): return x.holder == y.holder && x.epoch == y.epoch && x.holderName == y.holderName
        default: return a == b
        }
    }
}

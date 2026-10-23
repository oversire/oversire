import Foundation
import OverSireCore

// ─── Runner desk ─────────────────────────────────────────────────────────────
// The runner role of the group in the app. An order goes to the daemon of its target machine when that machine is live,
// else to the hub when the cloud is paired. The answers to runner questions take the path of their session.

/// One machine of the group, as the runner choice sees it.
public struct RunnerTarget: Hashable, Sendable {
    public var link: MachineLink
    public var live: Bool
    /// The runtimes of the daemon (whoami). nil: not known, for example when the machine is offline.
    public var runtimes: [ProviderID]?

    public init(link: MachineLink, live: Bool, runtimes: [ProviderID]?) {
        self.link = link
        self.live = live
        self.runtimes = runtimes
    }
}

public enum RunnerRoute: Hashable, Sendable {
    case daemon(MachineLink)
    /// The hub makes the order from the accepted suggestion.
    case hub
}

/// No live daemon and no cloud for the order.
public struct RunnerOffline: Error, Hashable, LocalizedError {
    public var machine: String
    public init(machine: String) { self.machine = machine }
    public var errorDescription: String? { "\(machine) is offline" }
}

/// The choice of the path of an order.
public struct RunnerChoice: Hashable, Sendable {
    public var targets: [RunnerTarget]
    /// The cloud is paired: the hub can take the order.
    public var cloud: Bool

    public init(targets: [RunnerTarget] = [], cloud: Bool = false) {
        self.targets = targets
        self.cloud = cloud
    }

    /// The target is the member with the machine name whose runtimes hold the runtime. "local" is this Mac.
    public func target(runtime: ProviderID, machine: String) -> RunnerTarget? {
        targets.first { ($0.link.machine == machine || machine == "local" && $0.link.local) && ($0.runtimes?.contains(runtime) ?? true) }
    }

    public func route(runtime: ProviderID, machine: String) throws -> RunnerRoute {
        let t = target(runtime: runtime, machine: machine)
        if let t, t.live { return .daemon(t.link) }
        if cloud { return .hub }
        throw RunnerOffline(machine: t?.link.machine ?? machine)
    }

    /// The runner of the draft, else the account of its order.
    public func route(_ draft: WorkOrderDraft) throws -> RunnerRoute {
        try route(runtime: draft.runtime, machine: draft.runner ?? draft.order.account)
    }
}

/// Keeps the transports of the live members, writes their frames into the store, and routes the answers.
public final class RunnerDesk: RunnerAnswerSending, @unchecked Sendable {
    private let store: any Store
    private let hub: any RunnerAnswerSending
    private let http: any HTTPTransport
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var choice = RunnerChoice()
    private var transports: [String: DaemonRunnerTransport] = [:]
    private var pumps: [String: Task<Void, Never>] = [:]
    /// runner session id → the machine whose daemon sent it.
    private var sessions: [String: String] = [:]
    /// A record that a frame wrote. The app tells the pages.
    public var onWrite: @Sendable (String) -> Void = { _ in }

    public init(store: any Store, hub: any RunnerAnswerSending, http: any HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.hub = hub
        self.http = http
        self.now = now
    }

    deinit { pumps.values.forEach { $0.cancel() } }

    public var current: RunnerChoice { lock.withLock { choice } }

    /// The machines or the cloud changed. A machine that left loses its transport.
    public func update(_ next: RunnerChoice) {
        lock.withLock {
            choice = next
            let links = Dictionary(next.targets.map { ($0.link.machine, $0.link) }, uniquingKeysWith: { a, _ in a })
            for (m, t) in transports where links[m] != t.link {
                transports[m] = nil
                pumps.removeValue(forKey: m)?.cancel()
            }
        }
    }

    public func route(_ draft: WorkOrderDraft) throws -> RunnerRoute { try current.route(draft) }

    /// The transport of the machine. It starts to write its frames into the store.
    public func transport(_ link: MachineLink) -> DaemonRunnerTransport {
        lock.withLock {
            if let t = transports[link.machine], t.link == link { return t }
            pumps.removeValue(forKey: link.machine)?.cancel()
            let t = DaemonRunnerTransport(link: link, http: http)
            transports[link.machine] = t
            let stream = t.messages()
            let machine = link.machine
            pumps[machine] = Task { [weak self] in
                for await m in stream { await self?.write(m, from: machine) }
            }
            return t
        }
    }

    /// A text frame of the WebSocket of a machine.
    public func received(_ frame: String, from machine: String) {
        lock.withLock { transports[machine] }?.receive(frame)
    }

    /// Sends the order of an accepted suggestion to the daemon. The answer is the suggestion, done or failed.
    /// The hub never sees this suggestion as accepted, so it does not make a second order.
    public func run(_ s: Suggestion, draft: WorkOrderDraft, on link: MachineLink) async -> Suggestion {
        var next = s
        do {
            _ = try await send(draft, on: link, suggestion: s.id)
            next.state = .done
        } catch {
            next.state = .failed
            next.error = Self.reason(error)
        }
        return next
    }

    /// Sends one order to the daemon of the machine and keeps it in the store. A failed send stays as a failed order.
    /// `suggestion` is empty for an order without a suggestion, for example from the assistant.
    public func send(_ draft: WorkOrderDraft, on link: MachineLink, suggestion: String = "") async throws -> WorkOrder {
        var d = draft
        d.order = d.order.onTarget
        let order = d.order(suggestion: suggestion, runner: link.machine, now: now())
        do {
            try await store.put(order)
            onWrite(WorkOrder.collection)
            try await transport(link).send(order)
            return order
        } catch {
            var failed = order
            failed.state = .failed
            failed.result = WorkOrderResult(error: Self.reason(error))
            try? await store.put(failed)
            onWrite(WorkOrder.collection)
            throw error
        }
    }

    private static func reason(_ error: Error) -> String {
        String(((error as? LocalizedError)?.errorDescription ?? (error as? ProviderError)?.message ?? "\(error)").prefix(500))
    }

    // MARK: Answers

    public func send(session: String, answer: RunnerAnswer) async throws -> AnswerResult {
        if let t = daemon(for: session) { return try await t.send(session: session, answer: answer) }
        return try await hub.send(session: session, answer: answer)
    }

    public func send(session: String, permission: PermissionAnswer) async throws -> AnswerResult {
        if let t = daemon(for: session) { return try await t.send(session: session, permission: permission) }
        return try await hub.send(session: session, permission: permission)
    }

    /// The daemon of the session, when its machine is a live member. Else the hub.
    func daemon(for session: String) -> DaemonRunnerTransport? {
        let (machine, c): (String?, RunnerChoice) = lock.withLock { (sessions[session], choice) }
        guard let machine, let t = c.targets.first(where: { $0.link.machine == machine }), t.live else { return nil }
        return transport(t.link)
    }

    // MARK: Frames

    private func write(_ m: RunnerMessage, from machine: String) async {
        switch m {
        case .ack(let id):
            await change(id) { o in if o.state == .queued || o.state == .sent { o.state = .acked } }
        case .result(let id, let state, let result):
            await change(id) { o in
                guard o.state != .done, o.state != .failed, o.state != .expired else { return }
                o.state = state
                if let result { o.result = result }
            }
        case .session(let s):
            lock.withLock { sessions[s.id] = machine }
            try? await store.put(s)
            onWrite(RunnerSession.collection)
        default: break
        }
    }

    private func change(_ id: String, _ edit: (inout WorkOrder) -> Void) async {
        guard var o = try? await store.get(WorkOrder.self, id: id) else { return }
        let before = o
        edit(&o)
        guard o != before else { return }
        try? await store.put(o)
        onWrite(WorkOrder.collection)
    }
}

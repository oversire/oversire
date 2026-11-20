import Foundation
import OverSireCore

/// A provider with a stream that the test drives. The feed has an event list. Its cursor is the count of events.
public final class FakeLiveFeed: LiveFeeding, @unchecked Sendable {
    public let base: FakeProvider
    public var id: ProviderID { base.id }
    public var account: AccountID { base.account }
    public var capabilities: Set<Capability> { base.capabilities }
    public var pollPolicy: PollPolicy { base.pollPolicy }
    public let liveFeedTimeout: Duration

    private let lock = NSLock()
    private var opened = 0
    private var continuation: AsyncThrowingStream<LiveSignal, Error>.Continuation?
    private var refusals: [ProviderError] = []
    private var connectList: [String?] = []
    private var pullList: [Cursor?] = []
    private var items: [ProviderEvent] = []
    private var expired = false
    private var gate: (@Sendable () async -> Void)?
    private var pollFailure: ProviderError?

    public init(account: String = "bt.test", timeout: Duration = .seconds(60)) {
        base = FakeProvider(id: "fake-feed", account: account, capabilities: [.liveFeed])
        liveFeedTimeout = timeout
    }

    /// The `lastEventID` of each connect.
    public var connects: [String?] { lock.withLock { connectList } }
    /// The cursor of each poll.
    public var pulls: [Cursor?] { lock.withLock { pullList } }
    /// True while a stream is open.
    public var isOpen: Bool { lock.withLock { continuation != nil } }

    public func push(_ s: LiveSignal) { lock.withLock { continuation }?.yield(s) }

    /// Ends the open stream. With an error, the stream throws it.
    public func drop(_ error: Error? = nil) {
        let c = lock.withLock { () -> AsyncThrowingStream<LiveSignal, Error>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        if let error { c?.finish(throwing: error) } else { c?.finish() }
    }

    /// The next connect throws `e`. Calls add up.
    public func refuseNextConnect(_ e: ProviderError) { lock.withLock { refusals.append(e) } }

    public func addItemEvent(project: String, item: String) {
        lock.withLock {
            let ref = ItemRef(project: ProjectRef(account: account, id: project), id: item, key: "T-\(item)",
                              url: URL(string: "fake://item/\(item)")!)
            items.append(ProviderEvent(id: "fake-feed-\(items.count + 1)", provider: id, account: account, kind: .item, action: "updated",
                                       subject: .item(ref), at: Date(timeIntervalSince1970: 0)))
        }
    }

    /// The next poll gives a baseline page, as a server does with an old cursor.
    public func expireCursor() { lock.withLock { expired = true } }

    /// Each poll waits for `gate` first.
    public func gatePolls(_ gate: (@Sendable () async -> Void)?) { lock.withLock { self.gate = gate } }

    /// Each poll throws `e` until a call with nil.
    public func failPolls(_ e: ProviderError?) { lock.withLock { pollFailure = e } }

    public func probe() async throws -> Identity { try await base.probe() }

    public func poll(since: Cursor?) async throws -> EventPage {
        let gate = lock.withLock { pullList.append(since); return self.gate }
        await gate?()
        if let e = lock.withLock({ pollFailure }) { throw e }
        return try base.locked {
            lock.withLock {
                let head = Cursor(rawValue: "\(items.count)")
                if since == nil || expired {
                    expired = false
                    return EventPage(events: [], cursor: head, baseline: true)
                }
                let from = min(since.flatMap { Int($0.rawValue) } ?? 0, items.count)
                return EventPage(events: Array(items[from...]), cursor: head)
            }
        }
    }

    public func liveFeed(lastEventID: String?) async throws -> AsyncThrowingStream<LiveSignal, Error> {
        try base.check()
        let refusal: ProviderError? = lock.withLock {
            connectList.append(lastEventID)
            return refusals.isEmpty ? nil : refusals.removeFirst()
        }
        if let refusal { throw refusal }
        return AsyncThrowingStream { cont in
            let n = lock.withLock { () -> Int in
                opened += 1
                continuation = cont
                return opened
            }
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { if opened == n { continuation = nil } }
            }
        }
    }
}

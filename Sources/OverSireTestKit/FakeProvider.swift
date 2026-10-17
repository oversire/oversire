import Foundation
import OverSireCore

/// The shared part of each fake adapter: capabilities, a set failure and an event log for poll.
/// All fakes keep their state behind one lock.
public final class FakeProvider: @unchecked Sendable {
    public let id: ProviderID
    public let account: AccountID
    private let lock = NSLock()
    private var caps: Set<Capability>
    private var failure: ProviderError?
    private var events: [ProviderEvent] = []
    var now: @Sendable () -> Date = Date.init

    public init(id: ProviderID, account: String, capabilities: Set<Capability>) {
        self.id = id
        self.account = AccountID(provider: id, id: account)
        caps = capabilities
    }

    public var capabilities: Set<Capability> {
        get { lock.withLock { caps } }
        set { lock.withLock { caps = newValue } }
    }

    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(1), requestsPerHour: 3600) }

    /// Each call throws `e` until a call with nil.
    public func fail(_ e: ProviderError?) { lock.withLock { failure = e } }

    /// Throws the set failure.
    public func check() throws {
        if let e = lock.withLock({ failure }) { throw e }
    }

    /// Runs `body` under the lock after the failure check.
    func locked<T>(_ body: () throws -> T) throws -> T {
        try check()
        return try lock.withLock(body)
    }

    /// Runs `body` under the lock, with no failure check.
    func lockedValue<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }

    /// Call it under `locked`.
    func emit(_ kind: EventKind, _ action: String, _ subject: SubjectRef, title: String? = nil) {
        events.append(ProviderEvent(id: "\(id)-\(events.count + 1)", provider: id, account: account, kind: kind, action: action,
                                    subject: subject, at: now(), summary: EventSummary(title: title)))
    }

    public func probe() async throws -> Identity {
        try check()
        return Identity(person: PersonRef(id: "me", name: "Fake \(id)"))
    }

    /// The cursor is the count of events. A nil cursor gives all events.
    public func poll(since: Cursor?) async throws -> EventPage {
        try locked {
            let from = min(since.flatMap { Int($0.rawValue) } ?? 0, events.count)
            return EventPage(events: Array(events[from...]), cursor: Cursor(rawValue: "\(events.count)"))
        }
    }
}

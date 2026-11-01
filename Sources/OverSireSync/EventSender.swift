import Foundation
import OverSireCore

/// Where the app sends its event rows: the events table of a daemon.
public protocol EventTable: Sendable {
    func appendEvents(_ drafts: [EventDraft]) async throws -> Event.AppendResult
    func setItemLinks(_ links: [ItemLink]) async throws
}

extension DaemonClient: EventTable {}

/// Keeps the rows of the app until a daemon takes them. The local daemon is the first choice: a member daemon sends
/// its rows home through its outbox. A failure keeps the rows and tries again later: 2 s, then twice as long, at most 5 min.
public actor EventSender: EventSink {
    public static let batch = 500

    private let target: @Sendable () async -> (any EventTable)?
    private let limit: Int
    private var pending: [EventDraft] = []
    private var links: [String: ItemLink] = [:]
    private var recent: [String] = []
    private var recentSet: Set<String> = []
    private var wait: TimeInterval = 2
    private var timer: Task<Void, Never>?
    private var sending = false

    /// limit: the most rows that wait. Above it, the oldest rows go.
    public init(limit: Int = 5000, target: @escaping @Sendable () async -> (any EventTable)?) {
        self.limit = limit
        self.target = target
    }

    public var waiting: Int { pending.count }

    /// Drops a row that this sender sent or keeps already. The daemon also drops a repeat.
    public func append(_ drafts: [EventDraft]) async {
        let ids = Set(pending.map(\.id))
        for d in drafts where !recentSet.contains(d.id) && !ids.contains(d.id) { pending.append(d) }
        if pending.count > limit, !sending { pending.removeFirst(pending.count - limit) }
        await flush()
    }

    /// The parent of each item. The last link of an item wins.
    public func link(_ l: [ItemLink]) async {
        for x in l { links[x.item.uppercased()] = x }
        await flush()
    }

    /// Sends what waits. A failure sets a timer for the next try.
    public func flush() async {
        guard !sending, !pending.isEmpty || !links.isEmpty else { return }
        sending = true
        defer { sending = false }
        guard let t = await target() else { retry(); return }
        do {
            while !pending.isEmpty {
                let part = Array(pending.prefix(Self.batch))
                _ = try await t.appendEvents(part)
                pending.removeFirst(part.count)
                remember(part.map(\.id))
            }
            if !links.isEmpty {
                let all = Array(links.values)
                for i in stride(from: 0, to: all.count, by: 2000) {
                    try await t.setItemLinks(Array(all[i..<min(all.count, i + 2000)]))
                }
                for x in all where links[x.item.uppercased()] == x { links[x.item.uppercased()] = nil }
            }
            wait = 2
        } catch {
            retry()
        }
    }

    private func retry() {
        guard timer == nil else { return }
        let w = wait
        wait = min(wait * 2, 300)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(w * 1_000_000_000))
            await self?.fire()
        }
    }

    private func fire() async {
        timer = nil
        await flush()
    }

    private func remember(_ ids: [String]) {
        for id in ids where recentSet.insert(id).inserted { recent.append(id) }
        if recent.count > 20000 {
            let drop = recent.prefix(recent.count - 20000)
            recentSet.subtract(drop)
            recent.removeFirst(drop.count)
        }
    }
}

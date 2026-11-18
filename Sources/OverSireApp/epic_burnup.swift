import Foundation
import OverSireCore

/// The state-change rows of the members of each epic, for the burn-up chart. The epic rows come from `JOURNAL`.
/// Use it on the main thread.
final class EpicBurnUps {
    static let maxMembers = 80
    static let batch = 8

    private let reader: () async -> (any ItemEventReader)?
    private let bus: ChangeBus
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Epic event key → the read of the member rows.
    private var reads: [String: PartReader<[Event]>] = [:]
    private var members: [String: [String]] = [:]
    /// False for `--uishots` and tests: the seeded rows stay.
    var enabled = true

    init(reader: @escaping () async -> (any ItemEventReader)? = ItemJournal.homeReader, bus: ChangeBus = .shared,
         now: @escaping () -> Date = Date.init, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter) {
        self.reader = reader
        self.bus = bus
        self.now = now
        self.schedule = schedule
    }

    /// The state-change rows of the members. Nil before the first good read.
    func rows(_ epicKey: String) -> [Event]? { reads[epicKey.uppercased()]?.value }

    /// Reads the rows of the member keys. A read in the last minute is enough, unless force.
    func load(_ epicKey: String, members keys: [String], force: Bool = false) {
        guard enabled else { return }
        let k = epicKey.uppercased()
        members[k] = keys
        read(k).start(force: force)
    }

    func part(_ epicKey: String) -> PagePart { read(epicKey.uppercased()).part(id: "burnup", title: "Burn-up history") }

    /// Waits for the read that began. For tests.
    func settled(_ epicKey: String) async { await reads[epicKey.uppercased()]?.settled() }

    /// For tests and `--uishots`.
    func seed(_ epicKey: String, _ rows: [Event]) { read(epicKey.uppercased()).seed(Read(value: ItemJournal.merge([], rows))) }

    /// The chart data. Nil until the member rows are read.
    func burnUp(_ rollup: EpicRollup, epicRows: [Event]?, now: Date) -> EpicBurnUp? {
        guard let members = rows(rollup.epic.eventKey) else { return nil }
        return EpicBurnUp.build(epicKey: rollup.epic.eventKey, rows: (epicRows ?? []) + members, now: now, current: rollup)
    }

    private func read(_ k: String) -> PartReader<[Event]> {
        if let r = reads[k] { return r }
        let r = PartReader<[Event]>(
            fetch: { [weak self] in
                guard let self else { throw ProviderError.transport("The history is gone.") }
                return try await self.fetch(k)
            },
            merge: { ItemJournal.merge($0 ?? [], $1) },
            maxAge: 60, now: now, schedule: schedule,
            changed: { [weak self] in self?.bus.post(DataChange(.events, items: [k], origin: .event)) })
        reads[k] = r
        return r
    }

    private func fetch(_ k: String) async throws -> [Event] {
        guard let r = await reader() else { throw ProviderError.transport("No daemon is live.") }
        let keys = await MainActor.run { Array((members[k] ?? []).prefix(Self.maxMembers)) }
        var out: [Event] = []
        for start in stride(from: 0, to: keys.count, by: Self.batch) {
            let slice = keys[start..<min(start + Self.batch, keys.count)]
            try await withThrowingTaskGroup(of: [Event].self) { g in
                for m in slice {
                    g.addTask { try await r.events(Event.Query(item: m, tree: false, kinds: [Event.Kind.itemStateChanged.rawValue], limit: 200)).events }
                }
                for try await rows in g { out += rows }
            }
        }
        return out
    }
}

let EPIC_BURNUPS = EpicBurnUps()

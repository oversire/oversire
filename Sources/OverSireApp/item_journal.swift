import Foundation
import OverSireCore
import OverSireSync
import RuntimeDaemon

/// Reads the event rows of an item tree. MachineRuntime is the real one.
protocol ItemEventReader {
    func events(_ q: Event.Query) async throws -> Event.Page
}

extension MachineRuntime: ItemEventReader {}

/// The event rows of the item trees that the app shows (OVERSIRE-383). It reads the home daemon, else the local one.
/// An event frame adds its row to each tree that holds the item, with no new read. It also keeps your last look of each item.
/// Use it on the main thread.
final class ItemJournal {
    static let pageSize = 1000
    static let maxPages = 5
    static let keepLooks = 500

    private let reader: () async -> (any ItemEventReader)?
    private let bus: ChangeBus
    var lookPath: String?
    private var trees: [String: [Event]] = [:]
    private var loading: Set<String> = []
    private var readAt: [String: Date] = [:]
    private(set) var errors: [String: String] = [:]
    private var looks: [String: Date] = [:]
    /// False for `--uishots` and tests: the seeded rows stay.
    var reads = true

    init(reader: @escaping () async -> (any ItemEventReader)? = ItemJournal.homeReader, bus: ChangeBus = .shared,
         lookPath: String? = (CONFIG_DIR as NSString).appendingPathComponent("looks.json")) {
        self.reader = reader
        self.bus = bus
        self.lookPath = lookPath
        if let p = lookPath, let d = FileManager.default.contents(atPath: p), let l = try? JSONDecoder().decode([String: Date].self, from: d) { looks = l }
    }

    /// The home daemon when it is live, else the daemon of this Mac.
    static func homeReader() async -> (any ItemEventReader)? {
        guard let (machines, live) = await MainActor.run(body: { () -> (Machines, [MachineLink])? in
            guard let hub = ENV.machines else { return nil }
            return (hub.machines, hub.links.filter { hub.isLive($0.machine) })
        }) else { return nil }
        let home = await machines.group?.home.rawValue
        let pick = live.first { $0.machine == home } ?? live.first(where: \.local)
        guard let m = pick?.machine else { return nil }
        return await MainActor.run { ENV.machines?.runtime(m) }
    }

    // MARK: Rows

    /// The rows of the key and its sub-items, oldest first. Nil before the first read.
    func rows(_ key: String) -> [Event]? { trees[key.uppercased()] }

    func isLoading(_ key: String) -> Bool { loading.contains(key.uppercased()) }

    /// Reads the tree of the key. A read in the last 30 s is enough, unless force.
    func load(_ key: String, force: Bool = false) {
        let k = key.uppercased()
        guard reads, !loading.contains(k), force || -(readAt[k] ?? .distantPast).timeIntervalSinceNow > 30 else { return }
        loading.insert(k)
        Task {
            var out: [Event] = []
            var err: String?
            if let r = await reader() {
                var after: Int64 = 0
                do {
                    for _ in 0..<Self.maxPages {
                        let p = try await r.events(Event.Query(item: k, tree: true, after: after, limit: Self.pageSize))
                        out += p.events
                        after = p.next
                        if !p.more { break }
                    }
                } catch { err = String(describing: error) }
            } else {
                err = "No daemon is live."
            }
            let rows = out, e = err
            await MainActor.run { self.finish(k, rows, error: e) }
        }
    }

    private func finish(_ k: String, _ rows: [Event], error: String?) {
        loading.remove(k)
        readAt[k] = Date()
        errors[k] = error
        if error == nil || trees[k] == nil { trees[k] = Self.merge(trees[k] ?? [], rows) }
        post([k])
    }

    /// A row of an event frame: it goes into each tree that holds its item.
    func received(_ e: Event) {
        let keys = Set([e.item, e.parentItem].compactMap { $0?.uppercased() }).filter { trees[$0] != nil }
        for k in keys { trees[k] = Self.merge(trees[k] ?? [], [e]) }
        if !keys.isEmpty { post(keys) }
    }

    /// For tests and `--uishots`.
    func seed(_ key: String, _ rows: [Event]) {
        trees[key.uppercased()] = Self.merge([], rows)
        readAt[key.uppercased()] = Date()
    }

    static func merge(_ a: [Event], _ b: [Event]) -> [Event] {
        var byId: [String: Event] = [:]
        for e in a + b { byId[e.id] = e }
        return byId.values.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    // MARK: Looks

    /// Your last look of the item on this Mac.
    func lastLook(_ key: String) -> Date? { looks[key.uppercased()] }

    func look(_ key: String, at: Date = Date()) {
        looks[key.uppercased()] = at
        if looks.count > Self.keepLooks {
            for (k, _) in looks.sorted(by: { $0.value < $1.value }).prefix(looks.count - Self.keepLooks) { looks[k] = nil }
        }
        guard let p = lookPath, let d = try? JSONEncoder().encode(looks) else { return }
        try? d.write(to: URL(fileURLWithPath: p), options: .atomic)
    }

    /// The last look before `opened`: this Mac, or an item.viewed row of another Mac.
    func since(_ key: String, before local: Date?, opened: Date) -> Date? {
        let row = rows(key)?.last { $0.kind == .itemViewed && $0.item?.uppercased() == key.uppercased() && $0.at < opened.addingTimeInterval(-30) }?.at
        return [local, row].compactMap { $0 }.max()
    }

    private func post(_ keys: Set<String>) { bus.post(DataChange(.events, items: keys, origin: .event)) }
}

let JOURNAL = ItemJournal()

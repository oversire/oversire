import Foundation

// ─── Data changes ────────────────────────────────────────────────────────────
// Each source posts what changed. The bus collects one burst and gives it to each observer once.

/// The kinds of data that a change touches.
struct DataDomains: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let runs = DataDomains(rawValue: 1 << 0)
    static let prs = DataDomains(rawValue: 1 << 1)
    static let projects = DataDomains(rawValue: 1 << 2)
    static let agents = DataDomains(rawValue: 1 << 3)
    static let queue = DataDomains(rawValue: 1 << 4)
    static let relations = DataDomains(rawValue: 1 << 5)
    static let stats = DataDomains(rawValue: 1 << 6)
    static let questions = DataDomains(rawValue: 1 << 7)
    static let intake = DataDomains(rawValue: 1 << 8)
    static let summaries = DataDomains(rawValue: 1 << 9)
    static let planner = DataDomains(rawValue: 1 << 10)
    static let logs = DataDomains(rawValue: 1 << 11)
    static let connection = DataDomains(rawValue: 1 << 12)
    static let config = DataDomains(rawValue: 1 << 13)

    static let all = DataDomains(rawValue: (1 << 14) - 1)

    /// The domains whose keys are repos, store keys or item keys.
    static let byRepo: DataDomains = [.runs, .prs]
    static let byProject: DataDomains = [.projects, .intake]
    static let byItem: DataDomains = [.agents, .relations, .summaries]

    var names: [String] {
        let all: [(DataDomains, String)] = [(.runs, "runs"), (.prs, "prs"), (.projects, "projects"), (.agents, "agents"), (.queue, "queue"),
                                            (.relations, "relations"), (.stats, "stats"), (.questions, "questions"), (.intake, "intake"),
                                            (.summaries, "summaries"), (.planner, "planner"), (.logs, "logs"), (.connection, "connection"),
                                            (.config, "config")]
        return all.filter { contains($0.0) }.map(\.1)
    }
}

/// One change. An empty key set means "all keys" of its domains.
struct DataChange: Sendable, Equatable {
    enum Origin: Int, Sendable, Comparable {
        case poll, event, user
        static func < (a: Origin, b: Origin) -> Bool { a.rawValue < b.rawValue }
    }

    var domains: DataDomains
    var repos: Set<String> = []
    var projects: Set<String> = []
    var items: Set<String> = []
    var origin: Origin

    init(_ domains: DataDomains, repos: Set<String> = [], projects: Set<String> = [], items: Set<String> = [], origin: Origin = .poll) {
        self.domains = domains
        self.repos = repos
        self.projects = projects
        self.items = items
        self.origin = origin
    }

    static func config(_ origin: Origin = .user) -> DataChange { DataChange(.config, origin: origin) }

    /// The union. A side that has a keyed domain with no keys makes the result "all keys". The strongest origin wins.
    mutating func merge(_ o: DataChange) {
        repos = Self.union(repos, domains.intersection(.byRepo), o.repos, o.domains.intersection(.byRepo))
        projects = Self.union(projects, domains.intersection(.byProject), o.projects, o.domains.intersection(.byProject))
        items = Self.union(items, domains.intersection(.byItem), o.items, o.domains.intersection(.byItem))
        domains.formUnion(o.domains)
        origin = max(origin, o.origin)
    }

    private static func union(_ a: Set<String>, _ ad: DataDomains, _ b: Set<String>, _ bd: DataDomains) -> Set<String> {
        if !ad.isEmpty && a.isEmpty || !bd.isEmpty && b.isEmpty { return [] }
        return a.union(b)
    }

    /// True when the change can touch data in `watches` for these keys. A nil key set means the page shows all keys.
    func touches(_ watches: DataDomains, repos r: Set<String>?, projects p: Set<String>?, items i: Set<String>?) -> Bool {
        let hit = domains.intersection(watches)
        if hit.isEmpty { return false }
        if !hit.subtracting(.byRepo).subtracting(.byProject).subtracting(.byItem).isEmpty { return true }
        func keyed(_ d: DataDomains, _ keys: Set<String>, _ shown: Set<String>?) -> Bool {
            guard !hit.intersection(d).isEmpty else { return false }
            guard let shown, !keys.isEmpty else { return true }
            return !keys.isDisjoint(with: shown)
        }
        return keyed(.byRepo, repos, r) || keyed(.byProject, projects, p) || keyed(.byItem, items, i)
    }

    /// A short text for the build log, for example "runs oversire/cloud".
    var reason: String {
        var parts = [domains.names.joined(separator: "+")]
        let keys = (repos.sorted() + projects.sorted() + items.sorted()).prefix(3)
        if !keys.isEmpty { parts.append(keys.joined(separator: ", ")) }
        return parts.joined(separator: " ")
    }
}

/// Main thread only. Coalesces the changes of one burst and sends them to each observer once.
final class ChangeBus {
    /// The bus of the app. Code with no injected bus, such as a settings control, posts here.
    static let shared = ChangeBus()

    /// Keeps an observer. The observer stops when the observation goes.
    final class Observation {
        private weak var bus: ChangeBus?
        private let id: Int
        fileprivate init(bus: ChangeBus, id: Int) { self.bus = bus; self.id = id }
        func cancel() { bus?.observers[id] = nil }
        deinit { cancel() }
    }

    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var observers: [Int: (DataChange) -> Void] = [:]
    private var nextId = 0
    private var pending: DataChange?
    /// The bursts sent so far. Tests and the self-test read it.
    private(set) var sent = 0

    init(delay: TimeInterval = 0.25, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter) {
        self.delay = delay
        self.schedule = schedule
    }

    static func mainAfter(_ t: TimeInterval, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
    }

    func post(_ c: DataChange) {
        if pending != nil { pending?.merge(c); return }
        pending = c
        schedule(delay) { [weak self] in self?.flush() }
    }

    func observe(_ f: @escaping (DataChange) -> Void) -> Observation {
        nextId += 1
        observers[nextId] = f
        return Observation(bus: self, id: nextId)
    }

    private func flush() {
        guard let c = pending else { return }
        pending = nil
        sent += 1
        for k in observers.keys.sorted() { observers[k]?(c) }
    }
}

/// The repos whose list changed between two fetches. A repo that comes or goes counts.
enum RunDiff {
    static func repos<T: Equatable>(_ old: [(String, [T])], _ new: [(String, [T])]) -> Set<String> {
        let before = Dictionary(old, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new, uniquingKeysWith: { a, _ in a })
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }
}

import Foundation
import OverSireCore

/// The groups of Work › Review, in page order.
enum ReviewGroup: String, CaseIterable {
    case plans, code, waiting, conflict

    var title: String {
        switch self {
        case .plans: return "Plans to approve"
        case .code: return "Code to review"
        case .waiting: return "Waiting for the agent"
        case .conflict: return "Conflict"
        }
    }

    var note: String {
        switch self {
        case .plans: return "Approve sets Todo, then the queue can take it"
        case .code: return "Oldest first"
        case .waiting: return ""
        case .conflict: return "The agent rebases and fixes it"
        }
    }

    /// nil: a merged review shows in no group.
    init?(_ s: ReviewSummary) {
        switch s.state {
        case .ready: self = s.kind == .plan ? .plans : .code
        case .waiting: self = .waiting
        case .conflict: self = .conflict
        case .merged: return nil
        }
    }
}

/// The reviews of all machines of the group (OVERSIRE-371). Each row keeps its machine, so each call goes to the right daemon.
/// A review frame of a daemon reads that machine again. A read on start, on a log gap and each 60 s catches what a frame missed.
/// A failed read keeps the last rows of the machine. Use it on the main thread.
final class ReviewBook {
    static let changed = Notification.Name("ReviewBook.changed")

    private let sources: () -> [any ReviewSource]
    private let bus: ChangeBus
    private var pages: [String: ReviewsPage] = [:]   // machine → page
    private var desks: [String: ReviewDesk] = [:]    // ReviewSummary.id → desk
    private var timer: Timer?
    /// The tracker writes of the desks.
    var tracker: (any ReviewTracking)? = nil
    /// False for `--uishots`: the seeded rows stay.
    var reads = true

    init(sources: @escaping () -> [any ReviewSource] = ReviewBook.groupSources, bus: ChangeBus = .shared) {
        self.sources = sources
        self.bus = bus
    }

    /// The daemons of the active machines.
    static func groupSources() -> [any ReviewSource] {
        guard let hub = ENV.machines else { return [] }
        return hub.active.compactMap { hub.runtime($0.machine) }
    }

    // MARK: What the page shows

    /// All open reviews of all machines. A merged review does not show.
    var rows: [ReviewSummary] {
        pages.keys.sorted().flatMap { pages[$0]!.reviews }.filter { $0.state != .merged }
    }

    /// Each group with its rows, oldest first. A group with no rows is left out.
    var groups: [(group: ReviewGroup, rows: [ReviewSummary])] {
        let all = rows
        return ReviewGroup.allCases.compactMap { g in
            let list = all.filter { ReviewGroup($0) == g }.sorted { Self.since($0) < Self.since($1) }
            return list.isEmpty ? nil : (g, list)
        }
    }

    /// The rows where you act: a plan or code that waits for your review.
    var yourTurn: Int { rows.filter { $0.state == .ready }.count }

    /// The base branches with local commits, on all machines.
    var notPushed: [(machine: String, item: NotPushed)] {
        pages.keys.sorted().flatMap { m in pages[m]!.notPushed.map { (m, $0) } }
    }

    /// The open review of the key. A code review wins over a plan review of the same key.
    func review(_ key: String, kind: ReviewKind? = nil) -> ReviewSummary? {
        let list = rows.filter { $0.key == key && (kind == nil || $0.kind == kind) }
        return list.first { $0.kind == .code } ?? list.first
    }

    static func since(_ s: ReviewSummary) -> Date { s.readyAt ?? s.updatedAt }

    // MARK: Reads

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { await refresh() }
    }

    /// Reads all machines at once. A machine that left the group loses its rows.
    func refresh() async {
        guard reads else { return }
        let list = await MainActor.run { sources() }
        let got = await withTaskGroup(of: (String, ReviewsPage?).self) { g in
            for s in list { g.addTask { (s.machine, await Self.read(s)) } }
            var out: [(String, ReviewsPage?)] = []
            for await r in g { out.append(r) }
            return out
        }
        await MainActor.run {
            let machines = Set(list.map(\.machine))
            var next = pages.filter { machines.contains($0.key) }
            for (m, p) in got { if let p { next[m] = p } }
            set(next)
        }
    }

    /// Reads one machine again.
    func refresh(machine: String) async {
        guard reads, let s = await MainActor.run(body: { source(machine) }), let p = await Self.read(s) else { return }
        await MainActor.run {
            var next = pages
            next[machine] = p
            set(next)
        }
    }

    /// A review frame: the rows of the machine and the open desk of the key read again.
    func apply(_ e: ReviewEvent, from machine: String) async {
        let m = e.machine ?? machine
        await refresh(machine: m)
        let desk = await MainActor.run { desks["\(m)/\(e.kind.rawValue)/\(e.key)"] }
        await desk?.load()
    }

    private static func read(_ s: any ReviewSource) async -> ReviewsPage? {
        do { return try await s.reviews(kind: nil) } catch {
            log.info("Reviews: the read of \(s.machine, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func source(_ machine: String) -> (any ReviewSource)? { sources().first { $0.machine == machine } }

    /// The desk of a review. It stays while the app runs, so a tab keeps its place and its drafts.
    func desk(_ s: ReviewSummary) -> ReviewDesk? {
        if let d = desks[s.id] { return d }
        guard let src = source(s.machine) else { return nil }
        let d = ReviewDesk(summary: s, source: src, tracker: tracker, bus: bus)
        desks[s.id] = d
        return d
    }

    /// For tests and `--uishots`: a desk with its data, and no reads.
    func put(_ d: ReviewDesk) { desks[d.id] = d }

    /// For tests and `--uishots`.
    func set(_ next: [String: ReviewsPage]) {
        guard next != pages else { return }
        let keys = Set(pages.values.flatMap(\.reviews).map(\.key)).union(next.values.flatMap(\.reviews).map(\.key))
        pages = next
        bus.post(DataChange(.reviews, items: keys, origin: .event))
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

let REVIEWS = ReviewBook()

import Foundation
import OverSireCore

/// The reviews of one daemon, in memory. It keeps the pending batch, the rounds and the Viewed marks as the daemon does.
/// A comment that is not pending throws `.vendor(code: "409")`; an unknown key or comment throws `.notFound`.
public final class FakeReviewSource: ReviewSource, @unchecked Sendable {
    private let lock = NSLock()
    private var details: [String: ReviewDetail] = [:]   // "kind/key" → detail
    private var order: [String] = []
    private var diffs: [String: FileDiff] = [:]         // "key/repo/path" → diff
    private var notPushed: [NotPushed] = []
    private var made = 0
    private var observer: (@Sendable (ReviewEvent) -> Void)?

    public let machine: String
    public var now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_793_000_000) }
    /// The calls in order, for example "submit SLING-170".
    public private(set) var calls: [String] = []
    /// The agent of each submit, or nil.
    public private(set) var launches: [AgentLaunchSpec?] = []
    /// Each call throws this error while it is set.
    public var failure: Error?
    /// Each call on one of these keys throws its error. For one part of a folded review.
    public var failures: [String: Error] = [:]
    /// The parent of each sub-item key, as the worktree bindings of the daemon. A folded read uses it.
    public var parents: [String: String] = [:]
    /// The fold of the last read.
    public private(set) var lastFold: ReviewFold = .off

    public init(machine: String) { self.machine = machine }

    private func with<T>(_ f: () throws -> T) rethrows -> T { try lock.withLock(f) }

    /// Gets each change, as the review frames of a daemon.
    public func observe(_ f: (@Sendable (ReviewEvent) -> Void)?) { with { observer = f } }

    /// Adds reviews and diffs as they are, for tests.
    public func seed(_ list: [ReviewDetail], diffs: [FileDiff] = [], notPushed: [NotPushed] = []) {
        with {
            for d in list {
                let id = Self.id(d.summary.key, d.summary.kind)
                if details[id] == nil { order.append(id) }
                details[id] = d
            }
            for f in diffs {
                for d in list where d.files.contains(where: { $0.repo == f.repo && $0.path == f.path }) {
                    self.diffs["\(d.summary.key)/\(f.repo)/\(f.path)"] = f
                }
            }
            self.notPushed += notPushed
        }
    }

    public func detail(_ key: String, kind: ReviewKind) -> ReviewDetail? { with { details[Self.id(key, kind)] } }

    // MARK: ReviewSource

    public func reviews(kind: ReviewKind?, fold: ReviewFold) async throws -> ReviewsPage {
        try with {
            try call("reviews")
            lastFold = fold
            var list = order.compactMap { details[$0]?.summary }.filter { kind == nil || $0.kind == kind }
            let parts = Dictionary(grouping: list.filter { $0.kind == .code && parent(of: $0.key, fold) != nil }) { parent(of: $0.key, fold)! }
            guard !parts.isEmpty else { return ReviewsPage(reviews: list, notPushed: notPushed) }
            list.removeAll { $0.kind == .code && (parent(of: $0.key, fold) != nil || parts[$0.key] != nil) }
            for p in parts.keys.sorted() {
                list.append(folded(p, parts[p]!.map(\.key)).summary)
            }
            return ReviewsPage(reviews: list, notPushed: notPushed)
        }
    }

    public func review(_ key: String, kind: ReviewKind, fold: ReviewFold) async throws -> ReviewDetail {
        try with {
            try call("review \(key)")
            lastFold = fold
            let kids = kind == .code ? parents.keys.filter { parent(of: $0, fold) == key && details[Self.id($0, .code)] != nil } : []
            if !kids.isEmpty { return folded(key, kids) }
            guard let d = details[Self.id(key, kind)] else { throw ProviderError.notFound }
            return d
        }
    }

    private func parent(of key: String, _ fold: ReviewFold) -> String? { fold.folds(key) ? parents[key] : nil }

    /// The folded detail of parent, as the daemon makes it: the sub-items in key order, then the parent.
    private func folded(_ parent: String, _ kids: [String]) -> ReviewDetail {
        let keys = kids.sorted { $0.localizedStandardCompare($1) == .orderedAscending } + [parent]
        let parts = keys.compactMap { details[Self.id($0, .code)] }
        let first = parts[0].summary
        var s = details[Self.id(parent, .code)]?.summary
            ?? ReviewSummary(key: parent, kind: .code, machine: machine, state: .ready, root: first.root, updatedAt: first.updatedAt)
        s.repos = parts.flatMap { d in d.summary.repos.map { var r = $0; r.item = d.summary.key; return r } }
        s.subitems = kids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        s.pending = parts.reduce(0) { $0 + $1.summary.pending }
        s.unanswered = parts.reduce(0) { $0 + $1.summary.unanswered }
        s.round = parts.map(\.summary.round).max() ?? 0
        s.parts = parts.map {
            let p = $0.summary
            return ReviewPart(key: p.key, root: p.root, group: p.group, state: p.state, round: p.round, pending: p.pending,
                              unanswered: p.unanswered, session: p.session, note: p.note, readyAt: p.readyAt)
        }
        let states = parts.map(\.summary.state)
        s.state = states.contains(.conflict) ? .conflict : states.contains(.ready) ? .ready : states.contains(.waiting) ? .waiting : .merged
        let files = parts.flatMap { d in d.files.map { var f = $0; f.item = d.summary.key; return f } }
        let rounds = parts.flatMap { d in d.rounds.map { var r = $0; r.item = d.summary.key; return r } }
        return ReviewDetail(summary: s, files: files, comments: parts.flatMap(\.comments), rounds: rounds)
    }

    public func diff(_ key: String, repo: String, path: String, full: Bool) async throws -> FileDiff {
        try with {
            try call("diff \(key) \(repo)/\(path)" + (full ? " full" : ""))
            guard let d = diffs["\(key)/\(repo)/\(path)"] else { throw ProviderError.notFound }
            return d
        }
    }

    public func addComment(_ key: String, _ draft: CommentDraft) async throws -> ReviewComment {
        try change(key, draft.kind ?? Self.kind(of: draft.anchor), "comment") { d in
            made += 1
            let c = ReviewComment(id: String(format: "c_%08x", made), key: key, round: d.summary.round + 1, state: .pending,
                                  anchor: draft.anchor, text: draft.text, createdAt: now())
            d.comments.append(c)
            return c
        }
    }

    public func editComment(_ key: String, id: String, _ e: CommentEdit) async throws {
        let kind = with { ReviewKind.allCases.first { details[Self.id(key, $0)]?.comments.contains { $0.id == id } == true } }
        try change(key, kind, "edit") { d in
            let i = try Self.pending(d, id)
            d.comments[i].text = e.text
            d.comments[i].updatedAt = now()
        }
    }

    public func deleteComment(_ key: String, id: String, kind: ReviewKind) async throws {
        try change(key, kind, "delete") { d in d.comments.remove(at: try Self.pending(d, id)) }
    }

    public func markViewed(_ key: String, _ m: ViewedMark) async throws {
        try change(key, .code, "viewed", event: nil) { d in
            guard let i = d.files.firstIndex(where: { $0.repo == m.repo && $0.path == m.path }) else { throw ProviderError.notFound }
            d.files[i].viewed = m.viewed
            d.files[i].viewedStale = nil
        }
    }

    public func submit(_ key: String, _ s: SubmitReview) async throws -> ReviewRound {
        with { launches.append(s.launch) }
        return try change(key, s.kind ?? .code, "submit") { d in
            let n = d.summary.round + 1
            var count = 0
            for i in d.comments.indices where d.comments[i].state == .pending {
                d.comments[i].state = .submitted
                d.comments[i].round = n
                count += 1
            }
            let delivery: ReviewRound.Delivery
            if s.verdict == .approve {
                delivery = .none
            } else {
                switch d.summary.session?.state {
                case .idle?: delivery = .sent
                case .working?: delivery = .queued
                default: delivery = .newSession
                }
                d.summary.state = .waiting
                d.summary.session?.state = .working
            }
            let r = ReviewRound(n: n, verdict: s.verdict, summary: s.summary, count: count, submittedAt: now(), delivery: delivery,
                                session: d.summary.session?.id)
            d.rounds.append(r)
            d.summary.round = n
            return r
        }
    }

    public func merge(_ key: String, _ r: MergeRequest) async throws -> MergeResult {
        let res: MergeResult = try change(key, .code, "merge") { d in
            guard d.summary.state != .waiting else { throw ProviderError.vendor(code: "409", message: "A session of \(key) works.") }
            if let bad = d.summary.repos.firstIndex(where: { $0.merge == .conflict }) {
                d.summary.state = .conflict
                let repos = d.summary.repos.enumerated().map { i, repo in
                    RepoMerge(name: repo.name, result: i == bad ? .conflict : .skipped, conflictFiles: i == bad ? repo.conflictFiles : nil)
                }
                return MergeResult(merged: false, repos: repos, notPushed: notPushed)
            }
            d.summary.state = .merged
            let repos = d.summary.repos.map { RepoMerge(name: $0.name, result: $0.merge == .rebase ? .rebased : .merged, head: "f00d\($0.ahead)") }
            notPushed += d.summary.repos.map { NotPushed(root: d.summary.root, repo: $0.name, base: $0.base, ahead: $0.ahead) }
            return MergeResult(merged: true, repos: repos, removed: r.removeGroup, notPushed: notPushed)
        }
        if res.merged { with { order.removeAll { $0 == Self.id(key, .code) }; details[Self.id(key, .code)] = nil } }
        return res
    }

    public func fix(_ key: String) async throws -> ReviewRound {
        try change(key, .code, "fix") { d in
            let n = d.summary.round + 1
            d.summary.round = n
            d.summary.state = .waiting
            let r = ReviewRound(n: n, verdict: .requestChanges, summary: "Rebase and fix the conflict.", count: 0, submittedAt: now(),
                                delivery: .newSession)
            d.rounds.append(r)
            return r
        }
    }

    // MARK: Inside

    private static func id(_ key: String, _ kind: ReviewKind) -> String { kind.rawValue + "/" + key }

    private static func kind(of a: ReviewAnchor) -> ReviewKind {
        if case .plan = a { return .plan }
        return .code
    }

    private static func pending(_ d: ReviewDetail, _ id: String) throws -> Int {
        guard let i = d.comments.firstIndex(where: { $0.id == id }) else { throw ProviderError.notFound }
        guard d.comments[i].state == .pending else { throw ProviderError.vendor(code: "409", message: "The comment \(id) is not pending.") }
        return i
    }

    private func call(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
        if let key = name.split(separator: " ").dropFirst().first, let e = failures[String(key)] { throw e }
    }

    /// Changes the review of the key. `kind` nil: the review that has the comment. Each change sends review.changed.
    private func change<T>(_ key: String, _ kind: ReviewKind?, _ name: String, event: ReviewEvent.Name? = .changed,
                           _ f: (inout ReviewDetail) throws -> T) throws -> T {
        let (out, ev): (T, ReviewEvent?) = try with {
            try call("\(name) \(key)")
            let kinds = kind.map { [$0] } ?? ReviewKind.allCases
            guard let k = kinds.first(where: { details[Self.id(key, $0)] != nil }), var d = details[Self.id(key, k)] else { throw ProviderError.notFound }
            let out = try f(&d)
            d.summary.pending = d.pending.count
            d.summary.unanswered = d.comments.filter { $0.state == .submitted }.count
            d.summary.updatedAt = now()
            details[Self.id(key, k)] = d
            return (out, event.map { ReviewEvent(event: $0, key: key, kind: k, machine: machine) })
        }
        if let ev, let o = with({ observer }) { o(ev) }
        return out
    }
}

import Foundation
import OverSireCore

/// The tracker writes of a review. The daemon has no tracker token, so the app writes (OVERSIRE-372).
protocol ReviewTracking: AnyObject {
    func post(_ key: String, markdown: String, done: @escaping (Bool) -> Void)
    /// Sets the item and its open sub-items to the first state of the group.
    func move(key: String, group: String, else category: StatusCategory, done: @escaping (Bool) -> Void)
}

extension ProjectStore: ReviewTracking {
    func post(_ key: String, markdown: String, done: @escaping (Bool) -> Void) {
        guard let found = item(key: key) else { done(false); return }
        comment(itemId: found.item.id, body: markdown, done: done)
    }
}

/// The lines of a code comment: a click picks one line, a shift-click on the same side picks the lines between.
struct LinePick: Hashable {
    let repo: String
    let path: String
    let side: ReviewAnchor.Side
    let first: Int
    var last: Int

    init(repo: String, path: String, side: ReviewAnchor.Side, line: Int) {
        self.repo = repo
        self.path = path
        self.side = side
        first = line
        last = line
    }

    /// The pick after a click on `line`. A shift-click on another file or side starts a new pick.
    func click(_ line: Int, side: ReviewAnchor.Side, shift: Bool) -> LinePick {
        guard shift, side == self.side else { return LinePick(repo: repo, path: path, side: side, line: line) }
        var p = self
        p.last = line
        return p
    }

    var from: Int { min(first, last) }
    var to: Int { max(first, last) }

    /// `from` only for a range. The anchor line is the last line.
    var anchor: ReviewAnchor { .code(repo: repo, path: path, line: to, from: from == to ? nil : from, side: side) }

    var label: String { from == to ? "line \(to)" : "lines \(from)–\(to)" }

    func contains(_ line: Int, side: ReviewAnchor.Side) -> Bool { side == self.side && (from...to).contains(line) }

    /// The side and the number of a diff line for a pick. A context line counts on the new side.
    static func place(_ l: DiffLine) -> (side: ReviewAnchor.Side, line: Int)? {
        switch l.kind {
        case .del: return l.old.map { (.old, $0) }
        case .add, .ctx: return l.new.map { (.new, $0) }
        }
    }
}

/// One review that the person works on: its detail, the diffs, the pending batch and the place in the tab.
/// Each call goes to the daemon of the machine of the review. Use it on the main thread.
final class ReviewDesk {
    let machine: String
    let key: String
    let kind: ReviewKind
    var id: String { "\(machine)/\(kind.rawValue)/\(key)" }
    private let source: (any ReviewSource)?
    private let tracker: (any ReviewTracking)?
    private let bus: ChangeBus

    private(set) var summary: ReviewSummary
    private(set) var detail: ReviewDetail?
    private(set) var diffs: [String: FileDiff] = [:]   // ReviewFile.id → diff
    private var asked: Set<String> = []                 // the diffs read once, so a failed read does not loop
    /// The text of the last failed call.
    private(set) var error: String?
    private(set) var loading = false
    /// The agent for a new session when the daemon knows no agent of the key.
    var agent: (String) -> AgentLaunchSpec? = { _ in nil }

    // The place in the tab. It stays across builds of the page.
    var file: String?
    var split = false
    var pick: LinePick?
    var block: String?
    var draft = ""
    var editing: String?
    var unfolded: Set<String> = []
    var view = FileView.saved { didSet { FileView.saved = view } }
    /// Long diff lines wrap. Off by default: the diff scrolls horizontally (OVERSIRE-392). One choice for all reviews, kept across launches.
    var wrap: Bool {
        get { Self.wraps }
        set {
            Self.wraps = newValue
            if !UIShots.shooting { UserDefaults.standard.set(newValue, forKey: "review.wrap") }
        }
    }
    /// The diff scrolls horizontally: a unified diff with no wrap.
    var scrolls: Bool { !wrap && !split }
    private static var wraps = !UIShots.shooting && UserDefaults.standard.bool(forKey: "review.wrap")
    var filter = FileFilter()
    var collapsed: Set<String> = []
    /// The comment to scroll to after the next build of the diff.
    var reveal: String?
    /// The review runs on this Mac, so its files are on this disk.
    var local = false

    init(summary: ReviewSummary, source: (any ReviewSource)?, tracker: (any ReviewTracking)?, bus: ChangeBus = .shared) {
        machine = summary.machine
        key = summary.key
        kind = summary.kind
        self.summary = summary
        self.source = source
        self.tracker = tracker
        self.bus = bus
    }

    /// For tests and `--uishots`: a desk with its data and no daemon.
    convenience init(detail: ReviewDetail, diffs: [FileDiff] = [], tracker: (any ReviewTracking)? = nil, bus: ChangeBus = .shared) {
        self.init(summary: detail.summary, source: nil, tracker: tracker, bus: bus)
        self.detail = detail
        for d in diffs { self.diffs[d.repo + "/" + d.path] = d }
        file = detail.files.first?.id
    }

    // MARK: What the tab shows

    var files: [ReviewFile] { detail?.files ?? [] }
    var comments: [ReviewComment] { detail?.comments ?? [] }
    var rounds: [ReviewRound] { detail?.rounds ?? [] }
    var pending: [ReviewComment] { detail?.pending ?? [] }
    /// The round that a submit makes.
    var nextRound: Int { summary.round + 1 }

    /// Only a pending comment changes. A submitted comment belongs to its round.
    static func canEdit(_ c: ReviewComment) -> Bool { c.state == .pending }

    /// The comments of one file, in line order.
    func comments(in f: ReviewFile) -> [ReviewComment] {
        comments.filter {
            if case .code(let repo, let path, _, _, _) = $0.anchor { return repo == f.repo && path == f.path }
            return false
        }.sorted { Self.line($0) < Self.line($1) }
    }

    func comments(block: String) -> [ReviewComment] { comments.filter { $0.anchor == .plan(block: block) } }

    static func line(_ c: ReviewComment) -> Int {
        if case .code(_, _, let line, _, _) = c.anchor { return line }
        return 0
    }

    /// The pending comments of each file id, for the file list.
    var pendingByFile: [String: Int] {
        var out: [String: Int] = [:]
        for c in pending { if case .code(let repo, let path, _, _, _) = c.anchor { out[repo + "/" + path, default: 0] += 1 } }
        return out
    }

    /// ReviewFile.id → answered comments.
    var answeredByFile: [String: Int] {
        var out: [String: Int] = [:]
        for c in comments where c.state == .answered {
            if case .code(let repo, let path, _, _, _) = c.anchor { out[repo + "/" + path, default: 0] += 1 }
        }
        return out
    }

    var tree: FileTree {
        FileTree(files: files, repos: summary.repos.map(\.name), filter: filter, collapsed: collapsed, pending: pendingByFile)
    }

    // MARK: Calls

    func load() async {
        guard let source else { return }
        await MainActor.run { loading = true }
        do {
            let d = try await source.review(key, kind: kind)
            await MainActor.run {
                // A Viewed mark keeps the diffs. A new commit drops them.
                if d.files.map(\.change) != (detail?.files ?? []).map(\.change) {
                    diffs = [:]
                    asked = []
                }
                detail = d
                summary = d.summary
                if file == nil || !d.files.contains(where: { $0.id == file }) { file = d.files.first?.id }
                error = nil
                loading = false
                changed()
            }
        } catch { await fail(error) }
    }

    /// The diff of the file. A read keeps it until the review changes.
    func diff(_ f: ReviewFile) async {
        guard let source, diffs[f.id] == nil, !asked.contains(f.id) else { return }
        asked.insert(f.id)
        do {
            let d = try await source.diff(key, repo: f.repo, path: f.path, full: false)
            await MainActor.run {
                diffs[f.id] = d
                changed()
            }
        } catch { await fail(error) }
    }

    func add(_ anchor: ReviewAnchor, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let source else { return false }
        return await run {
            _ = try await source.addComment(self.key, CommentDraft(kind: self.kind, anchor: anchor, text: t))
            await MainActor.run { self.pick = nil; self.block = nil; self.draft = "" }
        }
    }

    func edit(_ c: ReviewComment, text: String) async -> Bool {
        guard Self.canEdit(c), let source else { return false }
        return await run {
            try await source.editComment(self.key, id: c.id, CommentEdit(text: text))
            await MainActor.run { self.editing = nil }
        }
    }

    func delete(_ c: ReviewComment) async -> Bool {
        guard Self.canEdit(c), let source else { return false }
        return await run { try await source.deleteComment(self.key, id: c.id, kind: self.kind) }
    }

    /// Deletes all pending comments.
    func discardAll() async -> Bool {
        guard let source else { return false }
        let list = pending
        return await run { for c in list { try await source.deleteComment(self.key, id: c.id, kind: self.kind) } }
    }

    /// The path of the file on the disk of the machine of the review.
    func absolutePath(_ f: ReviewFile) -> String {
        let group = summary.group.map { $0.hasPrefix("/") ? $0 : (summary.root as NSString).appendingPathComponent($0) } ?? summary.root
        return ((group as NSString).appendingPathComponent(f.repo) as NSString).appendingPathComponent(f.path)
    }

    func setViewed(_ f: ReviewFile, _ on: Bool) async -> Bool {
        guard let source else { return false }
        return await run { try await source.markViewed(self.key, ViewedMark(repo: f.repo, path: f.path, viewed: on)) }
    }

    /// All pending comments become one round. The app writes the tracker parts: the round comment, and Todo for an approved plan.
    func submit(_ verdict: ReviewVerdict, summary text: String?, post: Bool) async throws -> ReviewRound {
        guard let source else { throw ProviderError.transport("No daemon has this review.") }
        let batch = pending
        let note = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = note?.isEmpty == false ? note : nil
        do {
            // A given launch wins over the agent of the last session, so send one only when the daemon knows none.
            let known = self.summary.session?.harness != nil
            let launch = verdict == .requestChanges && !known ? agent(key) : nil
            let round = try await source.submit(key, SubmitReview(kind: kind, verdict: verdict, summary: summary, postToTracker: post, launch: launch))
            await MainActor.run {
                if post { self.tracker?.post(self.key, markdown: self.trackerNote(round, batch)) { _ in } }
                if verdict == .approve, self.kind == .plan { self.tracker?.move(key: self.key, group: "unstarted", else: .todo) { _ in } }
            }
            await load()
            return round
        } catch {
            await fail(error)
            throw error
        }
    }

    /// Merges each repo locally. `setDone` sets the item and its sub-items to Done, with a merge comment.
    func merge(removeGroup: Bool, setDone: Bool) async throws -> MergeResult {
        guard let source else { throw ProviderError.transport("No daemon has this review.") }
        do {
            let r = try await source.merge(key, MergeRequest(removeGroup: removeGroup))
            await MainActor.run {
                if r.merged, setDone {
                    self.tracker?.post(self.key, markdown: self.mergeNote(r)) { _ in }
                    self.tracker?.move(key: self.key, group: "completed", else: .done) { _ in }
                }
                self.changed()
            }
            await load()
            return r
        } catch {
            await fail(error)
            throw error
        }
    }

    /// The agent rebases the group and fixes the conflict.
    func fix() async throws -> ReviewRound {
        guard let source else { throw ProviderError.transport("No daemon has this review.") }
        do {
            let r = try await source.fix(key)
            await load()
            return r
        } catch {
            await fail(error)
            throw error
        }
    }

    private func run(_ op: @escaping () async throws -> Void) async -> Bool {
        do {
            try await op()
            await load()
            return true
        } catch {
            await fail(error)
            return false
        }
    }

    private func fail(_ e: Error) async {
        await MainActor.run {
            error = (e as? ProviderError)?.message ?? e.localizedDescription
            loading = false
            changed()
        }
    }

    private func changed() {
        bus.post(DataChange(.reviews, items: [key], origin: .event))
    }

    // MARK: Texts

    /// One tracker comment for a round.
    func trackerNote(_ r: ReviewRound, _ batch: [ReviewComment]) -> String {
        let what = kind == .plan ? "Plan review" : "Code review"
        let verdict = r.verdict == .approve ? "Approve" : "Request changes"
        var lines = ["**\(what) round \(r.n) · \(verdict)**"]
        if let s = r.summary { lines += ["", s] }
        if !batch.isEmpty {
            lines.append("")
            for c in batch { lines.append("- `\(Self.place(c, plan: detail?.plan))`: \(c.text.replacingOccurrences(of: "\n", with: " "))") }
        }
        lines += ["", "_OverSire review, sent by the daemon on \(machine)._"]
        return lines.joined(separator: "\n")
    }

    /// The merge comment on the item.
    func mergeNote(_ r: MergeResult) -> String {
        let repos = r.repos.filter { $0.result == .merged || $0.result == .rebased }.map { m -> String in
            let base = summary.repos.first { $0.name == m.name }?.base ?? "base"
            return "- `\(m.name)` into `\(base)`" + (m.head.map { " at `\($0)`" } ?? "") + (m.result == .rebased ? ", after a rebase" : "")
        }
        return (["**Merged locally** on \(machine). Not pushed."] + repos).joined(separator: "\n")
    }

    /// "sling-cli/a.go:12-14", or the plan block heading.
    static func place(_ c: ReviewComment, plan: PlanDoc?) -> String {
        if case .plan(let b) = c.anchor { return "Plan section \"" + (plan?.blocks.first { $0.id == b }?.heading ?? c.excerpt ?? b) + "\"" }
        return c.anchor.label
    }

    /// The prompt that the agent gets for the batch, as the daemon writes it. A preview only.
    func prompt(summary text: String?) -> String {
        let place = kind == .plan ? summary.root : summary.group ?? summary.root
        var out: String
        if kind == .plan {
            out = "Plan review round \(nextRound) of \(key). Work in \(place).\n"
                + "For each comment: change the plan and the sub-items, then answer it with\n"
                + "  oversire review reply <id> \"<what you did>\"\n"
                + "When all are done, hand off the new plan with\n"
                + "  oversire review ready --kind plan --note \"<one line>\"\n"
                + "Do not write code.\n"
        } else {
            out = "Code review round \(nextRound) of \(key). Work in \(place).\n"
                + "For each comment: fix it, commit, then answer it with\n"
                + "  oversire review reply <id> \"<what you did>\"\n"
                + "When all are done, run the tests and\n"
                + "  oversire review ready --note \"<one line>\"\n"
                + "Do not merge.\n"
        }
        if let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out += "\nSummary: \(s)\n" }
        for c in pending {
            out += "\n[\(c.id)] \(Self.place(c, plan: detail?.plan))\n"
            if let ex = c.excerpt, kind == .code {
                let first = c.anchor.lines.lowerBound
                for (i, l) in ex.components(separatedBy: "\n").enumerated() { out += "    \(first + i) | \(l)\n" }
            }
            out += "  \(c.text)\n"
        }
        return out
    }
}

extension ReviewFile {
    fileprivate var change: String { "\(id) \(added) \(removed)" }
}

extension ReviewAnchor {
    /// The lines of a code anchor. A plan block has none.
    var lines: ClosedRange<Int> {
        if case .code(_, _, let line, let from, _) = self { return (from ?? line)...line }
        return 0...0
    }
}

import Foundation
import OverSireCore

// ─── Cleanup ─────────────────────────────────────────────────────────────────
// What a finished item leaves behind: Orca worktrees and cards, .wt/<task>/ groups, merged branches, open PRs.

struct CleanupConfig: Codable, Equatable {
    static let waits = [15, 60, 1440, 10080]   // minutes
    var auto = false            // remove the safe lines of finished items without a click
    var waitMinutes = 60        // after the item is finished
    var onlyOurs = true         // only worktrees that OverSire started
    var runHooks = false        // orca worktree rm --run-hooks

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        waitMinutes = try c.decodeIfPresent(Int.self, forKey: .waitMinutes) ?? 60
        onlyOurs = try c.decodeIfPresent(Bool.self, forKey: .onlyOurs) ?? true
        runHooks = try c.decodeIfPresent(Bool.self, forKey: .runHooks) ?? false
    }

    static func waitText(_ m: Int) -> String {
        m < 60 ? "\(m) minutes" : m < 1440 ? "\(m / 60) hour\(m == 60 ? "" : "s")" : m < 10080 ? "\(m / 1440) day\(m == 1440 ? "" : "s")" : "\(m / 10080) week\(m == 10080 ? "" : "s")"
    }
}

/// One thing left over. A safe line is checked by default, and auto-remove may run it. A Look line is never checked.
struct CleanupLine: Equatable {
    enum Kind: String {
        case worktree, card, group, localBranch, remoteBranch, pr, session

        var noun: String {
            switch self {
            case .worktree: return "worktree"
            case .card: return "Orca card"
            case .group: return "worktree group"
            case .localBranch: return "local branch"
            case .remoteBranch: return "remote branch"
            case .pr: return "open PR"
            case .session: return "live session"
            }
        }
    }
    enum Action: Equatable {
        case workspace(Workspace)                            // orca worktree rm
        case group(path: String, worktrees: [String])        // git worktree remove each, then the folder
        case localBranch(main: String, name: String)         // git branch -d
        case remoteBranch(repo: String, name: String, main: String)
        case none                                            // flag only
    }

    let id: String
    let kind: Kind
    let action: Action
    let title: String
    let detail: String
    let safe: Bool
    var url: String? = nil

    var removable: Bool { action != .none }
    /// A worktree line: the Worktrees page counts it.
    var isWorktree: Bool { kind == .worktree || kind == .card || kind == .group }
}

/// The git and code host facts that the plan uses. The Cleaner reads them in the background.
struct CleanupFacts {
    var states: [String: CheckoutState] = [:]      // checkout path
    var mains: [String: String] = [:]              // checkout path → main checkout
    var bases: [String: String] = [:]              // main checkout → default branch
    var branches: [String: [GitBranch]] = [:]      // main checkout → local branches
    var remotes: [String: Set<String>] = [:]       // main checkout → origin branches
    var repos: [String: String] = [:]              // main checkout → owner/name
    var pulls: [String: [ChangeRequest]] = [:]     // "owner/name|branch" → changes with that head
}

struct CleanupRecord: Codable, Equatable {
    let at: Date
    let key: String
    let text: String
}

final class Cleaner {
    static let changed = Notification.Name("CleanerChanged")
    /// The item key of a change, when the change is for one item.
    static let keyInfo = "key"
    private static let logKey = "cleanupLog"

    private(set) var facts = CleanupFacts()
    private(set) var records: [CleanupRecord] = []   // newest first
    private(set) var running: Set<String> = []       // item keys
    private var refreshing = false
    private var pullsAt: [String: Date] = [:]
    private var autoTried: [String: Date] = [:]      // item key → last auto run
    private let commands: any CommandRunner
    private let defaults: UserDefaults
    var runtime: () -> (any WorkspaceRemoving)? = { ENV.runtime as? any WorkspaceRemoving }
    var branchHost: (String) -> (host: any BranchDeleting, ref: RepoRef)? = { REPO_CLIENT.branchHost($0) }
    var now: () -> Date = Date.init

    init(commands: any CommandRunner = ProcessRunner(), defaults: UserDefaults = .standard) {
        self.commands = commands
        self.defaults = defaults
        records = (defaults.data(forKey: Self.logKey)).flatMap { try? JSONDecoder().decode([CleanupRecord].self, from: $0) } ?? []
    }

    /// Sets the facts. For tests and --uishots.
    func load(_ f: CleanupFacts, records r: [CleanupRecord]? = nil) {
        facts = f
        if let r { records = r }
    }

    // MARK: The plan (pure)

    /// The leftovers of a finished item. `live`: a card of the item has a working or waiting agent.
    static func plan(key: String, cards: [Workspace], checkouts: [Checkout], openPRs: [(repo: String, pr: ChangeRequest)],
                     facts: CleanupFacts, known: Set<String>) -> [CleanupLine] {
        var out: [CleanupLine] = []
        let live = cards.contains { $0.hasLiveAgent }
        func ours(_ branch: String) -> Bool {
            !branch.isEmpty && !DEFAULT_BRANCHES.contains(branch)
                && (WorkstreamIndex.key(inBranch: branch, known: known) == key || checkouts.contains { $0.branch == branch })
        }

        for c in cards where c.kind != .main {
            if c.hasLiveAgent {
                out.append(CleanupLine(id: "session|" + c.id, kind: .session, action: .none, title: "Agent session in \(c.name) is live",
                                       detail: "OverSire does not remove a worktree with a live agent.", safe: false))
                continue
            }
            if c.kind == .folder {
                out.append(CleanupLine(id: "card|" + c.id, kind: .card, action: .workspace(c), title: "Orca card \"\(c.name)\"",
                                       detail: "Folder workspace on \(c.repo). OverSire closes the card and keeps the folder.", safe: true))
                continue
            }
            let s = facts.states[c.path]
            let detail = s.map { $0.risk.map { $0 + "." } ?? "Merged · clean · no live agent" } ?? "OverSire is checking git."
            out.append(CleanupLine(id: "worktree|" + c.id, kind: .worktree, action: .workspace(c), title: "Orca worktree \(c.name)",
                                   detail: [c.repo, c.branch].filter { !$0.isEmpty }.joined(separator: " · ") + ". " + detail,
                                   safe: s?.clean == true))
        }

        // .wt/<task>/<repo> checkouts that no card owns.
        var groups: [String: [Checkout]] = [:]
        for co in checkouts where !cards.contains(where: { $0.path == co.path }) {
            let parent = (co.path as NSString).deletingLastPathComponent
            guard ((parent as NSString).deletingLastPathComponent as NSString).lastPathComponent == ".wt" else { continue }
            groups[parent, default: []].append(co)
        }
        for (path, cos) in groups.sorted(by: { $0.key < $1.key }) {
            let paths = cos.map(\.path).sorted()
            let states = paths.map { facts.states[$0] }
            let risks = zip(paths, states).compactMap { p, s in s?.risk.map { "\((p as NSString).lastPathComponent): \($0)" } }
            let names = paths.map { ($0 as NSString).lastPathComponent }
            let task = (path as NSString).lastPathComponent
            var detail = "\(names.count) repo\(names.count == 1 ? "" : "s") (\(names.joined(separator: ", "))). "
            if live { detail += "An agent of the item is live." }
            else if states.contains(where: { $0 == nil }) { detail += "OverSire is checking git." }
            else if risks.isEmpty { detail += "Merged, no changes. Removes each worktree, then the folder." }
            else { detail += risks.joined(separator: "; ") + "." }
            out.append(CleanupLine(id: "group|" + path, kind: .group, action: .group(path: path, worktrees: paths),
                                   title: "Worktree group .wt/\(task)/", detail: detail,
                                   safe: !live && !states.contains(where: { $0 == nil }) && risks.isEmpty))
        }

        let busy = Set(checkouts.map(\.branch))
        for (main, list) in facts.branches.sorted(by: { $0.key < $1.key }) {
            let base = facts.bases[main] ?? "main"
            for b in list where b.merged && !b.checkedOut && b.name != base && !busy.contains(b.name) && ours(b.name) {
                out.append(CleanupLine(id: "branch|\(main)|\(b.name)", kind: .localBranch, action: .localBranch(main: main, name: b.name),
                                       title: "Local branch \(b.name)", detail: "\((main as NSString).lastPathComponent) · merged into \(base).", safe: true))
            }
        }

        var flagged = Set<String>()
        for (main, names) in facts.remotes.sorted(by: { $0.key < $1.key }) {
            guard let repo = facts.repos[main], !repo.isEmpty else { continue }
            for name in names.sorted() where ours(name) {
                let pulls = facts.pulls["\(repo)|\(name)"] ?? []
                if let open = pulls.first(where: { $0.state == "OPEN" }) {
                    guard flagged.insert("\(repo)#\(open.number)").inserted else { continue }
                    out.append(CleanupLine(id: "pr|\(repo)#\(open.number)", kind: .pr, action: .none, title: "PR #\(open.number) is still open",
                                           detail: "\(repo) · OverSire does not close a PR.", safe: false, url: open.url))
                } else if let merged = pulls.first(where: { $0.state == "MERGED" }) {
                    out.append(CleanupLine(id: "remote|\(repo)|\(name)", kind: .remoteBranch, action: .remoteBranch(repo: repo, name: name, main: main),
                                           title: "Remote branch \(name)", detail: "\(repo) · PR #\(merged.number) is merged.", safe: true))
                }
            }
        }
        for (repo, pr) in openPRs where pr.state == "OPEN" && flagged.insert("\(repo)#\(pr.number)").inserted {
            out.append(CleanupLine(id: "pr|\(repo)#\(pr.number)", kind: .pr, action: .none, title: "PR #\(pr.number) is still open",
                                   detail: "\(repo) · OverSire does not close a PR.", safe: false, url: pr.url))
        }
        return out
    }

    // MARK: The app

    /// The finished item of a key, or nil.
    static func finished(_ key: String, data: AppData) -> (item: Item, snap: ProjectSnapshot)? {
        guard let f = data.projectStore.item(key: key), f.snap.isFinished(f.item) else { return nil }
        return (f.item, f.snap)
    }

    private static func known(_ data: AppData) -> Set<String> { Set(data.projectStore.tracked.map { $0.identifier.uppercased() }) }

    /// The leftovers of an item. Empty when the item is not finished.
    func lines(_ key: String, data: AppData) -> [CleanupLine] {
        let k = key.uppercased()
        guard Self.finished(k, data: data) != nil else { return [] }
        let cards = data.agentIndex.cards.filter { AgentsPage.cardKey($0, data: data) == k }
        let checkouts = data.workstreams.checkouts.filter { $0.key == k }
        return Self.plan(key: k, cards: cards, checkouts: checkouts, openPRs: data.workstreams.stream(k)?.prs ?? [],
                         facts: facts, known: Self.known(data))
    }

    /// The item keys with a card or a checkout.
    static func attachedKeys(_ data: AppData) -> Set<String> {
        Set(data.agentIndex.cards.compactMap { AgentsPage.cardKey($0, data: data) } + data.workstreams.checkouts.compactMap(\.key))
    }

    /// Finished items with leftovers, by key.
    /// The line of one Orca card of a finished item: a worktree, a folder card or a live session. Else nil.
    func line(card c: Workspace, key: String, data: AppData) -> CleanupLine? {
        lines(key, data: data).first { [.worktree, .card, .session].contains($0.kind) && $0.id.hasSuffix("|" + c.id) }
    }

    func pending(_ data: AppData) -> [String: [CleanupLine]] {
        var out: [String: [CleanupLine]] = [:]
        for k in Self.attachedKeys(data) {
            let l = lines(k, data: data)
            if !l.isEmpty { out[k] = l }
        }
        for (main, list) in facts.branches {
            _ = main
            for b in list {
                guard let k = WorkstreamIndex.key(inBranch: b.name, known: Self.known(data)), out[k] == nil else { continue }
                let l = lines(k, data: data)
                if !l.isEmpty { out[k] = l }
            }
        }
        return out
    }

    /// Reads the git state of the checkouts of finished items, and the changes of their branches.
    func refresh(_ data: AppData, done: (() -> Void)? = nil) {
        guard !refreshing else { done?(); return }
        let keys = Self.attachedKeys(data).filter { Self.finished($0, data: data) != nil }
        var paths: [String: String] = [:]   // checkout path → owner/name
        for co in data.workstreams.checkouts where co.key.map(keys.contains) == true { paths[co.path] = co.repo }
        for c in data.agentIndex.cards where c.kind == .worktree {
            if let k = AgentsPage.cardKey(c, data: data), keys.contains(k), paths[c.path] == nil { paths[c.path] = "" }
        }
        let known = Self.known(data)
        let old = facts
        let pullsAt = self.pullsAt
        let at = now()
        refreshing = true
        Task { [commands, branchHost] in
            var f = old
            for (path, repo) in paths {
                let g = GitCheckout(path: path, commands: commands)
                guard let s = try? await g.state() else { f.states[path] = nil; continue }
                f.states[path] = s
                if f.mains[path] == nil, let m = try? await g.mainCheckout() { f.mains[path] = m }
                if let m = f.mains[path], !repo.isEmpty { f.repos[m] = repo }
            }
            var fetched: [String: Date] = [:]
            for main in Set(f.mains.values) {
                let g = GitCheckout(path: main, commands: commands)
                guard FileManager.default.fileExists(atPath: main) else {
                    f.branches[main] = nil; f.remotes[main] = nil
                    continue
                }
                let base = await g.baseBranch()
                f.bases[main] = base
                f.branches[main] = (try? await g.branches(base: base)) ?? f.branches[main]
                f.remotes[main] = (try? await g.remoteBranches()).map(Set.init) ?? f.remotes[main]
                guard let repo = f.repos[main], let host = branchHost(repo) else { continue }
                let names = Set((f.branches[main] ?? []).map(\.name)).union(f.remotes[main] ?? [])
                for name in names where !DEFAULT_BRANCHES.contains(name) && name != base {
                    guard let k = WorkstreamIndex.key(inBranch: name, known: known), keys.contains(k) else { continue }
                    let id = "\(repo)|\(name)"
                    if let t = pullsAt[id], at.timeIntervalSince(t) < 600 { continue }
                    if let list = try? await host.host.changes(host.ref, head: name) { f.pulls[id] = list; fetched[id] = at }
                }
            }
            await MainActor.run { [f, fetched] in
                self.refreshing = false
                self.pullsAt.merge(fetched) { $1 }
                self.facts = f
                NotificationCenter.default.post(name: Self.changed, object: self)
                done?()
            }
        }
    }

    // MARK: Run

    /// Runs the lines of one item. The Plane item does not change. `done` gets the errors.
    func run(_ lines: [CleanupLine], key: String, data: AppData, auto: Bool = false, done: (([String]) -> Void)? = nil) {
        let k = key.uppercased()
        guard !running.contains(k) else { done?(["A cleanup of \(k) is running."]); return }
        running.insert(k)
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: [Self.keyInfo: k])
        let finishedAt = Self.finished(k, data: data)?.item.updatedAt
        let hooks = AGENTS.cleanup.runHooks
        let facts = self.facts
        Task { [commands, runtime, branchHost] in
            var errors: [String] = [], done_: [String] = []
            for l in lines {
                do {
                    switch l.action {
                    case .workspace(let w):
                        guard let rt = runtime() else { throw ProviderError.unsupported(.removeWorkspace) }
                        _ = try await rt.remove(w, force: !l.safe, runHooks: hooks)
                        done_.append(w.kind == .folder ? "Closed Orca card \(w.name)" : "Removed worktree \(w.name)")
                    case .group(let path, let worktrees):
                        try await Self.removeGroup(path, worktrees: worktrees, force: !l.safe, facts: facts, commands: commands)
                        done_.append("Removed worktree group .wt/\((path as NSString).lastPathComponent)/")
                    case .localBranch(let main, let name):
                        try await GitCheckout(path: main, commands: commands).deleteBranch(name)
                        done_.append("Deleted local branch \(name)")
                    case .remoteBranch(let repo, let name, let main):
                        guard let h = branchHost(repo) else { throw ProviderError.unsupported(.deleteBranch) }
                        try await h.host.deleteBranch(h.ref, name: name)
                        try? await GitCheckout(path: main, commands: commands).forgetRemoteBranch(name)
                        done_.append("Deleted remote branch \(name) of \(repo)")
                    case .none:
                        continue
                    }
                } catch {
                    errors.append("\(l.title): \((error as? ProviderError)?.message ?? error.localizedDescription)")
                }
            }
            await MainActor.run { [errors, done_] in
                self.running.remove(k)
                let at = self.now()
                let ago = finishedAt.map { " (\(k) finished \(relativeAgo($0)))" } ?? ""
                for text in done_ { self.records.insert(CleanupRecord(at: at, key: k, text: text + ago + (auto ? ", automatically" : "")), at: 0) }
                self.records = Array(self.records.prefix(50))
                if let d = try? JSONEncoder().encode(self.records) { self.defaults.set(d, forKey: Self.logKey) }
                if !errors.isEmpty { log.warning("Cleanup of \(k, privacy: .public): \(errors.joined(separator: "; "), privacy: .public)") }
                data.agentIndex.poll()
                // One change for the item, after the new scan and facts.
                let post = { NotificationCenter.default.post(name: Self.changed, object: self, userInfo: [Self.keyInfo: k]) }
                if let app = data as? GHActionsBar { app.scanCheckouts(force: true, done: post) } else { post() }
                done?(errors)
            }
        }
    }

    /// Removes each repo worktree of a .wt/<task>/ group, then the links, then the empty folder. Never a recursive delete.
    static func removeGroup(_ path: String, worktrees: [String], force: Bool, facts: CleanupFacts, commands: any CommandRunner) async throws {
        for wt in worktrees {
            let g = GitCheckout(path: wt, commands: commands)
            var main = facts.mains[wt]
            if main == nil { main = try? await g.mainCheckout() }
            guard let main else { continue }
            let branch = facts.states[wt]?.branch ?? ""
            let m = GitCheckout(path: main, commands: commands)
            try await m.removeWorktree(wt, force: force)
            // git refuses a branch that is not merged. Then the branch stays.
            if !branch.isEmpty, !DEFAULT_BRANCHES.contains(branch) { try? await m.deleteBranch(branch) }
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
            let p = path + "/" + name
            if (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeSymbolicLink { try fm.removeItem(atPath: p) }
        }
        let rest = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".DS_Store" }
        guard rest.isEmpty else { throw ProviderError.vendor(code: "not_empty", message: "the folder keeps \(rest.joined(separator: ", "))") }
        try? fm.removeItem(atPath: path + "/.DS_Store")
        try fm.removeItem(atPath: path)
    }

    // MARK: Auto-remove

    /// The safe lines that auto-remove may run for an item now, or [].
    func autoLines(_ key: String, data: AppData, config c: CleanupConfig) -> [CleanupLine] {
        guard c.auto, let f = Self.finished(key, data: data),
              now().timeIntervalSince(f.item.updatedAt) >= Double(c.waitMinutes) * 60 else { return [] }
        let card = data.agentIndex.launchedCard(key)
        if c.onlyOurs, card == nil { return [] }
        return lines(key, data: data).filter { l in
            guard l.safe, l.removable else { return false }
            if c.onlyOurs, case .workspace(let w) = l.action { return w.id == card }
            return true
        }
    }

    /// Runs auto-remove for each finished item. At most one try for each item in 10 minutes.
    func sweep(_ data: AppData) {
        let c = AGENTS.cleanup
        guard c.auto else { return }
        for (k, _) in pending(data) where !running.contains(k) {
            if let t = autoTried[k], now().timeIntervalSince(t) < 600 { continue }
            let l = autoLines(k, data: data, config: c)
            guard !l.isEmpty else { continue }
            autoTried[k] = now()
            run(l, key: k, data: data, auto: true)
        }
    }
}

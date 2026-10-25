import Foundation
import OverSireCore

// ─── Workstreams ─────────────────────────────────────────────────────────────
// A workstream joins one Plane item with its Orca cards, git checkouts, agent, runs and PRs.

// Which rules link a run to an item. All are on by default. The first match wins.
struct LinkRules: Codable, Equatable {
    var card = true       // Orca card name is the item key
    var folder = true     // a checkout in .wt/<key>/
    var head = true       // run head SHA = checkout HEAD
    var branch = true     // run branch = checkout branch
    var prefix = true     // branch <key>/… or <key>-…
    var pr = true         // the PR of the branch names the key
    var trailer = true    // the commit title names the key

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decodeIfPresent(Bool.self, forKey: .card) ?? true
        folder = try c.decodeIfPresent(Bool.self, forKey: .folder) ?? true
        head = try c.decodeIfPresent(Bool.self, forKey: .head) ?? true
        branch = try c.decodeIfPresent(Bool.self, forKey: .branch) ?? true
        prefix = try c.decodeIfPresent(Bool.self, forKey: .prefix) ?? true
        pr = try c.decodeIfPresent(Bool.self, forKey: .pr) ?? true
        trailer = try c.decodeIfPresent(Bool.self, forKey: .trailer) ?? true
    }
}

// A git checkout on disk, with the item key it belongs to.
struct Checkout: Equatable {
    let path: String
    let repo: String          // owner/name from the origin remote, or ""
    let branch: String
    let head: String
    let key: String?          // from the card name or the .wt/<key> folder
    let cardId: String?
}

// How a run found its item. The run page shows it.
enum LinkReason: String {
    case head = "HEAD of the worktree"
    case branch = "branch of the worktree"
    case prefix = "branch prefix"
    case pr = "pull request"
    case trailer = "commit title"
}

struct RunLink {
    let repo: String
    let run: Run
    let reason: LinkReason
}

struct Workstream {
    let key: String
    var item: Item?
    var projectKey: String?           // snapshot key slug/uuid
    var cards: [Workspace] = []
    var checkouts: [Checkout] = []
    var agent: AgentSession?
    var runs: [RunLink] = []          // newest first
    var prs: [(repo: String, pr: ChangeRequest)] = []

    // The latest run of each workflow, so an old failure that passed again does not count.
    var latestRuns: [RunLink] {
        var seen = Set<String>()
        return runs.filter { seen.insert("\($0.repo)|\($0.run.workflowName ?? $0.run.name)").inserted }
    }

    var ci: Tone? {
        let l = latestRuns.map(\.run)
        if l.isEmpty { return nil }
        if l.contains(where: { $0.status != "completed" }) { return .running }
        if l.contains(where: { $0.isFailure }) { return .bad }
        return .ok
    }

    var ciRunning: Bool { ci?.word == Tone.running.word }

    var branches: [String] {
        var seen = Set<String>()
        return checkouts.map(\.branch).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

final class WorkstreamIndex {
    static let changed = Notification.Name("WorkstreamIndexChanged")
    static let keyRE = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9]*)-([0-9]+)(?![0-9])")
    /// The key formats of the tracker accounts. The app sets them when the accounts change.
    static var formats: [KeyFormat] = [.projectDash]

    private(set) var streams: [String: Workstream] = [:]
    private(set) var checkouts: [Checkout] = []
    private(set) var unlinked: [(repo: String, run: Run)] = []
    private var runLinks: [String: (key: String, reason: LinkReason)] = [:]
    private var scanning = false
    private var lastScan = Date.distantPast
    private let q = DispatchQueue(label: "com.oversire.app.workstreams", qos: .utility)
    private static let git = "/usr/bin/git"
    private var remotes: [String: String] = [:]     // path → owner/name

    var rules: LinkRules { LINKING }

    func stream(_ key: String) -> Workstream? { streams[key.uppercased()] }
    func link(runId: String) -> (key: String, reason: LinkReason)? { runLinks[runId] }

    // Joins everything. Cheap: no I/O. Call it after each data change.
    func rebuild(store: ProjectStore, agents: AgentIndex, runs: [(String, [Run])], prs: [(String, [ChangeRequest])]) {
        let known = Set(store.tracked.map { $0.identifier.uppercased() })
        var out: [String: Workstream] = [:]
        func touch(_ key: String) -> String {
            let k = key.uppercased()
            if out[k] == nil { out[k] = Workstream(key: k) }
            return k
        }
        for (pk, snap) in store.snapshots {
            for item in snap.items {
                let k = item.key.uppercased()
                // Only items with something attached become workstreams. The item fills in below.
                if agents.agent(k) != nil || checkouts.contains(where: { $0.key == k }) {
                    let key = touch(k)
                    out[key]?.item = item
                    out[key]?.projectKey = pk
                }
            }
        }
        for c in agents.cards {
            if rules.card, let k = WorkstreamIndex.key(in: c.name, known: known, whole: true) { out[touch(k)]?.cards.append(c) }
        }
        for co in checkouts { if let k = co.key { out[touch(k)]?.checkouts.append(co) } }
        for (k, a) in agents.agents { out[touch(k)]?.agent = a }

        var links: [String: (String, LinkReason)] = [:]
        var loose: [(String, Run)] = []
        let prList = prs.flatMap { g in g.1.map { (repo: g.0, pr: $0) } }
        for (repo, list) in runs {
            for r in list {
                if let (k, why) = WorkstreamIndex.match(repo: repo, run: r, checkouts: checkouts, prs: prList, known: known, rules: rules) {
                    out[touch(k)]?.runs.append(RunLink(repo: repo, run: r, reason: why))
                    links[r.id] = (k, why)
                } else {
                    loose.append((repo, r))
                }
            }
        }
        for (repo, p) in prList {
            if let k = WorkstreamIndex.key(forPR: p, known: known, checkouts: checkouts, repo: repo) { out[touch(k)]?.prs.append((repo, p)) }
        }
        // Fill items for streams that only got runs or PRs.
        for (k, var s) in out where s.item == nil {
            for (pk, snap) in store.snapshots {
                if let i = snap.items.first(where: { $0.key.uppercased() == k }) { s.item = i; s.projectKey = pk; break }
            }
            s.runs.sort { lastActivity($0.run) > lastActivity($1.run) }
            out[k] = s
        }
        for (k, var s) in out { s.runs.sort { lastActivity($0.run) > lastActivity($1.run) }; out[k] = s }
        streams = out
        runLinks = links
        unlinked = loose
    }

    // MARK: Linking rules (pure, for the selftest)

    // The first item key in a text, if its project is tracked. `whole`: the text must be only the key.
    static func key(in text: String, known: Set<String>, whole: Bool = false, formats: [KeyFormat] = formats) -> String? {
        for f in formats {
            // Underscores are word characters, so "x_FOO-1" has no word edge before the key.
            guard let k = f.keys(in: text.replacingOccurrences(of: "_", with: " "), known: known).first else { continue }
            return whole && k.count != text.count ? nil : k
        }
        return nil
    }

    // <key>/… or <key>-… at the start of a branch.
    static func key(inBranch b: String, known: Set<String>, formats: [KeyFormat] = formats) -> String? {
        guard let k = key(in: b, known: known, formats: formats) else { return nil }
        let lower = b.lowercased(), kl = k.lowercased()
        guard lower.hasPrefix(kl) else { return nil }
        let rest = lower.dropFirst(kl.count)
        return rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("-") || rest.hasPrefix("_") ? k : nil
    }

    static func key(forPR p: ChangeRequest, known: Set<String>, checkouts: [Checkout], repo: String) -> String? {
        if let co = checkouts.first(where: { $0.branch == p.headRefName && ($0.repo.isEmpty || $0.repo == repo) }), let k = co.key { return k }
        return key(inBranch: p.headRefName, known: known) ?? key(in: p.title, known: known) ?? key(in: p.body ?? "", known: known)
    }

    static func match(repo: String, run r: Run, checkouts: [Checkout], prs: [(repo: String, pr: ChangeRequest)],
                      known: Set<String>, rules: LinkRules) -> (String, LinkReason)? {
        let mine = checkouts.filter { $0.key != nil && ($0.repo.isEmpty || $0.repo.caseInsensitiveCompare(repo) == .orderedSame) }
        if rules.head, let co = mine.first(where: { !$0.head.isEmpty && $0.head == r.headSha }), let k = co.key { return (k, .head) }
        if rules.branch, let co = mine.first(where: { !$0.branch.isEmpty && $0.branch == r.headBranch && !DEFAULT_BRANCHES.contains($0.branch) }),
           let k = co.key { return (k, .branch) }
        if rules.prefix, let k = key(inBranch: r.headBranch, known: known) { return (k, .prefix) }
        if rules.pr, let p = prs.first(where: { $0.repo == repo && $0.pr.headRefName == r.headBranch }),
           let k = key(in: p.pr.title, known: known) ?? key(in: p.pr.body ?? "", known: known) { return (k, .pr) }
        if rules.trailer, let k = key(in: r.displayTitle, known: known) { return (k, .trailer) }
        return nil
    }

    // "git@github.com:o/r.git" or "https://github.com/o/r" → "o/r".
    static func repoName(remote: String) -> String {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if let r = s.range(of: "github.com[:/]", options: .regularExpression) { return String(s[r.upperBound...]) }
        return ""
    }

    // MARK: Scan of the checkouts on disk

    // Reads branch and HEAD of each checkout: Orca card folders, their .wt/<key>/<repo>, and the Orca roots.
    func scan(cards: [Workspace], roots: [String], known: Set<String>, done: @escaping () -> Void) {
        guard !scanning else { done(); return }
        scanning = true
        let rules = self.rules
        let remotes = self.remotes
        q.async { [weak self] in
            var found: [Checkout] = []
            var newRemotes = remotes
            var seen = Set<String>()
            let fm = FileManager.default
            func read(_ dir: String, key: String?, card: String?) {
                guard seen.insert(dir).inserted, fm.fileExists(atPath: dir + "/.git") else { return }
                guard let out = WorkstreamIndex.runGit(["-C", dir, "rev-parse", "HEAD", "--abbrev-ref", "HEAD"]) else { return }
                let lines = out.split(separator: "\n").map(String.init)
                guard lines.count == 2 else { return }
                if newRemotes[dir] == nil {
                    newRemotes[dir] = WorkstreamIndex.runGit(["-C", dir, "config", "--get", "remote.origin.url"]).map(WorkstreamIndex.repoName) ?? ""
                }
                let branch = lines[1] == "HEAD" ? "" : lines[1]
                let k = key ?? WorkstreamIndex.key(inBranch: branch, known: known)
                found.append(Checkout(path: dir, repo: newRemotes[dir] ?? "", branch: branch, head: lines[0], key: k, cardId: card))
            }
            func group(_ base: String, key: String?, card: String?) {
                read(base, key: key, card: card)
                // A symlink points at the main checkout of the workspace. Only real folders are worktrees.
                for sub in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where !sub.hasPrefix(".") {
                    let p = base + "/" + sub
                    if (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
                    read(p, key: key, card: card)
                }
            }
            var bases: [(String, String?)] = cards.map { ($0.path, $0.id) }
            bases += roots.map { ($0, nil) }
            for (path, card) in bases {
                let name = cards.first { $0.id == card }?.name ?? ""
                let cardKey = rules.card ? WorkstreamIndex.key(in: name, known: known, whole: true) : nil
                read(path, key: cardKey, card: card)
                let wt = path + "/.wt"
                for f in (try? fm.contentsOfDirectory(atPath: wt)) ?? [] where !f.hasPrefix(".") {
                    let fk = rules.folder ? WorkstreamIndex.key(in: f, known: known, whole: true) : nil
                    group(wt + "/" + f, key: fk ?? (f.lowercased() == name.lowercased() ? cardKey : nil), card: card)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.lastScan = Date()
                self.remotes = newRemotes
                if found != self.checkouts { self.checkouts = found }
                done()
            }
        }
    }

    var scanAge: TimeInterval { -lastScan.timeIntervalSinceNow }

    private static func runGit(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_OPTIONAL_LOCKS": "0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

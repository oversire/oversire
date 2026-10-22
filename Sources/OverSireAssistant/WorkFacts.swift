import Foundation
import OverSireCore

// ─── Work facts ──────────────────────────────────────────────────────────────
// All that the app knows about one work item: the item, its code, its sessions and its place in the queue.
// The app fills it (WorkContext). The item page and the read tools show the same facts.

public struct WorkFacts: Codable, Hashable, Sendable {
    public struct ItemFacts: Codable, Hashable, Sendable {
        public var key: String
        public var title: String
        public var url: String
        public var project: String
        public var status: String?
        /// todo, progress, review, blocked or done.
        public var group: String
        public var priority: String?
        public var assignees: [String]
        public var labels: [String]
        public var parent: String?
        public var updatedAt: Date
        /// Markdown. The facts keep the start of a long body.
        public var body: String?

        public init(key: String, title: String, url: String, project: String, status: String?, group: String, priority: String?,
                    assignees: [String], labels: [String], parent: String?, updatedAt: Date, body: String?) {
            self.key = key
            self.title = title
            self.url = url
            self.project = project
            self.status = status
            self.group = group
            self.priority = priority
            self.assignees = assignees
            self.labels = labels
            self.parent = parent
            self.updatedAt = updatedAt
            self.body = body
        }
    }

    public struct SubItem: Codable, Hashable, Sendable {
        public var key: String
        public var title: String
        public var status: String?
        public var done: Bool

        public init(key: String, title: String, status: String?, done: Bool) {
            self.key = key
            self.title = title
            self.status = status
            self.done = done
        }
    }

    public struct Progress: Codable, Hashable, Sendable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    public struct Relation: Codable, Hashable, Sendable {
        /// blockedBy, blocks, relatesTo, duplicate, ...
        public var kind: String
        public var key: String
        public var title: String?
        public var done: Bool?

        public init(kind: String, key: String, title: String?, done: Bool?) {
            self.kind = kind
            self.key = key
            self.title = title
            self.done = done
        }
    }

    public struct PR: Codable, Hashable, Sendable {
        public var repo: String
        public var number: Int
        public var title: String
        public var state: String
        public var url: String
        public var head: String
        public var base: String
        public var draft: Bool
        public var review: String?
        public var author: String
        public var mine: Bool
        public var updatedAt: String

        public init(repo: String, number: Int, title: String, state: String, url: String, head: String, base: String, draft: Bool,
                    review: String?, author: String, mine: Bool, updatedAt: String) {
            self.repo = repo
            self.number = number
            self.title = title
            self.state = state
            self.url = url
            self.head = head
            self.base = base
            self.draft = draft
            self.review = review
            self.author = author
            self.mine = mine
            self.updatedAt = updatedAt
        }
    }

    public struct Job: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var conclusion: String?
        public var url: String?

        public init(id: String, name: String, conclusion: String?, url: String?) {
            self.id = id
            self.name = name
            self.conclusion = conclusion
            self.url = url
        }
    }

    public struct Run: Codable, Hashable, Sendable {
        public var repo: String
        public var id: String
        public var workflow: String
        public var branch: String
        public var sha: String
        public var status: String
        public var conclusion: String?
        public var url: String
        public var updatedAt: String
        /// The PR whose head the run tests.
        public var pr: Int?
        /// The run is on the base branch, not on the item branch.
        public var onBase: Bool
        /// The failed jobs of a failed run. Nil: not read.
        public var failedJobs: [Job]?

        public init(repo: String, id: String, workflow: String, branch: String, sha: String, status: String, conclusion: String?, url: String,
                    updatedAt: String, pr: Int?, onBase: Bool, failedJobs: [Job]? = nil) {
            self.repo = repo
            self.id = id
            self.workflow = workflow
            self.branch = branch
            self.sha = sha
            self.status = status
            self.conclusion = conclusion
            self.url = url
            self.updatedAt = updatedAt
            self.pr = pr
            self.onBase = onBase
            self.failedJobs = failedJobs
        }

        public var failed: Bool { status == "completed" && conclusion == "failure" }
    }

    public struct Session: Codable, Hashable, Sendable {
        public var machine: String
        /// The session runs on this Mac.
        public var local: Bool
        public var agent: String
        /// For example working, needsInput, done.
        public var state: String
        public var since: Date
        public var repo: String?
        public var branch: String?
        public var workspace: String?
        /// The last agent reply or the error, short.
        public var message: String?

        public init(machine: String, local: Bool, agent: String, state: String, since: Date, repo: String?, branch: String?,
                    workspace: String?, message: String?) {
            self.machine = machine
            self.local = local
            self.agent = agent
            self.state = state
            self.since = since
            self.repo = repo
            self.branch = branch
            self.workspace = workspace
            self.message = message
        }
    }

    public struct Question: Codable, Hashable, Sendable {
        public var id: String
        public var text: String
        public var items: Int
        public var via: String
        public var askedAt: Date

        public init(id: String, text: String, items: Int, via: String, askedAt: Date) {
            self.id = id
            self.text = text
            self.items = items
            self.via = via
            self.askedAt = askedAt
        }
    }

    public struct Queue: Codable, Hashable, Sendable {
        public var project: String
        /// 1 is the first entry of the lane.
        public var position: Int
        public var length: Int
        public var condition: String
        /// Why the entry does not start now. Nil: it starts next.
        public var waits: String?

        public init(project: String, position: Int, length: Int, condition: String, waits: String?) {
            self.project = project
            self.position = position
            self.length = length
            self.condition = condition
            self.waits = waits
        }
    }

    public struct Order: Codable, Hashable, Sendable {
        public var id: String
        public var state: String
        public var runner: String
        public var createdAt: Date
        public var hold: String?

        public init(id: String, state: String, runner: String, createdAt: Date, hold: String?) {
            self.id = id
            self.state = state
            self.runner = runner
            self.createdAt = createdAt
            self.hold = hold
        }
    }

    public struct Activity: Codable, Hashable, Sendable {
        public var at: Date
        public var text: String
        public var actor: String?

        public init(at: Date, text: String, actor: String?) {
            self.at = at
            self.text = text
            self.actor = actor
        }
    }

    public var key: String
    /// Nil: the app has no loaded item with this key.
    public var item: ItemFacts?
    public var subItems: [SubItem] = []
    public var progress: Progress?
    /// Nil: the tracker has no relations, or they did not load yet.
    public var relations: [Relation]?
    /// The keys of the open blockers.
    public var blockers: [String] = []
    public var areas: [String] = []
    public var branch: String?
    /// checkout, pr or template.
    public var branchFrom: String?
    public var prs: [PR] = []
    public var runs: [Run] = []
    /// ok, running or failed: the latest run of each workflow on the item branches.
    public var ci: String?
    public var sessions: [Session] = []
    /// The open questions.
    public var questions: [Question] = []
    public var queue: Queue?
    public var orders: [Order] = []
    /// The newest first.
    public var activity: [Activity] = []
    /// The facts that the app could not get, and why.
    public var notes: [String] = []

    public init(key: String) { self.key = key }

    /// One line for a chip.
    public var summary: String {
        guard let item else { return "No loaded item \(key)." }
        var parts = ["\(item.key) \(item.status ?? item.group)"]
        if !prs.isEmpty { parts.append("\(prs.count) PR\(prs.count == 1 ? "" : "s")") }
        if let ci { parts.append("CI \(ci)") }
        if !sessions.isEmpty { parts.append("\(sessions.count) session\(sessions.count == 1 ? "" : "s")") }
        if !questions.isEmpty { parts.append("\(questions.count) question\(questions.count == 1 ? "" : "s")") }
        if let q = queue { parts.append("queue \(q.position) of \(q.length)") }
        if !blockers.isEmpty { parts.append("blocked by \(blockers.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

// ─── Byte limit ──────────────────────────────────────────────────────────────

extension JSONValue {
    /// The default byte limit of the data of a read action.
    public static let readLimit = 24_000

    /// The value as JSON of at most `maxBytes` bytes. A cut drops the tail of the largest lists and the end of long texts,
    /// and adds a `cut` field, for example "items: showing 40 of 212". A top-level list becomes `{"items": [...], "cut": ...}`.
    public func clipped(to maxBytes: Int = JSONValue.readLimit) -> JSONValue {
        guard text.utf8.count > maxBytes else { return self }
        var o: [String: JSONValue]
        switch self {
        case .object(let x): o = x
        case .array: o = ["items": self]
        case .string(let s): return .string(Self.prefix(s, bytes: maxBytes - 8))
        default: return self
        }
        var notes: [String: String] = [:]
        var counts: [String: Int] = [:]
        func note() -> JSONValue? { notes.isEmpty ? nil : .string(notes.keys.sorted().map { notes[$0]! }.joined(separator: "; ")) }
        for _ in 0..<12 {
            o["cut"] = note()
            let size = JSONValue.object(o).text.utf8.count + 48
            guard size > maxBytes else { return .object(o) }
            let fields = o.filter { $0.key != "cut" }.map { (key: $0.key, value: $0.value, size: $0.value.text.utf8.count) }
            guard let big = fields.filter({ $0.value.canShrink }).max(by: { $0.size < $1.size }) else { break }
            let budget = max(0, big.size - (size - maxBytes))
            switch big.value {
            case .array(let a):
                let total = counts[big.key] ?? a.count
                counts[big.key] = total
                var lo = 0, hi = a.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if JSONValue.array(Array(a.prefix(mid))).text.utf8.count <= budget { lo = mid } else { hi = mid - 1 }
                }
                o[big.key] = .array(Array(a.prefix(lo)))
                notes[big.key] = "\(big.key): showing \(lo) of \(total)"
            case .string(let s):
                o[big.key] = .string(Self.prefix(s, bytes: max(0, budget - 8)) + "…")
                notes[big.key] = "\(big.key): text cut"
            case .object:
                o[big.key] = big.value.clipped(to: max(2, budget))
                notes[big.key] = "\(big.key): cut"
            default: break
            }
        }
        o["cut"] = note()
        if JSONValue.object(o).text.utf8.count <= maxBytes { return .object(o) }
        return .object(["cut": .string("The data is larger than \(maxBytes) bytes."), "keys": .array(o.keys.sorted().map(JSONValue.string))])
    }

    private var canShrink: Bool {
        switch self {
        case .array(let a): return !a.isEmpty
        case .string(let s): return s.utf8.count > 64
        case .object(let o): return !o.isEmpty
        default: return false
        }
    }

    /// The start of `s` in at most `bytes` UTF-8 bytes of JSON text. Whole characters only.
    private static func prefix(_ s: String, bytes: Int) -> String {
        var lo = 0, hi = s.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if JSONValue.string(String(s.prefix(mid))).text.utf8.count <= bytes { lo = mid } else { hi = mid - 1 }
        }
        return String(s.prefix(lo))
    }
}

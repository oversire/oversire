import Foundation

// The review gate (review.json, OVERSIRE-365). The daemon of the session machine finds each review,
// keeps the pending comments and the rounds, sends a submitted batch to the session, and merges locally.

public enum ReviewKind: String, Codable, Hashable, Sendable, CaseIterable { case code, plan }

public enum ReviewState: String, Codable, Hashable, Sendable { case ready, waiting, conflict, merged }

public enum MergeMode: String, Codable, Hashable, Sendable { case fastForward, rebase, conflict }

public struct ReviewSession: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable { case idle, working, ended, none }

    public var id: String?
    public var state: State
    public var harness: String?
    public var profile: String?
    public var canSend: Bool

    public init(id: String? = nil, state: State, harness: String? = nil, profile: String? = nil, canSend: Bool) {
        self.id = id
        self.state = state
        self.harness = harness
        self.profile = profile
        self.canSend = canSend
    }
}

public struct ReviewCommit: Codable, Hashable, Sendable {
    public var sha: String
    public var subject: String
    public var items: [String]?

    public init(sha: String, subject: String, items: [String]? = nil) {
        self.sha = sha
        self.subject = subject
        self.items = items
    }
}

public struct ReviewRepo: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var branch: String
    public var base: String
    public var ahead: Int
    public var behind: Int
    public var added: Int
    public var removed: Int
    public var files: Int
    public var dirty: Bool
    public var merge: MergeMode
    public var conflictFiles: [String]?
    public var commits: [ReviewCommit]?

    public var id: String { name }

    public init(name: String, branch: String, base: String, ahead: Int, behind: Int = 0, added: Int = 0, removed: Int = 0, files: Int = 0,
                dirty: Bool = false, merge: MergeMode = .fastForward, conflictFiles: [String]? = nil, commits: [ReviewCommit]? = nil) {
        self.name = name
        self.branch = branch
        self.base = base
        self.ahead = ahead
        self.behind = behind
        self.added = added
        self.removed = removed
        self.files = files
        self.dirty = dirty
        self.merge = merge
        self.conflictFiles = conflictFiles
        self.commits = commits
    }
}

/// One row of Work › Review.
public struct ReviewSummary: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var kind: ReviewKind
    public var title: String?
    public var machine: String
    public var state: ReviewState
    public var round: Int
    public var pending: Int
    public var unanswered: Int
    public var root: String
    public var group: String?
    public var repos: [ReviewRepo]
    public var subitems: [String]
    public var session: ReviewSession?
    public var note: String?
    public var readyAt: Date?
    public var updatedAt: Date

    /// Unique across machines and kinds.
    public var id: String { "\(machine)/\(kind.rawValue)/\(key)" }

    public init(key: String, kind: ReviewKind, title: String? = nil, machine: String, state: ReviewState, round: Int = 0, pending: Int = 0,
                unanswered: Int = 0, root: String, group: String? = nil, repos: [ReviewRepo] = [], subitems: [String] = [],
                session: ReviewSession? = nil, note: String? = nil, readyAt: Date? = nil, updatedAt: Date) {
        self.key = key
        self.kind = kind
        self.title = title
        self.machine = machine
        self.state = state
        self.round = round
        self.pending = pending
        self.unanswered = unanswered
        self.root = root
        self.group = group
        self.repos = repos
        self.subitems = subitems
        self.session = session
        self.note = note
        self.readyAt = readyAt
        self.updatedAt = updatedAt
    }

    public var added: Int { repos.reduce(0) { $0 + $1.added } }
    public var removed: Int { repos.reduce(0) { $0 + $1.removed } }
    public var fileCount: Int { repos.reduce(0) { $0 + $1.files } }
    public var commitCount: Int { repos.reduce(0) { $0 + $1.ahead } }
    /// The worst merge mode of the repos.
    public var merge: MergeMode {
        if repos.contains(where: { $0.merge == .conflict }) { return .conflict }
        return repos.contains { $0.merge == .rebase } ? .rebase : .fastForward
    }
}

/// A base branch with local commits that its upstream does not have.
public struct NotPushed: Codable, Hashable, Sendable {
    public var root: String
    public var repo: String
    public var base: String
    public var ahead: Int
    /// The item keys that the commits name. Nil from an older daemon.
    public var items: [String]?

    public init(root: String, repo: String, base: String, ahead: Int, items: [String]? = nil) {
        self.root = root
        self.repo = repo
        self.base = base
        self.ahead = ahead
        self.items = items
    }
}

/// The answer of GET /v1/reviews.
public struct ReviewsPage: Codable, Hashable, Sendable {
    public var reviews: [ReviewSummary]
    public var notPushed: [NotPushed]

    public init(reviews: [ReviewSummary] = [], notPushed: [NotPushed] = []) {
        self.reviews = reviews
        self.notPushed = notPushed
    }
}

public enum FileStatus: String, Codable, Hashable, Sendable { case added = "A", modified = "M", deleted = "D", renamed = "R" }

public struct ReviewFile: Codable, Hashable, Sendable, Identifiable {
    public var repo: String
    public var path: String
    public var oldPath: String?
    public var status: FileStatus
    public var added: Int
    public var removed: Int
    public var binary: Bool
    public var untracked: Bool?
    public var viewed: Bool

    public var id: String { repo + "/" + path }

    public init(repo: String, path: String, oldPath: String? = nil, status: FileStatus, added: Int, removed: Int, binary: Bool = false,
                untracked: Bool? = nil, viewed: Bool = false) {
        self.repo = repo
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.binary = binary
        self.untracked = untracked
        self.viewed = viewed
    }
}

public struct DiffLine: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case ctx, add, del }

    public var kind: Kind
    public var old: Int?
    public var new: Int?
    public var text: String

    public init(kind: Kind, old: Int? = nil, new: Int? = nil, text: String) {
        self.kind = kind
        self.old = old
        self.new = new
        self.text = text
    }
}

public struct DiffHunk: Codable, Hashable, Sendable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var header: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, header: String = "", lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.header = header
        self.lines = lines
    }
}

/// The answer of GET /v1/reviews/{key}/diff.
public struct FileDiff: Codable, Hashable, Sendable {
    public var repo: String
    public var path: String
    public var oldPath: String?
    public var status: FileStatus
    public var binary: Bool
    public var truncated: Bool
    public var hunks: [DiffHunk]

    public init(repo: String, path: String, oldPath: String? = nil, status: FileStatus, binary: Bool = false, truncated: Bool = false, hunks: [DiffHunk]) {
        self.repo = repo
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.binary = binary
        self.truncated = truncated
        self.hunks = hunks
    }

    /// The diff as a unified patch, as `git diff` writes it.
    public var patch: String {
        let from = status == .added ? "/dev/null" : "a/" + (oldPath ?? path)
        let to = status == .deleted ? "/dev/null" : "b/" + path
        var out = "--- \(from)\n+++ \(to)\n"
        for h in hunks {
            out += "@@ -\(h.oldStart),\(h.oldLines) +\(h.newStart),\(h.newLines) @@" + (h.header.isEmpty ? "" : " " + h.header) + "\n"
            for l in h.lines { out += (l.kind == .add ? "+" : l.kind == .del ? "-" : " ") + l.text + "\n" }
        }
        return out
    }
}

/// A line or the lines from...line of a file, or one block of a plan.
public enum ReviewAnchor: Codable, Hashable, Sendable {
    public enum Side: String, Codable, Hashable, Sendable { case old, new }

    case code(repo: String, path: String, line: Int, from: Int? = nil, side: Side? = nil)
    case plan(block: String)

    private enum CodingKeys: String, CodingKey { case repo, path, line, from, side, block }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let block = try c.decodeIfPresent(String.self, forKey: .block) {
            self = .plan(block: block)
            return
        }
        self = .code(repo: try c.decode(String.self, forKey: .repo), path: try c.decode(String.self, forKey: .path),
                     line: try c.decode(Int.self, forKey: .line), from: try c.decodeIfPresent(Int.self, forKey: .from),
                     side: try c.decodeIfPresent(Side.self, forKey: .side))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plan(let block):
            try c.encode(block, forKey: .block)
        case .code(let repo, let path, let line, let from, let side):
            try c.encode(repo, forKey: .repo)
            try c.encode(path, forKey: .path)
            try c.encode(line, forKey: .line)
            try c.encodeIfPresent(from, forKey: .from)
            try c.encodeIfPresent(side, forKey: .side)
        }
    }

    /// cli/review/merge.go:40-42, or the block id.
    public var label: String {
        switch self {
        case .plan(let block): return block
        case .code(let repo, let path, let line, let from, _):
            let lines = from.map { $0 == line ? "\(line)" : "\($0)-\(line)" } ?? "\(line)"
            return "\(repo)/\(path):\(lines)"
        }
    }
}

public struct ReviewComment: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable { case pending, submitted, answered }

    public var id: String
    public var key: String
    public var round: Int
    public var state: State
    public var anchor: ReviewAnchor
    public var excerpt: String?
    public var text: String
    public var reply: String?
    public var createdAt: Date
    public var updatedAt: Date?
    public var answeredAt: Date?

    public init(id: String, key: String, round: Int, state: State, anchor: ReviewAnchor, excerpt: String? = nil, text: String,
                reply: String? = nil, createdAt: Date, updatedAt: Date? = nil, answeredAt: Date? = nil) {
        self.id = id
        self.key = key
        self.round = round
        self.state = state
        self.anchor = anchor
        self.excerpt = excerpt
        self.text = text
        self.reply = reply
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.answeredAt = answeredAt
    }
}

public enum ReviewVerdict: String, Codable, Hashable, Sendable { case requestChanges, approve }

public struct ReviewRound: Codable, Hashable, Sendable, Identifiable {
    public enum Delivery: String, Codable, Hashable, Sendable { case sent, queued, newSession, none }

    public var n: Int
    public var verdict: ReviewVerdict
    public var summary: String?
    public var count: Int
    public var submittedAt: Date
    public var delivery: Delivery
    public var session: String?
    public var deliveredAt: Date?
    public var error: String?
    public var answeredAt: Date?

    public var id: Int { n }

    public init(n: Int, verdict: ReviewVerdict, summary: String? = nil, count: Int, submittedAt: Date, delivery: Delivery, session: String? = nil,
                deliveredAt: Date? = nil, error: String? = nil, answeredAt: Date? = nil) {
        self.n = n
        self.verdict = verdict
        self.summary = summary
        self.count = count
        self.submittedAt = submittedAt
        self.delivery = delivery
        self.session = session
        self.deliveredAt = deliveredAt
        self.error = error
        self.answeredAt = answeredAt
    }
}

public struct PlanBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var heading: String
    public var markdown: String

    public init(id: String, heading: String, markdown: String) {
        self.id = id
        self.heading = heading
        self.markdown = markdown
    }
}

public struct PlanSubitem: Codable, Hashable, Sendable {
    public var key: String?
    public var title: String

    public init(key: String? = nil, title: String) {
        self.key = key
        self.title = title
    }
}

/// The plan of a Plan session, split at each ## heading.
public struct PlanDoc: Codable, Hashable, Sendable {
    public var key: String
    public var version: Int
    public var title: String?
    public var root: String?
    public var blocks: [PlanBlock]
    public var subitems: [PlanSubitem]?

    public init(key: String, version: Int, title: String? = nil, root: String? = nil, blocks: [PlanBlock], subitems: [PlanSubitem]? = nil) {
        self.key = key
        self.version = version
        self.title = title
        self.root = root
        self.blocks = blocks
        self.subitems = subitems
    }
}

/// The answer of GET /v1/reviews/{key}.
public struct ReviewDetail: Codable, Hashable, Sendable {
    public var summary: ReviewSummary
    public var files: [ReviewFile]
    public var comments: [ReviewComment]
    public var rounds: [ReviewRound]
    public var plan: PlanDoc?

    public init(summary: ReviewSummary, files: [ReviewFile] = [], comments: [ReviewComment] = [], rounds: [ReviewRound] = [], plan: PlanDoc? = nil) {
        self.summary = summary
        self.files = files
        self.comments = comments
        self.rounds = rounds
        self.plan = plan
    }

    public var pending: [ReviewComment] { comments.filter { $0.state == .pending } }
}

public struct CommentDraft: Codable, Hashable, Sendable {
    public var kind: ReviewKind?
    public var anchor: ReviewAnchor
    public var text: String

    public init(kind: ReviewKind? = nil, anchor: ReviewAnchor, text: String) {
        self.kind = kind
        self.anchor = anchor
        self.text = text
    }
}

public struct CommentEdit: Codable, Hashable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct CommentReply: Codable, Hashable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ViewedMark: Codable, Hashable, Sendable {
    public var repo: String
    public var path: String
    public var viewed: Bool

    public init(repo: String, path: String, viewed: Bool) {
        self.repo = repo
        self.path = path
        self.viewed = viewed
    }
}

public struct SubmitReview: Codable, Hashable, Sendable {
    public var kind: ReviewKind?
    public var verdict: ReviewVerdict
    public var summary: String?
    public var postToTracker: Bool
    public var launch: AgentLaunchSpec?

    public init(kind: ReviewKind? = nil, verdict: ReviewVerdict, summary: String? = nil, postToTracker: Bool, launch: AgentLaunchSpec? = nil) {
        self.kind = kind
        self.verdict = verdict
        self.summary = summary
        self.postToTracker = postToTracker
        self.launch = launch
    }
}

public struct ReviewReady: Codable, Hashable, Sendable {
    public var kind: ReviewKind?
    public var root: String?
    public var note: String?

    public init(kind: ReviewKind? = nil, root: String? = nil, note: String? = nil) {
        self.kind = kind
        self.root = root
        self.note = note
    }
}

public struct MergeRequest: Codable, Hashable, Sendable {
    public var removeGroup: Bool
    public init(removeGroup: Bool) { self.removeGroup = removeGroup }
}

public struct RepoMerge: Codable, Hashable, Sendable {
    public enum Result: String, Codable, Hashable, Sendable { case merged, rebased, conflict, skipped }

    public var name: String
    public var result: Result
    public var head: String?
    public var conflictFiles: [String]?

    public init(name: String, result: Result, head: String? = nil, conflictFiles: [String]? = nil) {
        self.name = name
        self.result = result
        self.head = head
        self.conflictFiles = conflictFiles
    }
}

public struct MergeResult: Codable, Hashable, Sendable {
    public var merged: Bool
    public var repos: [RepoMerge]
    public var removed: Bool
    public var error: String?
    public var notPushed: [NotPushed]

    public init(merged: Bool, repos: [RepoMerge], removed: Bool = false, error: String? = nil, notPushed: [NotPushed] = []) {
        self.merged = merged
        self.repos = repos
        self.removed = removed
        self.error = error
        self.notPushed = notPushed
    }
}

/// The WebSocket frame {type: review}. A hint: the app gets the data with GET.
public struct ReviewEvent: Codable, Hashable, Sendable {
    public enum Name: String, Codable, Hashable, Sendable {
        case ready = "review.ready", changed = "review.changed", merged = "review.merged", conflict = "review.conflict"
    }

    public var type: String
    public var event: Name
    public var key: String
    public var kind: ReviewKind
    public var machine: String?

    public init(event: Name, key: String, kind: ReviewKind, machine: String? = nil) {
        self.type = "review"
        self.event = event
        self.key = key
        self.kind = kind
        self.machine = machine
    }
}

import Foundation

/// Who did it (event.json ActorType).
public enum ActorType: String, Codable, Sendable, CaseIterable {
    case human, agent, system, provider
}

/// One row of the events table before the home daemon gets it (event.json EventDraft).
public struct EventDraft: Hashable, Sendable, Codable {
    public static let maxSummary = 200
    public static let maxPayload = 4096

    public var id: String
    public var at: Date
    public var kind: Event.Kind
    public var item: String?
    public var parentItem: String?
    public var project: String?
    public var repo: String?
    public var machine: String?
    public var provider: String?
    public var session: String?
    public var corr: String?
    public var actorType: ActorType
    public var actor: String
    public var onBehalf: String?
    public var via: String
    public var summary: String
    public var payload: [String: JSONValue]?
    /// The summary holds prompt text. It does not leave the user's Macs.
    public var isPrivate: Bool

    public init(id: String, at: Date, kind: Event.Kind, item: String? = nil, parentItem: String? = nil, project: String? = nil,
                repo: String? = nil, machine: String? = nil, provider: String? = nil, session: String? = nil, corr: String? = nil,
                actorType: ActorType, actor: String, onBehalf: String? = nil, via: String, summary: String,
                payload: [String: JSONValue]? = nil, isPrivate: Bool = false) {
        self.id = id
        self.at = at
        self.kind = kind
        self.item = item
        self.parentItem = parentItem
        self.project = project
        self.repo = repo
        self.machine = machine
        self.provider = provider
        self.session = session
        self.corr = corr
        self.actorType = actorType
        self.actor = actor
        self.onBehalf = onBehalf
        self.via = via
        self.summary = Self.clip(summary)
        self.payload = payload
        self.isPrivate = isPrivate
    }

    /// At most maxSummary code points, on one line.
    public static func clip(_ s: String) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let scalars = one.unicodeScalars
        guard scalars.count > maxSummary else { return one }
        var out = String.UnicodeScalarView(scalars.prefix(maxSummary - 1))
        out.append("…")
        return String(out)
    }

    enum CodingKeys: String, CodingKey {
        case id, at, kind, item, parentItem, project, repo, machine, provider, session, corr, actorType, actor, onBehalf, via, summary, payload
        case isPrivate = "private"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decode(Event.Kind.self, forKey: .kind)
        item = try c.decodeIfPresent(String.self, forKey: .item)
        parentItem = try c.decodeIfPresent(String.self, forKey: .parentItem)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        machine = try c.decodeIfPresent(String.self, forKey: .machine)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        corr = try c.decodeIfPresent(String.self, forKey: .corr)
        actorType = try c.decode(ActorType.self, forKey: .actorType)
        actor = try c.decode(String.self, forKey: .actor)
        onBehalf = try c.decodeIfPresent(String.self, forKey: .onBehalf)
        via = try c.decode(String.self, forKey: .via)
        summary = try c.decode(String.self, forKey: .summary)
        payload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(at, forKey: .at)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(item, forKey: .item)
        try c.encodeIfPresent(parentItem, forKey: .parentItem)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(machine, forKey: .machine)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(session, forKey: .session)
        try c.encodeIfPresent(corr, forKey: .corr)
        try c.encode(actorType, forKey: .actorType)
        try c.encode(actor, forKey: .actor)
        try c.encodeIfPresent(onBehalf, forKey: .onBehalf)
        try c.encode(via, forKey: .via)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(payload, forKey: .payload)
        if isPrivate { try c.encode(true, forKey: .isPrivate) }
    }
}

/// One row of the events table (event.json Event): a draft plus the place of the row on the daemon that answers.
@dynamicMemberLookup
public struct Event: Hashable, Sendable, Codable, Identifiable {
    public var seq: Int64
    public var seenAt: Date
    public var draft: EventDraft

    public init(seq: Int64, seenAt: Date, draft: EventDraft) {
        self.seq = seq
        self.seenAt = seenAt
        self.draft = draft
    }

    public var id: String { draft.id }
    public subscript<T>(dynamicMember path: KeyPath<EventDraft, T>) -> T { draft[keyPath: path] }

    enum CodingKeys: String, CodingKey { case seq, seenAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        seenAt = try c.decode(Date.self, forKey: .seenAt)
        draft = try EventDraft(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try draft.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(seenAt, forKey: .seenAt)
    }
}

extension Event {
    /// domain.verb. An open set: the catalog is Contract/schema/event-kinds.json.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        public var description: String { rawValue }
        /// The part before the first dot: session, turn, git, ci, ...
        public var domain: String { rawValue.split(separator: ".").first.map(String.init) ?? rawValue }

        public static let sessionStarted: Kind = "session.started"
        public static let sessionEnded: Kind = "session.ended"
        public static let turnStarted: Kind = "turn.started"
        public static let turnEnded: Kind = "turn.ended"
        public static let turnInterrupted: Kind = "turn.interrupted"
        public static let waitStarted: Kind = "wait.started"
        public static let waitEnded: Kind = "wait.ended"
        public static let contextCompacted: Kind = "context.compacted"
        public static let subagentEnded: Kind = "subagent.ended"
        public static let reviewReady: Kind = "review.ready"
        public static let promptSubmitted: Kind = "prompt.submitted"
        public static let questionAnswered: Kind = "question.answered"
        public static let reviewSubmitted: Kind = "review.submitted"
        public static let reviewApproved: Kind = "review.approved"
        public static let itemShipped: Kind = "item.shipped"
        public static let planStarted: Kind = "plan.started"
        public static let itemStateChanged: Kind = "item.state_changed"
        public static let itemViewed: Kind = "item.viewed"
        public static let itemFavorited: Kind = "item.favorited"
        public static let itemUnfavorited: Kind = "item.unfavorited"
        public static let worktreeAdded: Kind = "worktree.added"
        public static let worktreeRemoved: Kind = "worktree.removed"
        public static let gitCommit: Kind = "git.commit"
        public static let gitRebase: Kind = "git.rebase"
        public static let gitReset: Kind = "git.reset"
        public static let gitMerge: Kind = "git.merge"
        public static let gitPush: Kind = "git.push"
        public static let ciQueued: Kind = "ci.queued"
        public static let ciStarted: Kind = "ci.started"
        public static let ciCompleted: Kind = "ci.completed"
        public static let ciRerun: Kind = "ci.rerun"
        public static let prOpened: Kind = "pr.opened"
        public static let prUpdated: Kind = "pr.updated"
        public static let prMerged: Kind = "pr.merged"
        public static let prClosed: Kind = "pr.closed"
        public static let releasePublished: Kind = "release.published"
        public static let itemCreated: Kind = "item.created"
        public static let itemUpdated: Kind = "item.updated"
        public static let commentCreated: Kind = "comment.created"
        public static let intakeCreated: Kind = "intake.created"
        public static let intakeAccepted: Kind = "intake.accepted"
        public static let queuePicked: Kind = "queue.picked"
        public static let queueHeld: Kind = "queue.held"
        public static let runbookStepStarted: Kind = "runbook.step_started"
        public static let runbookStepEnded: Kind = "runbook.step_ended"
        public static let jobRan: Kind = "job.ran"
        public static let automationRan: Kind = "automation.ran"
        public static let agentChanged: Kind = "agent.changed"
        public static let secretSet: Kind = "secret.set"
        public static let secretResolved: Kind = "secret.resolved"
    }

    /// The answer of GET /v1/items/{key}/events (event.json EventPage).
    public struct Page: Hashable, Sendable, Codable {
        public var events: [Event]
        public var next: Int64
        public var head: Int64
        public var more: Bool

        public init(events: [Event], next: Int64, head: Int64, more: Bool) {
            self.events = events
            self.next = next
            self.head = head
            self.more = more
        }
    }

    /// The URL query of GET /v1/items/{key}/events (event.json EventQuery).
    public struct Query: Hashable, Sendable {
        public var item: String
        public var tree: Bool
        public var after: Int64
        public var kinds: [String]
        public var limit: Int?

        public init(item: String, tree: Bool = true, after: Int64 = 0, kinds: [String] = [], limit: Int? = nil) {
            self.item = item
            self.tree = tree
            self.after = after
            self.kinds = kinds
            self.limit = limit
        }

        public var queryItems: [URLQueryItem] {
            var q = [URLQueryItem(name: "tree", value: tree ? "1" : "0")]
            if after > 0 { q.append(URLQueryItem(name: "after", value: String(after))) }
            if !kinds.isEmpty { q.append(URLQueryItem(name: "kinds", value: kinds.joined(separator: ","))) }
            if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
            return q
        }
    }

    /// The body of POST /v1/events.
    public struct Append: Hashable, Sendable, Codable {
        public var events: [EventDraft]
        public init(events: [EventDraft]) { self.events = events }
    }

    public struct AppendResult: Hashable, Sendable, Codable {
        public var accepted: Int
        public var head: Int64
        public init(accepted: Int, head: Int64) {
            self.accepted = accepted
            self.head = head
        }
    }
}

extension Event {
    /// The WebSocket frame {type: event} of the daemon: one new row.
    public struct Frame: Hashable, Sendable, Codable {
        public var type: String
        public var event: Event
        public init(event: Event) {
            type = "event"
            self.event = event
        }
    }
}

/// The parent of an item, from the tracker (event.json ItemLink).
public struct ItemLink: Hashable, Sendable, Codable {
    public var item: String
    public var parent: String?
    public init(item: String, parent: String?) {
        self.item = item
        self.parent = parent
    }
}

/// The body of POST /v1/events/links.
public struct ItemLinks: Hashable, Sendable, Codable {
    public var links: [ItemLink]
    public init(links: [ItemLink]) { self.links = links }
}

/// Takes event rows. The app sends them to the home daemon.
public protocol EventSink: Sendable {
    func append(_ drafts: [EventDraft]) async throws
}

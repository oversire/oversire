import Foundation

// ─── Cloud autopilot ─────────────────────────────────────────────────────────
// The cloud hub runs AI jobs. A job only writes suggestions. The user accepts a suggestion,
// then the hub runs its proposal: a vendor write, a work order to a runner, or a memory entry.
// The app reads these records from the store. The JSON form is in Contract/schema/
// (jobs.json, suggestion.json, work-order.json, memory.json).

/// The x-oversire-schema numbers of Contract/schema/jobs.json and suggestion.json. 2: sequence became plan.
public let jobsSchemaVersion = 2
public let suggestionSchemaVersion = 2

/// Open set. Each kind has a prompt in Contract/prompts.
public struct AIJobKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let triage: AIJobKind = "triage"
    public static let failureReason: AIJobKind = "failureReason"
    public static let digest: AIJobKind = "digest"
    public static let changeSummary: AIJobKind = "changeSummary"
    public static let tidy: AIJobKind = "tidy"
    public static let memoryUpkeep: AIJobKind = "memoryUpkeep"
    /// The Planner (paid). Schema 1 named it sequence.
    public static let plan: AIJobKind = "plan"
}

// MARK: Jobs

/// The ProviderEvent values that start a job. A nil list matches all.
public struct EventFilter: Hashable, Sendable, Codable {
    public var kinds: [EventKind]?
    public var actions: [String]?
    public var providers: [ProviderID]?

    public init(kinds: [EventKind]? = nil, actions: [String]? = nil, providers: [ProviderID]? = nil) {
        self.kinds = kinds
        self.actions = actions
        self.providers = providers
    }
}

/// JSON: {"type": "schedule", "cron": "0 7 * * *"}, {"type": "event", "filter": {...}}, {"type": "manual"}.
public enum AIJobTrigger: Hashable, Sendable {
    case schedule(cron: String)
    case event(EventFilter)
    case manual
}

extension AIJobTrigger: Codable {
    private enum CodingKeys: String, CodingKey { case type, cron, filter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "schedule": self = .schedule(cron: try c.decode(String.self, forKey: .cron))
        case "event": self = .event(try c.decode(EventFilter.self, forKey: .filter))
        case "manual": self = .manual
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown job trigger \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .schedule(let cron):
            try c.encode("schedule", forKey: .type)
            try c.encode(cron, forKey: .cron)
        case .event(let f):
            try c.encode("event", forKey: .type)
            try c.encode(f, forKey: .filter)
        case .manual:
            try c.encode("manual", forKey: .type)
        }
    }
}

/// What a job can do with its result. Only `suggest` exists: the AI does no action on its own.
public enum Autonomy: String, Codable, Sendable, CaseIterable { case suggest }

public struct AIJob: StoreRecord {
    public static let collection = "jobs"

    public let id: String
    public var kind: AIJobKind
    public var trigger: AIJobTrigger
    /// Empty: all subjects of the account.
    public var scope: [SubjectRef]
    public var enabled: Bool
    public var autonomy: Autonomy
    public var lastRun: String?          // AIJobRun id

    public init(id: String, kind: AIJobKind, trigger: AIJobTrigger, scope: [SubjectRef] = [], enabled: Bool = true,
                autonomy: Autonomy = .suggest, lastRun: String? = nil) {
        self.id = id
        self.kind = kind
        self.trigger = trigger
        self.scope = scope
        self.enabled = enabled
        self.autonomy = autonomy
        self.lastRun = lastRun
    }
}

public struct AIJobRun: StoreRecord {
    public static let collection = "job-runs"

    public enum Outcome: String, Codable, Sendable, CaseIterable { case running, suggested, nothing, skipped, capped, failed }

    public let id: String
    public let job: String
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome
    public var usage: [String]           // UsageRow ids
    public var suggestions: [String]?
    public var error: String?

    public init(id: String, job: String, startedAt: Date, endedAt: Date? = nil, outcome: Outcome, usage: [String] = [],
                suggestions: [String]? = nil, error: String? = nil) {
        self.id = id
        self.job = job
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.usage = usage
        self.suggestions = suggestions
        self.error = error
    }
}

// MARK: Work orders

/// A typed order for an agent runtime on a runner. There is no shell order.
/// JSON: the fields "op" and "payload" at the top level of the order.
public enum SessionOrder: Hashable, Sendable {
    case start(LaunchRequest)
    case stop(SessionRef)
    /// `scrollback` reads the scrollback with blank lines, not the visible screen.
    case read(SessionRef, lines: Int, scrollback: Bool = false)
    /// `permission` answers the PermissionPrompt, `answer` the RunnerQuestion of a runner session. Then `text` is empty.
    case send(SessionRef, text: String, permission: PermissionAnswer? = nil, answer: RunnerAnswer? = nil)
    case history(SessionRef, budget: HistoryBudget? = nil)

    public enum Op: String, Codable, Sendable, CaseIterable { case sessionStart, sessionStop, sessionRead, sessionSend, sessionHistory }

    public var op: Op {
        switch self {
        case .start: return .sessionStart
        case .stop: return .sessionStop
        case .read: return .sessionRead
        case .send: return .sessionSend
        case .history: return .sessionHistory
        }
    }
}

extension SessionOrder: Codable {
    private enum CodingKeys: String, CodingKey { case op, payload }
    private enum PayloadKeys: String, CodingKey { case session, lines, scrollback, text, permission, answer, budget }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func payload() throws -> KeyedDecodingContainer<PayloadKeys> { try c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload) }
        switch try c.decode(Op.self, forKey: .op) {
        case .sessionStart: self = .start(try c.decode(LaunchRequest.self, forKey: .payload))
        case .sessionStop: self = .stop(try payload().decode(SessionRef.self, forKey: .session))
        case .sessionRead:
            let p = try payload()
            self = .read(try p.decode(SessionRef.self, forKey: .session), lines: try p.decode(Int.self, forKey: .lines),
                         scrollback: try p.decodeIfPresent(Bool.self, forKey: .scrollback) ?? false)
        case .sessionSend:
            let p = try payload()
            self = .send(try p.decode(SessionRef.self, forKey: .session), text: try p.decode(String.self, forKey: .text),
                         permission: try p.decodeIfPresent(PermissionAnswer.self, forKey: .permission),
                         answer: try p.decodeIfPresent(RunnerAnswer.self, forKey: .answer))
        case .sessionHistory:
            let p = try payload()
            self = .history(try p.decode(SessionRef.self, forKey: .session), budget: try p.decodeIfPresent(HistoryBudget.self, forKey: .budget))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        func payload() -> KeyedEncodingContainer<PayloadKeys> { c.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload) }
        switch self {
        case .start(let r): try c.encode(r, forKey: .payload)
        case .stop(let s):
            var p = payload()
            try p.encode(s, forKey: .session)
        case .read(let s, let lines, let scrollback):
            var p = payload()
            try p.encode(s, forKey: .session)
            try p.encode(lines, forKey: .lines)
            if scrollback { try p.encode(true, forKey: .scrollback) }
        case .send(let s, let text, let permission, let answer):
            var p = payload()
            try p.encode(s, forKey: .session)
            try p.encode(text, forKey: .text)
            try p.encodeIfPresent(permission, forKey: .permission)
            try p.encodeIfPresent(answer, forKey: .answer)
        case .history(let s, let budget):
            var p = payload()
            try p.encode(s, forKey: .session)
            try p.encodeIfPresent(budget, forKey: .budget)
        }
    }
}

/// The proposal of a suggestion. On accept, the hub makes a WorkOrder from it.
public struct WorkOrderDraft: Hashable, Sendable, Codable {
    public var runtime: ProviderID
    /// nil: the hub picks a runner that has the runtime.
    public var runner: String?
    public var order: SessionOrder

    public init(runtime: ProviderID, runner: String? = nil, order: SessionOrder) {
        self.runtime = runtime
        self.runner = runner
        self.order = order
    }

    private enum CodingKeys: String, CodingKey { case runtime, runner }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try c.decode(ProviderID.self, forKey: .runtime)
        runner = try c.decodeIfPresent(String.self, forKey: .runner)
        order = try SessionOrder(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runtime, forKey: .runtime)
        try c.encodeIfPresent(runner, forKey: .runner)
        try order.encode(to: encoder)
    }
}

public struct WorkOrderResult: Hashable, Sendable, Codable {
    public var session: SessionRef?      // sessionStart
    public var lines: [String]?          // sessionRead
    public var digest: SessionDigest?    // sessionHistory
    public var paneKey: String?          // sessionStart: the DaemonSession id
    public var turnStarted: Bool?        // sessionStart, sessionSend
    public var error: String?

    public init(session: SessionRef? = nil, lines: [String]? = nil, digest: SessionDigest? = nil, paneKey: String? = nil,
                turnStarted: Bool? = nil, error: String? = nil) {
        self.session = session
        self.lines = lines
        self.digest = digest
        self.paneKey = paneKey
        self.turnStarted = turnStarted
        self.error = error
    }
}

/// Why the hub holds a work order.
public struct WorkOrderHold: Hashable, Sendable, Codable {
    public var blockers: [ItemRef]
    public var areas: [String]
    public var since: Date

    public init(blockers: [ItemRef] = [], areas: [String] = [], since: Date) {
        self.blockers = blockers
        self.areas = areas
        self.since = since
    }
}

public struct WorkOrder: StoreRecord {
    public static let collection = "work-orders"

    /// Open set: a state that this app does not know keeps its raw value.
    public struct State: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        public var description: String { rawValue }

        /// The hub keeps the order while its item has an open blocker or a busy area. A runner never gets it.
        public static let held: State = "held"
        public static let queued: State = "queued"
        public static let sent: State = "sent"
        public static let acked: State = "acked"
        public static let done: State = "done"
        public static let failed: State = "failed"
        public static let expired: State = "expired"
    }

    public let id: String
    public let runner: String            // device id
    public let runtime: ProviderID
    public let order: SessionOrder
    public let suggestion: String
    public let createdAt: Date
    public let expiresAt: Date
    public var state: State
    public var hold: WorkOrderHold?
    public var result: WorkOrderResult?

    public init(id: String, runner: String, runtime: ProviderID, order: SessionOrder, suggestion: String,
                createdAt: Date, expiresAt: Date, state: State = .queued, hold: WorkOrderHold? = nil, result: WorkOrderResult? = nil) {
        self.id = id
        self.runner = runner
        self.runtime = runtime
        self.order = order
        self.suggestion = suggestion
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.hold = hold
        self.result = result
    }

    private enum CodingKeys: String, CodingKey { case id, runner, runtime, suggestion, createdAt, expiresAt, state, hold, result }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        runner = try c.decode(String.self, forKey: .runner)
        runtime = try c.decode(ProviderID.self, forKey: .runtime)
        order = try SessionOrder(from: decoder)
        suggestion = try c.decode(String.self, forKey: .suggestion)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        state = try c.decode(State.self, forKey: .state)
        hold = try c.decodeIfPresent(WorkOrderHold.self, forKey: .hold)
        result = try c.decodeIfPresent(WorkOrderResult.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(runner, forKey: .runner)
        try c.encode(runtime, forKey: .runtime)
        try order.encode(to: encoder)
        try c.encode(suggestion, forKey: .suggestion)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(hold, forKey: .hold)
        try c.encodeIfPresent(result, forKey: .result)
    }
}

// MARK: Memory

public enum MemoryScope: String, Codable, Sendable, CaseIterable { case user, project, subject }

/// A fact, or the vision (the true north) of a project. JSON: a missing kind is a fact.
public enum MemoryKind: String, Codable, Sendable, CaseIterable { case fact, vision }

/// The proposal of a suggestion. On accept, the hub writes a MemoryEntry. The hub refuses kind vision.
public struct MemoryDraft: Hashable, Sendable, Codable {
    public static let maxText = 500

    public var scope: MemoryScope
    public var scopeRef: SubjectRef?     // nil for scope user
    public var text: String
    public var kind: MemoryKind

    public init(scope: MemoryScope, scopeRef: SubjectRef? = nil, text: String, kind: MemoryKind = .fact) {
        self.scope = scope
        self.scopeRef = scopeRef
        self.text = text
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case scope, scopeRef, text, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(MemoryScope.self, forKey: .scope)
        scopeRef = try c.decodeIfPresent(SubjectRef.self, forKey: .scopeRef)
        text = try c.decode(String.self, forKey: .text)
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? .fact
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(scopeRef, forKey: .scopeRef)
        try c.encode(text, forKey: .text)
        if kind != .fact { try c.encode(kind, forKey: .kind) }
    }
}

/// A short, editable fact that AI jobs read.
public struct MemoryEntry: StoreRecord {
    public static let collection = "memory"

    public enum Source: String, Codable, Sendable { case user, suggestion }

    public let id: String
    public var scope: MemoryScope
    public var scopeRef: SubjectRef?
    public var text: String
    public var kind: MemoryKind
    public var source: Source
    public var suggestion: String?
    public var updatedAt: Date

    public init(id: String, scope: MemoryScope, scopeRef: SubjectRef? = nil, text: String, kind: MemoryKind = .fact,
                source: Source = .user, suggestion: String? = nil, updatedAt: Date) {
        self.id = id
        self.scope = scope
        self.scopeRef = scopeRef
        self.text = text
        self.kind = kind
        self.source = source
        self.suggestion = suggestion
        self.updatedAt = updatedAt
    }

    /// The vision of a project. The fixed id makes one vision for each project.
    public static func vision(_ text: String, of project: ProjectRef, updatedAt: Date) -> MemoryEntry {
        MemoryEntry(id: visionID(of: project), scope: .project, scopeRef: .project(project), text: text, kind: .vision,
                    updatedAt: updatedAt)
    }

    public static func visionID(of project: ProjectRef) -> String { "vision-\(project.storeKey)" }

    /// The vision entry of the project, if any.
    public static func vision(for project: ProjectRef, in entries: [MemoryEntry]) -> MemoryEntry? {
        entries.first {
            guard $0.kind == .vision, $0.scope == .project, case .project(let p)? = $0.scopeRef else { return false }
            return p.storeKey == project.storeKey
        }
    }

    private enum CodingKeys: String, CodingKey { case id, scope, scopeRef, text, kind, source, suggestion, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        scope = try c.decode(MemoryScope.self, forKey: .scope)
        scopeRef = try c.decodeIfPresent(SubjectRef.self, forKey: .scopeRef)
        text = try c.decode(String.self, forKey: .text)
        kind = try c.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? .fact
        source = try c.decode(Source.self, forKey: .source)
        suggestion = try c.decodeIfPresent(String.self, forKey: .suggestion)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(scopeRef, forKey: .scopeRef)
        try c.encode(text, forKey: .text)
        if kind != .fact { try c.encode(kind, forKey: .kind) }
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(suggestion, forKey: .suggestion)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: Suggestions

/// What happens on accept. The target is the subject of the suggestion.
public enum Proposal: Hashable, Sendable {
    /// `relations`: the relations of the subject to add on accept.
    case itemPatch(ItemPatch, relations: [ItemRelation] = [])
    case changeAction(ChangeAction)
    case runAction(RunAction)
    case workOrder(WorkOrderDraft)
    case memory(MemoryDraft)
    case plan(PlanDraft)
    /// A type that this app does not know, for example sequence of schema 1. It keeps the JSON as it is.
    case unknown(type: String, json: JSONValue)
}

extension Proposal: Codable {
    private enum CodingKeys: String, CodingKey { case type, patch, relations, action, order, memory, plan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "itemPatch":
            self = .itemPatch(try c.decode(ItemPatch.self, forKey: .patch), relations: try c.decodeIfPresent([ItemRelation].self, forKey: .relations) ?? [])
        case "changeAction": self = .changeAction(try c.decode(ChangeAction.self, forKey: .action))
        case "runAction": self = .runAction(try c.decode(RunAction.self, forKey: .action))
        case "workOrder": self = .workOrder(try c.decode(WorkOrderDraft.self, forKey: .order))
        case "memory": self = .memory(try c.decode(MemoryDraft.self, forKey: .memory))
        case "plan": self = .plan(try c.decode(PlanDraft.self, forKey: .plan))
        case let t: self = .unknown(type: t, json: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(_, let json) = self { return try json.encode(to: encoder) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown: break
        case .itemPatch(let p, let relations):
            try c.encode("itemPatch", forKey: .type)
            try c.encode(p, forKey: .patch)
            if !relations.isEmpty { try c.encode(relations, forKey: .relations) }
        case .changeAction(let a):
            try c.encode("changeAction", forKey: .type)
            try c.encode(a, forKey: .action)
        case .runAction(let a):
            try c.encode("runAction", forKey: .type)
            try c.encode(a, forKey: .action)
        case .workOrder(let o):
            try c.encode("workOrder", forKey: .type)
            try c.encode(o, forKey: .order)
        case .memory(let m):
            try c.encode("memory", forKey: .type)
            try c.encode(m, forKey: .memory)
        case .plan(let d):
            try c.encode("plan", forKey: .type)
            try c.encode(d, forKey: .plan)
        }
    }
}

/// What the user removed before Accept. Only a removal: the user cannot add text through it.
public struct SuggestionEdit: Hashable, Sendable, Codable {
    public var drop: [Int]

    public init(drop: [Int]) { self.drop = drop }
}

public struct Suggestion: StoreRecord {
    public static let collection = "suggestions"

    public enum State: String, Codable, Sendable, CaseIterable { case open, accepted, dismissed, expired, done, failed }

    public let id: String
    public let subject: SubjectRef
    public let kind: AIJobKind
    public var title: String
    public var body: String              // Markdown
    /// nil: the suggestion only informs. Accept then sets it to done.
    public var proposal: Proposal?
    public var state: State
    public let dedupeKey: String
    public let subjectVersion: String
    public let createdAt: Date
    public var expiresAt: Date
    public var decidedAt: Date?
    public var decidedBy: String?        // device id
    public var jobRun: String?
    public var error: String?
    /// Set with state accepted. The hub applies it to the proposal and removes it.
    public var edit: SuggestionEdit?

    public init(id: String, subject: SubjectRef, kind: AIJobKind, title: String, body: String, proposal: Proposal? = nil,
                state: State = .open, subjectVersion: String, createdAt: Date, expiresAt: Date, decidedAt: Date? = nil,
                decidedBy: String? = nil, jobRun: String? = nil, error: String? = nil) {
        self.id = id
        self.subject = subject
        self.kind = kind
        self.title = title
        self.body = body
        self.proposal = proposal
        self.state = state
        dedupeKey = Self.dedupeKey(subject: subject, kind: kind, version: subjectVersion)
        self.subjectVersion = subjectVersion
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.jobRun = jobRun
        self.error = error
    }

    /// Subject, kind and subject version. A job does not write a second open suggestion with the same key.
    public static func dedupeKey(subject: SubjectRef, kind: AIJobKind, version: String) -> String {
        "\(subject.kind.rawValue):\(subject.key)|\(kind.rawValue)|\(version)"
    }
}

extension SubjectRef {
    /// A short, stable text for the subject inside one account.
    var key: String {
        switch self {
        case .project(let r): return "\(r.account.provider)/\(r.storeKey)"
        case .item(let r): return r.id
        case .repo(let r): return r.path
        case .change(let r): return "\(r.repo.path)#\(r.number)"
        case .run(let r): return "\(r.id)#\(r.attempt)"
        case .job(let r): return "\(r.run.id)#\(r.run.attempt)/\(r.id)"
        case .workspace(let r): return r.id
        case .session(let r): return "\(r.workspace.id)/\(r.id)"
        }
    }
}

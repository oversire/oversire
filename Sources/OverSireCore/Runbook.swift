import Foundation

/// A runbook takes one item from plan to merge in a fixed list of steps (runbook.json). Each step is a fresh agent session.
/// The app keeps the runbooks in config.json. The daemon of the sessions machine runs them.
public struct Runbook: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var steps: [RunbookStep]

    public init(id: String, name: String, steps: [RunbookStep]) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    public func step(_ id: String) -> RunbookStep? { steps.first { $0.id == id } }
    public func index(of step: String) -> Int? { steps.firstIndex { $0.id == step } }
    /// The review that `fix` serves.
    public func review(fixedBy fix: String) -> RunbookStep? { steps.first { $0.review?.fix == fix } }
}

public struct RunbookStep: Codable, Hashable, Sendable, Identifiable {
    /// Verdict gaps runs the fix step, then the review again, up to `rounds` more times.
    public struct Review: Codable, Hashable, Sendable {
        public var fix: String
        public var rounds: Int

        public init(fix: String, rounds: Int = 1) {
            self.fix = fix
            self.rounds = rounds
        }
    }

    public var id: String
    public var name: String
    public var agent: String
    public var prompt: String
    public var pauseBefore: Bool?
    public var review: Review?

    public init(id: String, name: String, agent: String, prompt: String, pauseBefore: Bool? = nil, review: Review? = nil) {
        self.id = id
        self.name = name
        self.agent = agent
        self.prompt = prompt
        self.pauseBefore = pauseBefore
        self.review = review
    }

    public var pauses: Bool { pauseBefore ?? false }
}

/// One agent, resolved by the app at the start. The fields go into LaunchRequest.
public struct AgentLaunchSpec: Codable, Hashable, Sendable {
    public var cli: String
    public var command: String?
    public var model: String?
    public var effort: String?
    public var profile: String

    public init(cli: String, command: String? = nil, model: String? = nil, effort: String? = nil, profile: String) {
        self.cli = cli
        self.command = command
        self.model = model
        self.effort = effort
        self.profile = profile
    }
}

/// The body of POST /v1/runbook-runs.
public struct RunbookStart: Codable, Hashable, Sendable {
    public var item: ItemRef
    public var title: String?
    public var repo: String
    public var runtime: String?        // nil: the daemon picks a runtime with workspaces
    public var runbook: Runbook
    public var agents: [String: AgentLaunchSpec]
    public var startAt: String?
    public var notes: String?

    public init(item: ItemRef, title: String? = nil, repo: String, runtime: String? = nil, runbook: Runbook,
                agents: [String: AgentLaunchSpec], startAt: String? = nil, notes: String? = nil) {
        self.item = item
        self.title = title
        self.repo = repo
        self.runtime = runtime
        self.runbook = runbook
        self.agents = agents
        self.startAt = startAt
        self.notes = notes
    }
}

public struct RunbookRunID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// One round of one step. Round 1 is the first run.
public struct StepRun: Codable, Hashable, Sendable {
    /// pass and gaps: a review verdict. done and skipped: the verdict of another step. ended: no verdict. failed: no start.
    public enum State: String, Codable, Sendable, CaseIterable {
        case waits, starting, working, asks, pass, gaps, done, skipped, blocked, ended, failed

        /// The session of the step is open.
        public var isLive: Bool { [.starting, .working, .asks].contains(self) }
        public var isFinished: Bool { [.pass, .gaps, .done, .skipped, .blocked, .ended, .failed].contains(self) }
    }

    public var step: String
    public var round: Int
    public var state: State
    public var session: SessionRef?
    public var daemonSession: String?  // the DaemonSession id
    public var terminal: String?
    public var note: String?
    public var started: Date?
    public var ended: Date?

    public init(step: String, round: Int = 1, state: State, session: SessionRef? = nil, daemonSession: String? = nil,
                terminal: String? = nil, note: String? = nil, started: Date? = nil, ended: Date? = nil) {
        self.step = step
        self.round = round
        self.state = state
        self.session = session
        self.daemonSession = daemonSession
        self.terminal = terminal
        self.note = note
        self.started = started
        self.ended = ended
    }
}

public struct RunbookRun: Codable, Hashable, Sendable, Identifiable {
    /// gate: waits for your approval. paused: needs you.
    public enum State: String, Codable, Sendable {
        case running, gate, paused, done, failed, stopped

        public var isOpen: Bool { [.running, .gate, .paused].contains(self) }
    }

    public var id: RunbookRunID
    public var item: ItemRef
    public var title: String?
    public var machine: MachineName
    public var runtime: String
    public var repo: String
    public var runbook: Runbook
    public var agents: [String: AgentLaunchSpec]
    public var notes: String?
    public var state: State
    public var reason: String?
    public var current: String?
    public var steps: [StepRun]
    public var started: Date
    public var updated: Date

    public init(id: RunbookRunID, item: ItemRef, title: String? = nil, machine: MachineName, runtime: String, repo: String,
                runbook: Runbook, agents: [String: AgentLaunchSpec], notes: String? = nil, state: State, reason: String? = nil,
                current: String? = nil, steps: [StepRun], started: Date, updated: Date) {
        self.id = id
        self.item = item
        self.title = title
        self.machine = machine
        self.runtime = runtime
        self.repo = repo
        self.runbook = runbook
        self.agents = agents
        self.notes = notes
        self.state = state
        self.reason = reason
        self.current = current
        self.steps = steps
        self.started = started
        self.updated = updated
    }

    /// The rounds of a step, first round first.
    public func rounds(of step: String) -> [StepRun] { steps.filter { $0.step == step }.sorted { $0.round < $1.round } }
    /// The last round of a step.
    public func last(_ step: String) -> StepRun? { rounds(of: step).last }
    /// The 1-based place of the current step.
    public var position: Int? { current.flatMap { runbook.index(of: $0) }.map { $0 + 1 } }
}

/// The body of POST /v1/runbook-runs/{id}/steps/{step}/done.
public struct StepDone: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable, CaseIterable { case pass, gaps, done, skipped, blocked }

    public var verdict: Verdict
    public var note: String?

    public init(verdict: Verdict, note: String? = nil) {
        self.verdict = verdict
        self.note = note
    }
}

/// The body of PATCH /v1/runbook-runs/{id}/steps/{step}, only for a step that did not start.
public struct StepPatch: Codable, Hashable, Sendable {
    public var agent: String?
    public var launch: AgentLaunchSpec?
    public var prompt: String?

    public init(agent: String? = nil, launch: AgentLaunchSpec? = nil, prompt: String? = nil) {
        self.agent = agent
        self.launch = launch
        self.prompt = prompt
    }
}

import Foundation

// ─── Agent runtime model ─────────────────────────────────────────────────────

/// One agent session in a runtime workspace, as the app tracks it for an item.
public struct AgentSession: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case starting, working, waiting, done, failed }

    public var phase: Phase
    public var since: Date
    public var card: String?        // workspace id
    public var paneKey: String?     // session id
    public var agent: AgentName
    public var repo: String
    public var prompt: String?
    public var message: String?     // the error of a failed start, else the last agent reply

    public init(phase: Phase, since: Date, card: String? = nil, paneKey: String? = nil, agent: AgentName = .claude,
                repo: String = "", prompt: String? = nil, message: String? = nil) {
        self.phase = phase
        self.since = since
        self.card = card
        self.paneKey = paneKey
        self.agent = agent
        self.repo = repo
        self.prompt = prompt
        self.message = message
    }

    // Needs input first, done last.
    public var rank: Int {
        switch phase {
        case .waiting: return 0
        case .working: return 1
        case .starting: return 2
        case .failed: return 3
        case .done: return 4
        }
    }
}

/// A runtime workspace (an Orca card: a worktree with its sessions).
public struct Workspace: Hashable, Sendable {
    public let id: String
    public let repo: String
    public let path: String
    public let name: String
    public let comment: String?
    public let liveTerminals: Int
    public let lastActivity: Date
    public let agents: [AgentSession]

    public init(id: String, repo: String, path: String, name: String, comment: String?, liveTerminals: Int,
                lastActivity: Date, agents: [AgentSession]) {
        self.id = id
        self.repo = repo
        self.path = path
        self.name = name
        self.comment = comment
        self.liveTerminals = liveTerminals
        self.lastActivity = lastActivity
        self.agents = agents
    }
}

public struct RuntimeRepo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let folder: Bool

    public init(id: String, name: String, path: String, folder: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.folder = folder
    }
}

/// What a start made: the workspace, the terminal and how far the prompt got.
public struct Launch: Hashable, Sendable {
    public let card: String
    public let handle: String
    public let paneKey: String
    public let turnStarted: Bool

    public init(card: String, handle: String, paneKey: String, turnStarted: Bool) {
        self.card = card
        self.handle = handle
        self.paneKey = paneKey
        self.turnStarted = turnStarted
    }
}

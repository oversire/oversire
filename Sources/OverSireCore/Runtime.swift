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
    public var key: String?         // the start key of the session, for example enhance:K-1
    public var startedAt: Date?     // the start of the session; `since` is the start of the phase

    public init(phase: Phase, since: Date, card: String? = nil, paneKey: String? = nil, agent: AgentName = .claude,
                repo: String = "", prompt: String? = nil, message: String? = nil, key: String? = nil, startedAt: Date? = nil) {
        self.phase = phase
        self.since = since
        self.card = card
        self.paneKey = paneKey
        self.agent = agent
        self.repo = repo
        self.prompt = prompt
        self.message = message
        self.key = key
        self.startedAt = startedAt
    }

    /// The session waits, or its turn ended with a question.
    public var needsInput: Bool { phase == .waiting || (phase == .done && Self.question(in: message) != nil) }

    /// The last paragraph of a reply whose last sentence is a question. A "?" in a code block does not count.
    public static func question(in message: String?) -> String? {
        guard let message else { return nil }
        var prose: [String] = []
        var code = false
        for line in message.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.toggle()
                prose.append("")
            } else {
                prose.append(code ? "" : line)
            }
        }
        if code { return nil }
        let paragraphs = prose.joined(separator: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = paragraphs.last, message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(last.suffix(1)) else { return nil }
        let end = last.trimmingCharacters(in: CharacterSet(charactersIn: "*_\"')”’ "))
        return end.hasSuffix("?") ? last : nil
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
    /// worktree: a git worktree of its own. folder: a card on a shared folder. main: the main checkout of a repo.
    public enum Kind: Hashable, Sendable { case worktree, folder, main }

    public let id: String
    public let repo: String
    public let path: String
    public let name: String
    public let comment: String?
    public let liveTerminals: Int
    public let lastActivity: Date
    public let agents: [AgentSession]
    public var kind: Kind = .worktree
    public var branch = ""

    public init(id: String, repo: String, path: String, name: String, comment: String?, liveTerminals: Int,
                lastActivity: Date, agents: [AgentSession], kind: Kind = .worktree, branch: String = "") {
        self.id = id
        self.repo = repo
        self.path = path
        self.name = name
        self.comment = comment
        self.liveTerminals = liveTerminals
        self.lastActivity = lastActivity
        self.agents = agents
        self.kind = kind
        self.branch = branch
    }

    /// An agent works or waits for input in the workspace.
    public var hasLiveAgent: Bool { agents.contains { $0.phase == .working || $0.phase == .waiting || $0.phase == .starting } }
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

/// A place where a runtime runs sessions: this Mac, a paired server or a cloud.
public struct RuntimeEnvironment: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case local, ssh, cloud }

    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public static let local = RuntimeEnvironment(id: "local", name: "This Mac", kind: .local)
}

/// One terminal of a workspace. A terminal can hold an agent session.
public struct RuntimeSession: Hashable, Sendable {
    public let ref: SessionRef
    public let title: String
    public let paneKey: String
    public let orphaned: Bool

    public init(ref: SessionRef, title: String, paneKey: String, orphaned: Bool) {
        self.ref = ref
        self.title = title
        self.paneKey = paneKey
        self.orphaned = orphaned
    }
}

/// Start an agent in a workspace of the runtime. The JSON form is in Contract/schema/actions.json.
public struct LaunchRequest: Hashable, Sendable, Codable {
    public var repo: String              // the repo path or remote URL in the runtime
    public var item: ItemRef?
    public var name: String?             // the workspace name; default: the item key
    public var note: String?             // the workspace note; default: the item URL
    public var branch: String?
    public var agent: AgentName
    public var prompt: String
    public var environment: String?      // deprecated: the daemon ignores it
    public var command: String?          // the resolved start command; nil: the runtime default
    public var title: String?            // the terminal title
    public var baseBranch: String?
    public var inPlace: Bool?            // true: a new terminal in the folder `repo`, no workspace
    public var key: String?              // the start key: one live session for each key, for example enhance:K-1

    public init(repo: String, item: ItemRef? = nil, name: String? = nil, note: String? = nil, branch: String? = nil,
                agent: AgentName, prompt: String, environment: String? = nil, command: String? = nil, title: String? = nil,
                baseBranch: String? = nil, inPlace: Bool? = nil, key: String? = nil) {
        self.repo = repo
        self.item = item
        self.name = name
        self.note = note
        self.branch = branch
        self.agent = agent
        self.prompt = prompt
        self.environment = environment
        self.command = command
        self.title = title
        self.baseBranch = baseBranch
        self.inPlace = inPlace
        self.key = key
    }

    public var workspaceName: String? { name ?? item?.key }
}

public protocol AgentRuntime: Provider {
    func environments() async throws -> [RuntimeEnvironment]
    /// nil: the environment of the account.
    func repos(in env: RuntimeEnvironment?) async throws -> [RuntimeRepo]
    func workspaces() async throws -> [Workspace]
    func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession]
    func launch(_ r: LaunchRequest) async throws -> Launch
}

public protocol SessionIO: AgentRuntime {
    /// True when the agent started a turn.
    @discardableResult func send(_ s: SessionRef, text: String) async throws -> Bool
    /// The last lines that the screen shows, without empty lines.
    func tail(_ s: SessionRef, lines: Int) async throws -> [String]
    /// The scroll back as text.
    func output(_ s: SessionRef, lines: Int) async throws -> [String]
    func close(_ s: SessionRef) async throws
}

/// Shows a session in the runtime UI on this Mac.
public protocol Revealing: AgentRuntime {
    func reveal(_ s: SessionRef) async throws
}

/// A local file for the host of a workspace.
public struct HostFile: Sendable, Equatable {
    public var name: String      // the file name on the host; the adapter makes it safe
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Writes files on the host of a workspace. The result is the host path of each file, in order.
public protocol HostFileWriting: AgentRuntime {
    /// `dir` is a host folder, for example /tmp/oversire/<session-id>. `progress` gives (bytes sent, total bytes).
    func writeFiles(_ files: [HostFile], workspacePath: String, dir: String,
                    progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String]
}

/// What a removal did. `warning` is a note of the runtime, for example a kept branch.
public struct WorkspaceRemoval: Hashable, Sendable, Codable {
    public let warning: String?

    public init(warning: String? = nil) { self.warning = warning }
}

/// Removes a workspace. A worktree goes from the runtime and from git. A folder card closes, and the folder stays.
/// The main checkout of a repo cannot be removed.
public protocol WorkspaceRemoving: AgentRuntime {
    /// `force` removes a worktree with changes. `runHooks` runs the archive hooks of the repo; a failed hook stops the removal.
    func remove(_ w: Workspace, force: Bool, runHooks: Bool) async throws -> WorkspaceRemoval
}


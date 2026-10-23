import Foundation

// ─── runtime API of the daemon ───────────────────────────────────────────────
// Each daemon talks only to the agent runtimes of its own machine. Contract: daemon.json.

/// One agent runtime on the machine. GET /v1/runtimes.
public struct DaemonRuntime: Codable, Hashable, Sendable, Identifiable {
    public var id: String                   // orca, oversire
    public var name: String
    public var installed: Bool
    public var reachable: Bool
    public var version: String?
    public var error: String?
    public var capabilities: [String]       // Capability raw values

    public init(id: String, name: String, installed: Bool, reachable: Bool, version: String? = nil, error: String? = nil,
                capabilities: [String] = []) {
        self.id = id
        self.name = name
        self.installed = installed
        self.reachable = reachable
        self.version = version
        self.error = error
        self.capabilities = capabilities
    }
}

public struct DaemonRuntimesPage: Codable, Hashable, Sendable {
    public var runtimes: [DaemonRuntime]
    public init(runtimes: [DaemonRuntime]) { self.runtimes = runtimes }
}

/// GET /v1/repos.
public struct DaemonRepo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runtime: String
    public var name: String
    public var path: String
    public var folder: Bool

    public init(id: String, runtime: String, name: String, path: String, folder: Bool) {
        self.id = id
        self.runtime = runtime
        self.name = name
        self.path = path
        self.folder = folder
    }
}

public struct DaemonReposPage: Codable, Hashable, Sendable {
    public var repos: [DaemonRepo]
    public init(repos: [DaemonRepo]) { self.repos = repos }
}

public struct DaemonTerminal: Codable, Hashable, Sendable, Identifiable {
    public var id: String                   // the terminal handle
    public var title: String
    public var session: String?             // DaemonSession.id
    public var orphaned: Bool

    public init(id: String, title: String, session: String? = nil, orphaned: Bool) {
        self.id = id
        self.title = title
        self.session = session
        self.orphaned = orphaned
    }
}

/// GET /v1/workspaces.
public struct DaemonWorkspace: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case worktree, folder, main }

    public var id: String
    public var runtime: String
    public var repo: String?
    public var path: String
    public var name: String?
    public var comment: String?
    public var kind: Kind
    public var branch: String?
    public var liveTerminals: Int
    public var lastActivity: Date
    public var terminals: [DaemonTerminal]?

    public init(id: String, runtime: String, repo: String? = nil, path: String, name: String? = nil, comment: String? = nil,
                kind: Kind, branch: String? = nil, liveTerminals: Int, lastActivity: Date, terminals: [DaemonTerminal]? = nil) {
        self.id = id
        self.runtime = runtime
        self.repo = repo
        self.path = path
        self.name = name
        self.comment = comment
        self.kind = kind
        self.branch = branch
        self.liveTerminals = liveTerminals
        self.lastActivity = lastActivity
        self.terminals = terminals
    }
}

public struct DaemonWorkspacesPage: Codable, Hashable, Sendable {
    public var workspaces: [DaemonWorkspace]
    public var errors: [String: String]?    // runtime id → error text

    public init(workspaces: [DaemonWorkspace], errors: [String: String]? = nil) {
        self.workspaces = workspaces
        self.errors = errors
    }
}

/// The body of DELETE /v1/workspaces/{id}. The answer is a WorkspaceRemoval.
public struct WorkspaceRemove: Codable, Hashable, Sendable {
    public var runtime: String
    public var force: Bool
    public var runHooks: Bool

    public init(runtime: String, force: Bool, runHooks: Bool) {
        self.runtime = runtime
        self.force = force
        self.runHooks = runHooks
    }
}

public struct WorkspaceFile: Codable, Hashable, Sendable {
    public var name: String
    public var data: Data                   // base64 on the wire

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// The body of POST /v1/files. The daemon chooses the folder.
public struct WorkspaceFiles: Codable, Hashable, Sendable {
    public var files: [WorkspaceFile]
    public init(files: [WorkspaceFile]) { self.files = files }
}

public struct WorkspaceFilesResult: Codable, Hashable, Sendable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

/// The body of POST /v1/workers.
public struct WorkerStart: Codable, Hashable, Sendable {
    public var runtime: String?
    public var spec: String
    public var title: String
    public var path: String
    public var agent: String

    public init(runtime: String? = nil, spec: String, title: String, path: String, agent: String) {
        self.runtime = runtime
        self.spec = spec
        self.title = title
        self.path = path
        self.agent = agent
    }
}

/// A supervised worker on a daemon. The daemon keeps it over a restart.
public struct Worker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var runtime: String
    public var title: String?
    public var path: String?
    public var agent: String?
    public var terminal: String?
    public var startedAt: Date

    public init(id: String, runtime: String, title: String? = nil, path: String? = nil, agent: String? = nil,
                terminal: String? = nil, startedAt: Date) {
        self.id = id
        self.runtime = runtime
        self.title = title
        self.path = path
        self.agent = agent
        self.terminal = terminal
        self.startedAt = startedAt
    }
}

/// GET /v1/workers/{id}.
public struct WorkerState: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case running, done, ended }

    public var state: State
    public var outcome: String?             // with done
    public var body: String?                // with done
    public var reason: String?              // with ended

    public init(state: State, outcome: String? = nil, body: String? = nil, reason: String? = nil) {
        self.state = state
        self.outcome = outcome
        self.body = body
        self.reason = reason
    }
}

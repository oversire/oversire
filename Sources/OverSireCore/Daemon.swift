import Foundation

// ─── oversire daemon ─────────────────────────────────────────────────────────
// The HTTP API of the oversire daemon on a machine, and the group of the machines of one user.
// Contract: daemon.json. The app reads /v1/events as CloudEventsPage (OverSireSync).

/// The daemon name. Unique in a group.
public struct MachineName: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
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

/// One agent session on the machine, merged from all sources.
public struct DaemonSession: Codable, Hashable, Sendable, Identifiable {
    /// The same values as AgentSession.Phase.
    public enum State: String, Codable, Sendable { case starting, working, waiting, done, failed }
    /// monitoring: the session works, but only a background shell runs.
    public enum Reason: String, Codable, Sendable { case question, permission, turnEnd, interrupted, error, monitoring }

    public var id: String               // Orca: the pane key <tabId>:<leafId>; CLI: cli:<harness session id>; oversire: s-…
    public var machine: MachineName
    public var runtime: String          // orca, oversire or cli
    public var harness: String
    public var workspace: String?
    public var terminal: String?
    public var harnessSession: String?
    public var cwd: String
    public var repo: String?
    public var branch: String?
    public var state: State
    public var reason: Reason?
    public var question: QuestionID?
    public var prompt: String?
    public var lastMessage: String?
    public var stateSince: Date
    public var updatedAt: Date
    public var sources: [String]        // hook, orca, wire

    public init(id: String, machine: MachineName, runtime: String, harness: String, workspace: String? = nil,
                terminal: String? = nil, harnessSession: String? = nil, cwd: String, repo: String? = nil, branch: String? = nil,
                state: State, reason: Reason? = nil, question: QuestionID? = nil, prompt: String? = nil,
                lastMessage: String? = nil, stateSince: Date, updatedAt: Date, sources: [String]) {
        self.id = id
        self.machine = machine
        self.runtime = runtime
        self.harness = harness
        self.workspace = workspace
        self.terminal = terminal
        self.harnessSession = harnessSession
        self.cwd = cwd
        self.repo = repo
        self.branch = branch
        self.state = state
        self.reason = reason
        self.question = question
        self.prompt = prompt
        self.lastMessage = lastMessage
        self.stateSince = stateSince
        self.updatedAt = updatedAt
        self.sources = sources
    }
}

/// GET /v1/sessions.
public struct DaemonSessionsPage: Codable, Hashable, Sendable {
    public var sessions: [DaemonSession]
    public init(sessions: [DaemonSession]) { self.sessions = sessions }
}

/// The environment of the agent process. The `oversire hook` command sends it with each hook call.
public struct HookEnv: Codable, Hashable, Sendable {
    public var paneKey: String?
    public var tabId: String?
    public var worktreeId: String?
    public var terminalHandle: String?
    public var worktreePath: String?
    public var pwd: String?
    public var ppid: Int?
    public var oversireSession: String?

    public init(paneKey: String? = nil, tabId: String? = nil, worktreeId: String? = nil, terminalHandle: String? = nil,
                worktreePath: String? = nil, pwd: String? = nil, ppid: Int? = nil, oversireSession: String? = nil) {
        self.paneKey = paneKey
        self.tabId = tabId
        self.worktreeId = worktreeId
        self.terminalHandle = terminalHandle
        self.worktreePath = worktreePath
        self.pwd = pwd
        self.ppid = ppid
        self.oversireSession = oversireSession
    }
}

/// The hook state of one harness on the machine.
public struct HarnessHooks: Codable, Hashable, Sendable {
    /// untrusted: Codex did not approve the hooks yet.
    public enum State: String, Codable, Sendable { case installed, missing, untrusted, outdated, unsupported }

    public var name: String
    public var hooks: State

    public init(name: String, hooks: State) {
        self.name = name
        self.hooks = hooks
    }
}

/// GET /v1/whoami on a daemon.
public struct DaemonInfo: Codable, Hashable, Sendable {
    public struct Listen: Codable, Hashable, Sendable {
        public var loopback: String         // host:port
        public var tailscale: String?

        public init(loopback: String, tailscale: String? = nil) {
            self.loopback = loopback
            self.tailscale = tailscale
        }
    }

    public var machine: MachineName
    public var version: String
    public var contract: Int
    public var roles: [String]              // serve, runner
    public var runtimes: [ProviderID]
    public var harnesses: [HarnessHooks]
    public var group: String?               // nil before the machine has a group
    public var home: MachineName?
    public var device: String?              // set only on a call with a credential
    public var update: DaemonUpdate?
    public var listen: Listen

    public init(machine: MachineName, version: String, contract: Int, roles: [String], runtimes: [ProviderID],
                harnesses: [HarnessHooks], group: String? = nil, home: MachineName? = nil, device: String? = nil,
                update: DaemonUpdate? = nil, listen: Listen) {
        self.machine = machine
        self.version = version
        self.contract = contract
        self.roles = roles
        self.runtimes = runtimes
        self.harnesses = harnesses
        self.group = group
        self.home = home
        self.device = device
        self.update = update
        self.listen = listen
    }
}

/// UpdateStatus of daemon.json: the last self-update check of a daemon. POST /v1/update answers it too.
public struct DaemonUpdate: Codable, Hashable, Sendable {
    public var checkedAt: Date
    public var latest: String?
    /// The version that the check installed. The daemon restarts with it.
    public var installed: String?
    public var error: String?

    public init(checkedAt: Date, latest: String? = nil, installed: String? = nil, error: String? = nil) {
        self.checkedAt = checkedAt
        self.latest = latest
        self.installed = installed
        self.error = error
    }
}

/// daemon: a machine of the group. app: an app on a machine without a daemon.
public enum DeviceKind: String, Codable, Sendable { case daemon, app }

/// One machine (daemon) of the group.
public struct GroupMember: Codable, Hashable, Sendable {
    public var machine: MachineName
    public var host: String
    public var addrs: [String]
    public var port: Int
    public var roles: [String]
    public var joinedAt: Date
    public var lastSeen: Date?
    /// The CLI version. nil: a CLI before 0.2.2.
    public var version: String?

    public init(machine: MachineName, host: String, addrs: [String], port: Int, roles: [String], joinedAt: Date, lastSeen: Date? = nil,
                version: String? = nil) {
        self.machine = machine
        self.host = host
        self.addrs = addrs
        self.port = port
        self.roles = roles
        self.joinedAt = joinedAt
        self.lastSeen = lastSeen
        self.version = version
    }

    /// The URL that the other members dial. The daemon listens only on loopback and the tailnet,
    /// so a tailnet address (IPv4 first) wins over the host name, which can resolve to a LAN address.
    public var dialURL: URL? {
        let addr = addrs.first { !$0.contains(":") } ?? addrs.first.map { "[\($0)]" } ?? host
        return URL(string: "http://\(addr):\(port)")
    }
}

/// One credential holder: a daemon or an app.
public struct GroupDevice: Codable, Hashable, Sendable {
    public var deviceId: String
    public var name: String
    public var kind: DeviceKind
    public var machine: MachineName
    public var issuedBy: MachineName
    public var issuedAt: Date

    public init(deviceId: String, name: String, kind: DeviceKind, machine: MachineName, issuedBy: MachineName, issuedAt: Date) {
        self.deviceId = deviceId
        self.name = name
        self.kind = kind
        self.machine = machine
        self.issuedBy = issuedBy
        self.issuedAt = issuedAt
    }
}

/// The "My machines" group. It never holds the secret. Only a JoinResult holds it.
public struct Group: Codable, Hashable, Sendable {
    public struct Removed: Codable, Hashable, Sendable {
        public var machine: MachineName
        public var at: Date

        public init(machine: MachineName, at: Date) {
            self.machine = machine
            self.at = at
        }
    }

    public struct Cloud: Codable, Hashable, Sendable {
        public var hub: String
        public var account: String

        public init(hub: String, account: String) {
            self.hub = hub
            self.account = account
        }
    }

    public var id: String
    public var name: String
    public var home: MachineName
    public var version: Int
    public var members: [GroupMember]
    public var devices: [GroupDevice]
    public var revoked: [String]
    public var removed: [Removed]
    public var cloud: Cloud?

    public init(id: String, name: String, home: MachineName, version: Int, members: [GroupMember], devices: [GroupDevice],
                revoked: [String] = [], removed: [Removed] = [], cloud: Cloud? = nil) {
        self.id = id
        self.name = name
        self.home = home
        self.version = version
        self.members = members
        self.devices = devices
        self.revoked = revoked
        self.removed = removed
        self.cloud = cloud
    }
}

/// A join code that a member made.
public struct GroupInvite: Codable, Hashable, Sendable {
    public var code: String
    public var via: MachineName
    public var expiresAt: Date

    public init(code: String, via: MachineName, expiresAt: Date) {
        self.code = code
        self.via = via
        self.expiresAt = expiresAt
    }
}

/// The body of POST /v1/group/join and POST /v1/group/requests. `code` is nil for a request that waits for approval.
public struct JoinRequest: Codable, Hashable, Sendable {
    public var code: String?
    public var machine: MachineName
    public var host: String
    public var addrs: [String]?
    public var port: Int?
    public var roles: [String]?
    public var kind: DeviceKind
    public var nonce: String

    public init(code: String? = nil, machine: MachineName, host: String, addrs: [String]? = nil, port: Int? = nil,
                roles: [String]? = nil, kind: DeviceKind, nonce: String) {
        self.code = code
        self.machine = machine
        self.host = host
        self.addrs = addrs
        self.port = port
        self.roles = roles
        self.kind = kind
        self.nonce = nonce
    }
}

/// A join request that waits for approval. Both sides show `confirm`.
public struct JoinPending: Codable, Hashable, Sendable {
    public var request: String
    public var confirm: String
    public var expiresAt: Date

    public init(request: String, confirm: String, expiresAt: Date) {
        self.request = request
        self.confirm = confirm
        self.expiresAt = expiresAt
    }
}

/// The token is opaque to clients.
public struct DeviceCredential: Codable, Hashable, Sendable {
    public var deviceId: String
    public var token: String

    public init(deviceId: String, token: String) {
        self.deviceId = deviceId
        self.token = token
    }
}

/// An accepted join. Only a result for kind daemon holds the secret.
public struct JoinResult: Codable, Hashable, Sendable {
    public var group: Group
    public var secret: String?
    public var credential: DeviceCredential

    public init(group: Group, secret: String? = nil, credential: DeviceCredential) {
        self.group = group
        self.secret = secret
        self.credential = credential
    }
}

/// One open pause of a session. The fields match SessionQuestion. An item can have the kind approve.
public struct DaemonQuestion: Codable, Hashable, Sendable, Identifiable {
    public enum Via: String, Codable, Sendable { case form, permission, turn, waiting, askReply }
    public enum Source: String, Codable, Sendable { case hook, screen, transcript, mail }

    public var id: QuestionID
    public var session: String              // DaemonSession.id
    public var terminal: String?
    public var harness: String
    public var via: Via
    public var items: [QuestionItem]
    public var answerable: Bool
    public var source: Source
    public var askedAt: Date
    public var expiresAt: Date?             // permissions only

    public init(id: QuestionID, session: String, terminal: String? = nil, harness: String, via: Via, items: [QuestionItem],
                answerable: Bool, source: Source, askedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.session = session
        self.terminal = terminal
        self.harness = harness
        self.via = via
        self.items = items
        self.answerable = answerable
        self.source = source
        self.askedAt = askedAt
        self.expiresAt = expiresAt
    }
}

/// GET /v1/questions.
public struct DaemonQuestionsPage: Codable, Hashable, Sendable {
    public var questions: [DaemonQuestion]
    public init(questions: [DaemonQuestion]) { self.questions = questions }
}

/// POST /v1/questions/{id}/answer. The body of the call is a RunnerAnswer.
public struct DaemonAnswerResult: Codable, Hashable, Sendable {
    public enum Result: String, Codable, Sendable { case sent, alreadyAnswered, gone, error }

    public var result: Result
    public var code: String?                // with error, for example form_changed
    public var message: String?

    public init(result: Result, code: String? = nil, message: String? = nil) {
        self.result = result
        self.code = code
        self.message = message
    }
}

/// The body of POST /v1/sessions/{id}/ask.
public struct SessionAsk: Codable, Hashable, Sendable {
    public var text: String
    public var timeoutSec: Int?
    public var readOnly: Bool?

    public init(text: String, timeoutSec: Int? = nil, readOnly: Bool? = nil) {
        self.text = text
        self.timeoutSec = timeoutSec
        self.readOnly = readOnly
    }
}

/// The answer of POST /v1/sessions/{id}/ask. A 409 or 504 has error and screenTail, no reply.
public struct SessionAskReply: Codable, Hashable, Sendable {
    public var reply: String?
    public var turnEndedAt: Date?
    public var screenTail: String?
    public var error: String?               // busy, timeout
    public var message: String?

    public init(reply: String? = nil, turnEndedAt: Date? = nil, screenTail: String? = nil, error: String? = nil, message: String? = nil) {
        self.reply = reply
        self.turnEndedAt = turnEndedAt
        self.screenTail = screenTail
        self.error = error
        self.message = message
    }
}

/// GET /v1/orders/{id}: the state of a direct work order, and its result when it ended.
public struct DaemonOrderState: Codable, Hashable, Sendable {
    public var state: WorkOrder.State
    public var result: WorkOrderResult?

    public init(state: WorkOrder.State, result: WorkOrderResult? = nil) {
        self.state = state
        self.result = result
    }
}

import Foundation

/// One env row of an agent. A secret row has no value here: the value is on the home daemon.
public struct EnvVar: Codable, Hashable, Sendable {
    public var key: String
    public var value: String?
    public var secret: Bool

    public init(key: String, value: String? = nil, secret: Bool = false) {
        self.key = key
        self.value = secret ? nil : value
        self.secret = secret
    }
}

/// One secret value on the home daemon (actions.json AgentSecretRef).
public struct AgentSecretRef: Codable, Hashable, Sendable {
    public static let shared = "shared"

    /// The agent name. `AgentDef.allAgents` is the env for all agents.
    public var agent: String
    /// `shared`, or the device id of the app of an agent of one Mac only.
    public var scope: String

    public init(agent: String, scope: String) {
        self.agent = agent
        self.scope = scope
    }
}

/// A shared agent in the home store (OVERSIRE-399). The id is the name. The id `*` holds the env for all agents.
public struct AgentDef: StoreRecord {
    public static let collection = "agents"
    public static let allAgents = "*"

    public var name: String
    public var cli: String?          // a Harness raw value; nil: terminal only
    public var command: String?      // nil: the default of the CLI
    public var model: String?        // nil: Auto
    public var effort: String?       // nil: Auto
    public var runsOn: [String]?     // machine names; nil: any machine
    public var env: [EnvVar]
    public var updatedAt: Date
    public var updatedBy: String?

    public var id: String { name }

    public init(name: String, cli: String? = nil, command: String? = nil, model: String? = nil, effort: String? = nil,
                runsOn: [String]? = nil, env: [EnvVar] = [], updatedAt: Date = Date(), updatedBy: String? = nil) {
        self.name = name
        self.cli = cli
        self.command = command
        self.model = model
        self.effort = effort
        self.runsOn = runsOn
        self.env = env
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    public func runs(on machine: String) -> Bool { runsOn.map { $0.contains(machine) } ?? true }

    /// The same agent, without the edit stamp.
    public func sameDefinition(as o: AgentDef) -> Bool {
        var a = self, b = o
        a.updatedAt = .distantPast; a.updatedBy = nil
        b.updatedAt = .distantPast; b.updatedBy = nil
        return a == b
    }
}

/// A problem of one env row. A warning does not block the save.
public enum EnvProblem: Error, Hashable, Sendable, CustomStringConvertible {
    case badKey(String)
    case reserved(String)
    case duplicate(String)
    case unknownPlaceholder(key: String, name: String)
    case tooLong(String)
    case tooMany
    case noValue(String)
    case pathReplaced

    public var isWarning: Bool { self == .pathReplaced }

    public var key: String? {
        switch self {
        case .badKey(let k), .reserved(let k), .duplicate(let k), .tooLong(let k), .noValue(let k): k
        case .unknownPlaceholder(let k, _): k
        case .pathReplaced: "PATH"
        case .tooMany: nil
        }
    }

    public var description: String {
        switch self {
        case .badKey: "A key starts with a letter or _. It has only A–Z, a–z, 0–9 and _."
        case .reserved: "The daemon sets this key for each session. Keys that start with OVERSIRE_ or AGENT_VISOR_ are not available."
        case .duplicate(let k): "\(k) is in this agent two times. Remove one."
        case .unknownPlaceholder(_, let n): "Unknown placeholder {\(n)}. Use {name}, {KEY}, {key} or {title}."
        case .tooLong: "The value is too long. The limit is \(AgentEnv.maxValue) characters."
        case .tooMany: "An agent has at most \(AgentEnv.maxRows) env rows."
        case .noValue(let k): "Type a value for \(k), or mark it as a secret."
        case .pathReplaced: "PATH replaces the PATH of the daemon. The agent CLI can go missing. Add $PATH to keep it: /opt/bin:$PATH."
        }
    }
}

/// The env rules and the merge of the env for all agents with the env of one agent.
public enum AgentEnv {
    public static let maxRows = 64
    public static let maxValue = 8192
    public static let reservedPrefixes = ["OVERSIRE_", "AGENT_VISOR_"]
    public static let reservedKeys: Set<String> = ["ORCA_PANE_KEY"]

    public static func validKey(_ k: String) -> Bool {
        guard let f = k.unicodeScalars.first, k.count <= 200 else { return false }
        let letters = CharacterSet(charactersIn: "a"..."z").union(CharacterSet(charactersIn: "A"..."Z")).union(CharacterSet(charactersIn: "_"))
        let rest = letters.union(CharacterSet(charactersIn: "0"..."9"))
        return letters.contains(f) && k.unicodeScalars.allSatisfy(rest.contains)
    }

    public static func reserved(_ k: String) -> Bool {
        reservedKeys.contains(k) || reservedPrefixes.contains { k.hasPrefix($0) }
    }

    nonisolated(unsafe) static let placeholder = /(\$?)\{([A-Za-z_][A-Za-z0-9_]*)\}/

    /// The {x} names in a value. A brace that does not hold a name (JSON, ${HOME}) is not a placeholder.
    static func placeholders(_ v: String) -> [String] {
        v.matches(of: placeholder).filter { $0.1.isEmpty }.map { String($0.2) }
    }

    /// The problems of the rows, in row order. Warnings come after the errors of the same row.
    public static func problems(_ env: [EnvVar]) -> [EnvProblem] {
        var out: [EnvProblem] = []
        var seen = Set<String>()
        if env.count > maxRows { out.append(.tooMany) }
        for v in env {
            if !validKey(v.key) { out.append(.badKey(v.key)); continue }
            if reserved(v.key) { out.append(.reserved(v.key)) }
            if !seen.insert(v.key).inserted { out.append(.duplicate(v.key)) }
            guard !v.secret else { continue }
            guard let value = v.value else { out.append(.noValue(v.key)); continue }
            if value.count > maxValue { out.append(.tooLong(v.key)) }
            for n in placeholders(value) where !LaunchCommand.keys.contains(n) {
                out.append(.unknownPlaceholder(key: v.key, name: n))
            }
            if v.key == "PATH", !value.contains("$PATH"), !value.contains("${PATH}") { out.append(.pathReplaced) }
        }
        return out
    }

    public static func errors(_ env: [EnvVar]) -> [EnvProblem] { problems(env).filter { !$0.isWarning } }

    /// The value with {name}, {KEY}, {key} and {title} filled. No shell quotes: the value goes to the process env.
    public static func fill(_ v: String, name: String, key: String, title: String) -> String {
        let values = ["name": name, "KEY": key, "key": key.lowercased(), "title": title]
        return v.replacing(placeholder) { m in m.1.isEmpty ? values[String(m.2)] ?? String(m.0) : String(m.0) }
    }

    /// The env for all agents, then the env of the agent: the agent wins on the same key.
    /// Plain rows give values, secret rows give references to home.
    public static func merged(shared: [EnvVar], agent: [EnvVar], agentRef: AgentSecretRef, sharedScope: String = AgentSecretRef.shared,
                              name: String, key: String, title: String) -> (env: [String: String], secrets: [String: AgentSecretRef]) {
        var env: [String: String] = [:]
        var secrets: [String: AgentSecretRef] = [:]
        let all = AgentSecretRef(agent: AgentDef.allAgents, scope: sharedScope)
        for (rows, ref) in [(shared, all), (agent, agentRef)] {
            for v in rows where validKey(v.key) && !reserved(v.key) {
                if v.secret {
                    env[v.key] = nil
                    secrets[v.key] = ref
                } else if let value = v.value {
                    secrets[v.key] = nil
                    env[v.key] = fill(value, name: name, key: key, title: title)
                }
            }
        }
        return (env, secrets)
    }

    /// A command that starts with KEY=value. The env goes in the env rows.
    public static func commandSetsEnv(_ template: String) -> Bool {
        guard let first = template.split(whereSeparator: \.isWhitespace).first, let eq = first.firstIndex(of: "=") else { return false }
        return validKey(String(first[..<eq]))
    }
}

/// The body of PUT /v1/agent-secrets/{scope}/{agent}/{key} on home.
public struct AgentSecretSet: Codable, Hashable, Sendable {
    public var value: String
    public init(value: String) { self.value = value }
}

/// One secret on home, with no value.
public struct AgentSecretKey: Codable, Hashable, Sendable {
    public var scope: String
    public var agent: String
    public var key: String
    public var setAt: Date

    public init(scope: String, agent: String, key: String, setAt: Date) {
        self.scope = scope
        self.agent = agent
        self.key = key
        self.setAt = setAt
    }
}

/// The answer of GET /v1/agent-secrets: the keys, never the values.
public struct AgentSecretList: Codable, Hashable, Sendable {
    public var secrets: [AgentSecretKey]
    public init(secrets: [AgentSecretKey]) { self.secrets = secrets }
}

/// The body of POST /v1/agent-secrets/resolve. Only a daemon of the group calls it.
public struct AgentSecretResolve: Codable, Hashable, Sendable {
    public var order: String?
    public var machine: String
    public var refs: [String: AgentSecretRef]

    public init(order: String? = nil, machine: String, refs: [String: AgentSecretRef]) {
        self.order = order
        self.machine = machine
        self.refs = refs
    }
}

/// The answer of POST /v1/agent-secrets/resolve.
public struct AgentSecretValues: Codable, Hashable, Sendable {
    public var env: [String: String]
    public init(env: [String: String]) { self.env = env }
}

import Foundation

/// The vendor CLI of a provider. `oversire vendor run` runs it with the token of the account from the Keychain.
public struct VendorCLI: Hashable, Sendable {
    /// A name, never a path.
    public let binary: String
    /// Nil: the CLI keeps its own login (gh).
    public let tokenEnv: String?
    public let hostEnv: String?
    /// The key of the ConfigField that holds the host.
    public let hostField: String?
    public let defaultHost: String?
    /// Gets `values["workspace"]`, else the account id.
    public let accountEnv: String?
    /// Gets the project identifier of `--project`.
    public let projectEnv: String?
    /// Gets "OverSire". The CLI then runs in its managed mode.
    public let managedEnv: String?
    /// Names that the app copies from its own environment.
    public let passEnv: [String]
    public let lockedFlags: [String]
    public let deniedCommands: [[String]]
    /// The lowest version that the app runs. Nil: the app runs any version.
    public let minVersion: String?
    /// The flags that the app sets when the call has `--project`.
    public let projectFlags: [String]
    /// The args that print the agent reference of the CLI. Nil: the app does not run one.
    public let skillCommand: [String]?
    /// Where `oversire vendor install` gets the CLI. Nil: OverSire does not install it.
    public let release: VendorRelease?

    public static let helpFlags: Set<String> = ["--help", "-h"]

    public init(binary: String, tokenEnv: String? = nil, hostEnv: String? = nil, hostField: String? = nil,
                defaultHost: String? = nil, accountEnv: String? = nil, projectEnv: String? = nil,
                managedEnv: String? = nil, passEnv: [String] = [], lockedFlags: [String] = [],
                deniedCommands: [[String]] = [], minVersion: String? = nil,
                projectFlags: [String] = [], skillCommand: [String]? = nil, release: VendorRelease? = nil) {
        self.binary = binary
        self.tokenEnv = tokenEnv
        self.hostEnv = hostEnv
        self.hostField = hostField
        self.defaultHost = defaultHost
        self.accountEnv = accountEnv
        self.projectEnv = projectEnv
        self.managedEnv = managedEnv
        self.passEnv = passEnv
        self.lockedFlags = lockedFlags
        self.deniedCommands = deniedCommands
        self.minVersion = minVersion
        self.projectFlags = projectFlags
        self.skillCommand = skillCommand
        self.release = release
    }

    /// The leading args that do not start with "-".
    public static func command(_ args: [String]) -> [String] {
        Array(args.prefix { !$0.hasPrefix("-") })
    }

    /// The words of the event summary: the leading command words of only lower-case letters and hyphens, at most 3.
    public static func summaryWords(_ args: [String]) -> [String] {
        if let first = args.first, helpFlags.contains(first) { return ["help"] }
        return Array(command(args).prefix { w in w.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "-" } }.prefix(3))
    }

    /// Why the app does not run these args, or nil.
    /// `project`: the call has `--project`. The app then refuses `projectFlags` too.
    public func refusal(_ args: [String], project: Bool) -> VendorRefusal? {
        guard let first = args.first else { return .noArgs }
        if first.hasPrefix("-") && !Self.helpFlags.contains(first) { return .flagFirst }
        let locked = Set(lockedFlags.map(Self.flagName))
        let projectOnly = project ? Set(projectFlags.map(Self.flagName)) : []
        for a in args where a.hasPrefix("-") {
            let name = Self.flagName(a), flag = String(a.prefix { $0 != "=" })
            if locked.contains(name) { return .lockedFlag(flag) }
            if projectOnly.contains(name) { return .projectFlag(flag) }
        }
        let words = Self.command(args).map { $0.lowercased() }
        for d in deniedCommands where words.starts(with: d) { return .deniedCommand(d.joined(separator: " ")) }
        return nil
    }

    /// The flag without its dashes and without a value after "=".
    static func flagName(_ arg: String) -> String {
        String(arg.drop { $0 == "-" }.prefix { $0 != "=" })
    }

    /// The environment of one run: `base`, then the `passEnv` names from `inherited`, then the host, account,
    /// project, managed and token values. No other key.
    public func environment(_ config: AccountConfig, project: String?, token: String?,
                            base: [String: String], inherited: [String: String]) -> [String: String] {
        var env = base
        for name in passEnv { if let v = inherited[name] { env[name] = v } }
        if let hostEnv {
            let v = hostField.flatMap { config.values[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let host = v.isEmpty ? defaultHost : v { env[hostEnv] = host }
        }
        if let accountEnv {
            let w = config.values["workspace"] ?? ""
            env[accountEnv] = w.isEmpty ? config.account.id : w
        }
        if let projectEnv, let project { env[projectEnv] = project }
        if let managedEnv { env[managedEnv] = "OverSire" }
        if let tokenEnv, let token, !token.isEmpty { env[tokenEnv] = token }
        return env
    }

    /// The environment of the skill command: `base` and the managed value. No token, host or account.
    public func skillEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        if let managedEnv { env[managedEnv] = "OverSire" }
        return env
    }
}

/// The source of a vendor CLI for `oversire vendor install`.
public enum VendorRelease: Hashable, Sendable {
    /// An entry of the signed Trebi catalog.
    case trebiCatalog(entry: String)
    /// The newest `<tagPrefix><version>` release. `asset` has the slots `{version}` and `{arch}`.
    case githubRelease(repo: String, tagPrefix: String, asset: String)
    /// OverSire does not install it. The user installs the formula with Homebrew.
    case homebrew(formula: String)
}

public enum VendorRefusal: Hashable, Sendable {
    case noArgs
    /// The args start with a flag. The command must come first.
    case flagFirst
    case lockedFlag(String)
    /// The denied words, joined with a space.
    case deniedCommand(String)
    /// A flag of `projectFlags` in a call with `--project`.
    case projectFlag(String)

    public var message: String {
        switch self {
        case .noArgs: return "Give the vendor command after --."
        case .flagFirst: return "Put the command first, then its flags."
        case .lockedFlag(let f): return "OverSire sets \(f). Do not give it."
        case .deniedCommand(let c): return "OverSire does not run the command \(c)."
        case .projectFlag(let f): return "OverSire sets \(f) from --project. Do not give it."
        }
    }
}

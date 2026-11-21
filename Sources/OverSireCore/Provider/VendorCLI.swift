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

    public init(binary: String, tokenEnv: String? = nil, hostEnv: String? = nil, hostField: String? = nil,
                defaultHost: String? = nil, accountEnv: String? = nil, projectEnv: String? = nil,
                managedEnv: String? = nil, passEnv: [String] = [], lockedFlags: [String] = [],
                deniedCommands: [[String]] = []) {
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
    }

    /// The leading args that do not start with "-".
    public static func command(_ args: [String]) -> [String] {
        Array(args.prefix { !$0.hasPrefix("-") })
    }

    /// The words of the event summary: the leading command words of only lower-case letters and hyphens, at most 3.
    public static func summaryWords(_ args: [String]) -> [String] {
        Array(command(args).prefix { w in w.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "-" } }.prefix(3))
    }

    /// Why the app does not run these args, or nil.
    public func refusal(_ args: [String]) -> VendorRefusal? {
        guard let first = args.first else { return .noArgs }
        if first.hasPrefix("-") { return .flagFirst }
        let locked = Set(lockedFlags.map(Self.flagName))
        for a in args where a.hasPrefix("-") && locked.contains(Self.flagName(a)) {
            return .lockedFlag(String(a.prefix { $0 != "=" }))
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
}

public enum VendorRefusal: Hashable, Sendable {
    case noArgs
    /// The args start with a flag. The command must come first.
    case flagFirst
    case lockedFlag(String)
    /// The denied words, joined with a space.
    case deniedCommand(String)

    public var message: String {
        switch self {
        case .noArgs: return "Give the vendor command after --."
        case .flagFirst: return "Put the command first, then its flags."
        case .lockedFlag(let f): return "OverSire sets \(f). Do not give it."
        case .deniedCommand(let c): return "OverSire does not run the command \(c)."
        }
    }
}

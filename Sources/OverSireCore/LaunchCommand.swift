import Foundation

/// A start command template, for example "claude -n {name} --model opus".
/// A terminal runtime types the resolved text into a shell.
public struct LaunchCommand: Hashable, Sendable, Codable {
    public var template: String

    public static let keys = ["name", "KEY", "key", "title"]
    public static let shellOperators = [";", "|", "&", "`", "$(", ">", "<", "\n"]
    /// Flags that let the agent act without a permission prompt.
    public static let permissionSkips = ["--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox",
                                         "--yolo", "--permission-mode bypassPermissions"]

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case empty
        case noProgram
        case unknownKey(String)
        case openQuote
        case shellOperator(String)

        public var description: String {
            switch self {
            case .empty: "Type a command."
            case .noProgram: "Start with a program name."
            case .unknownKey(let k): "Unknown placeholder {\(k)}. Use {name}, {KEY}, {key} or {title}."
            case .openQuote: "A quote is open. Close it, or remove it."
            case .shellOperator(let op): "Remove the shell operator \(op == "\n" ? "newline" : op)."
            }
        }
    }

    public init(_ template: String) { self.template = template }
    public init(from decoder: Decoder) throws { template = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(template)
    }

    public static func defaultFor(_ agent: AgentName) -> LaunchCommand {
        LaunchCommand(agent == .claude ? "claude -n {name}" : agent.rawValue)
    }

    public static let intakeDefault = LaunchCommand("claude -n {name} --permission-mode plan")

    var trimmed: String { template.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The first word.
    public var program: String { String(trimmed.prefix { !$0.isWhitespace }) }

    public var skipsPermissions: Bool {
        let t = " " + trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
        return Self.permissionSkips.contains { t.contains(" \($0) ") }
    }

    public func validate() throws {
        let t = trimmed
        guard !t.isEmpty else { throw Problem.empty }
        guard let c = t.unicodeScalars.first, CharacterSet(charactersIn: "_./~-").union(.alphanumerics).contains(c) else {
            throw Problem.noProgram
        }
        if let op = Self.shellOperators.first(where: { t.contains($0) }) { throw Problem.shellOperator(op) }
        for k in placeholders where !Self.keys.contains(k) { throw Problem.unknownKey(k) }
        if t.filter({ $0 == "'" }).count % 2 == 1 || t.filter({ $0 == "\"" }).count % 2 == 1 { throw Problem.openQuote }
    }

    /// The text with each {x} replaced by the shell-quoted value.
    public func resolve(name: String, key: String, title: String) throws -> String {
        try validate()
        let values = ["name": name, "KEY": key, "key": key.lowercased(), "title": title]
        var out = ""
        var rest = Substring(trimmed)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let k = String(rest[rest.index(after: open)..<close])
            out += Self.quote(values[k] ?? "")
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    var placeholders: [String] {
        var keys: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            keys.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return keys
    }

    /// A value of [A-Za-z0-9._/:-] stays bare. Else it goes in single quotes without its own quotes.
    /// Shell operators become spaces, so the runner check accepts a quoted title.
    public static func quote(_ v: String) -> String {
        let bare = CharacterSet(charactersIn: "._/:-").union(CharacterSet(charactersIn: "a"..."z"))
            .union(CharacterSet(charactersIn: "A"..."Z")).union(CharacterSet(charactersIn: "0"..."9"))
        if !v.isEmpty, v.unicodeScalars.allSatisfy(bare.contains) { return v }
        var s = v.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\r", with: "\n")
        for op in shellOperators { s = s.replacingOccurrences(of: op, with: " ") }
        return "'" + s + "'"
    }
}

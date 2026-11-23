import Foundation

/// The fixed worktree folder of one item, in the home store. The app writes it when it makes the item.
public struct WorktreeBinding: StoreRecord {
    public static let collection = "worktree-bindings"

    public enum Mode: String, Codable, Sendable { case own, parent }
    public enum Source: String, Codable, Sendable { case create, intake, session, auto, link }

    public let key: String
    public var machine: String
    public var root: String
    public var group: String         // relative to root, or absolute
    public var branch: String        // "" : none
    public var parent: String?
    public var mode: Mode
    public var source: Source
    public var updatedAt: Date
    public var updatedBy: String?

    public var id: String { key }

    public init(key: String, machine: String, root: String, group: String, branch: String = "", parent: String? = nil,
                mode: Mode = .own, source: Source = .create, updatedAt: Date = Date(), updatedBy: String? = nil) {
        self.key = key.uppercased()
        self.machine = machine
        self.root = root
        self.group = group
        self.branch = branch
        self.parent = parent
        self.mode = mode
        self.source = source
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    /// The absolute folder of the group.
    public var dir: String {
        group.hasPrefix("/") ? group : (root as NSString).appendingPathComponent(group)
    }

    public static func defaultGroup(_ key: String) -> String { ".wt/\(key.lowercased())" }

    /// The group folder from a template with `{key}`. Nil when the result is empty or has a `..` part.
    public static func group(from template: String, key: String) -> String? {
        let raw = template.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{key}", with: key.lowercased())
            .replacingOccurrences(of: "{KEY}", with: key.uppercased())
        guard !raw.isEmpty, !raw.split(separator: "/").contains("..") else { return nil }
        return raw
    }
}

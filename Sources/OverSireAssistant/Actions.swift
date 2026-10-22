import Foundation
import OverSireCore
import OverSireAI

// ─── Action catalog ──────────────────────────────────────────────────────────
// Each button of the app and each tool of the assistant is one ActionSpec. An action shows no UI:
// a choice that a menu made is an arg. The app holds the specs (AppActionCatalog).

/// Who runs an action.
public enum ActionCaller: Hashable, Sendable {
    case user
    case assistant(thread: String)
}

public struct ActionArgs: Sendable {
    public var values: JSONValue
    public var caller: ActionCaller

    public init(_ values: JSONValue = .object([:]), caller: ActionCaller = .user) {
        self.values = values
        self.caller = caller
    }

    public subscript(_ key: String) -> JSONValue? { values[key] }
    public func string(_ key: String) -> String? { values[key]?.string }
    public func int(_ key: String) -> Int? { values[key]?.int }
    public func bool(_ key: String) -> Bool? { values[key]?.bool }
}

public enum ActionResult: Sendable, Equatable {
    /// `parts` go into the chat after the result, for example a navigation part.
    case ok(summary: String, data: JSONValue? = nil, parts: [AssistantPart] = [])
    case failed(String)
    /// The action does not apply here: no capability, the wrong state, a missing arg.
    case notAllowed(String)

    public var summary: String {
        switch self {
        case .ok(let s, _, _), .failed(let s), .notAllowed(let s): return s
        }
    }
}

public struct ActionSpec: Sendable {
    /// For example item.setStatus, pr.merge, queue.add.
    public let id: String
    public let title: String
    /// For the model and for the ⌘K palette.
    public let help: String
    public let kind: ActionKind
    /// A JSON Schema object for the args.
    public let input: JSONValue
    /// The action hides when no provider has the capability.
    public let capability: Capability?
    public let perform: @Sendable (ActionArgs) async -> ActionResult

    public init(id: String, title: String, help: String, kind: ActionKind, input: JSONValue = ActionSpec.noArgs,
                capability: Capability? = nil, perform: @escaping @Sendable (ActionArgs) async -> ActionResult) {
        self.id = id
        self.title = title
        self.help = help
        self.kind = kind
        self.input = input
        self.capability = capability
        self.perform = perform
    }

    public static let noArgs: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    /// A schema object with `properties` as name → (type, help). `required` lists the names that must be set.
    public static func args(_ properties: [String: (String, String)], required: [String] = []) -> JSONValue {
        var props: [String: JSONValue] = [:]
        for (name, p) in properties {
            props[name] = .object(["type": .string(p.0), "description": .string(p.1)])
        }
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(props)]
        if !required.isEmpty { schema["required"] = .array(required.sorted().map(JSONValue.string)) }
        return .object(schema)
    }
}

public protocol ActionCatalog: Sendable {
    /// The actions that apply now. `page` nil: all actions.
    func specs(for page: PageContext?) async -> [ActionSpec]
    func run(_ id: String, _ args: ActionArgs) async -> ActionResult
}

extension ActionCatalog {
    public func run(_ id: String, _ args: ActionArgs) async -> ActionResult {
        guard let spec = await specs(for: nil).first(where: { $0.id == id }) else { return .notAllowed("No action \(id).") }
        return await spec.perform(args)
    }
}

/// A fixed list of actions.
public struct ActionList: ActionCatalog {
    public let all: [ActionSpec]

    public init(_ all: [ActionSpec]) { self.all = all }

    public func specs(for page: PageContext?) async -> [ActionSpec] { all }
}

/// What the window shows. The app fills it. The assistant gets it in the system prompt and from page.current.
public struct PageContext: Hashable, Sendable, Codable {
    public struct Row: Hashable, Sendable, Codable {
        public var id: String
        /// One line.
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// The path form of the route, for example item/OVERSIRE-153/session.
    public var route: String
    public var title: String
    public var rows: [Row]
    public var selection: [String]

    public init(route: String, title: String, rows: [Row] = [], selection: [String] = []) {
        self.route = route
        self.title = title
        self.rows = rows
        self.selection = selection
    }

    /// The text for the system prompt. At most `maxRows` rows.
    public func promptText(maxRows: Int = 20) -> String {
        var s = "\(title) (route \(route))."
        if !selection.isEmpty { s += " Selected: \(selection.joined(separator: ", "))." }
        if !rows.isEmpty {
            s += " Rows in view:"
            for r in rows.prefix(maxRows) { s += "\n- \(r.id): \(r.text)" }
            if rows.count > maxRows { s += "\n- and \(rows.count - maxRows) more" }
        }
        return s
    }
}

import Foundation
import OverSireAI

/// The tools of one turn, from the action specs. The model APIs allow only [A-Za-z0-9_-] in a tool name,
/// so the tool name is the action id with _ in place of the dots.
/// settings actions are not tools: the assistant never runs them.
public struct ToolRegistry: Sendable {
    public let specs: [ActionSpec]
    private let byTool: [String: ActionSpec]

    public init(_ specs: [ActionSpec]) {
        self.specs = specs.filter { $0.kind != .settings }
        byTool = Dictionary(self.specs.map { (Self.toolName($0.id), $0) }, uniquingKeysWith: { a, _ in a })
    }

    public static func toolName(_ actionID: String) -> String { actionID.replacingOccurrences(of: ".", with: "_") }

    public var tools: [ToolSpec] {
        specs.map { ToolSpec(name: Self.toolName($0.id), title: $0.title, description: $0.help, kind: $0.kind, input: $0.input) }
    }

    /// Takes a tool name or an action id.
    public func spec(_ name: String) -> ActionSpec? { byTool[name] ?? byTool[Self.toolName(name)] }
}

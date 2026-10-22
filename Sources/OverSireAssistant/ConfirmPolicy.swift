import Foundation
import OverSireAI

/// The answer of the developer to an approval card.
public enum ApprovalAnswer: String, Sendable, Codable {
    case approve
    /// Approve, and do not ask again for this action in this chat.
    case approveForChat
    case deny
}

/// Shows an approval card and waits for the answer. `canAllowForChat` false hides "Allow in this chat".
public typealias ApprovalAsk = @Sendable (_ call: ToolCall, _ note: String?, _ canAllowForChat: Bool) async -> ApprovalAnswer

public struct ConfirmDecision: Sendable, Equatable {
    public var approval: Approval
    /// Add the action id to the allow list of the thread.
    public var allowForChat: Bool

    public init(_ approval: Approval, allowForChat: Bool = false) {
        self.approval = approval
        self.allowForChat = allowForChat
    }

    public var runs: Bool { approval.decision != .denied }
}

public protocol ConfirmPolicy: Sendable {
    func decide(_ call: ToolCall, action: String, kind: ActionKind, thread: AssistantThread, note: String?,
                ask: ApprovalAsk) async -> ConfirmDecision
}

/// The permission of one action kind.
public enum PermissionRule: String, Sendable, Codable, CaseIterable {
    case allow
    /// Ask once in each chat.
    case askOnce
    case askEach
    case never
}

/// The permissions that the developer can set. outward is always askEach and settings always never.
public struct AssistantPermissions: Hashable, Sendable, Codable {
    public var read: PermissionRule
    public var change: PermissionRule

    public init(read: PermissionRule = .allow, change: PermissionRule = .askOnce) {
        self.read = read
        self.change = change
    }

    public func rule(_ kind: ActionKind) -> PermissionRule {
        switch kind {
        case .read: return read
        case .change: return change
        case .outward: return .askEach
        case .settings: return .never
        }
    }
}

/// Decision D of OVERSIRE-262: read runs, change asks once in each chat, outward asks each time, settings never runs.
public struct RuleConfirmPolicy: ConfirmPolicy {
    let permissions: @Sendable () -> AssistantPermissions

    public init(permissions: @escaping @Sendable () -> AssistantPermissions = { AssistantPermissions() }) {
        self.permissions = permissions
    }

    public func decide(_ call: ToolCall, action: String, kind: ActionKind, thread: AssistantThread, note: String?,
                       ask: ApprovalAsk) async -> ConfirmDecision {
        switch permissions().rule(kind) {
        case .allow:
            return ConfirmDecision(Approval(call: call.id, decision: .allowedByRule, by: "kind:\(kind.rawValue)"))
        case .never:
            return ConfirmDecision(Approval(call: call.id, decision: .denied, by: "kind:\(kind.rawValue)"))
        case .askOnce where thread.allow.contains(action):
            return ConfirmDecision(Approval(call: call.id, decision: .allowedByRule, by: "chat:\(action)"))
        case .askOnce, .askEach:
            let once = permissions().rule(kind) == .askOnce
            switch await ask(call, note, once) {
            case .approve: return ConfirmDecision(Approval(call: call.id, decision: .approved, by: "user"))
            case .approveForChat: return ConfirmDecision(Approval(call: call.id, decision: .approved, by: "user"), allowForChat: once)
            case .deny: return ConfirmDecision(Approval(call: call.id, decision: .denied, by: "user"))
            }
        }
    }
}

import Foundation
import OverSireCore

extension AITaskKind {
    /// The prompt of the kind for the input. Each kind has an AIInput builder next to its prompt.
    public func prompt(_ input: AIInput) throws -> AIPrompt {
        switch self {
        case .ping: return AIPrompt(system: "Reply with OK.", user: "ping", maxTokens: 32)
        case .draft: return DraftContext.prompt(input)
        case .tidy: return DraftContext.tidyPrompt(input)
        case .check: return AgentPrompts.check(input)
        case .order: return AgentPrompts.order(input)
        case .sessionSummary: return AgentPrompts.sessionSummary(input)
        case .question: return AgentPrompts.question(input)
        case .triage: return AgentPrompts.triage(input)
        case .failureReason: return CIPrompts.failureReason(input)
        case .digest: return CIPrompts.digest(input)
        default: throw AIError.unsupported(self)
        }
    }
}

extension AIInput {
    public subscript(_ key: String) -> String { context[key] ?? "" }

    /// The system text with the extra instructions of the user.
    func withExtra(_ system: String) -> String {
        let e = self["extra"].trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? system : system + "\n\nExtra instructions from the user:\n" + e
    }
}

/// The whole reply, without a code fence around it.
public func unfenced(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return t }
    t = String(t.dropFirst(3).dropLast(3))
    if let nl = t.firstIndex(of: "\n"), !t[..<nl].contains(" ") { t = String(t[t.index(after: nl)...]) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The first `{` to the last `}` of an unfenced reply, as a JSON object.
public func replyObject(_ text: String) -> [String: Any]? {
    let t = unfenced(text)
    guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(t[a...b].utf8)) as? [String: Any]
}

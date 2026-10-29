import Foundation

/// One problem of a runbook. `step` is nil for a problem of the whole runbook.
public struct RunbookProblem: Hashable, Sendable {
    public var step: String?
    public var text: String

    public init(step: String? = nil, _ text: String) {
        self.step = step
        self.text = text
    }
}

extension Runbook {
    /// The placeholders of a step prompt. The daemon renders them (cli/runbook/prompt.go).
    public static let placeholders = ["key", "url", "title", "item", "workspace", "project", "round", "notes", "worktree", "done"]
    public static let maxRounds = 5

    /// The rules of the runbook editor and of runbook.validate. The daemon checks the same rules, minus the agents.
    /// `agents` are the agent names of Settings › Agents.
    public func validate(agents: Set<String>) -> [RunbookProblem] {
        var out: [RunbookProblem] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append(RunbookProblem("The runbook has no name.")) }
        if steps.isEmpty { out.append(RunbookProblem("The runbook has no steps.")) }
        var seen = Set<String>()
        var fixes: [String: String] = [:]   // fix step → review step
        for (i, s) in steps.enumerated() {
            let label = s.name.isEmpty ? s.id : s.name
            if s.id.isEmpty || s.id.contains(where: { !Self.idCharacters.contains($0) }) {
                out.append(RunbookProblem(step: s.id, "\(label): the id must use only a-z, 0-9 and -."))
            }
            if !seen.insert(s.id).inserted { out.append(RunbookProblem(step: s.id, "\(label): two steps have the id \(s.id).")) }
            if s.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append(RunbookProblem(step: s.id, "Step \(i + 1) has no name.")) }
            if !agents.contains(s.agent) { out.append(RunbookProblem(step: s.id, "\(label): there is no agent \(s.agent).")) }
            if !s.prompt.contains("{done}") { out.append(RunbookProblem(step: s.id, "\(label): the prompt has no {done}.")) }
            for p in Self.unknownPlaceholders(s.prompt) { out.append(RunbookProblem(step: s.id, "\(label): {\(p)} is not a placeholder.")) }
            if i == 0 && s.pauses { out.append(RunbookProblem(step: s.id, "\(label): the first step cannot pause before it starts.")) }
            guard let r = s.review else { continue }
            if !(0...Self.maxRounds).contains(r.rounds) { out.append(RunbookProblem(step: s.id, "\(label): the rounds must be 0 to \(Self.maxRounds).")) }
            guard let j = index(of: r.fix), j > i else {
                out.append(RunbookProblem(step: s.id, "\(label): the fix step must be a step after the review."))
                continue
            }
            if steps[j].review != nil { out.append(RunbookProblem(step: s.id, "\(label): the fix step cannot be a review.")) }
            if let other = fixes[r.fix] {
                out.append(RunbookProblem(step: s.id, "\(label): \(steps[j].name) is the fix step of \(step(other)?.name ?? other) already."))
            }
            fixes[r.fix] = s.id
        }
        return out
    }

    private static let idCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    /// The {names} of the text that are not placeholders, in order.
    static func unknownPlaceholders(_ text: String) -> [String] {
        text.matches(of: /\{([A-Za-z_]+)\}/).map { String($0.1) }.filter { !placeholders.contains($0) }
    }
}

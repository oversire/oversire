import Foundation
import OverSireCore

/// Inputs and replies of the agent session prompts: checks, queue order, summaries, questions and intake triage.
public enum AgentPrompts {
    // MARK: Check

    /// The facts of a quiet agent. `tail`: the last terminal lines.
    /// `turn`: the last turn on the screen, without the harness UI. `message`: the last agent message of the runtime.
    public static func checkInput(key: String, title: String, quietMinutes: Int, phase: String, ticking: Bool, ci: String,
                                  prOpen: Bool, status: String, message: String, turn: String) -> AIInput {
        AIInput(text: String(turn.suffix(6000)),
                context: ["key": key, "title": title, "quiet": "\(quietMinutes)", "phase": phase, "ticking": ticking ? "yes" : "no",
                          "ci": ci, "prOpen": prOpen ? "yes" : "no", "status": status, "message": String(message.prefix(4000))])
    }

    // MARK: Session end

    public static func sessionEndInput(key: String, title: String, status: String, message: String, turn: String) -> AIInput {
        AIInput(text: String(turn.suffix(6000)),
                context: ["key": key, "title": title, "status": status, "message": String(message.prefix(4000))])
    }

    // MARK: Queue order

    /// `vision`: the project vision. `blockers`: the open blocker keys of each entry.
    public static func orderInput(_ entries: [QueueEntry], bodies: [String: String], vision: String? = nil,
                                  blockers: [String: [String]] = [:]) -> AIInput {
        let list = entries.map { e in
            let held = blockers[e.key].flatMap { $0.isEmpty ? nil : "Blocked by: \($0.joined(separator: ", "))\n" } ?? ""
            return "\(e.key): \(e.title)\n\(held)\(bodies[e.key]?.prefix(600) ?? "")"
        }.joined(separator: "\n\n")
        guard let vision, !vision.isEmpty else { return AIInput(text: list) }
        return AIInput(text: "Project vision:\n\(vision)\n\nTasks:\n\(list)")
    }

    /// The new order of `keys`, or nil when the reply is not a change of the same keys.
    public static func parseOrder(_ text: String, keys: [String]) -> (order: [String], reason: String)? {
        guard let obj = replyObject(text), let order = obj["order"] as? [String] else { return nil }
        let clean = order.map { $0.uppercased() }.filter(keys.contains)
        guard Set(clean) == Set(keys), clean != keys else { return nil }
        return (clean, obj["reason"] as? String ?? "")
    }

    // MARK: Session

    public static func sessionInput(key: String, title: String, transcript: String) -> AIInput {
        AIInput(text: transcript, context: ["key": key, "title": title])
    }

    public static func questionInput(transcript: String, question: String) -> AIInput {
        AIInput(text: transcript, context: ["question": question])
    }

    // MARK: Item

    /// The most description characters that go into one summary prompt.
    public static let summaryBudget = 24_000

    public static func summaryInput(key: String, title: String, body: String) -> AIInput {
        let text = body.count > summaryBudget ? String(body.prefix(summaryBudget)) + "\n[… the rest is left out …]" : body
        return AIInput(text: text, context: ["key": key, "title": title])
    }

    // MARK: Triage

    /// The template fields: {KEY}, {key}, {title}, {url}, {body} and {vision}. An agent in plan mode runs the prompt,
    /// so the filled template is the whole user text. {vision} becomes a "Project vision" block, or nothing.
    public static func triageInput(template: String, key: String, title: String, url: String, body: String,
                                   vision: String? = nil) -> AIInput {
        var prompt = template.replacingOccurrences(of: "{KEY}", with: key).replacingOccurrences(of: "{key}", with: key.lowercased())
            .replacingOccurrences(of: "{title}", with: title).replacingOccurrences(of: "{url}", with: url)
            .replacingOccurrences(of: "{body}", with: body.isEmpty ? "(no description)" : String(body.prefix(6000)))
        if prompt.contains("{vision}") {
            let block = vision.flatMap { $0.isEmpty ? nil : visionBlock($0) } ?? ""
            prompt = prompt.replacingOccurrences(of: "{vision}", with: block)
            while prompt.contains("\n\n\n") { prompt = prompt.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            prompt = prompt.trimmingCharacters(in: .newlines)
        }
        var context = ["prompt": prompt, "key": key, "title": title, "url": url]
        if let vision, !vision.isEmpty { context["vision"] = vision }
        return AIInput(text: body, context: context)
    }

    static func visionBlock(_ vision: String) -> String {
        """
        Project vision (the true north of the project):
        \(vision)
        If the ticket works against this vision, use the verdict off_vision. Give the one reason as the first finding.
        """
    }
}

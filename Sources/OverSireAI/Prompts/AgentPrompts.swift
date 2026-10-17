import Foundation
import OverSireCore

/// Inputs and replies of the agent session prompts: checks, queue order, summaries, questions and intake triage.
public enum AgentPrompts {
    // MARK: Check

    /// The facts of a quiet agent. `tail`: the last terminal lines.
    public static func checkInput(key: String, title: String, quietMinutes: Int, phase: String, ci: String, prOpen: Bool,
                                  status: String, tail: [String]) -> AIInput {
        AIInput(text: tail.suffix(60).joined(separator: "\n"),
                context: ["key": key, "title": title, "quiet": "\(quietMinutes)", "phase": phase, "ci": ci,
                          "prOpen": prOpen ? "yes" : "no", "status": status])
    }

    // MARK: Queue order

    public static func orderInput(_ entries: [QueueEntry], bodies: [String: String]) -> AIInput {
        AIInput(text: entries.map { "\($0.key): \($0.title)\n\(bodies[$0.key]?.prefix(600) ?? "")" }.joined(separator: "\n\n"))
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

    // MARK: Triage

    /// The template fields: {KEY}, {key}, {title}, {url} and {body}. An agent in plan mode runs the prompt,
    /// so the filled template is the whole user text.
    public static func triageInput(template: String, key: String, title: String, url: String, body: String) -> AIInput {
        let prompt = template.replacingOccurrences(of: "{KEY}", with: key).replacingOccurrences(of: "{key}", with: key.lowercased())
            .replacingOccurrences(of: "{title}", with: title).replacingOccurrences(of: "{url}", with: url)
            .replacingOccurrences(of: "{body}", with: body.isEmpty ? "(no description)" : String(body.prefix(6000)))
        return AIInput(text: body, context: ["prompt": prompt, "key": key, "title": title, "url": url])
    }
}

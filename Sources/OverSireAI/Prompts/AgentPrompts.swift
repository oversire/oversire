import Foundation
import OverSireCore

/// Prompts about agent sessions: checks, queue order, summaries, questions and intake triage.
public enum AgentPrompts {
    // MARK: Check

    /// The facts of a quiet agent. `tail`: the last terminal lines.
    public static func checkInput(key: String, title: String, quietMinutes: Int, phase: String, ci: String, prOpen: Bool,
                                  status: String, tail: [String]) -> AIInput {
        AIInput(text: tail.suffix(60).joined(separator: "\n"),
                context: ["key": key, "title": title, "quiet": "\(quietMinutes)", "phase": phase, "ci": ci,
                          "prOpen": prOpen ? "yes" : "no", "status": status])
    }

    static func check(_ i: AIInput) -> AIPrompt {
        let system = """
        You check a coding agent that went quiet. Decide if its task looks done or if it looks stuck.
        Reply with one JSON object only: {"verdict":"done|stuck","evidence":["short fact", "..."],"nudge":"one message to send to a stuck agent, or empty"}
        Use at most 4 facts. Use simple English.
        """
        var u = "Item \(i["key"]): \(i["title"])\nQuiet for \(i["quiet"]) min. Agent state: \(i["phase"]).\n"
        u += "CI: \(i["ci"]). PR open: \(i["prOpen"]). Plane status: \(i["status"]).\n"
        u += "Last terminal lines:\n" + i.text
        return AIPrompt(system: system, user: u, maxTokens: 600)
    }

    // MARK: Queue order

    public static func orderInput(_ entries: [QueueEntry], bodies: [String: String]) -> AIInput {
        AIInput(text: entries.map { "\($0.key): \($0.title)\n\(bodies[$0.key]?.prefix(600) ?? "")" }.joined(separator: "\n\n"))
    }

    static func order(_ i: AIInput) -> AIPrompt {
        let system = """
        You order a queue of coding tasks. Put a task first when other tasks need its result.
        Reply with one JSON object only: {"order":["KEY-1","KEY-2"],"reason":"one short sentence"}
        """
        return AIPrompt(system: system, user: i.text, maxTokens: 400)
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

    static func sessionSummary(_ i: AIInput) -> AIPrompt {
        let system = """
        You summarize a coding agent session for the team that tracks the work item.
        Use short sentences in plain technical English. Do not guess. Use only facts from the transcript.
        Reply with one JSON object only:
        {"done":["what the agent did"],"files":["changed file paths"],"decisions":["choices and why"],"questions":["open questions for a person"]}
        """
        return AIPrompt(system: system, user: "Item \(i["key"]): \(i["title"])\n\nTranscript:\n\(i.text)", maxTokens: 900)
    }

    public static func questionInput(transcript: String, question: String) -> AIInput {
        AIInput(text: transcript, context: ["question": question])
    }

    static func question(_ i: AIInput) -> AIPrompt {
        let system = "You answer a question about a coding agent session. Use only the transcript. Say so when the transcript does not tell. Be short."
        return AIPrompt(system: system, user: "Transcript:\n\(i.text)\n\nQuestion: \(i["question"])", maxTokens: 500)
    }

    // MARK: Triage

    /// The template fields: {KEY}, {key}, {title}, {url} and {body}.
    public static func triageInput(template: String, key: String, title: String, url: String, body: String) -> AIInput {
        AIInput(text: body, context: ["template": template, "key": key, "title": title, "url": url])
    }

    /// An agent in plan mode runs this prompt, so the user text is the whole prompt.
    static func triage(_ i: AIInput) -> AIPrompt {
        let key = i["key"]
        let user = i["template"].replacingOccurrences(of: "{KEY}", with: key).replacingOccurrences(of: "{key}", with: key.lowercased())
            .replacingOccurrences(of: "{title}", with: i["title"]).replacingOccurrences(of: "{url}", with: i["url"])
            .replacingOccurrences(of: "{body}", with: i.text.isEmpty ? "(no description)" : String(i.text.prefix(6000)))
        return AIPrompt(system: "", user: user)
    }
}

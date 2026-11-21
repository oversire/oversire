import Foundation
import OverSireCore

/// Inputs and replies of the agent session prompts: status, queue order, summaries and questions.
public enum AgentPrompts {
    // MARK: Status

    /// The facts of one session for the Status job. A nil `digest` means the screen is the only record.
    /// `screen`: the live screen tail while the session works. `previous`: the last status headline.
    /// `decisions`: the decisions of the developer after the last turn, oldest first.
    public static func statusInput(key: String, title: String, status: String, description: String, digest: SessionDigest?,
                                   screen: String, state: String, idleMinutes: Int, ci: String, pr: String,
                                   previous: String, decisions: [String] = []) -> AIInput {
        let flat = { (s: String) in s.replacingOccurrences(of: "\n", with: " ") }
        var earlier = "(none)", last = "(no history: the screen only)", turns = "0"
        if let d = digest {
            let first = d.turns - d.earlier.count - d.last.count
            if !d.earlier.isEmpty {
                earlier = d.earlier.enumerated().map { i, t in
                    "[turn \(first + i + 1)] \(flat(t.prompt)) → \(flat(t.closing))\(t.interrupted == true ? " (stopped)" : "")"
                }.joined(separator: "\n")
            }
            if !d.last.isEmpty {
                last = d.last.map { t in
                    let stopped = t.interrupted == true ? ", stopped by the developer" : ""
                    return "USER: \(t.prompt)\nAGENT (\(t.tools) tool calls\(stopped)):\n\(t.text)"
                }.joined(separator: "\n\n---\n\n")
            }
            turns = "\(d.turns)"
        }
        return AIInput(text: "", context: [
            "key": key, "title": title, "status": status, "description": String(description.prefix(8000)), "turns": turns,
            "earlier": earlier, "last": last, "screen": String(screen.suffix(2000)), "state": state, "idle": "\(idleMinutes)",
            "ci": ci, "pr": pr, "previous": previous,
            "decisions": decisions.suffix(6).map { "- " + $0.replacingOccurrences(of: "\n", with: " ").prefix(300) }.joined(separator: "\n"),
        ])
    }

    /// The status reply, or nil when the reply has no known state.
    public static func parseStatus(_ text: String, key: String) -> StatusReply? {
        guard let obj = replyObject(text), let raw = obj["state"] as? String,
              let state = StatusReply.State(rawValue: raw.lowercased()) else { return nil }
        let list = { (k: String, n: Int) in ((obj[k] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }.prefix(n).map { $0 } }
        let steps = ((obj["needsYou"] as? [Any]) ?? []).prefix(8).compactMap { v -> StatusReply.Step? in
            if let s = v as? String, !s.isEmpty { return StatusReply.Step(text: s, kind: "other") }
            guard let d = v as? [String: Any], let t = d["text"] as? String, !t.isEmpty else { return nil }
            return StatusReply.Step(text: t, kind: d["kind"] as? String ?? "other")
        }
        let own = key.uppercased()
        let blockers = list("blockedBy", 8).map { $0.uppercased() }.filter { $0 != own && $0.contains("-") }
        return StatusReply(state: state, headline: obj["headline"] as? String ?? "", done: list("done", 4), next: list("next", 3),
                           needsYou: steps, blockedBy: blockers, nudge: obj["nudge"] as? String ?? "")
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
}

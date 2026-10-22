import Foundation
import OverSireCore

/// A tool permission prompt or the plan approval of Claude Code, read from the screen of a terminal as a best effort.
/// Recorded on Claude Code 2.1.308: a number picks the choice and sends it at once.
struct ClaudePrompt {
    enum Kind { case permission, plan }

    let kind: Kind
    /// The first row of the prompt: "Bash command", "Edit file", "Ready to code?".
    let title: String
    /// The rows between the title and the question: the command, the diff, the plan.
    let body: [String]
    /// The row above the choices: "Do you want to proceed?".
    let question: String
    let options: [(n: Int, label: String)]
    /// The row under the cursor, with no marker: "4. No".
    var cursor: String?
    /// The number of the choice that takes a text: "No" with Tab to amend, or "Tell Claude what to change".
    var typed: Int?
    /// True while the "No" choice of a permission takes a text after Tab.
    var amending = false

    /// The text that names the prompt when the transcript does not give the tool call.
    var key: String { ([title] + body + [question]).joined(separator: "\n") }

    /// nil when no prompt is open at the bottom of the screen.
    static func parse(_ screen: [String]) -> ClaudePrompt? {
        let rows = ClaudeForm.lines(screen)
        guard let footer = rows.last.map(ClaudeForm.trim) else { return nil }
        let kind: Kind
        if footer.hasPrefix("ctrl+g to edit") { kind = .plan } else if footer.hasPrefix("Esc to cancel") { kind = .permission } else { return nil }

        // The question is the first row above the choices that is not to the right of the numbers.
        func indent(_ r: String) -> Int { r.prefix { $0 == " " || $0 == "❯" }.count }
        var column: Int?, skipped = 0
        var q: Int?
        for i in stride(from: rows.count - 2, through: 0, by: -1) {
            let t = ClaudeForm.trim(rows[i])
            if ClaudeForm.option(rows[i]) != nil {
                column = indent(rows[i])
            } else if let column, !t.isEmpty, indent(rows[i]) <= column {
                q = i
                break
            } else if column == nil {
                // A hint row below the choices: "shift+tab to approve with this feedback".
                skipped += 1
                if skipped > 2 { return nil }
            }
        }
        guard let q, ClaudeForm.trim(rows[q]).hasSuffix("?") else { return nil }

        // A choice can wrap. A row that fills the width wraps in a word.
        let width = rows.map(\.count).max() ?? 0
        var options: [(n: Int, label: String)] = []
        for i in (q + 1)..<(rows.count - 1) {
            let t = ClaudeForm.trim(rows[i])
            if let (n, label) = ClaudeForm.option(rows[i]) {
                options.append((n, label))
            } else if !options.isEmpty, !t.isEmpty, !t.hasPrefix("shift+tab") {
                options[options.count - 1].label += (rows[i - 1].count >= width - 1 ? "" : " ") + t
            }
        }
        guard options.count >= 2, options.first?.n == 1 else { return nil }

        // The prompt starts below the last rule above the question. A plan has one more rule below its text.
        let rules = rows[..<q].indices.filter { ClaudeForm.separator(rows[$0]) }
        guard var top = rules.last else { return nil }
        if kind == .plan, top + 1 == q, rules.count >= 2 { top = rules[rules.count - 2] }
        let inside = rows[(top + 1)..<q].map(ClaudeForm.trim).filter { !$0.isEmpty && !$0.allSatisfy { $0 == "╌" } && !$0.hasPrefix("Tip:") }
        guard let title = inside.first else { return nil }

        let cursor = rows[(q + 1)...].last { ClaudeForm.trim($0).hasPrefix("❯") }.map { ClaudeForm.trim(String(ClaudeForm.trim($0).dropFirst())) }
        let amending = kind == .permission && !footer.contains("Tab to amend")
        let last = options[options.count - 1]
        let typed = kind == .plan || (last.label.hasPrefix("No") && (footer.contains("Tab to amend") || amending)) ? last.n : nil
        return ClaudePrompt(kind: kind, title: title, body: Array(inside.dropFirst()), question: ClaudeForm.trim(rows[q]),
                            options: options, cursor: cursor, typed: typed, amending: amending)
    }

    /// One choice item. The header names the tool, and the text is a short form of its input: "Bash" and "git push".
    func item(tool: String?, input: String?) -> QuestionItem {
        let header = kind == .plan ? "Plan" : tool ?? title
        var text = input?.split(whereSeparator: \.isNewline).first.map(String.init)
        if let t = text, ["Write", "Edit", "MultiEdit", "Read", "NotebookEdit"].contains(tool ?? "") { text = (t as NSString).lastPathComponent }
        if kind == .plan { text = body.first { $0.hasPrefix("Plan: ") }.map { String($0.dropFirst("Plan: ".count)) } ?? "Approve the plan" }
        let short = (text ?? title).trimmingCharacters(in: .whitespaces)
        return QuestionItem(id: "q1", header: header, text: short.count > 120 ? String(short.prefix(119)) + "…" : short, why: question,
                            kind: .single, options: options.map { .init(label: $0.label) }, allowsOther: typed != nil)
    }

    /// The id of the last call of `tool` in a Claude transcript that has no result yet.
    /// `input` is the start of the input that Orca shows, for example the command. A string of the call must start with it.
    static func openTool(_ tool: String, input: String? = nil, in jsonl: Data) -> String? {
        let start = input.map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 }
        var open: String?
        for line in jsonl.split(separator: UInt8(ascii: "\n")) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let blocks = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for b in blocks {
                if b["type"] as? String == "tool_use", b["name"] as? String == tool {
                    let values = (b["input"] as? [String: Any])?.values.compactMap { $0 as? String } ?? []
                    open = start.map { s in values.contains { $0.hasPrefix(s) } } ?? true ? b["id"] as? String : nil
                }
                if b["type"] as? String == "tool_result", let id = open, b["tool_use_id"] as? String == id { open = nil }
            }
        }
        return open
    }
}

/// The keys that answer a prompt, one step for each key.
/// A text for a permission: Down to "No", Tab, the text, Enter. A text for a plan: the number moves the cursor, the text, Enter.
struct PromptKeys {
    struct Step: Hashable {
        /// The start of the cursor row, for example "4.".
        var cursor: String?
        /// The state of the "No" text of a permission. nil: either.
        var amending: Bool?
        let keys: String

        func holds(_ p: ClaudePrompt) -> Bool {
            if let cursor, !(p.cursor ?? "").hasPrefix(cursor) { return false }
            return amending.map { $0 == p.amending } ?? true
        }
    }

    let steps: [Step]

    init(_ p: ClaudePrompt, _ a: QuestionAnswer.Item) {
        let other = (a.other ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if let label = a.choices.first, let n = p.options.first(where: { $0.label == label })?.n {
            steps = [Step(amending: false, keys: "\(n)")]
        } else if let t = p.typed, p.kind == .plan {
            steps = [Step(keys: "\(t)"), Step(cursor: "\(t).", keys: other), Step(cursor: "\(t).", keys: FormKeys.enter)]
        } else if let t = p.typed {
            steps = (1..<t).map { Step(cursor: "\($0).", amending: false, keys: FormKeys.down) }
                + [Step(cursor: "\(t).", amending: false, keys: "\t"), Step(cursor: "\(t).", amending: true, keys: other),
                   Step(cursor: "\(t).", amending: true, keys: FormKeys.enter)]
        } else {
            steps = []
        }
    }
}

extension OrcaRuntime {
    /// Presses the keys of the answer. The prompt on the screen must have the choices of the question.
    /// .alreadyAnswered: the prompt is gone, or another prompt shows, so the user answered in Orca.
    func answerPrompt(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult {
        guard let item = q.items.first, let given = a.items.first(where: { $0.id == item.id }) else { return .gone }
        guard let p = ClaudePrompt.parse(try await output(q.session, lines: 40)), p.question == item.why,
              p.options.map(\.label) == item.options.map(\.label) else { return .alreadyAnswered }
        let steps = PromptKeys(p, given).steps.map { step in
            (keys: step.keys, check: { (s: [String]) -> Bool? in ClaudePrompt.parse(s).flatMap { $0.key == p.key ? step.holds($0) : nil } })
        }
        return try await press(steps, in: q.session) ?? .sent
    }
}

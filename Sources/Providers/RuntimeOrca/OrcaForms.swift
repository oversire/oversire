import Foundation
import OverSireCore

/// The AskUserQuestion form of Claude Code, read from the screen of a terminal as a best effort.
struct ClaudeForm: Hashable {
    /// The tab bar: one header for each question.
    let headers: [String]
    /// The question on the screen now, or each question of the review page.
    let items: [QuestionItem]
    var review = false
    /// The row under the cursor, with no marker: "4. [✔] perf", "Next", "1. Submit answers".
    var cursor: String?
    /// The box of each numbered option of a multi question: true when it is on.
    var boxes: [Int: Bool] = [:]

    /// The text that names the form when the transcript does not give its id.
    var key: String { headers.isEmpty ? items.first?.text ?? "" : headers.joined(separator: "|") }

    /// nil when no form is open at the bottom of the screen.
    static func parse(_ screen: [String]) -> ClaudeForm? {
        var rows = screen.map { $0.replacingOccurrences(of: "\u{a0}", with: " ") }
        // Orca draws a rule with the worktree name below the terminal.
        while let r = rows.last.map(trim), r.isEmpty || (r.hasPrefix("─") && !separator(r)) { rows.removeLast() }
        let filled = rows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = filled.last else { return nil }
        let review = filled.suffix(4).contains { $0.contains("Ready to submit your answers?") }
        guard review || (last.contains("Enter to select") && last.contains("Esc to cancel")) else { return nil }

        // The form starts below the second to last rule. "Chat about this" is below the last rule.
        let rules = rows.indices.filter { separator(rows[$0]) }
        let top = rules.count >= 2 ? rules[rules.count - 2] : rules.last
        let bar = rows.lastIndex { let t = trim($0); return t.hasPrefix("←") && t.contains("Submit") }
            ?? top.flatMap { $0 + 1 < rows.count && boxed(trim(rows[$0 + 1])) ? $0 + 1 : nil }
        let headers = bar.map { rows[$0].components(separatedBy: "  ").map(trim)
            .map { boxed($0) ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty && !["←", "→", "Submit"].contains($0) } } ?? []
        let start = bar.map { $0 + 1 } ?? top.map { $0 + 1 } ?? 0
        let firstOption = rows[start...].firstIndex { option($0) != nil }
        let cursor = rows[start...].last { trim($0).hasPrefix("❯") }.map { trim(String(trim($0).dropFirst())) }
        if review { return ClaudeForm(headers: headers, items: reviewItems(Array(rows[start...])), review: true, cursor: cursor) }
        guard let firstOption else { return ClaudeForm(headers: headers, items: [], cursor: cursor) }

        let text = rows[start..<firstOption].map { trim(trim($0).hasPrefix("│") ? String(trim($0).dropFirst()) : $0) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        var options: [(label: String, detail: [String])] = []
        var multi = false, other = false, keep = false
        var boxes: [Int: Bool] = [:]
        for row in rows[firstOption...] {
            if separator(row) || trim(row).hasPrefix("Enter to select") { break }
            if let (n, o) = option(row) {
                var label = o
                for box in ["[ ] ", "[✔] ", "[x] ", "[×] "] where label.hasPrefix(box) {
                    multi = true
                    boxes[n] = box != "[ ] "
                    label = String(label.dropFirst(box.count))
                }
                keep = false
                if label.hasPrefix("Type something") { other = true } else if label != "Chat about this" {
                    options.append((label, []))
                    keep = true
                }
            } else if keep, !trim(row).isEmpty, !options.isEmpty {
                options[options.count - 1].detail.append(trim(row))
            }
        }
        guard !text.isEmpty else { return ClaudeForm(headers: headers, items: [], cursor: cursor) }
        let item = QuestionItem(id: "q1", header: headers.count == 1 ? headers[0] : nil, text: text,
                                kind: options.isEmpty ? .free : multi ? .multi : .single,
                                options: options.map { .init(label: $0.label, detail: $0.detail.isEmpty ? nil : $0.detail.joined(separator: " ")) },
                                allowsOther: other && !options.isEmpty)
        return ClaudeForm(headers: headers, items: [item], cursor: cursor, boxes: boxes)
    }

    /// "● question" starts an item, "→ answer" ends it.
    private static func reviewItems(_ rows: [String]) -> [QuestionItem] {
        var texts: [String] = []
        var open = false
        for row in rows {
            var t = trim(row)
            if t.hasPrefix("│") { t = trim(String(t.dropFirst())) }
            if t.hasPrefix("● ") {
                texts.append(String(t.dropFirst(2)))
                open = true
            } else if t.hasPrefix("→") || t.hasPrefix("Ready to submit") {
                open = false
            } else if open, !t.isEmpty {
                texts[texts.count - 1] += " " + t
            }
        }
        return texts.enumerated().map { QuestionItem(id: "q\($0.offset + 1)", text: $0.element, kind: .free) }
    }

    /// The number and text of a numbered option row: "❯ 1. SQLite" gives 1 and "SQLite".
    private static func option(_ row: String) -> (Int, String)? {
        var t = trim(row)
        if t.hasPrefix("❯") { t = trim(String(t.dropFirst())) }
        guard let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]), t[..<dot].allSatisfy(\.isNumber),
              t[t.index(after: dot)...].hasPrefix(" ") else { return nil }
        return (n, trim(String(t[t.index(after: dot)...])))
    }

    /// A tab of the bar: "☐ Store", "☒ Tests", "✔ Submit".
    private static func boxed(_ t: String) -> Bool { t.hasPrefix("☐ ") || t.hasPrefix("☒ ") || t.hasPrefix("✔ ") }

    private static func separator(_ row: String) -> Bool { let t = trim(row); return !t.isEmpty && t.allSatisfy { $0 == "─" } }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
}

/// The last AskUserQuestion call in a Claude transcript, and its answers when it has a result.
struct ClaudeAsk: Hashable {
    let id: String
    let items: [QuestionItem]
    /// Question text to the answer text. nil while the call is open.
    let answers: [String: String]?
    let notes: [String]

    var open: Bool { answers == nil }

    /// `jsonl` can start in the middle of a line: that line is skipped.
    static func last(in jsonl: Data) -> ClaudeAsk? {
        var ask: ClaudeAsk?
        for line in jsonl.split(separator: UInt8(ascii: "\n")) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let blocks = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for b in blocks {
                if b["type"] as? String == "tool_use", b["name"] as? String == "AskUserQuestion", let id = b["id"] as? String {
                    let qs = (b["input"] as? [String: Any])?["questions"] as? [[String: Any]] ?? []
                    ask = ClaudeAsk(id: id, items: qs.enumerated().map(item), answers: nil, notes: [])
                } else if b["type"] as? String == "tool_result", let a = ask, b["tool_use_id"] as? String == a.id {
                    let r = e["toolUseResult"] as? [String: Any]
                    let notes = (r?["annotations"] as? [String: Any] ?? [:]).values.compactMap { ($0 as? [String: Any])?["notes"] as? String }
                    ask = ClaudeAsk(id: a.id, items: a.items, answers: r?["answers"] as? [String: String] ?? [:], notes: notes.sorted())
                }
            }
        }
        return ask
    }

    private static func item(_ i: Int, _ q: [String: Any]) -> QuestionItem {
        let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o in
            (o["label"] as? String).map { QuestionItem.Option(label: $0, detail: o["description"] as? String) }
        }
        return QuestionItem(id: "q\(i + 1)", header: q["header"] as? String, text: q["question"] as? String ?? "",
                            kind: options.isEmpty ? .free : q["multiSelect"] as? Bool == true ? .multi : .single,
                            options: options, allowsOther: !options.isEmpty)
    }

    /// True when the screen shows this call: the same headers, or the same question text.
    func matches(_ form: ClaudeForm) -> Bool {
        func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        if !form.headers.isEmpty, form.headers == items.compactMap(\.header) { return true }
        let texts = Set(items.map { flat($0.text) })
        return !form.items.isEmpty && form.items.allSatisfy { texts.contains(flat($0.text)) }
    }

    /// The answers of the result. Claude joins the labels with ", "; a text that is no label is the free text.
    func answer(_ q: QuestionID) -> QuestionAnswer? {
        guard let answers else { return nil }
        let items = self.items.compactMap { item -> QuestionAnswer.Item? in
            guard let given = answers[item.text] else { return nil }
            let labels = Set(item.options.map(\.label))
            let parts = given.components(separatedBy: ", ")
            if !labels.contains(given), parts.contains(where: { !labels.contains($0) }) {
                return .init(id: item.id, other: given)
            }
            return .init(id: item.id, choices: labels.contains(given) ? [given] : parts)
        }
        return QuestionAnswer(question: q, items: items, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
    }
}

/// The keys that answer an AskUserQuestion form, one step for each key. Each step names the screen that its key needs.
/// Recorded on Claude Code 2.1.308: a number picks a single option, or toggles a multi option and leaves the cursor.
/// The number of "Type something" moves the cursor there in a single question. Then the text goes into that row.
/// A form with a tab bar ends on a review page.
struct FormKeys: Hashable {
    static let enter = "\r"
    static let down = "\u{1b}[B"

    struct Step: Hashable {
        /// The question of the tab. nil: the review page.
        var question: String?
        /// The start of the cursor row, for example "4." or "Next".
        var cursor: String?
        /// The boxes of a multi question before the key.
        var boxes: [Int: Bool] = [:]
        let keys: String

        func holds(_ f: ClaudeForm) -> Bool {
            func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            if let question {
                guard !f.review, f.items.count == 1, flat(f.items[0].text) == flat(question) else { return false }
            } else if !f.review { return false }
            if let cursor, !(f.cursor ?? "").hasPrefix(cursor) { return false }
            return boxes.allSatisfy { f.boxes[$0.key] == $0.value }
        }
    }

    let steps: [Step]

    init(_ q: SessionQuestion, _ a: QuestionAnswer) {
        var steps: [Step] = []
        for (i, item) in q.items.enumerated() {
            let given = a.items.first { $0.id == item.id } ?? .init(id: item.id)
            let other = (given.other ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let text = item.text, n = item.options.count, typed = n + 1
            let picked = given.choices.compactMap { c in item.options.firstIndex { $0.label == c }.map { $0 + 1 } }
            switch item.kind {
            case .free:
                steps += [Step(question: text, keys: other), Step(question: text, keys: Self.enter)]
            case .single, .approve:
                if let p = picked.first {
                    steps.append(Step(question: text, keys: "\(p)"))
                } else {
                    steps += [Step(question: text, keys: "\(typed)"), Step(question: text, cursor: "\(typed).", keys: other),
                              Step(question: text, cursor: "\(typed).", keys: Self.enter)]
                }
            case .multi:
                let on = picked + (other.isEmpty ? [] : [typed])
                steps += on.map { Step(question: text, boxes: [$0: false], keys: "\($0)") }
                let rows = n + (item.allowsOther ? 1 : 0)
                if other.isEmpty {
                    steps += (1...rows).map { Step(question: text, cursor: "\($0).", keys: Self.down) }
                } else {
                    steps += (1..<typed).map { Step(question: text, cursor: "\($0).", keys: Self.down) }
                    steps += [Step(question: text, cursor: "\(typed).", keys: other), Step(question: text, cursor: "\(typed).", keys: Self.down)]
                }
                let boxes = Dictionary(uniqueKeysWithValues: (1...rows).map { ($0, on.contains($0)) })
                steps.append(Step(question: text, cursor: i == q.items.count - 1 ? "Submit" : "Next", boxes: boxes, keys: Self.enter))
            }
        }
        if q.items.count > 1 || q.items.contains(where: { $0.kind == .multi }) {
            steps.append(Step(question: nil, cursor: "1. Submit answers", keys: "1"))
        }
        self.steps = steps
    }
}

extension OrcaRuntime {
    /// The transcript bytes that one read looks at.
    static let transcriptTail = 512 * 1024

    /// The native forms of these sessions: Orca shows the agent waiting in AskUserQuestion, and the screen shows the form.
    func formQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion] {
        guard !sessions.isEmpty else { return [] }
        let waiting = try await formWaits()
        guard !waiting.isEmpty else { return [] }
        let terminals = try await terminalRows()
        var out: [SessionQuestion] = []
        for s in sessions {
            guard let t = terminals[s.id], let w = waiting[t.paneKey] else { continue }
            let screen = try await output(s, lines: 40)
            guard let form = ClaudeForm.parse(screen) else { continue }
            let ask = localAsk(cwd: w.path ?? t.path).flatMap { $0.open && $0.matches(form) ? $0 : nil }
            let id = ask.map { "form:" + $0.id } ?? "form:\(s.id):\(Self.fnv(form.key))"
            let items = ask?.items ?? (form.items.isEmpty ? [QuestionItem(id: "q1", text: "The session asks a question in Orca.", kind: .free)] : form.items)
            let via: SessionQuestion.Via = ask != nil || !form.items.isEmpty ? .form : .waiting
            out.append(SessionQuestion(id: questionID(id), session: s, origin: .session, items: items, via: via, askedAt: w.since))
        }
        return out
    }

    /// Types the answer into the form. Before each key it reads the screen and stops when the form is not at the step.
    /// .alreadyAnswered: the form is gone, so the user answered in Orca. form_changed: another form or step shows.
    func answerForm(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult {
        for step in FormKeys(q, a).steps {
            var form: ClaudeForm?
            for i in 0..<formTries {
                form = ClaudeForm.parse(try await output(q.session, lines: 40))
                if form.map(step.holds) ?? false { break }
                if form == nil { return .alreadyAnswered }
                if i == formTries - 1 { throw ProviderError.vendor(code: "form_changed", message: "The form in Orca changed. Answer it in Orca.") }
                try await Task.sleep(for: formWait)
            }
            _ = try await run(["terminal", "send", "--terminal", q.session.id, "--text", step.keys])
        }
        for i in 0..<formTries * 5 {
            if ClaudeForm.parse(try await output(q.session, lines: 40)) == nil { break }
            if i == formTries * 5 - 1 { throw ProviderError.vendor(code: "form_open", message: "The form is still open in Orca.") }
            try await Task.sleep(for: formWait)
        }
        if let given = try? await formAnswer(q), Self.flat(given) != Self.flat(a) {
            log.write(LogEntry(level: .warn, area: .sessions, job: "Form answer", subject: q.session.id,
                               message: "The session got another answer than OverSire typed: \(Self.flat(given)), not \(Self.flat(a))."))
        }
        return .sent
    }

    /// Each item as Claude shows it: the labels and the text, in any order.
    static func flat(_ a: QuestionAnswer) -> [String: Set<String>] {
        Dictionary(a.items.map { i in (i.id, Set((i.choices + [i.other].compactMap { $0 }).flatMap { $0.components(separatedBy: ", ") })) },
                   uniquingKeysWith: { x, _ in x })
    }

    /// The exact answer of a form on this Mac, from the transcript.
    func formAnswer(_ q: SessionQuestion) async throws -> QuestionAnswer? {
        guard environment == nil, let msg = messageID(q.id), msg.hasPrefix("form:") else { return nil }
        let tool = String(msg.dropFirst("form:".count))
        guard !tool.contains(":"), let path = try await terminalRows()[q.session.id]?.path, let ask = localAsk(cwd: path), ask.id == tool else { return nil }
        return ask.answer(q.id)
    }

    /// The agents that wait in AskUserQuestion, by pane key.
    private func formWaits() async throws -> [String: (path: String?, since: Date)] {
        var out: [String: (path: String?, since: Date)] = [:]
        for w in try await run(["worktree", "ps", "--limit", "500"])["worktrees"] as? [[String: Any]] ?? [] {
            for a in w["agents"] as? [[String: Any]] ?? [] where a["state"] as? String == "waiting" && a["toolName"] as? String == "AskUserQuestion" {
                guard let pane = a["paneKey"] as? String else { continue }
                out[pane] = (w["path"] as? String, Date(timeIntervalSince1970: ((a["stateStartedAt"] as? Double) ?? 0) / 1000))
            }
        }
        return out
    }

    /// The pane key and the checkout of each terminal, by handle.
    private func terminalRows() async throws -> [String: (paneKey: String, path: String?)] {
        var out: [String: (paneKey: String, path: String?)] = [:]
        for t in try await run(["terminal", "list"])["terminals"] as? [[String: Any]] ?? [] {
            guard let h = t["handle"] as? String else { continue }
            out[h] = ("\(t["tabId"] as? String ?? ""):\(t["leafId"] as? String ?? "")", t["worktreePath"] as? String)
        }
        return out
    }

    /// The last AskUserQuestion of the newest Claude transcript in `cwd`. Only on this Mac.
    private func localAsk(cwd: String?) -> ClaudeAsk? {
        guard environment == nil, let cwd, let transcripts, let file = transcripts.newest(agent: .claude, cwd: cwd),
              let data = transcripts.tail(file: file, bytes: Self.transcriptTail) else { return nil }
        return ClaudeAsk.last(in: data)
    }

    /// A short stable hash (FNV-1a, 64 bit) for an id.
    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}

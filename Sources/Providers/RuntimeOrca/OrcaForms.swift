import Foundation
import OverSireCore

/// The AskUserQuestion form of Claude Code, read from the screen of a terminal as a best effort.
struct ClaudeForm: Hashable {
    /// The tab bar: one header for each question.
    let headers: [String]
    /// The question on the screen now, or each question of the review page.
    let items: [QuestionItem]

    /// The text that names the form when the transcript does not give its id.
    var key: String { headers.isEmpty ? items.first?.text ?? "" : headers.joined(separator: "|") }

    /// nil when no form is open at the bottom of the screen.
    static func parse(_ screen: [String]) -> ClaudeForm? {
        let rows = screen.map { $0.replacingOccurrences(of: "\u{a0}", with: " ") }
        let filled = rows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = filled.last else { return nil }
        let review = filled.suffix(4).contains { $0.contains("Ready to submit your answers?") }
        guard review || (last.contains("Enter to select") && last.contains("Esc to cancel")) else { return nil }

        let bar = rows.lastIndex { let t = trim($0); return t.hasPrefix("←") && t.contains("Submit") }
        let headers = bar.map { rows[$0].components(separatedBy: "  ").map(trim)
            .map { $0.hasPrefix("☐ ") || $0.hasPrefix("☒ ") || $0.hasPrefix("✔ ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty && !["←", "→", "Submit"].contains($0) } } ?? []
        let firstOption = rows.firstIndex { option($0) != nil }
        let start = bar.map { $0 + 1 } ?? firstOption.flatMap { o in rows[..<o].lastIndex(where: separator).map { $0 + 1 } } ?? 0
        if review { return ClaudeForm(headers: headers, items: reviewItems(Array(rows[start...]))) }
        guard let firstOption, firstOption >= start else { return ClaudeForm(headers: headers, items: []) }

        let text = rows[start..<firstOption].map { trim(trim($0).hasPrefix("│") ? String(trim($0).dropFirst()) : $0) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        var options: [(label: String, detail: [String])] = []
        var multi = false, other = false, keep = false
        for row in rows[firstOption...] {
            if separator(row) || trim(row).hasPrefix("Enter to select") { break }
            if let o = option(row) {
                var label = o
                for box in ["[ ] ", "[✔] ", "[x] ", "[×] "] where label.hasPrefix(box) {
                    multi = true
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
        guard !text.isEmpty else { return ClaudeForm(headers: headers, items: []) }
        let item = QuestionItem(id: "q1", header: headers.count == 1 ? headers[0] : nil, text: text,
                                kind: options.isEmpty ? .free : multi ? .multi : .single,
                                options: options.map { .init(label: $0.label, detail: $0.detail.isEmpty ? nil : $0.detail.joined(separator: " ")) },
                                allowsOther: other && !options.isEmpty)
        return ClaudeForm(headers: headers, items: [item])
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

    /// The text of a numbered option row: "❯ 1. SQLite" gives "SQLite".
    private static func option(_ row: String) -> String? {
        var t = trim(row)
        if t.hasPrefix("❯") { t = trim(String(t.dropFirst())) }
        guard let dot = t.firstIndex(of: "."), !t[..<dot].isEmpty, t[..<dot].allSatisfy(\.isNumber),
              t[t.index(after: dot)...].hasPrefix(" ") else { return nil }
        return trim(String(t[t.index(after: dot)...]))
    }

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
            out.append(SessionQuestion(id: questionID(id), session: s, origin: .session, items: items, via: .form, askedAt: w.since))
        }
        return out
    }

    /// The exact answer of a form on this Mac, from the transcript.
    func formAnswer(_ q: SessionQuestion) async throws -> QuestionAnswer? {
        guard environment == nil, let msg = messageID(q.id), msg.hasPrefix("form:") else { return nil }
        let tool = String(msg.dropFirst("form:".count))
        guard !tool.contains(":"), let path = try await terminalRows()[q.session.id]?.path, let ask = localAsk(cwd: path), ask.id == tool else { return nil }
        return ask.answer(q.id)
    }

    /// Waits until the form is gone, then sends `line`, which asks the session to use oversire-ask. It sends no key while the form shows.
    public func askAgainWithOverSire(_ s: SessionRef, line: String, every: Duration = .seconds(2), tries: Int = 300) async throws {
        for i in 0..<tries {
            if ClaudeForm.parse(try await output(s, lines: 40)) == nil { break }
            if i == tries - 1 { throw ProviderError.vendor(code: "form_open", message: "The form is still open in Orca.") }
            try await Task.sleep(for: every)
        }
        try await waitIdle(s, name: s.id)
        try await send(s, text: line)
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

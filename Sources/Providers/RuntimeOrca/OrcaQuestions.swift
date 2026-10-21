import Foundation
import OverSireCore

/// One row of `orchestration inbox`.
struct OrcaMessage: Hashable, Sendable {
    let id: String
    let type: String
    let from: String
    let to: String
    let thread: String?
    let body: String
    let payload: [String: String]
    let at: Date

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let type = d["type"] as? String else { return nil }
        self.id = id
        self.type = type
        from = d["from_handle"] as? String ?? ""
        to = d["to_handle"] as? String ?? ""
        thread = d["thread_id"] as? String
        body = d["body"] as? String ?? ""
        let raw = (d["payload"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? d["payload"]
        payload = (raw as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        at = (d["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
    }

    /// A reply names the question in its thread. A question of a worker names itself.
    var replyTo: String? { thread.flatMap { $0 == id ? nil : $0 } }
}

/// The body of an ask and of its reply: `{"round":N,"questions":[...]}` and `{"round":N,"answers":{id: text or [text]},"note":...}`.
/// A body that is not this JSON is one free question, and its reply is plain text.
enum OrcaAskBody {
    static func parse(_ body: String) -> (round: Int, items: [QuestionItem])? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let qs = d["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        var items: [QuestionItem] = []
        for (i, q) in qs.enumerated() {
            guard let text = q["text"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [Any] ?? []).compactMap { o -> QuestionItem.Option? in
                if let s = o as? String { return QuestionItem.Option(label: s) }
                guard let o = o as? [String: Any], let l = o["label"] as? String else { return nil }
                return QuestionItem.Option(label: l, detail: o["detail"] as? String)
            }
            let kind = (q["type"] as? String).flatMap(QuestionItem.Kind.init(rawValue:)).flatMap { [.single, .multi, .free].contains($0) ? $0 : nil }
                ?? (options.isEmpty ? .free : .single)
            items.append(QuestionItem(id: q["id"] as? String ?? "q\(i + 1)", header: q["header"] as? String, text: text,
                                      why: q["why"] as? String, kind: options.isEmpty ? .free : kind,
                                      options: options, allowsOther: q["allowsOther"] as? Bool ?? !options.isEmpty))
        }
        return ((d["round"] as? Int) ?? 1, items)
    }

    static func items(_ body: String) -> (round: Int, items: [QuestionItem], plain: Bool) {
        if let p = parse(body) { return (p.round, p.items, false) }
        return (1, [QuestionItem(id: "q1", text: body, kind: .free)], true)
    }

    static func reply(_ a: QuestionAnswer, to q: SessionQuestion, plain: Bool) -> String {
        if plain {
            let text = a.items.first.map { ($0.choices + [$0.other].compactMap { $0 }).joined(separator: ", ") } ?? ""
            return [text, a.note].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: "\n\n")
        }
        var answers: [String: Any] = [:]
        for item in q.items {
            guard let given = a.items.first(where: { $0.id == item.id }) else { continue }
            let other = given.other.flatMap { $0.isEmpty ? nil : $0 }
            switch item.kind {
            case .multi: answers[item.id] = given.choices + [other].compactMap { $0 }
            default: answers[item.id] = other ?? given.choices.first ?? ""
            }
        }
        var d: [String: Any] = ["round": q.round, "answers": answers]
        if let n = a.note, !n.isEmpty { d["note"] = n }
        let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The answer in a reply. A text that is an option label is a choice; any other text is the free text.
    static func answer(_ body: String, to q: SessionQuestion) -> QuestionAnswer {
        guard let d = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let answers = d["answers"] as? [String: Any] else {
            return QuestionAnswer(question: q.id, items: [.init(id: q.items.first?.id ?? "q1", other: body)])
        }
        let items = q.items.compactMap { item -> QuestionAnswer.Item? in
            let given = (answers[item.id] as? [String]) ?? (answers[item.id] as? String).map { [$0] }
            guard let given else { return nil }
            let labels = Set(item.options.map(\.label))
            let others = given.filter { !labels.contains($0) }
            return .init(id: item.id, choices: given.filter(labels.contains), other: others.isEmpty ? nil : others.joined(separator: ", "))
        }
        return QuestionAnswer(question: q.id, items: items, note: d["note"] as? String)
    }
}

extension OrcaRuntime {
    /// An ask older than this is not open any more.
    static let askLife: TimeInterval = 24 * 3600

    /// The asks to the coordinator that have no reply, then the native forms of the other sessions.
    /// A newer ask of the same sender replaces an older one.
    public func openQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion] {
        let coord = try await coordinator()
        let mail = try await inbox()
        let byHandle = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let asks = Self.openAsks(mail, to: coord, now: now()).compactMap { m in
            byHandle[m.from].map { question(m, session: $0) }
        }
        let asked = Set(asks.map(\.session))
        return asks + (try await formQuestions(in: sessions.filter { !asked.contains($0) }))
    }

    public func answer(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult {
        guard q.answerable else { throw QuestionError.notAnswerable }
        try q.validate(a)
        guard let msg = messageID(q.id) else { return .gone }
        let mail = try await inbox()
        if mail.contains(where: { $0.replyTo == msg }) { return .alreadyAnswered }
        guard let ask = mail.first(where: { $0.id == msg && $0.type == "question" }) else { return .gone }
        let body = OrcaAskBody.reply(a, to: q, plain: OrcaAskBody.parse(ask.body) == nil)
        do {
            try await reply(msg, body: body, from: coordinator())
        } catch ProviderError.vendor(let code, _) where ["stable_pane_required", "consumer_fenced", "terminal_not_found"].contains(code) {
            coordinatorSlot.reset()
            try await reply(msg, body: body, from: coordinator())
        }
        return .sent
    }

    public func answerGiven(_ q: SessionQuestion) async throws -> QuestionAnswer? {
        if q.via == .form { return try await formAnswer(q) }
        guard let msg = messageID(q.id), let r = try await inbox().first(where: { $0.replyTo == msg }) else { return nil }
        return OrcaAskBody.answer(r.body, to: q)
    }

    /// Wakes on each new question in the coordinator mailbox. Each wake acknowledges the batch before.
    public var changes: AsyncStream<Void>? {
        AsyncStream { cont in
            let task = Task { [self] in
                var ack: String?
                while !Task.isCancelled {
                    do {
                        let coord = try await coordinator()
                        var args = ["orchestration", "check", "--terminal", coord.terminal, "--wait", "--types", "question", "--timeout-ms", "60000"]
                        if let ack { args += ["--ack", ack] }
                        let r = try await run(args, timeout: .seconds(75))
                        ack = r["deliveryId"] as? String
                        if !(r["messages"] as? [Any] ?? []).isEmpty { cont.yield() }
                    } catch {
                        if case ProviderError.vendor(let code, _) = error, ["stable_pane_required", "consumer_fenced"].contains(code) {
                            coordinatorSlot.reset()
                        }
                        ack = nil
                        try? await Task.sleep(for: changesRetry)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func openAsks(_ mail: [OrcaMessage], to coord: OrcaCoordinator, now: Date) -> [OrcaMessage] {
        let replied = Set(mail.compactMap(\.replyTo))
        let asks = mail.filter { $0.type == "question" && ($0.to == coord.address || $0.to == coord.terminal) }
        let newest = Dictionary(grouping: asks, by: \.from).compactMap { $0.value.max { $0.at < $1.at } }
        return newest.filter { !replied.contains($0.id) && now.timeIntervalSince($0.at) < askLife }.sorted { $0.at < $1.at }
    }

    func question(_ m: OrcaMessage, session: SessionRef) -> SessionQuestion {
        let b = OrcaAskBody.items(m.body)
        return SessionQuestion(id: questionID(m.id), session: session, origin: .session, round: b.round, items: b.items,
                               via: .askReply, askedAt: m.at)
    }

    var questionPrefix: String { "orca:\(environment ?? "local"):" }

    func questionID(_ message: String) -> QuestionID { QuestionID(rawValue: questionPrefix + message) }

    func messageID(_ q: QuestionID) -> String? {
        q.rawValue.hasPrefix(questionPrefix) ? String(q.rawValue.dropFirst(questionPrefix.count)) : nil
    }

    /// The last messages of the server, newest first. It marks nothing read.
    func inbox() async throws -> [OrcaMessage] {
        (try await run(["orchestration", "inbox", "--limit", "200"])["messages"] as? [[String: Any]] ?? []).compactMap(OrcaMessage.init)
    }

    /// Orca makes a new message for each reply, so the caller checks the thread first.
    func reply(_ message: String, body: String, from coord: OrcaCoordinator) async throws {
        _ = try await run(["orchestration", "reply", "--id", message, "--body", body, "--from", coord.terminal])
    }
}

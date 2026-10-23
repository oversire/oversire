import Foundation
import OverSireCore

/// The daemon finds the questions in the sessions of its machine. The app shows and answers them.
/// A question of a terminal that the app does not know is dropped.
extension MachineRuntime: QuestionChannel {
    /// Wakes the board when an event of the machine names a question. Each read of `changes` gets its own stream.
    public final class Pushes: @unchecked Sendable {
        private let lock = NSLock()
        private var conts: [UUID: AsyncStream<Void>.Continuation] = [:]

        public init() {}

        public func push() {
            lock.withLock { conts.values.forEach { $0.yield() } }
        }

        func stream() -> AsyncStream<Void> {
            let (s, c) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            lock.withLock { conts[id] = c }
            c.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.conts.removeValue(forKey: id) } }
            return s
        }
    }

    public var changes: AsyncStream<Void>? { pushes?.stream() }

    public func owns(_ id: QuestionID) -> Bool { daemonID(id) != nil }

    public func openQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion] {
        let page = try await client.questions()
        let byHandle = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return page.questions.compactMap { q in
            guard let t = q.terminal, let ref = byHandle[t] else { return nil }
            return question(q, session: ref)
        }
    }

    /// A question that the daemon cannot answer shows as waiting: the card then offers to open the session.
    public func question(_ q: DaemonQuestion, session: SessionRef) -> SessionQuestion {
        let via: SessionQuestion.Via
        switch q.via {
        case .form: via = .form
        case .permission: via = .permission
        case .turn: via = .turn
        case .askReply: via = .askReply
        case .waiting: via = .waiting
        }
        return SessionQuestion(id: questionID(q.id), session: session, origin: .session, round: 1, items: q.items,
                               via: q.answerable ? via : .waiting, askedAt: q.askedAt, expiresAt: q.expiresAt)
    }

    public func answer(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult {
        guard q.answerable else { throw QuestionError.notAnswerable }
        try q.validate(a)
        guard let id = daemonID(q.id) else { return .gone }
        let r: DaemonAnswerResult
        do { r = try await client.answer(id, RunnerAnswer(id: id, items: a.items, note: a.note)) } catch ProviderError.notFound { return .gone }
        switch r.result {
        case .sent: return .sent
        case .alreadyAnswered: return .alreadyAnswered
        case .gone: return .gone
        case .error: throw ProviderError.vendor(code: r.code ?? "error", message: r.message ?? "\(machine) did not send the answer")
        }
    }

    public func answerGiven(_ q: SessionQuestion) async throws -> QuestionAnswer? {
        guard let id = daemonID(q.id), let a = try await client.given(id) else { return nil }
        return QuestionAnswer(question: q.id, items: a.items, note: a.note)
    }

    var questionPrefix: String { "daemon:\(machine):" }

    func questionID(_ id: QuestionID) -> QuestionID { QuestionID(rawValue: questionPrefix + id.rawValue) }

    func daemonID(_ id: QuestionID) -> String? {
        id.rawValue.hasPrefix(questionPrefix) ? String(id.rawValue.dropFirst(questionPrefix.count)) : nil
    }
}

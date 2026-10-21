import Foundation
import OverSireCore

/// Sends an answer to the hub, which queues it as a sessionSend order for the runner.
/// .alreadyAnswered: the hub has no open question or prompt with this id. .gone: the prompt expired.
public protocol RunnerAnswerSending: Sendable {
    func send(session: String, answer: RunnerAnswer) async throws -> AnswerResult
    func send(session: String, permission: PermissionAnswer) async throws -> AnswerResult
}

/// The questions and the permission prompts of the oversire runner sessions, from the synced runner-sessions records.
/// It only reads and answers questions. The runner starts and stops the sessions.
public final class RunnerQuestions: QuestionChannel, @unchecked Sendable {
    public static let provider: ProviderID = "oversire"

    public let account = AccountID(provider: RunnerQuestions.provider, id: "local")
    public var id: ProviderID { Self.provider }
    public var capabilities: Set<Capability> { [.questions] }
    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(10), requestsPerHour: 360) }
    public let changes: AsyncStream<Void>?

    private let store: any Store
    private let sender: any RunnerAnswerSending
    private let now: @Sendable () -> Date
    private let pump: Task<Void, Never>

    public init(store: any Store, sender: any RunnerAnswerSending, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.sender = sender
        self.now = now
        let (stream, cont) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        changes = stream
        pump = Task {
            for await c in await store.changes() where c.collection == RunnerSession.collection { cont.yield() }
            cont.finish()
        }
    }

    deinit { pump.cancel() }

    public func probe() async throws -> Identity { Identity(person: PersonRef(id: "runner", name: "OverSire runner")) }
    public func poll(since: Cursor?) async throws -> EventPage { EventPage(events: [], cursor: since ?? Cursor(rawValue: "0")) }
    public func environments() async throws -> [RuntimeEnvironment] { [] }
    public func repos(in env: RuntimeEnvironment?) async throws -> [RuntimeRepo] { [] }
    public func workspaces() async throws -> [Workspace] { [] }
    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] { [] }
    public func launch(_ r: LaunchRequest) async throws -> Launch { throw ProviderError.unsupported("launch") }

    public func openQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion] {
        let wanted = Set(sessions)
        return try await store.all(RunnerSession.self)
            .filter { wanted.contains($0.session) && !$0.state.ended }
            .sorted { $0.id < $1.id }
            .flatMap(Self.questions)
    }

    /// The question and the permission prompt of one record, in this order.
    public static func questions(of r: RunnerSession) -> [SessionQuestion] {
        let origin: SessionQuestion.Origin = r.item.map { .work($0) } ?? .session
        var out: [SessionQuestion] = []
        if let q = r.question {
            out.append(SessionQuestion(id: questionID(r.id, q.id), session: r.session, origin: origin, round: q.round, items: q.items,
                                       via: .runnerInput, askedAt: q.askedAt))
        }
        if let p = r.permission {
            out.append(SessionQuestion(id: questionID(r.id, p.id), session: r.session, origin: origin,
                                       items: [.approve(id: "permission", header: p.tool, text: p.text)], via: .permission,
                                       askedAt: r.updatedAt, expiresAt: p.expiresAt))
        }
        return out
    }

    static func questionID(_ session: String, _ id: String) -> QuestionID { QuestionID(rawValue: "runner:\(session):\(id)") }

    /// Reads the latest record first. A question that is not on it any more sends nothing.
    public func answer(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult {
        guard let r = try await store.all(RunnerSession.self).first(where: { $0.session == q.session }) else { return .gone }
        if q.via == .permission {
            guard let p = r.permission, Self.questionID(r.id, p.id) == q.id else { return .alreadyAnswered }
            guard p.expiresAt > now() else { return .gone }
            let allow = a.items.first?.choices.first == QuestionItem.allow
            return try await sender.send(session: r.id, permission: PermissionAnswer(id: p.id, allow: allow))
        }
        guard let open = r.question, Self.questionID(r.id, open.id) == q.id else { return .alreadyAnswered }
        return try await sender.send(session: r.id, answer: RunnerAnswer(id: open.id, items: a.items, note: a.note))
    }

    /// The record keeps no answer after the fact.
    public func answerGiven(_ q: SessionQuestion) async throws -> QuestionAnswer? { nil }
}

extension RunnerSession.State {
    public var ended: Bool { self == .done || self == .failed }
}

import Foundation
import OverSireCore

/// A runtime with questions in memory. A test asks, answers outside OverSire, or removes a question.
/// The other runtime calls go to a FakeRuntime.
public final class FakeQuestionChannel: QuestionChannel, Revealing, @unchecked Sendable {
    public let runtime: FakeRuntime
    public var base: FakeProvider { runtime.base }
    public var id: ProviderID { runtime.id }
    public var account: AccountID { runtime.account }
    public var capabilities: Set<Capability> { [.reveal, .questions] }
    public var pollPolicy: PollPolicy { runtime.pollPolicy }
    public let changes: AsyncStream<Void>?
    private let push: AsyncStream<Void>.Continuation?

    private var open: [SessionQuestion] = []
    private var ours: Set<QuestionID> = []
    private var outside: [QuestionID: QuestionAnswer?] = [:]
    private var messages: [QuestionAnswer] = []
    private var sendFailure: ProviderError?

    /// `pushes`: the channel gives a `changes` stream.
    public init(account: String = "local", pushes: Bool = false) {
        runtime = FakeRuntime(account: account, capabilities: [.reveal])
        if pushes {
            let (s, c) = AsyncStream.makeStream(of: Void.self)
            changes = s
            push = c
        } else {
            changes = nil
            push = nil
        }
    }

    /// Each answer that the channel sent, in order.
    public var sent: [QuestionAnswer] { base.lockedValue { messages } }

    /// A session ref of this channel.
    public func session(_ id: String, workspace: String = "w1") -> SessionRef {
        SessionRef(workspace: WorkspaceRef(account: account, id: workspace), id: id)
    }

    public func ask(_ q: SessionQuestion) {
        base.lockedValue { open.append(q) }
        push?.yield()
    }

    /// The user answers in the runtime. nil: the channel cannot read the answer.
    public func answerOutside(_ id: QuestionID, _ a: QuestionAnswer?) {
        base.lockedValue {
            open.removeAll { $0.id == id }
            outside[id] = .some(a)
        }
        push?.yield()
    }

    /// The question leaves with no answer: the session stopped, or the user pressed Esc.
    public func remove(_ id: QuestionID) {
        base.lockedValue { open.removeAll { $0.id == id } }
        push?.yield()
    }

    /// Each answer throws `e` until a call with nil.
    public func failSends(_ e: ProviderError?) { base.lockedValue { sendFailure = e } }

    public func probe() async throws -> Identity { try await runtime.probe() }
    public func poll(since: Cursor?) async throws -> EventPage { try await runtime.poll(since: since) }
    public func environments() async throws -> [RuntimeEnvironment] { try await runtime.environments() }
    public func repos(in env: RuntimeEnvironment?) async throws -> [RuntimeRepo] { try await runtime.repos(in: env) }
    public func workspaces() async throws -> [Workspace] { try await runtime.workspaces() }
    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] { try await runtime.sessions(w) }
    public func launch(_ r: LaunchRequest) async throws -> Launch { try await runtime.launch(r) }
    public func reveal(_ s: SessionRef) async throws { try await runtime.reveal(s) }

    public func openQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion] {
        try base.locked { open.filter { sessions.contains($0.session) } }
    }

    public func answer(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult {
        guard q.answerable else { throw QuestionError.notAnswerable }
        return try base.locked {
            if let e = sendFailure { throw e }
            if ours.contains(q.id) { return .sent }
            if outside[q.id] != nil { return .alreadyAnswered }
            guard open.contains(where: { $0.id == q.id }) else { return .gone }
            open.removeAll { $0.id == q.id }
            ours.insert(q.id)
            messages.append(a)
            return .sent
        }
    }

    public func answerGiven(_ q: SessionQuestion) async throws -> QuestionAnswer? {
        try base.locked { outside[q.id] ?? nil }
    }
}

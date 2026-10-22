import Foundation
import OverSireCore

/// The questions that the daemon of one machine found in its sessions. The daemon finds them; the app shows and answers them.
/// The channel has the Orca account of the machine, so its questions go on the Orca sessions that the app knows.
/// A question of a terminal that the app does not know is dropped.
public final class DaemonQuestions: QuestionChannel, @unchecked Sendable {
    public static let provider: ProviderID = "daemon"

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

    public let link: MachineLink
    public let account: AccountID
    public var id: ProviderID { Self.provider }
    public var capabilities: Set<Capability> { [.questions] }
    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(2), requestsPerHour: 3600) }
    public var changes: AsyncStream<Void>? { pushes.stream() }

    private let client: DaemonClient
    private let supervised: @Sendable () async -> Set<String>
    private let pushes: Pushes

    /// account: the Orca account of the machine in this app. supervised: the terminals of the Orca workers.
    public init(link: MachineLink, account: AccountID, client: DaemonClient, supervised: @escaping @Sendable () async -> Set<String>,
                pushes: Pushes) {
        self.link = link
        self.account = account
        self.client = client
        self.supervised = supervised
        self.pushes = pushes
    }

    public func probe() async throws -> Identity {
        let me = try await client.whoami()
        return Identity(person: PersonRef(id: me.machine.rawValue, name: "oversire \(me.version) on \(me.machine)"))
    }
    public func poll(since: Cursor?) async throws -> EventPage { EventPage(events: [], cursor: since ?? Cursor(rawValue: "0")) }
    public func environments() async throws -> [RuntimeEnvironment] { [] }
    public func repos(in env: RuntimeEnvironment?) async throws -> [RuntimeRepo] { [] }
    public func workspaces() async throws -> [Workspace] { [] }
    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] { [] }
    public func launch(_ r: LaunchRequest) async throws -> Launch { throw ProviderError.unsupported("launch") }

    public func owns(_ id: QuestionID) -> Bool { daemonID(id) != nil }

    public func openQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion] {
        let page = try await client.questions()
        let byHandle = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let workers = page.questions.contains { $0.via == .turn } ? await supervised() : []
        return page.questions.compactMap { q in
            guard let t = q.terminal, let ref = byHandle[t] else { return nil }
            if q.via == .turn && workers.contains(t) { return nil }
            return question(q, session: ref)
        }
    }

    /// A question that the daemon cannot answer shows as waiting: the card then offers "Open in Orca".
    public func question(_ q: DaemonQuestion, session: SessionRef) -> SessionQuestion {
        let via: SessionQuestion.Via
        switch q.via {
        case .form: via = .form
        case .permission: via = .permission
        case .turn: via = .turn
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
        case .error: throw ProviderError.vendor(code: r.code ?? "error", message: r.message ?? "\(link.machine) did not send the answer")
        }
    }

    public func answerGiven(_ q: SessionQuestion) async throws -> QuestionAnswer? {
        guard let id = daemonID(q.id), let a = try await client.given(id) else { return nil }
        return QuestionAnswer(question: q.id, items: a.items, note: a.note)
    }

    var prefix: String { "daemon:\(link.machine):" }

    func questionID(_ id: QuestionID) -> QuestionID { QuestionID(rawValue: prefix + id.rawValue) }

    func daemonID(_ id: QuestionID) -> String? {
        id.rawValue.hasPrefix(prefix) ? String(id.rawValue.dropFirst(prefix.count)) : nil
    }
}

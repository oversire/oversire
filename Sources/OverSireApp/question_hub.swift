import Cocoa
import OverSireAI
import OverSireCore
import OverSireSync
import RuntimeOrca

// ─── Question hub ────────────────────────────────────────────────────────────
// The question board of the app. It gives the board the sessions of the open work, maps each session to its item,
// keeps the drafts of the cards, and tells the pages when the board changes.

final class QuestionHub {
    static let changed = Notification.Name("QuestionHubChanged")

    private let agents: AgentIndex
    private let writes: StoreWrites
    private let lock = NSLock()
    private var refs: [SessionRef: String] = [:]          // Orca session → item key
    private var intake: [SessionRef: ItemRef] = [:]       // Enhance worker → intake item
    private var drafts: [QuestionID: QuestionDraft] = [:]
    private var seeded: [QuestionBoard.Entry]?
    private var notified: Set<QuestionID> = []
    private var timer: Timer?
    private(set) var board: QuestionBoard?
    /// Posts one notification for a question that waits this long. nil: never.
    var tellAfter: () -> TimeInterval? = { AGENTS.questionNotice.delay }
    var notify: (_ key: String?, _ title: String, _ body: String) -> Void = { _, _, _ in }
    /// The answers of the runner sessions: the daemon of the session, else the hub.
    var sender: any RunnerAnswerSending = RUNNER_DESK

    init(agents: AgentIndex, writes: StoreWrites) {
        self.agents = agents
        self.writes = writes
    }

    /// Makes the board with the runtimes that have questions, and the runner channel.
    func start(channels: [any QuestionChannel]) {
        board?.stop()
        let runner = RunnerQuestions(store: writes.store, sender: sender)
        let b = QuestionBoard(channels: channels + [runner], sessions: { [weak self] in self?.sessions() ?? [] }, store: writes.store)
        attach(b)
        resolve()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.resolve()
            self?.tell()
        }
        b.start()
    }

    /// Uses the board without its timers. `start` calls it, and the tests too.
    func attach(_ b: QuestionBoard) {
        b.onChange = { [weak self] _ in DispatchQueue.main.async { self?.changed() } }
        board = b
    }

    func stop() {
        board?.stop()
        timer?.invalidate()
    }

    /// A sleep can break the changes streams. A new start opens them again and reads at once.
    func didWake() { board?.start() }

    /// For `--uishots`: fixed entries and no board.
    func seed(_ entries: [QuestionBoard.Entry], keys: [SessionRef: String], intake: [SessionRef: ItemRef] = [:]) {
        seeded = entries
        lock.withLock {
            refs.merge(keys) { _, b in b }
            self.intake.merge(intake) { _, b in b }
        }
    }

    // MARK: Reads

    /// An Enhance worker has its own cards, so a turn question of it does not show.
    var entries: [QuestionBoard.Entry] {
        let intake = lock.withLock { self.intake }
        return (seeded ?? board.map { Array($0.entries.values) } ?? [])
            .filter { $0.question.via != .turn || intake[$0.question.session] == nil }
            .sorted { $0.question.askedAt < $1.question.askedAt }
    }

    /// The item key of the question: its origin, else the work item of its Orca session.
    func key(_ q: SessionQuestion) -> String? {
        origin(q).item?.key ?? lock.withLock { refs[q.session] }
    }

    /// The origin of the question. A question of an Enhance worker is about its intake item.
    func origin(_ q: SessionQuestion) -> SessionQuestion.Origin {
        lock.withLock { intake[q.session] }.map { .intake($0) } ?? q.origin
    }

    func entries(key: String) -> [QuestionBoard.Entry] { entries.filter { self.key($0.question) == key } }

    /// The entries that wait for the user.
    var open: [QuestionBoard.Entry] { entries.filter { $0.state == .open } }

    func open(key: String) -> [QuestionBoard.Entry] { entries(key: key).filter { $0.state == .open } }

    func open(session: SessionRef) -> [QuestionBoard.Entry] { open.filter { $0.question.session == session } }

    /// The open questions of one session. One round can hold up to 4.
    func count(session: SessionRef) -> Int { open(session: session).reduce(0) { $0 + $1.question.items.count } }

    /// The Session column text of a work item: "✦ 2 questions", "✦ 1 question · in Orca" or "✓ Answered in Orca · works".
    func line(key: String) -> String? {
        let all = entries(key: key)
        let waiting = all.filter { $0.state == .open || $0.state == .sending }
        if !waiting.isEmpty {
            let n = waiting.reduce(0) { $0 + $1.question.items.count }
            let word = waiting.allSatisfy { $0.question.via == .permission } ? "permission" : "question"
            let text = "✦ \(n) \(word)\(n == 1 ? "" : "s")"
            return waiting.allSatisfy { !$0.question.answerable } ? text + " · in \(place(waiting[0].question).runtime)" : text
        }
        guard let last = all.last else { return nil }
        switch last.state {
        case .answeredHere: return "✓ Answered · works"
        case .answeredElsewhere: return "✓ Answered in \(place(last.question).runtime) · works"
        default: return nil
        }
    }

    /// The open questions of the item. One round can hold up to 4.
    func count(key: String) -> Int { open(key: key).reduce(0) { $0 + $1.question.items.count } }

    func checkedAt(_ q: SessionQuestion) -> Date? {
        seeded != nil ? Date().addingTimeInterval(-8) : board?.checkedAt(q.session.workspace.account)
    }

    func place(_ q: SessionQuestion) -> QuestionPlace {
        let account = q.session.workspace.account
        if account.provider == RunnerQuestions.provider {
            let runner = writes.load(RunnerSession.self).first { $0.session == q.session }?.runner
            let state = writes.load(RunnerState.self).first { $0.device == runner }
            return QuestionPlace(runtime: "OverSire runner", host: runner ?? "runner", local: false, offline: state.map { !$0.online } ?? false)
        }
        let name = ENV.registry.descriptors(.runtime).first { $0.id == account.provider }?.displayName ?? account.provider.rawValue.capitalized
        if let env = (ENV.provider(account) as? OrcaRuntime)?.environment { return QuestionPlace(runtime: name, host: "remote: \(env)", local: false) }
        return QuestionPlace(runtime: name, host: "this Mac")
    }

    // MARK: Cards and actions

    func card(_ e: QuestionBoard.Entry, stop: (() -> Void)? = nil) -> QuestionCard {
        let id = e.id
        var a = QuestionCard.Actions()
        a.send = { [weak self] answer in self?.answer(id, answer) }
        a.dismiss = { [weak self] in self?.dismiss(id) }
        a.draft = { [weak self] d in self?.lock.withLock { self?.drafts[id] = d } }
        a.stop = stop
        if channel(e.question) is any Revealing { a.reveal = { [weak self] in self?.reveal(e.question) } }
        return QuestionCard(e, place: place(e.question), checkedAt: checkedAt(e.question), draft: lock.withLock { drafts[id] } ?? QuestionDraft(), actions: a)
    }

    func answer(_ id: QuestionID, _ a: QuestionAnswer) {
        guard let board else { return }
        Task {
            do {
                try await board.answer(id, a)
                self.lock.withLock { self.drafts[id] = nil }
            } catch {
                log.error("Question answer failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func dismiss(_ id: QuestionID) {
        board?.dismiss(id)
        if var s = seeded {
            s.removeAll { $0.id == id }
            seeded = s
            changed()
        }
    }

    func reveal(_ q: SessionQuestion) {
        guard let r = channel(q) as? any Revealing else { return }
        Task { try? await r.reveal(q.session) }
    }

    private func channel(_ q: SessionQuestion) -> (any AgentRuntime)? {
        let account = q.session.workspace.account
        return account.provider == RunnerQuestions.provider ? nil : ENV.provider(account) as? any AgentRuntime
    }

    // MARK: Sessions

    /// The board asks the worker of an Enhance run, and its questions show in the intake row.
    func track(intake s: SessionRef, item: ItemRef) {
        lock.withLock { intake[s] = item }
        board?.poke()
    }

    func untrack(intake s: SessionRef) { lock.withLock { intake[s] = nil } }

    /// The Orca sessions of the open work items, and the runner sessions that have not ended.
    private func sessions() -> [SessionRef] {
        let orca = lock.withLock { Array(refs.keys) + Array(intake.keys) }
        return orca + writes.load(RunnerSession.self).filter { !$0.state.ended }.map(\.session)
    }

    /// Finds the terminal of each work item. One `sessions` call for each workspace.
    private func resolve() {
        guard seeded == nil, let rt = ENV.runtime else { return }
        let live = agents.agents.filter { $0.value.card != nil && $0.value.phase != .failed }
        Task {
            var map: [SessionRef: String] = [:]
            for (card, group) in Dictionary(grouping: live, by: { $0.value.card! }) {
                guard let ts = try? await rt.sessions(WorkspaceRef(account: rt.account, id: card)) else { continue }
                for (key, a) in group { if let t = AgentIndex.pick(ts, agent: a, key: key) { map[t.ref] = key } }
            }
            let grew = self.lock.withLock { () -> Bool in
                defer { self.refs = map }
                return !Set(map.keys).isSubset(of: Set(self.refs.keys))
            }
            if grew { self.board?.poke() }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changed, object: self)
        tell()
    }

    /// One macOS notification for each question that waits longer than the setting.
    private func tell() {
        guard let after = tellAfter() else { return }
        let now = Date()
        for e in open where !notified.contains(e.id) && now.timeIntervalSince(e.question.askedAt) >= after {
            notified.insert(e.id)
            let key = key(e.question)
            notify(key, "\(key ?? "A session") asks a question", e.question.items.first?.text ?? "")
        }
    }
}

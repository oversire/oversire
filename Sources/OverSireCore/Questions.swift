import Foundation

// ─── Session questions ───────────────────────────────────────────────────────
// A session that stops to ask the user something. Each runtime that can find these questions is a QuestionChannel.
// QuestionBoard reads all channels and owns the state of each question. The UI reads only the board.

/// "<channel>:<message or tool_use id>". The same in each read of the same question.
public struct QuestionID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

public struct SessionQuestion: Identifiable, Hashable, Sendable, Codable {
    public enum Origin: Hashable, Sendable, Codable {
        case work(ItemRef), intake(ItemRef), session

        public var item: ItemRef? {
            switch self {
            case .work(let i), .intake(let i): return i
            case .session: return nil
            }
        }
    }

    /// How the question reached OverSire. `waiting`: the session waits, and OverSire cannot read the screen.
    /// `turn`: the last reply of a turn ends with a question.
    public enum Via: String, Hashable, Sendable, Codable {
        case askReply, form, runnerInput, permission, waiting, turn
    }

    public let id: QuestionID
    public let session: SessionRef
    public let origin: Origin
    public let round: Int               // 1 for a work session; Enhance counts its rounds
    public let items: [QuestionItem]
    public let via: Via
    public let askedAt: Date
    public let expiresAt: Date?         // permissions only

    public init(id: QuestionID, session: SessionRef, origin: Origin, round: Int = 1, items: [QuestionItem], via: Via,
                askedAt: Date, expiresAt: Date? = nil) {
        self.id = id
        self.session = session
        self.origin = origin
        self.round = round
        self.items = items
        self.via = via
        self.askedAt = askedAt
        self.expiresAt = expiresAt
    }

    /// False when the runtime cannot answer it exactly. The card then shows "Open in Orca".
    public var answerable: Bool { via != .waiting }

    /// Throws when the answer does not fit the items.
    public func validate(_ a: QuestionAnswer) throws {
        guard a.question == id else { throw QuestionError.invalid("the answer is for \(a.question)") }
        for item in items {
            guard let ai = a.items.first(where: { $0.id == item.id }) else { throw QuestionError.invalid("no answer for \(item.id)") }
            try item.validate(ai)
        }
        let extra = Set(a.items.map(\.id)).subtracting(items.map(\.id))
        guard extra.isEmpty else { throw QuestionError.invalid("unknown items \(extra.sorted())") }
    }
}

public struct QuestionItem: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case single, multi, free, approve }

    public struct Option: Hashable, Sendable, Codable {
        public let label: String
        public let detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public let id: String
    public let header: String?          // short label, for example "Schema read"
    public let text: String
    public let why: String?
    public let kind: Kind
    public let options: [Option]        // empty for .free; [Allow, Deny] for .approve
    public let allowsOther: Bool        // a free text next to the options

    public init(id: String, header: String? = nil, text: String, why: String? = nil, kind: Kind, options: [Option] = [],
                allowsOther: Bool = false) {
        self.id = id
        self.header = header
        self.text = text
        self.why = why
        self.kind = kind
        self.options = options
        self.allowsOther = allowsOther
    }

    public static let allow = "Allow"
    public static let deny = "Deny"

    /// One .approve item with the options Allow and Deny.
    public static func approve(id: String, header: String? = nil, text: String) -> QuestionItem {
        QuestionItem(id: id, header: header, text: text, kind: .approve, options: [Option(label: allow), Option(label: deny)])
    }

    /// Throws when the answer does not fit this item: no choice for .single, an unknown label, empty .free.
    public func validate(_ a: QuestionAnswer.Item) throws {
        let other = a.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let labels = Set(options.map(\.label))
        if let bad = a.choices.first(where: { !labels.contains($0) }) { throw QuestionError.invalid("\(id): unknown option \(bad)") }
        if !other.isEmpty && !(allowsOther || kind == .free) { throw QuestionError.invalid("\(id): no free text allowed") }
        switch kind {
        case .single, .approve:
            let ok = a.choices.count == 1 || (a.choices.isEmpty && !other.isEmpty && kind == .single)
            guard ok else { throw QuestionError.invalid("\(id): choose one option") }
        case .multi:
            guard !a.choices.isEmpty || !other.isEmpty else { throw QuestionError.invalid("\(id): choose one or more options") }
        case .free:
            guard a.choices.isEmpty, !other.isEmpty else { throw QuestionError.invalid("\(id): write an answer") }
        }
    }
}

public struct QuestionAnswer: Hashable, Sendable, Codable {
    public struct Item: Hashable, Sendable, Codable {
        public let id: String
        public let choices: [String]    // option labels
        public let other: String?

        public init(id: String, choices: [String] = [], other: String? = nil) {
            self.id = id
            self.choices = choices
            self.other = other
        }
    }

    public let question: QuestionID
    public let items: [Item]
    public let note: String?

    public init(question: QuestionID, items: [Item], note: String? = nil) {
        self.question = question
        self.items = items
        self.note = note
    }
}

public enum AnswerResult: Equatable, Sendable { case sent, alreadyAnswered, gone }

public enum QuestionError: Error, Hashable, Sendable {
    case notAnswerable
    case notOpen
    case invalid(String)
}

public enum QuestionState: Hashable, Sendable, Codable {
    case open
    case sending
    case answeredHere(QuestionAnswer, at: Date)
    case answeredElsewhere(QuestionAnswer?, at: Date)   // nil: the channel cannot read it (remote Orca)
    case raced(at: Date)                                 // our send came after an answer in Orca
    case gone(at: Date)                                  // no answer, and the session stopped or the user pressed Esc

    /// When the question left the open states. nil while it is open or sending.
    public var closedAt: Date? {
        switch self {
        case .open, .sending: return nil
        case .answeredHere(_, let at), .answeredElsewhere(_, let at), .raced(let at), .gone(let at): return at
        }
    }
}

/// A runtime that can find and answer the questions of its sessions.
public protocol QuestionChannel: AgentRuntime {
    /// The open questions of these sessions now. A question that is not in the result is not open.
    func openQuestions(in sessions: [SessionRef]) async throws -> [SessionQuestion]
    /// Checks that the question is still open, then sends the answer. Safe to repeat with the same question id.
    func answer(_ q: SessionQuestion, _ a: QuestionAnswer) async throws -> AnswerResult
    /// The answer that was given outside OverSire, if the channel can read it.
    func answerGiven(_ q: SessionQuestion) async throws -> QuestionAnswer?
    /// A channel that can push calls this when its questions change. The board then reads at once.
    var changes: AsyncStream<Void>? { get }
    /// True when the id is one of this channel's. Two channels can share an account (Orca and a daemon of one machine).
    func owns(_ id: QuestionID) -> Bool
}

extension QuestionChannel {
    public func owns(_ id: QuestionID) -> Bool { true }
}

/// One question on the board, as the store keeps it.
public struct QuestionRecord: StoreRecord {
    public static let collection = "question-board"

    public let question: SessionQuestion
    public var state: QuestionState
    public let firstSeen: Date

    public init(question: SessionQuestion, state: QuestionState, firstSeen: Date) {
        self.question = question
        self.state = state
        self.firstSeen = firstSeen
    }

    public var id: String { question.id.rawValue }
}

// ─── QuestionBoard ───────────────────────────────────────────────────────────

/// Owns the reads of all channels, the diff between two reads, and the state of each question.
public final class QuestionBoard: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        public var question: SessionQuestion
        public var state: QuestionState
        public let firstSeen: Date
        public var error: String?       // the last failed send
        public var stale = false        // the channel failed two reads in a row

        public init(question: SessionQuestion, state: QuestionState, firstSeen: Date, error: String? = nil, stale: Bool = false) {
            self.question = question
            self.state = state
            self.firstSeen = firstSeen
            self.error = error
            self.stale = stale
        }

        public var id: QuestionID { question.id }
    }

    /// How long an answered or gone question stays on the board.
    public static let fold: TimeInterval = 600
    /// After a launch, the app needs time to find its sessions. Before that, a missing session is not a stopped session.
    public static let grace: TimeInterval = 120

    private let channels: [any QuestionChannel]
    private let sessions: @Sendable () -> [SessionRef]
    private let clock: any Clock<Duration>
    private let interval: Duration
    private let store: (any Store)?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var table: [QuestionID: Entry] = [:]
    private var seen: [QuestionID: SessionQuestion] = [:]     // the last good read of each id
    private var failures: [Int: Int] = [:]                    // channel index → failed reads in a row
    private var reads: [AccountID: Date] = [:]
    private var dismissed: Set<QuestionID> = []
    private var known: Set<SessionRef> = []                   // the sessions of this run
    private var firstRead: Date?
    private var loops: [Task<Void, Never>] = []
    private var sleeper: Task<Void, Never>?
    private var poked = false
    private var handler: (([Entry]) -> Void)?

    public init(channels: [any QuestionChannel], sessions: @escaping @Sendable () -> [SessionRef], clock: any Clock<Duration> = ContinuousClock(),
                interval: Duration = .seconds(10), store: (any Store)? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.channels = channels
        self.sessions = sessions
        self.clock = clock
        self.interval = interval
        self.store = store
        self.now = now
    }

    public var entries: [QuestionID: Entry] { lock.withLock { table } }

    /// Runs after each change, on the task of the change.
    public var onChange: (([Entry]) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// Loads the store, then reads each `interval` and at once on a push.
    public func start() {
        stop()
        var tasks = [Task { [weak self] in
            await self?.load()
            await self?.loop()
        }]
        for c in channels {
            guard let stream = c.changes else { continue }
            tasks.append(Task { [weak self] in
                for await _ in stream { self?.poke() }
            })
        }
        lock.withLock { loops = tasks }
    }

    public func stop() {
        let old = lock.withLock { () -> [Task<Void, Never>] in
            defer { loops = []; sleeper = nil }
            sleeper?.cancel()
            return loops
        }
        old.forEach { $0.cancel() }
    }

    /// Reads at once, out of the 10 s cycle.
    public func poke() {
        lock.withLock {
            poked = true
            sleeper?.cancel()
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            await refresh()
            let s: Task<Void, Never>? = lock.withLock {
                if poked {
                    poked = false
                    return nil
                }
                let c = clock, d = interval
                sleeper = Task { try? await c.sleep(for: d) }
                return sleeper
            }
            await s?.value
            lock.withLock { poked = false }
        }
    }

    /// Restores the entries of the last run, so an answered question does not show as new.
    public func load() async {
        guard let store, let records = try? await store.all(QuestionRecord.self) else { return }
        lock.withLock {
            for r in records where table[r.question.id] == nil {
                table[r.question.id] = Entry(question: r.question, state: r.state, firstSeen: r.firstSeen)
            }
        }
    }

    /// Reads each channel once and moves the states.
    public func refresh() async {
        let all = sessions()
        // One read for each channel, by index. A channel that failed keeps its entries as they are.
        var reads: [Int: [SessionQuestion]] = [:]
        for (i, c) in channels.enumerated() {
            let mine = all.filter { $0.workspace.account == c.account }
            do {
                reads[i] = try await c.openQuestions(in: mine)
            } catch {
                markFailed(i)
            }
        }
        // All good reads of each account. A pause can move from one channel of the account to the other.
        var byAccount: [AccountID: [SessionQuestion]] = [:]
        for (i, read) in reads { byAccount[channels[i].account, default: []] += read }
        // Questions that left a good read. The board asks the channel how they ended.
        let missing: [Entry] = lock.withLock {
            table.values.filter { e in
                guard e.state == .open, let read = owner(e.question).flatMap({ reads[$0] }) else { return false }
                return !read.contains { $0.id == e.id }
            }
        }
        var given: [QuestionID: QuestionAnswer] = [:]
        for e in missing {
            guard let c = channel(for: e.question) else { continue }
            if let a = try? await c.answerGiven(e.question) { given[e.id] = a }
        }
        let live = Set(all)
        let t = now()
        let (changed, dropped) = lock.withLock { () -> ([Entry], [QuestionID]) in
            let before = table
            known.formUnion(live)
            let start = firstRead ?? t
            firstRead = start
            let readIDs = Set(reads.values.joined().map(\.id))
            dismissed = dismissed.filter { id in
                readIDs.contains(id) || seen[id].flatMap(owner).map { reads[$0] == nil } ?? false
            }
            for (i, read) in reads {
                let account = channels[i].account
                failures[i] = 0
                self.reads[account] = t
                for q in read where !dismissed.contains(q.id) {
                    seen[q.id] = q
                    if var e = table[q.id] {
                        e.question = q
                        e.stale = false
                        // A question that comes back is open again, unless we sent an answer or it expired.
                        let expired = q.expiresAt.map { $0 <= t } ?? false
                        switch e.state {
                        case .gone, .answeredElsewhere: if !expired { e.state = .open }
                        default: break
                        }
                        table[q.id] = e
                    } else {
                        table[q.id] = Entry(question: q, state: .open, firstSeen: t)
                    }
                }
                let ids = Set(read.map(\.id))
                for (id, e) in table where owner(e.question) == i && e.state == .open && !ids.contains(id) {
                    if let a = given[id] {
                        table[id]?.state = .answeredElsewhere(a, at: t)
                    } else if !live.contains(e.question.session) {
                        guard known.contains(e.question.session) || t.timeIntervalSince(start) >= Self.grace else { continue }
                        table[id]?.state = .gone(at: t)
                    } else {
                        table[id]?.state = .answeredElsewhere(nil, at: t)
                    }
                }
            }
            for (id, e) in table where e.state == .open {
                if let x = e.question.expiresAt, x <= t { table[id]?.state = .gone(at: t) }
            }
            var dropped: [QuestionID] = []
            // A channel can name one pause with a new id (a form page, or a transcript found later).
            // The old entry then left with no answer, and the read has a question of the same session and time.
            for (id, e) in table {
                switch e.state {
                case .gone, .answeredElsewhere(nil, _): break
                default: continue
                }
                guard let read = byAccount[e.question.session.workspace.account], !read.contains(where: { $0.id == id }),
                      read.contains(where: { $0.session == e.question.session && $0.askedAt == e.question.askedAt }) else { continue }
                table[id] = nil
                dropped.append(id)
            }
            for (id, e) in table {
                guard let closed = e.state.closedAt, t.timeIntervalSince(closed) >= Self.fold else { continue }
                if let read = byAccount[e.question.session.workspace.account], read.contains(where: { $0.id == id }) { continue }
                table[id] = nil
                dropped.append(id)
            }
            let changed = table.values.filter { before[$0.id] != $0 }
            return (changed, dropped)
        }
        await persist(changed, dropped: dropped)
    }

    /// Validates, then sends the answer through the channel of the question.
    public func answer(_ id: QuestionID, _ a: QuestionAnswer) async throws {
        guard let e = entries[id] else { throw QuestionError.notOpen }
        guard e.question.answerable else { throw QuestionError.notAnswerable }
        guard e.state == .open else { throw QuestionError.notOpen }
        try e.question.validate(a)
        guard let c = channel(for: e.question) else { throw QuestionError.notOpen }
        await set(id) {
            $0.state = .sending
            $0.error = nil
        }
        let result: AnswerResult
        do {
            result = try await c.answer(e.question, a)
        } catch {
            let message = (error as? ProviderError)?.message ?? "\(error)"
            await set(id) {
                $0.state = .open
                $0.error = message
            }
            throw error
        }
        let t = now()
        await set(id) {
            switch result {
            case .sent: $0.state = .answeredHere(a, at: t)
            case .alreadyAnswered: $0.state = .raced(at: t)
            case .gone: $0.state = .gone(at: t)
            }
        }
    }

    /// Takes the entry off the board now.
    public func dismiss(_ id: QuestionID) {
        let removed: Bool = lock.withLock {
            guard table.removeValue(forKey: id) != nil else { return false }
            if seen[id] != nil { dismissed.insert(id) }
            return true
        }
        guard removed else { return }
        Task { await persist([], dropped: [id]) }
    }

    /// The entries of one item, oldest first: the Session tab and the Work row.
    public func open(for item: ItemRef) -> [Entry] {
        lock.withLock { table.values.filter { $0.question.origin.item == item }.sorted { $0.question.askedAt < $1.question.askedAt } }
    }

    /// The time of the last good read of the channel of this account.
    public func checkedAt(_ account: AccountID) -> Date? { lock.withLock { reads[account] } }

    /// The questions that wait for the user: Home and the menu bar.
    public var openCount: Int { lock.withLock { table.values.filter { $0.state == .open }.count } }

    private func channel(for q: SessionQuestion) -> (any QuestionChannel)? { owner(q).map { channels[$0] } }

    /// The channel of the account that owns the id. Else the first channel of the account: an entry of a channel
    /// that left the board then still closes.
    private func owner(_ q: SessionQuestion) -> Int? {
        let account = q.session.workspace.account
        return channels.firstIndex { $0.account == account && $0.owns(q.id) } ?? channels.firstIndex { $0.account == account }
    }

    /// One failed read keeps the entries. The second marks them stale.
    private func markFailed(_ channel: Int) {
        let changed: Bool = lock.withLock {
            failures[channel, default: 0] += 1
            guard failures[channel]! >= 2 else { return false }
            var any = false
            for (id, e) in table where owner(e.question) == channel && !e.stale {
                table[id]?.stale = true
                any = true
            }
            return any
        }
        if changed { notify() }
    }

    private func set(_ id: QuestionID, _ change: (inout Entry) -> Void) async {
        let e: Entry? = lock.withLock {
            guard var e = table[id] else { return nil }
            change(&e)
            table[id] = e
            return e
        }
        await persist(e.map { [$0] } ?? [], dropped: [])
    }

    private func persist(_ changed: [Entry], dropped: [QuestionID]) async {
        guard !changed.isEmpty || !dropped.isEmpty else { return }
        notify()
        guard let store else { return }
        for e in changed where e.state != .sending {
            try? await store.put(QuestionRecord(question: e.question, state: e.state, firstSeen: e.firstSeen))
        }
        for id in dropped { try? await store.delete(QuestionRecord.self, id: id.rawValue) }
    }

    private func notify() {
        let (h, all) = lock.withLock { (handler, Array(table.values)) }
        h?(all.sorted { $0.question.askedAt < $1.question.askedAt })
    }
}

import Cocoa
import OverSireCore
import OverSireAI

// ─── Groom ───────────────────────────────────────────────────────────────────
// One read-only session for each project (start key `groom:<PROJECT>`) reads the open items from a file on the daemon,
// checks the code, asks the user what the code cannot tell, and ends with an `oversire-result` block of proposals.
// Nothing goes to the tracker before Apply. Apply writes one item at a time (GroomApplier). Undo uses the GroomJournal.

/// The calls of a runtime that runs a Groom session.
typealias GroomHost = EnhanceHost & HostFileWriting

final class GroomAgent {
    static let changed = Notification.Name("GroomAgentChanged")
    /// The most work time of one run. The time that a question waits does not count.
    static let timeout: TimeInterval = 3600
    /// A started session that the daemon does not list in this time failed.
    static let showTime: TimeInterval = 180
    static let keyPrefix = StartKey.groomPrefix
    /// Enhance sessions at the same time after "Apply, then Enhance".
    static let enhanceSlots = 2

    /// The choices of the start sheet.
    struct Options: Equatable {
        var scope: GroomScope = .all
        var stale = true
        var staleDays = 14
        var label: String?                // a label name: only the backlog items with it
    }

    /// What a run reads, before the start.
    struct Plan: Equatable {
        var intake: [IntakeItem]
        var backlog: [Item]
        var skipped: [String]             // keys with a live session, in a lane, or in a started state
        var stale: Int                    // items older than the stale days
        var count: Int { intake.count + backlog.count }
        var tooMany: Bool { count > GroomInput.limit }
        /// About 4 to 8 seconds for each item.
        var minutes: ClosedRange<Int> {
            let lo = max(1, count * 4 / 60)
            return lo...max(lo + 2, count * 8 / 60)
        }
    }

    struct Run: Equatable {
        var key: String                   // groom:<PROJECT>
        var session: SessionRef?
        var pane: String?
        var project: ProjectRef
        var keys: [String]                // the input keys, uppercased
        var intake: [String: IntakeItem] = [:]   // key → the intake item
        var open: Int
        var scope: GroomScope
        var skipped: [String]
        var since: Date
        var waited: TimeInterval = 0
        var askedAt: Date?
        var seen = false
        var recovered: Date?
        var rounds = 1
        /// "Ask again" sent a new turn: a done phase from before it is the old result.
        var resent: Date?

        func worked(_ now: Date) -> TimeInterval { now.timeIntervalSince(since) - waited - (askedAt.map { now.timeIntervalSince($0) } ?? 0) }
        func overdue(_ now: Date) -> Bool { worked(now) - (recovered.map { $0.timeIntervalSince(since) } ?? 0) > GroomAgent.timeout }
    }

    /// The result to review. The other Macs of the user see it too.
    struct Review: Codable, Equatable {
        var result: GroomResult
        var keys: [String]
        var intake: [String: IntakeItem]
        var open: Int
        var scope: GroomScope
        var skipped: [String]
        var rounds: Int
        var worked: TimeInterval
        var at: Date

        var input: Set<String> { Set(keys) }
        /// The lines that Apply can write. Vague lines write nothing.
        var changes: [GroomResult.Proposal] { result.proposals.filter { $0.kind != .vague && $0.isApplicable(in: input) } }
        var vague: [GroomResult.Proposal] { result.proposals.filter { $0.kind == .vague && $0.isApplicable(in: input) } }
    }

    enum State: Equatable {
        case starting(String)             // the step: "Reading 142 items…"
        case grooming(Run)
        case asking(Run, n: Int)
        case ready(Review, Run?)
        case applying(Review, done: Int, of: Int)
        case applied(Review, GroomOutcome)
        case failed(String, kept: String?)

        var run: Run? {
            switch self {
            case .grooming(let r), .asking(let r, _): return r
            case .ready(_, let r): return r
            default: return nil
            }
        }

        var review: Review? {
            switch self {
            case .ready(let r, _), .applying(let r, _, _), .applied(let r, _): return r
            default: return nil
            }
        }
    }

    private(set) var states: [String: State] = [:]          // project key → state
    private(set) var selected: [String: Set<String>] = [:]  // project key → the checked proposal ids
    /// Projects with a Groom that Undo can put back.
    private(set) var undoable: Set<String> = []
    /// The vague items that wait for an Enhance slot.
    private(set) var handoff: [String: [EnhanceTarget]] = [:]
    private var held: [String: Run] = [:]
    private var dropped: Set<String> = []
    private var recovering: Set<String> = []
    private var reading: Set<String> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let store: ProjectStore
    private let memory: ProjectMemory
    private let questions: QuestionHub
    private let agents: AgentIndex
    private let queue: WorkQueue
    private let enhance: EnhanceAgent
    let journal: GroomJournal
    var host: () -> (any GroomHost)? = { ENV.runtime as? any GroomHost }
    var now: () -> Date = { Date() }
    var areas: (String) -> [String] = { _ in [] }
    /// For `--uishots`: a state for a project that has none.
    var sample: ((String) -> State?)?
    var outputs: AIOutputBook? { didSet { attach() } }
    private var outputsObserver: NSObjectProtocol?

    init(store: ProjectStore, memory: ProjectMemory, questions: QuestionHub, agents: AgentIndex, queue: WorkQueue, enhance: EnhanceAgent,
         journal: GroomJournal) {
        self.store = store
        self.memory = memory
        self.questions = questions
        self.agents = agents
        self.queue = queue
        self.enhance = enhance
        self.journal = journal
        let nc = NotificationCenter.default
        observers = [nc.addObserver(forName: AgentIndex.changed, object: agents, queue: nil) { [weak self] _ in self?.sync() },
                     nc.addObserver(forName: QuestionHub.changed, object: questions, queue: nil) { [weak self] _ in self?.sync() },
                     nc.addObserver(forName: EnhanceAgent.changed, object: enhance, queue: nil) { [weak self] _ in self?.pump() }]
        Task {
            let keys = await journal.projects()
            await MainActor.run { self.undoable = Set(keys) }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        outputsObserver.map(NotificationCenter.default.removeObserver)
    }

    private func attach() {
        outputsObserver.map(NotificationCenter.default.removeObserver)
        guard let outputs else { return }
        outputsObserver = NotificationCenter.default.addObserver(forName: AIOutputBook.changed, object: outputs, queue: .main) { [weak self] _ in self?.absorb() }
        absorb()
    }

    // A saved review shows after a restart, or when the other app finished the run. A review that the other app applied goes.
    private func absorb() {
        guard let outputs else { return }
        let saved = Dictionary(outputs.all(.groomReview, as: Review.self).map { ($0.subject, $0.value) }, uniquingKeysWith: { a, _ in a })
        for (pk, r) in saved {
            switch states[pk] {
            case nil, .failed: ready(pk, r, run: held[pk])
            default: continue
            }
        }
        for (pk, s) in states {
            if case .ready = s, saved[pk] == nil { drop(pk) }
        }
    }

    /// The Groom buttons show. With an old daemon they show too, and a start tells the user to update it.
    var available: Bool { AI_CFG.intakeAgent && host()?.capabilities.contains(.sessionHistory) == true }
    var ready: Bool { available && host()?.capabilities.isSuperset(of: [.sessionKey, .hostFiles]) == true }

    func state(_ projectKey: String) -> State? { states[projectKey] ?? sample?(projectKey) }

    // MARK: Plan

    /// The items of the scope. Closed items do not count. An item with a live session, in a lane or in a started state is skipped.
    func plan(_ projectKey: String, _ o: Options) -> Plan? {
        guard let snap = store.snapshots[projectKey] else { return nil }
        let id = snap.summary.identifier
        var skipped: [String] = []
        let intake = (snap.intake ?? []).filter { i in
            guard let n = store.intakeKeys[i.workItemId] else { return true }
            let key = "\(id)-\(n)"
            if busy(key) { skipped.append(key); return false }
            return true
        }
        var backlog: [Item] = []
        if o.scope == .all {
            let waiting = Set((snap.intake ?? []).map(\.workItemId))
            for item in snap.items where !waiting.contains(item.id) {
                guard let c = snap.option(item.statusOptionId)?.category, c != .done else { continue }
                guard o.label == nil || item.labels.contains(where: { $0.caseInsensitiveCompare(o.label!) == .orderedSame }) else { continue }
                if c != .todo || busy(item.key) { skipped.append(item.key); continue }
                backlog.append(item)
            }
        }
        let old = now().addingTimeInterval(-TimeInterval(o.staleDays) * 86400)
        let stale = o.stale ? intake.filter { $0.createdAt < old }.count + backlog.filter { $0.updatedAt < old }.count : 0
        return Plan(intake: intake, backlog: backlog, skipped: skipped.sorted(), stale: stale)
    }

    private func busy(_ key: String) -> Bool { agents.agent(key) != nil || queue.contains(key) }

    /// The machine of the sessions: "mbp".
    var place: String {
        guard let rt = host() else { return "no machine" }
        return rt is any Revealing ? "this Mac" : rt.account.id
    }

    // MARK: Start

    func start(projectKey: String, options o: Options) {
        guard let rt = host() else { set(projectKey, .failed("Install the OverSire daemon in Settings › Machines.", kept: nil)); return }
        guard ready else { set(projectKey, .failed("Update the daemon on \(rt.account.id) to use Groom.", kept: nil)); return }
        guard let snap = store.snapshots[projectKey], let plan = plan(projectKey, o) else { return }
        guard let root = PROJECTS_CFG.orca.roots[projectKey], !root.isEmpty else {
            set(projectKey, .failed("Choose an Orca workspace for \(snap.summary.identifier) first: start any item of the project once.", kept: nil))
            return
        }
        guard !plan.tooMany else { set(projectKey, .failed(GroomInput.TooMany(count: plan.count).description, kept: nil)); return }
        if let old = held.removeValue(forKey: projectKey) { stop(old) }
        outputs?.remove(.groomReview, projectKey)
        set(projectKey, .starting("Reading \(plan.count) items…"))
        let tracker = store.tracker(of: snap.summary.ref)
        let keys = store.intakeKeys
        let vision = memory.vision(of: snap.summary.ref)?.text
        let template = AGENTS.groomPrompt
        let areas = areas
        Task {
            do {
                let details = await Self.intakeDetails(plan.intake, tracker: tracker, project: snap.summary.ref)
                let (items, intake) = Self.items(plan, snap: snap, intakeKeys: keys, details: details, areas: areas)
                let data = try GroomInput.jsonLines(items)
                let name = "groom-\(snap.summary.identifier.lowercased()).jsonl"
                let paths = try await rt.writeFiles([HostFile(name: name, data: data)], workspacePath: root,
                                                    dir: "/tmp/oversire/groom-" + UUID().uuidString.lowercased()) { _, _ in }
                guard let file = paths.first else { throw ProviderError.transport("The daemon did not take the item file.") }
                var note = ["The file has \(items.count) items."]
                if !plan.skipped.isEmpty {
                    note.append("These items are not in the file: they have a live session, wait in the queue, or are in a started state: "
                                + plan.skipped.joined(separator: ", ") + ".")
                }
                if !o.stale { note.append("Do not do step 2: the user turned off the stale check.") }
                let input = GroomPrompt.input(project: snap.summary.identifier, file: file, scope: o.scope, staleDays: o.staleDays,
                                              vision: vision, note: note.joined(separator: " "))
                let req = LaunchRequest(repo: root, agent: .claude, prompt: GroomPrompt.render(template, input),
                                        title: "Groom " + snap.summary.identifier, inPlace: true, key: StartKey.groom(snap.summary.identifier))
                let l = try await rt.launch(req)
                await MainActor.run {
                    let session = SessionRef(workspace: WorkspaceRef(account: rt.account, id: l.card), id: l.handle)
                    self.begin(projectKey, Run(key: req.key!, session: session, pane: l.paneKey.isEmpty ? nil : l.paneKey, project: snap.summary.ref,
                                               keys: items.map { $0.key.uppercased() }, intake: intake, open: items.count, scope: o.scope,
                                               skipped: plan.skipped, since: self.now()))
                    self.agents.poll()
                }
            } catch {
                await MainActor.run { self.set(projectKey, .failed((error as? ProviderError)?.message ?? "\(error)", kept: nil)) }
            }
        }
    }

    /// The bodies of the intake items: one listing, else one call for each item.
    static func intakeDetails(_ intake: [IntakeItem], tracker: (any Tracker)?, project: ProjectRef) async -> [String: IntakeDetail] {
        guard !intake.isEmpty else { return [:] }
        var out = (try? await (tracker as? any IntakeListing)?.intakeDetails(project)) ?? [:]
        guard let t = tracker as? any IntakeTriaging else { return out }
        for i in intake where out[i.workItemId] == nil {
            if let d = try? await t.intakeDetail(i, in: project) { out[i.workItemId] = d }
        }
        return out
    }

    /// The lines of the input file, and the intake item of each intake key. An intake item with no number yet is left out.
    static func items(_ plan: Plan, snap: ProjectSnapshot, intakeKeys: [String: Int], details: [String: IntakeDetail],
                      areas: (String) -> [String]) -> (items: [GroomItem], intake: [String: IntakeItem]) {
        let id = snap.summary.identifier
        var intake: [String: IntakeItem] = [:]
        let notes = plan.intake.compactMap { i -> GroomItem? in
            guard let n = intakeKeys[i.workItemId] ?? details[i.workItemId]?.sequence else { return nil }
            let d = details[i.workItemId], key = "\(id)-\(n)"
            intake[key.uppercased()] = i
            return GroomItem(key: key, title: i.name, body: d?.body ?? "", state: "Intake", labels: d?.labels ?? [],
                             areas: areas(key), created: i.createdAt, updated: i.createdAt, intake: true, markers: OverSireBlock.markers)
        }
        return (notes + plan.backlog.map { i in
            GroomItem(key: i.key, title: i.title, body: i.body ?? "", state: snap.option(i.statusOptionId)?.name ?? "", labels: i.labels,
                      areas: areas(i.key), updated: i.updatedAt, comments: i.commentCount, markers: OverSireBlock.markers)
        }, intake)
    }

    func begin(_ projectKey: String, _ run: Run) {
        if let s = run.session, let snap = store.snapshots[projectKey] {
            let url = URL(string: snap.summary.url) ?? URL(fileURLWithPath: "/")
            questions.track(intake: s, item: ItemRef(project: run.project, id: run.key, key: snap.summary.identifier, url: url))
        }
        held[projectKey] = run
        set(projectKey, .grooming(run))
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard states.values.contains(where: \.isLive) else {
            timer?.invalidate()
            timer = nil
            return
        }
        sync()
        NotificationCenter.default.post(name: GroomAgent.changed, object: self)
    }

    private var live: [AgentSession] {
        agents.cards.flatMap { c in c.agents.filter { $0.key?.hasPrefix(Self.keyPrefix) == true } }
    }

    func sync() {
        let live = live
        for (pk, s) in states where s.isLive { if let run = s.run { follow(pk, run, in: live) } }
        recover(live)
    }

    private func follow(_ pk: String, _ old: Run, in live: [AgentSession]) {
        var run = old
        let t = now()
        guard let a = live.first(where: { $0.key == run.key && (run.pane == nil || $0.paneKey == run.pane) }) else {
            if run.seen {
                finish(pk, run, .failed("The session ended with no result.", kept: nil))
            } else if t.timeIntervalSince(run.since) > Self.showTime {
                finish(pk, run, .failed("The session did not show on \(place). Try again.", kept: nil))
            }
            return
        }
        run.seen = true
        if run.pane == nil { run.pane = a.paneKey }
        held[pk] = run
        let n = run.session.map { questions.count(session: $0) } ?? 0
        let old = run.resent.map { a.since <= $0 } ?? false
        switch a.phase {
        case .failed:
            finish(pk, run, .failed(a.message ?? "The session did not start.", kept: nil))
        case .done where n == 0 && !a.needsInput && !old:
            read(pk, run, a)
        default:
            if n > 0 || a.needsInput {
                if run.askedAt == nil { run.askedAt = t }
                set(pk, .asking(run, n: max(n, 1)))
            } else {
                if let at = run.askedAt { run.waited += t.timeIntervalSince(at); run.askedAt = nil }
                if run.overdue(t) {
                    finish(pk, run, .failed("No result after 60 minutes of work. Open the session to look.", kept: nil))
                } else {
                    set(pk, .grooming(run))
                }
            }
        }
    }

    // Reads the last turn once: the last message of the session list is clipped.
    private func read(_ pk: String, _ run: Run, _ a: AgentSession) {
        guard !reading.contains(pk) else { return }
        guard let rt = host(), let ws = agents.cards.first(where: { $0.id == a.card }) else { settle(pk, run, a.message, nil); return }
        reading.insert(pk)
        Task {
            let d = try? await rt.history(of: a, in: ws, budget: HistoryBudget(earlier: 0, full: 1, maxChars: 200_000))
            DispatchQueue.main.async {
                self.reading.remove(pk)
                guard let cur = self.states[pk]?.run, cur.pane == run.pane, self.states[pk]?.isLive == true else { return }
                self.settle(pk, cur, d?.last.last?.text, a.message)
            }
        }
    }

    private func settle(_ pk: String, _ run: Run, _ last: String?, _ message: String?) {
        var run = run
        guard let result = [last, message].compactMap({ $0 }).lazy.compactMap({ GroomResult.parse(lastMessage: $0) }).first else {
            finish(pk, run, .failed("The agent sent no result that OverSire can read. Its text is below.", kept: last ?? message))
            return
        }
        if let at = run.askedAt { run.waited += now().timeIntervalSince(at); run.askedAt = nil }
        if let s = run.session { questions.untrack(intake: s) }
        held[pk] = run
        let review = Review(result: result, keys: run.keys, intake: run.intake, open: run.open, scope: run.scope, skipped: run.skipped, rounds: run.rounds,
                            worked: run.worked(now()), at: now())
        outputs?.put(.groomReview, pk, hash: "", review, at: review.at, keep: 50)
        ready(pk, review, run: run)
    }

    private func ready(_ pk: String, _ review: Review, run: Run?) {
        selected[pk] = Set(review.changes.filter { $0.confidence == .sure }.map(\.id))
        set(pk, .ready(review, run))
    }

    private func finish(_ pk: String, _ run: Run, _ s: State) {
        if let t = run.session { questions.untrack(intake: t) }
        held[pk] = run
        set(pk, s)
    }

    // A restart, or a run of the other app: the daemon has a Groom session that this app does not follow.
    private func recover(_ live: [AgentSession]) {
        guard !live.isEmpty, let rt = host(), ready else { return }
        let known = Set(held.values.compactMap(\.pane)).union(dropped).union(recovering)
        for a in live where a.phase != .failed {
            guard let pane = a.paneKey, let key = a.key, let card = a.card, !known.contains(pane),
                  let pk = project(of: key), let snap = store.snapshots[pk] else { continue }
            let state = states[pk]
            // A saved review of this session: the run comes back for Ask again.
            let reviewed = state?.review.map { $0.at >= (a.startedAt ?? a.since) } ?? false
            guard state == nil || reviewed || state?.isApplied == true else { continue }
            recovering.insert(pane)
            Task {
                let t = try? await rt.sessions(WorkspaceRef(account: rt.account, id: card)).first { $0.paneKey == pane }?.ref
                DispatchQueue.main.async {
                    self.recovering.remove(pane)
                    let plan = self.plan(pk, Options())
                    let input = plan.map { GroomAgent.items($0, snap: snap, intakeKeys: self.store.intakeKeys, details: [:], areas: { _ in [] }) }
                    let keys = input?.items.map { $0.key.uppercased() } ?? []
                    var run = Run(key: key, session: t, pane: pane, project: snap.summary.ref, keys: keys, intake: input?.intake ?? [:], open: keys.count,
                                  scope: .all, skipped: plan?.skipped ?? [], since: a.startedAt ?? a.since, seen: true, recovered: self.now())
                    if case .ready(let r, nil) = self.states[pk] {
                        run.keys = r.keys
                        run.intake = r.intake
                        run.open = r.open
                        run.scope = r.scope
                        self.held[pk] = run
                        self.set(pk, .ready(r, run))
                    } else if self.states[pk] == nil || self.states[pk]?.isApplied == true {
                        self.begin(pk, run)
                        self.sync()
                    }
                }
            }
        }
    }

    /// The project key of a start key groom:<IDENTIFIER>.
    func project(of startKey: String) -> String? {
        let id = startKey.dropFirst(Self.keyPrefix.count).uppercased()
        return store.snapshots.first { $0.value.summary.identifier.uppercased() == id }?.key
    }

    // MARK: Review

    func isChecked(_ pk: String, _ p: GroomResult.Proposal) -> Bool { selected[pk]?.contains(p.id) == true }

    func toggle(_ pk: String, _ p: GroomResult.Proposal) {
        guard state(pk)?.review?.changes.contains(where: { $0.id == p.id }) == true else { return }
        if selected[pk, default: []].remove(p.id) == nil { selected[pk, default: []].insert(p.id) }
        NotificationCenter.default.post(name: GroomAgent.changed, object: self)
    }

    /// "Ask again": a new turn in the same session. The agent checks its lines and sends a new block.
    func askAgain(_ pk: String) {
        guard case .ready(_, let r?) = states[pk], let s = r.session, let rt = host() else { return }
        var run = r
        run.resent = now()
        run.rounds += 1
        run.askedAt = nil
        outputs?.remove(.groomReview, pk)
        begin(pk, run)
        Task { [run] in
            let text = "Check your proposals again. Ask me with AskUserQuestion about each line that you are not sure about. "
                + "Then end with a new oversire-result block that holds all lines."
            if case .failure(let e) = await Result(awaiting: { try await rt.send(s, text: text) }) {
                await MainActor.run { self.finish(pk, run, .failed(e.message, kept: nil)) }
            }
        }
    }

    /// The items of the project as apply targets. An intake item gets its intake page as the link.
    func targets(_ pk: String, _ review: Review) -> [String: GroomApplier.Target] {
        guard let snap = store.snapshots[pk] else { return [:] }
        var out: [String: GroomApplier.Target] = [:]
        for item in snap.items { if let r = item.ref(in: snap.summary.ref) { out[item.key.uppercased()] = .init(ref: r) } }
        let url = (store.tracker(of: snap.summary.ref) as? any IntakePage)?.intakeURL(snap.summary.ref) ?? snap.summary.url
        for (key, i) in review.intake {
            out[key] = .init(ref: ItemRef(project: snap.summary.ref, id: i.workItemId, key: key, url: URL(string: url) ?? URL(fileURLWithPath: "/")), intake: i)
        }
        return out
    }

    /// Writes the checked lines. With `enhance`, the vague items then wait for an Enhance slot.
    /// `only` writes again the failed lines of the last Apply ("Try again").
    func apply(_ pk: String, enhance withEnhance: Bool = false, only: Set<String>? = nil) {
        let review: Review
        var before = GroomOutcome()
        switch states[pk] {
        case .ready(let r, _): review = r
        case .applied(let r, let o) where only != nil: review = r; before = o
        default: return
        }
        guard let snap = store.snapshots[pk], let tracker = store.tracker(of: snap.summary.ref) else {
            set(pk, .failed("The project is not loaded.", kept: nil))
            return
        }
        let ids = only ?? selected[pk] ?? []
        let lines = review.changes.filter { ids.contains($0.id) }
        let vague = withEnhance ? review.vague : []
        if only == nil, let run = held.removeValue(forKey: pk) ?? states[pk]?.run { stop(run) }
        outputs?.remove(.groomReview, pk)
        set(pk, .applying(review, done: 0, of: lines.count))
        let applier = GroomApplier(tracker: tracker, snapshot: snap, targets: targets(pk, review), journal: journal, projectKey: pk)
        Task { [before] in
            if only == nil { await self.journal.begin(pk, project: snap.summary.ref, at: self.now()) }
            let out = await applier.apply(lines + vague) { n, of in
                DispatchQueue.main.async {
                    if case .applying = self.states[pk] { self.set(pk, .applying(review, done: min(n, lines.count), of: lines.count)) }
                }
            }
            let undo = await self.journal.last(pk) != nil
            await MainActor.run {
                var total = before
                total.written += out.written
                for id in out.written { total.failed[id] = nil }
                total.failed.merge(out.failed) { _, b in b }
                total.vague += out.vague.filter { !total.vague.contains($0) }
                if undo { self.undoable.insert(pk) }
                self.set(pk, .applied(review, total))
                self.store.refresh([pk], force: true) { _ in }
                if withEnhance { self.queueEnhance(pk, keys: out.vague, merged: Set(lines.flatMap(\.merged).map { $0.uppercased() })) }
            }
        }
    }

    // A vague item that a line merged away gets no Enhance.
    private func queueEnhance(_ pk: String, keys: [String], merged: Set<String>) {
        let found = keys.filter { !merged.contains($0) }.compactMap { enhance.find($0)?.target }
        handoff[pk, default: []] += found.filter { t in !(handoff[pk] ?? []).contains(t) }
        pump()
    }

    // Starts the next Enhance runs while a slot is free.
    private func pump() {
        let busy = enhance.states.values.filter { s in
            switch s {
            case .starting, .enhancing, .asking: return true
            default: return false
            }
        }.count
        var room = Self.enhanceSlots - busy
        for pk in handoff.keys.sorted() where room > 0 {
            while room > 0, var list = handoff[pk], !list.isEmpty {
                let t = list.removeFirst()
                handoff[pk] = list.isEmpty ? nil : list
                guard enhance.state(t) == nil else { continue }
                enhance.start(projectKey: pk, target: t)
                room -= 1
            }
        }
    }

    /// The items that changed after the last Groom. Undo leaves them as they are.
    func undoCheck(_ pk: String, done: @escaping ([String]) -> Void) {
        guard let snap = store.snapshots[pk], let tracker = store.tracker(of: snap.summary.ref) else { done([]); return }
        Task {
            let changed = await journal.changed(pk, tracker: tracker)
            await MainActor.run { done(changed) }
        }
    }

    func undo(_ pk: String, done: @escaping (GroomJournal.UndoOutcome) -> Void) {
        guard let snap = store.snapshots[pk], let tracker = store.tracker(of: snap.summary.ref) else { done(.init()); return }
        Task {
            let out = await journal.undo(pk, tracker: tracker)
            await MainActor.run {
                self.undoable.remove(pk)
                if self.states[pk]?.isApplied == true { self.drop(pk) }
                self.store.refresh([pk], force: true) { _ in }
                done(out)
            }
        }
    }

    // MARK: Session

    var canReveal: Bool { host() is any Revealing }

    func reveal(_ pk: String) {
        guard let s = (held[pk] ?? state(pk)?.run)?.session, let rt = host() else { return }
        Task {
            guard let r = rt as? any Revealing, case .failure(let e) = await Result(awaiting: { try await r.reveal(s) }) else { return }
            await MainActor.run { AlertConfirm.tell("Orca cannot show the session", info: e.message, in: NSApp.keyWindow) }
        }
    }

    /// Stops the session and forgets the run and its review.
    func discard(_ pk: String) {
        if let run = held[pk] ?? states[pk]?.run { stop(run) }
        outputs?.remove(.groomReview, pk)
        drop(pk)
    }

    func dismiss(_ pk: String) { drop(pk) }

    private func drop(_ pk: String) {
        if let t = held.removeValue(forKey: pk)?.session { questions.untrack(intake: t) }
        states[pk] = nil
        selected[pk] = nil
        NotificationCenter.default.post(name: GroomAgent.changed, object: self)
    }

    private func stop(_ run: Run) {
        if let t = run.session { questions.untrack(intake: t) }
        if let p = run.pane { dropped.insert(p) }
        guard let t = run.session, let rt = host() else { return }
        Task { _ = try? await rt.close(t) }
    }

    private func set(_ pk: String, _ s: State) {
        guard states[pk] != s else { return }
        states[pk] = s
        NotificationCenter.default.post(name: GroomAgent.changed, object: self)
    }

    // MARK: Words

    func pill(_ pk: String) -> (tone: Tone, text: String)? {
        state(pk).flatMap { Self.pill($0, now: now(), on: canReveal ? nil : host()?.account.id) }
    }

    /// "Grooming on mbp · 6m", "2 questions", "Groomed · 34 changes", "Written 32 of 33", "Groom failed".
    static func pill(_ s: State, now: Date = Date(), on machine: String? = nil) -> (tone: Tone, text: String)? {
        let word = "Grooming" + (machine.map { " on " + $0 } ?? "")
        switch s {
        case .starting: return (.question, word)
        case .grooming(let r): return (.question, word + " · \(max(1, Int(r.worked(now) / 60)))m")
        case .asking(_, let n): return (.question, "\(n) question\(n == 1 ? "" : "s")")
        case .ready(let r, _): return (.question, "Groomed · \(r.changes.count) change\(r.changes.count == 1 ? "" : "s")")
        case .applying(_, let n, let of): return (.question, "Writing \(n) of \(of)")
        case .applied(_, let o):
            let all = o.written.count + o.failed.count
            return (o.failed.isEmpty ? .ok : .warning, "Written \(o.written.count) of \(all)")
        case .failed: return (.bad, "Groom failed")
        }
    }
}

extension GroomAgent.State {
    var isLive: Bool {
        switch self {
        case .starting, .grooming, .asking: return true
        default: return false
        }
    }
    var isApplied: Bool { if case .applied = self { return true } else { return false } }
}

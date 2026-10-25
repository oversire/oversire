import Cocoa
import OverSireCore
import OverSireAI

// ─── Enhance ─────────────────────────────────────────────────────────────────
// A read-only session on the sessions machine reads the code for an intake item or a ticket, asks the user what the code cannot
// tell (the native AskUserQuestion form, shown with QuestionCard), and ends with an `oversire-result` block. The start key
// `enhance:<KEY>` keeps one session for each item, and each app finds it in the daemon sessions. The user then checks the
// properties to write. An intake item can be accepted in the same step.

/// The calls of a runtime that runs an Enhance session.
typealias EnhanceHost = SessionIO & SessionHistoryReading

/// A tracker with a web page for the intake of a project.
protocol IntakePage: Tracker { func intakeURL(_ p: ProjectRef) -> String }

/// What Enhance improves: a new intake item, or a ticket of the project.
enum EnhanceTarget: Hashable {
    case intake(IntakeItem)
    case item(ItemRef)

    /// The key of the state. The prefix keeps an item id apart from an intake id.
    var id: String {
        switch self {
        case .intake(let i): return i.id
        case .item(let r): return "item:" + r.id
        }
    }

    var isTicket: Bool { if case .item = self { return true } else { return false } }
}

final class EnhanceAgent {
    static let changed = Notification.Name("EnhanceAgentChanged")
    /// The most work time of one run. The time that a question waits does not count.
    static let timeout: TimeInterval = 1800
    /// A started session that the daemon does not list in this time failed.
    static let showTime: TimeInterval = 180
    static let keyPrefix = "enhance:"

    struct Run: Equatable {
        var key: String                // the start key, for example enhance:K-1
        var session: SessionRef?       // the terminal, that asks the questions
        var pane: String?              // the daemon session id
        var item: ItemRef
        var original: String
        var since: Date
        var waited: TimeInterval = 0
        var askedAt: Date?
        var seen = false               // the daemon listed the session

        func worked(_ now: Date) -> TimeInterval { now.timeIntervalSince(since) - waited - (askedAt.map { now.timeIntervalSince($0) } ?? 0) }
    }

    enum State: Equatable {
        case starting
        case enhancing(Run)
        case asking(Run, n: Int)
        case ready(EnhanceResult, Run)
        case applied(accepted: Bool)
        case failed(String, kept: String?)

        var run: Run? {
            switch self {
            case .enhancing(let r), .asking(let r, _), .ready(_, let r): return r
            default: return nil
            }
        }
    }

    /// A property of the review that the user can leave out.
    enum Pick: Hashable {
        case description, priority, label(String), relation(String)
    }

    /// What a start needs to know of the target.
    struct Spec {
        var kind: EnhancePrompt.Kind
        var ref: ItemRef
        var title: String
        var url: String
        var body: String
    }

    private(set) var states: [String: State] = [:]     // target id → state
    private(set) var picks: [String: Set<Pick>] = [:]  // target id → the unchecked properties
    private var held: [String: Run] = [:]              // target id → the run whose session can be open
    private var dropped: Set<String> = []              // the panes that this app stopped
    private var recovering: Set<String> = []
    private var reading: Set<String> = []
    private var timer: Timer?
    private var autoTried: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private let store: ProjectStore
    private let memory: ProjectMemory
    private let questions: QuestionHub
    private let agents: AgentIndex
    var host: () -> (any EnhanceHost)? = { ENV.runtime as? any EnhanceHost }
    var now: () -> Date = { Date() }
    /// For `--uishots`: a state for a target that has none.
    var sample: ((EnhanceTarget) -> State?)?

    init(store: ProjectStore, memory: ProjectMemory, questions: QuestionHub, agents: AgentIndex) {
        self.store = store
        self.memory = memory
        self.questions = questions
        self.agents = agents
        let nc = NotificationCenter.default
        observers = [nc.addObserver(forName: AgentIndex.changed, object: agents, queue: nil) { [weak self] _ in self?.sync() },
                     nc.addObserver(forName: QuestionHub.changed, object: questions, queue: nil) { [weak self] _ in self?.sync() }]
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// The Enhance buttons show. With an old daemon they show too, and a start tells the user to update it.
    var available: Bool { AI_CFG.intakeAgent && host()?.capabilities.contains(.sessionHistory) == true }
    /// The daemon keeps one session for each start key. A daemon before OVERSIRE-318 does not.
    var ready: Bool { available && host()?.capabilities.contains(.sessionKey) == true }

    func state(_ t: EnhanceTarget) -> State? { states[t.id] ?? sample?(t) }

    func spec(_ kind: EnhancePrompt.Kind, key: String, title: String, url: String, body: String, vision: String?) -> String {
        EnhancePrompt.render(AGENTS.intakePrompt, EnhancePrompt.input(kind: kind, key: key, title: title, url: url, body: body, vision: vision))
    }

    /// enhance:<KEY>. An intake item with no number yet uses its id.
    static func startKey(_ t: EnhanceTarget, ref: ItemRef) -> String {
        if AgentIndex.keyRE.firstMatch(in: ref.key, range: NSRange(ref.key.startIndex..., in: ref.key)) != nil { return keyPrefix + ref.key }
        switch t {
        case .intake(let i): return keyPrefix + i.id
        case .item(let r): return keyPrefix + r.id
        }
    }

    /// A short body with no steps. Quick triage starts Enhance for it when the setting is on.
    static func vague(_ body: String) -> Bool {
        body.split { $0.isWhitespace || $0.isNewline }.count < 25
    }

    /// Starts Enhance for the new vague items of the last day, at most two at a time.
    func autoStart() {
        guard AGENTS.enhanceVague, ready else { return }
        var room = 2 - states.values.filter { $0 == .starting || $0.run != nil && !$0.isReady }.count
        for (pk, snap) in store.snapshots {
            for item in snap.intake ?? [] where room > 0 && states[item.id] == nil && !autoTried.contains(item.id) {
                autoTried.insert(item.id)
                guard now().timeIntervalSince(item.createdAt) < 86400 else { continue }
                store.intakeDetail(projectKey: pk, item: item) { [weak self] r in
                    if case .success(let d) = r, EnhanceAgent.vague(d.body) { self?.start(projectKey: pk, target: .intake(item)) }
                }
                room -= 1
            }
        }
    }

    // Starts the session in the Orca workspace of the project. A run that failed stops its old session first.
    func start(projectKey: String, target: EnhanceTarget) {
        guard let rt = host() else { set(target.id, .failed("Install the OverSire daemon in Settings › Machines.", kept: nil)); return }
        guard ready else { set(target.id, .failed("Update the daemon on \(rt.account.id) to use Enhance.", kept: nil)); return }
        guard let snap = store.snapshots[projectKey] else { return }
        guard let root = PROJECTS_CFG.orca.roots[projectKey], !root.isEmpty else {
            set(target.id, .failed("Choose an Orca workspace for \(snap.summary.identifier) first: start any item of the project once.", kept: nil))
            return
        }
        set(target.id, .starting)
        prepare(projectKey, target) { [weak self] s in
            guard let self else { return }
            guard let s else { self.set(target.id, .failed("The project is not loaded.", kept: nil)); return }
            self.launch(target, s, root: root)
        }
    }

    private func prepare(_ projectKey: String, _ target: EnhanceTarget, done: @escaping (Spec?) -> Void) {
        guard let snap = store.snapshots[projectKey] else { done(nil); return }
        switch target {
        case .intake(let item):
            let url = (ENV.tracker(snap.summary.ref.workspace) as? any IntakePage)?.intakeURL(snap.summary.ref) ?? snap.summary.url
            store.intakeDetail(projectKey: projectKey, item: item) { [weak self] r in
                guard let self else { return }
                let detail = try? r.get()
                let key = (self.store.intakeKeys[item.workItemId] ?? detail?.sequence).map { "\(snap.summary.identifier)-\($0)" } ?? snap.summary.identifier
                let ref = ItemRef(project: snap.summary.ref, id: item.workItemId, key: key, url: URL(string: url) ?? URL(fileURLWithPath: "/"))
                done(Spec(kind: .intake, ref: ref, title: item.name, url: url, body: detail?.body ?? ""))
            }
        case .item(let ref):
            let item = store.item(key: ref.key)?.item
            done(Spec(kind: .ticket, ref: ref, title: item?.title ?? ref.key, url: ref.url.absoluteString, body: item?.body ?? ""))
        }
    }

    /// Starts one keyed session in place. The daemon gives the live session of the key when one runs.
    func launch(_ target: EnhanceTarget, _ s: Spec, root: String) {
        guard let rt = host() else { set(target.id, .failed("Install the OverSire daemon in Settings › Machines.", kept: nil)); return }
        let old = held.removeValue(forKey: target.id)
        if let old { forget(old) }
        let vision = memory.vision(of: s.ref.project)?.text
        let path = AGENTS.intakeScratch ? root + "/.wt/enhance-" + s.ref.key.lowercased() : root
        let req = LaunchRequest(repo: path, agent: .claude, prompt: spec(s.kind, key: s.ref.key, title: s.title, url: s.url, body: s.body, vision: vision),
                                title: "Enhance " + s.ref.key, inPlace: true, key: Self.startKey(target, ref: s.ref))
        Task {
            // The stop frees the key, so the start makes a new session.
            if let t = old?.session { _ = try? await rt.close(t) }
            if AGENTS.intakeScratch { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            let r = await Result(awaiting: { try await rt.launch(req) })
            DispatchQueue.main.async {
                switch r {
                case .success(let l):
                    let session = SessionRef(workspace: WorkspaceRef(account: rt.account, id: l.card), id: l.handle)
                    self.begin(target.id, Run(key: req.key!, session: session, pane: l.paneKey.isEmpty ? nil : l.paneKey, item: s.ref,
                                              original: s.body, since: self.now()))
                    self.agents.poll()
                case .failure(let e): self.set(target.id, .failed(e.message, kept: nil))
                }
            }
        }
    }

    /// Tracks the run. The daemon sessions of the agent index then move it.
    func begin(_ id: String, _ run: Run) {
        if let s = run.session { questions.track(intake: s, item: run.item) }
        held[id] = run
        set(id, .enhancing(run))
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // The work time and the pill minutes change with no session change.
    private func tick() {
        guard states.values.contains(where: { $0 == .starting || $0.isLive }) else {
            timer?.invalidate()
            timer = nil
            return
        }
        sync()
        NotificationCenter.default.post(name: EnhanceAgent.changed, object: self)
    }

    /// The Enhance sessions of the last agent index poll.
    private var live: [AgentSession] {
        agents.cards.flatMap { c in c.agents.filter { $0.key?.hasPrefix(Self.keyPrefix) == true } }
    }

    /// Moves each run to the state of its session, and follows the Enhance sessions that this app did not start.
    func sync() {
        let live = live
        for (id, s) in states { if let run = s.run { follow(id, run, in: live) } }
        recover(live)
    }

    private func follow(_ id: String, _ old: Run, in live: [AgentSession]) {
        var run = old
        let t = now()
        guard let a = live.first(where: { $0.key == run.key && (run.pane == nil || $0.paneKey == run.pane) }) else {
            if states[id]?.isReady == true {
                // Another app applied or dismissed the result.
                if run.seen { drop(id) }
            } else if run.seen {
                finish(id, run, .failed("The session ended with no result.", kept: nil))
            } else if t.timeIntervalSince(run.since) > Self.showTime {
                finish(id, run, .failed("The session did not show on \(place). Try again.", kept: nil))
            }
            return
        }
        guard states[id]?.isReady != true else { return }
        run.seen = true
        if run.pane == nil { run.pane = a.paneKey }
        held[id] = run
        let n = run.session.map { questions.count(session: $0) } ?? 0
        switch a.phase {
        case .failed:
            finish(id, run, .failed(a.message ?? "The session did not start.", kept: nil))
        case .done where n == 0 && !a.needsInput:
            read(id, run, a)
        default:
            if n > 0 || a.needsInput {
                if run.askedAt == nil { run.askedAt = t }
                set(id, .asking(run, n: max(n, 1)))
            } else {
                if let at = run.askedAt { run.waited += t.timeIntervalSince(at); run.askedAt = nil }
                if run.worked(t) > Self.timeout {
                    finish(id, run, .failed("No result after 30 minutes of work. Open the session to look.", kept: nil))
                } else {
                    set(id, .enhancing(run))
                }
            }
        }
    }

    // Reads the last turn once: the last message of the session list is clipped.
    private func read(_ id: String, _ run: Run, _ a: AgentSession) {
        guard !reading.contains(id) else { return }
        guard let rt = host(), let ws = agents.cards.first(where: { $0.id == a.card }) else { settle(id, run, a.message, nil); return }
        reading.insert(id)
        Task {
            let d = try? await rt.history(of: a, in: ws, budget: HistoryBudget(earlier: 0, full: 1, maxChars: 40000))
            DispatchQueue.main.async {
                self.reading.remove(id)
                guard let cur = self.states[id]?.run, cur.pane == run.pane, !(self.states[id]?.isReady ?? false) else { return }
                self.settle(id, cur, d?.last.last?.text, a.message)
            }
        }
    }

    private func settle(_ id: String, _ run: Run, _ last: String?, _ message: String?) {
        var run = run
        // A bare JSON object: a prompt that the user saved before the result block.
        let texts = [last, message].compactMap { $0 }
        guard let result = texts.lazy.compactMap({ EnhanceResult.parse(lastMessage: $0) }).first ?? texts.lazy.compactMap({ EnhanceResult.parse($0) }).first else {
            finish(id, run, .failed("The agent sent no result that OverSire can read. Its text is below.", kept: last ?? message))
            return
        }
        if let at = run.askedAt { run.waited += now().timeIntervalSince(at); run.askedAt = nil }
        if let s = run.session { questions.untrack(intake: s) }
        held[id] = run
        set(id, .ready(result, run))
    }

    private func finish(_ id: String, _ run: Run, _ s: State) {
        if let t = run.session { questions.untrack(intake: t) }
        held[id] = run
        set(id, s)
    }

    // A restart, or a run of the other app: the daemon has an Enhance session that this app does not follow.
    private func recover(_ live: [AgentSession]) {
        guard !live.isEmpty, let rt = host(), ready else { return }
        let known = Set(held.values.compactMap(\.pane)).union(dropped).union(recovering)
        for a in live where a.phase != .failed {
            guard let pane = a.paneKey, let key = a.key, let card = a.card, !known.contains(pane),
                  let (pk, target) = find(String(key.dropFirst(Self.keyPrefix.count))), states[target.id] == nil else { continue }
            recovering.insert(pane)
            prepare(pk, target) { [weak self] s in
                guard let self else { return }
                guard let s else { self.recovering.remove(pane); return }
                Task {
                    let t = try? await rt.sessions(WorkspaceRef(account: rt.account, id: card)).first { $0.paneKey == pane }?.ref
                    DispatchQueue.main.async {
                        self.recovering.remove(pane)
                        guard self.states[target.id] == nil else { return }
                        self.begin(target.id, Run(key: key, session: t, pane: pane, item: s.ref, original: s.body, since: a.since, seen: true))
                        self.sync()
                    }
                }
            }
        }
    }

    /// The target of a start key: an intake item by its key or id, else a ticket.
    func find(_ key: String) -> (projectKey: String, target: EnhanceTarget)? {
        let k = key.uppercased()
        for (pk, snap) in store.snapshots {
            for i in snap.intake ?? [] {
                let ik = store.intakeKeys[i.workItemId].map { "\(snap.summary.identifier)-\($0)".uppercased() }
                if ik == k || i.id == key || i.workItemId == key { return (pk, .intake(i)) }
            }
        }
        if let f = store.item(key: key), let ref = f.item.ref(in: f.snap.summary.ref) { return (f.key, .item(ref)) }
        return nil
    }

    // MARK: Review

    func isChecked(_ t: EnhanceTarget, _ p: Pick) -> Bool { !(picks[t.id] ?? []).contains(p) }

    func toggle(_ t: EnhanceTarget, _ p: Pick) {
        if picks[t.id, default: []].remove(p) == nil { picks[t.id, default: []].insert(p) }
    }

    /// The checked properties as one edit. Label names and relation keys that the project does not know drop,
    /// and so does a relation that makes a cycle in `graph`. A ticket has no duplicate action: its duplicate is a "relates to".
    func edit(_ item: EnhanceTarget, _ result: EnhanceResult, run: Run, labels: [StatusOption], keep: [String], items: [String: ItemRef],
              graph: BlockGraph = BlockGraph()) -> IntakeEdit {
        var graph = graph
        var patch = ItemPatch()
        if isChecked(item, .description) { patch.bodyMarkdown = result.description(keeping: run.original) }
        if let p = result.priority, isChecked(item, .priority) { patch.priority = p }
        let add = result.labels.filter { isChecked(item, .label($0)) }.compactMap { name in
            labels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        if !add.isEmpty { patch.labels = keep + add.filter { !keep.contains($0) } }
        let relations = result.relations.filter { isChecked(item, .relation($0.key)) }.compactMap { r -> ItemRelation? in
            let kind = r.relationKind ?? (item.isTicket && r.kind == "duplicate" ? .relatesTo : nil)
            guard let kind, let ref = items[r.key.uppercased()] else { return nil }
            let rel = ItemRelation(kind: kind, item: ref)
            return graph.add(run.item.key, rel) ? rel : nil
        }
        return IntakeEdit(patch: patch, relations: relations)
    }

    /// The edit with the start label next to the labels that the item keeps.
    static func queued(_ edit: IntakeEdit, label id: String, keep: [String]) -> IntakeEdit {
        var e = edit
        let base = e.patch.labels ?? keep
        e.patch.labels = base.contains(id) ? base : base + [id]
        return e
    }

    /// The checked duplicate of an intake item, else nil.
    func duplicate(_ item: EnhanceTarget, _ result: EnhanceResult, items: [String: ItemRef]) -> ItemRef? {
        guard !item.isTicket, let d = result.duplicateOf, isChecked(item, .relation(d.key)) else { return nil }
        return items[d.key.uppercased()]
    }

    // Writes the checked properties. With `accept`, also accepts the item, or marks it as a duplicate when that is checked.
    // With `queue`, also adds the start label, so the item joins the lane of its project. It needs no Enhance run.
    func apply(projectKey: String, item: IntakeItem, accept: Bool, queue: Bool = false, done: @escaping (_ error: String?) -> Void) {
        let target = EnhanceTarget.intake(item)
        var ready: (EnhanceResult, Run)?
        if case .ready(let result, let run) = states[item.id] { ready = (result, run) }
        guard ready != nil || queue, let snap = store.snapshots[projectKey],
              let tracker = ENV.tracker(snap.summary.ref.workspace) else { done("The project is not loaded."); return }
        let known = Self.known(snap)
        let graph = BlockGraph(store.relations.byKey)
        let startLabel = AGENTS.startLabel
        store.intakeDetail(projectKey: projectKey, item: item) { [weak self] r in
            guard let self else { return }
            Task {
                let labeler = tracker as? any LabelManaging
                var labels = (try? await labeler?.labels(snap.summary.ref)) ?? []
                let keep = (try? r.get())?.labels.compactMap { n in labels.first { $0.name == n }?.id } ?? []
                var edit = ready.map { self.edit(target, $0.0, run: $0.1, labels: labels, keep: keep, items: known, graph: graph) } ?? IntakeEdit()
                let dup = ready.flatMap { self.duplicate(target, $0.0, items: known) }
                if queue, dup == nil, !startLabel.isEmpty {
                    var id = labels.first { $0.name.caseInsensitiveCompare(startLabel) == .orderedSame }?.id
                    if id == nil, let made = try? await labeler?.createLabel(startLabel, color: "#3B82F6", in: snap.summary.ref) {
                        id = made
                        labels.append(StatusOption(id: made, name: startLabel, color: "#3B82F6"))
                    }
                    guard let id else {
                        await MainActor.run { done("Could not find or make the label \"\(startLabel)\" in the project.") }
                        return
                    }
                    edit = Self.queued(edit, label: id, keep: keep)
                }
                await MainActor.run {
                    let failed = { (what: String) in done(self.store.lastError ?? "Plane did not take \(what).") }
                    let after: (Bool) -> Void = { ok in
                        guard ok else { failed("the changes"); return }
                        if let run = ready?.1 { self.stop(run) }
                        guard accept else { self.set(item.id, .applied(accepted: false)); done(nil); return }
                        self.store.triage(projectKey: projectKey, item: item, action: dup.map { .duplicate(of: $0.id) } ?? .accept) { ok in
                            if ready != nil { self.set(item.id, .applied(accepted: ok)) }
                            ok ? done(nil) : failed("the accept")
                        }
                    }
                    if edit.isEmpty { after(true) } else { self.store.triage(projectKey: projectKey, item: item, action: .update(edit), done: after) }
                }
            }
        }
    }

    /// Writes the checked properties to a ticket at once: one update, then the relations.
    func apply(ticket ref: ItemRef, done: @escaping (_ error: String?) -> Void) {
        let target = EnhanceTarget.item(ref)
        guard case .ready(let result, let run) = states[target.id], let (_, snap, item) = store.item(key: ref.key),
              let tracker = store.tracker(of: snap.summary.ref) else { done("The item is not loaded."); return }
        let known = Self.known(snap)
        let graph = BlockGraph(store.relations.byKey)
        Task {
            let labels = (try? await (tracker as? any LabelManaging)?.labels(snap.summary.ref)) ?? []
            let keep = item.labels.compactMap { n in labels.first { $0.name == n }?.id }
            let edit = self.edit(target, result, run: run, labels: labels, keep: keep, items: known, graph: graph)
            await MainActor.run { self.write(edit, to: item.id, target: target, run: run, done: done) }
        }
    }

    private func write(_ edit: IntakeEdit, to id: String, target: EnhanceTarget, run: Run, done: @escaping (String?) -> Void) {
        let ended = {
            self.stop(run)
            self.set(target.id, .applied(accepted: false))
            done(nil)
        }
        let relate = {
            guard !edit.relations.isEmpty else { ended(); return }
            self.store.relate(itemId: id, RelationPatch(add: edit.relations)) { ok in
                ok ? ended() : done(self.store.lastError ?? "Plane did not take the relations.")
            }
        }
        guard edit.patch != ItemPatch() else { relate(); return }
        store.update(itemId: id, edit.patch, failure: "Could not write the changes") { ok in
            ok ? relate() : done(self.store.lastError ?? "Plane did not take the changes.")
        }
    }

    private static func known(_ snap: ProjectSnapshot) -> [String: ItemRef] {
        Dictionary(snap.items.compactMap { $0.ref(in: snap.summary.ref) }.map { ($0.key.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    var canReveal: Bool { host() is any Revealing }

    /// "this Mac", or the name of the sessions machine.
    var place: String {
        guard let rt = host() else { return "no machine" }
        return rt is any Revealing ? "this Mac" : rt.account.id
    }

    func reveal(_ item: EnhanceTarget) {
        guard let s = (held[item.id] ?? state(item)?.run)?.session, let rt = host() else { return }
        Task {
            guard let r = rt as? any Revealing, case .failure(let e) = await Result(awaiting: { try await r.reveal(s) }) else { return }
            await MainActor.run { AlertConfirm.tell("Orca cannot show the session", info: e.message, in: NSApp.keyWindow) }
        }
    }

    /// Stops the session and forgets the run.
    func discard(_ item: EnhanceTarget) {
        if let run = held[item.id] ?? states[item.id]?.run { stop(run) }
        drop(item.id)
    }

    private func drop(_ id: String) {
        if let t = held.removeValue(forKey: id)?.session { questions.untrack(intake: t) }
        states[id] = nil
        picks[id] = nil
        NotificationCenter.default.post(name: EnhanceAgent.changed, object: self)
    }

    // The session goes, and this app does not follow its pane again.
    private func stop(_ run: Run) {
        forget(run)
        guard let t = run.session, let rt = host() else { return }
        Task { _ = try? await rt.close(t) }
    }

    private func forget(_ run: Run) {
        if let t = run.session { questions.untrack(intake: t) }
        if let p = run.pane { dropped.insert(p) }
    }

    private func set(_ id: String, _ s: State) {
        guard states[id] != s else { return }
        states[id] = s
        NotificationCenter.default.post(name: EnhanceAgent.changed, object: self)
    }

    // MARK: Words

    /// The pill of the target, with the machine when it is not this Mac.
    func pill(_ t: EnhanceTarget) -> (tone: Tone, text: String)? {
        state(t).flatMap { Self.pill($0, now: now(), on: canReveal ? nil : host()?.account.id) }
    }

    /// The pill of the row: "Enhancing · 2m", "Enhancing on mbp · 2m", "2 questions", "Enhanced · High", "Duplicate of K-1".
    static func pill(_ s: State, now: Date = Date(), on machine: String? = nil) -> (tone: Tone, text: String)? {
        let word = "Enhancing" + (machine.map { " on " + $0 } ?? "")
        switch s {
        case .starting: return (.question, word)
        case .enhancing(let r): return (.question, word + " · \(max(1, Int(r.worked(now) / 60)))m")
        case .asking(_, let n): return (.question, "\(n) question\(n == 1 ? "" : "s")")
        case .ready(let res, _):
            if let d = res.duplicateOf { return (.question, "Duplicate of \(d.key)") }
            let word = res.verdict == .vague ? "Enhanced" : res.verdict.word
            return (.question, word + (res.priority.map { " · " + $0.capitalized } ?? ""))
        case .applied(let accepted): return (.ok, accepted ? "Written and accepted" : "Written")
        case .failed: return (.bad, "Enhance failed")
        }
    }
}

extension EnhanceAgent.State {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
    /// The session works or asks.
    var isLive: Bool {
        switch self {
        case .enhancing, .asking: return true
        default: return false
        }
    }
}

// The card under an intake line or on an item page: progress, the questions, the review with checkboxes, and the actions.
final class EnhancePanel: Card {
    private let agent: EnhanceAgent
    private let item: EnhanceTarget
    private var picks: [EnhanceAgent.Pick] = []

    init(_ state: EnhanceAgent.State, projectKey: String, target item: EnhanceTarget, agent: EnhanceAgent, questions: QuestionHub,
         after: @escaping (String?) -> Void) {
        self.agent = agent
        self.item = item
        super.init(title: nil, padding: 12, spacing: 8, fill: Palette.raise)
        var head: [NSView] = [Glyph("sparkles", color: Palette.acc, size: 13), NSTextField.text("Enhance", size: 12.5, weight: .semibold),
                              Chiplet("Runs on: \(agent.place)", mono: false),
                              Chiplet(AGENTS.intakeScratch ? "scratch worktree" : "main checkout", mono: true), Chiplet("read-only")]
        if let p = agent.pill(item) ?? EnhanceAgent.pill(state) { head.append(Pill(p.tone, text: p.text)) }
        add(NSStackView(h: head, spacing: 6))
        // Only a session on this Mac opens in the runtime UI.
        let open: [NSView] = agent.canReveal ? [ActionButton("Open in Orca ↗") { agent.reveal(item) }] : []
        switch state {
        case .starting:
            add(NSTextField.text("OverSire starts a session on \(agent.place).", size: 12, color: Palette.mut))
        case .enhancing:
            add(NSTextField.text("The agent reads the code and the related items. It asks here when the code cannot tell.", size: 12, color: Palette.mut, lines: 2))
            add(NSStackView(h: open + [ActionButton("Stop") { agent.discard(item) }], spacing: 6))
        case .asking(let run, _):
            let asked = run.session.map { questions.open(session: $0) } ?? []
            for e in asked { add(questions.card(e)) }
            if asked.isEmpty { add(NSTextField.text("The agent asks in the session. Open it to answer.", size: 12, color: Palette.mut)) }
            add(NSStackView(h: open + [ActionButton("Stop") { agent.discard(item) }], spacing: 6))
        case .ready(let res, let run):
            review(res, run)
            let acts: [NSView]
            switch item {
            case .intake(let i):
                acts = [ActionButton("Accept", style: .primary) { agent.apply(projectKey: projectKey, item: i, accept: true, done: after) },
                        ActionButton("Accept and queue") { agent.apply(projectKey: projectKey, item: i, accept: true, queue: true, done: after) },
                        ActionButton("Write to the item") { agent.apply(projectKey: projectKey, item: i, accept: false, done: after) }]
            case .item(let ref):
                acts = [ActionButton("Apply to \(ref.key)", style: .primary) { agent.apply(ticket: ref, done: after) }]
            }
            add(NSStackView(h: acts + open + [ActionButton("Discard") { agent.discard(item) }], spacing: 6))
            if item.isTicket { add(NSTextField.text("Writes the checked lines to Plane. No accept step: the item is already a ticket.", size: 12, color: Palette.dim, lines: 2)) }
        case .applied:
            add(NSTextField.text("OverSire wrote the checked changes. The original text is in the section \"Original note\".", size: 12, color: Palette.mut, lines: 2))
        case .failed(let msg, let kept):
            add(NSTextField.text(msg, size: 12, color: Palette.mut, lines: 3))
            if let kept, !kept.isEmpty { add(TermView(lines: kept.components(separatedBy: "\n"), height: 96)) }
            add(NSStackView(h: [ActionButton("Try again") { agent.start(projectKey: projectKey, target: item) }] + open
                                + [ActionButton("Dismiss") { agent.discard(item) }], spacing: 6))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func review(_ res: EnhanceResult, _ run: EnhanceAgent.Run) {
        for f in res.findings.prefix(res.verdict == .offVision ? 1 : 6) {
            add(NSStackView(h: [NSTextField.text("•", color: Palette.dim), NSTextField.text(f, size: 12.5, lines: 3)], spacing: 6, align: .top))
        }
        let now = column("Now", run.original.isEmpty ? "(no description)" : run.original, color: Palette.mut)
        let body = res.description.range(of: EnhancePrompt.originalHeading, options: .caseInsensitive).map { String(res.description[..<$0.lowerBound]) } ?? res.description
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = column("New description", text.isEmpty ? "(no new text)" : text, color: text.isEmpty ? Palette.mut : Palette.fg,
                         foot: "Then \(EnhancePrompt.originalHeading) with the text in Now.")
        let sides = NSStackView(h: [now, new], spacing: 10, align: .top)
        sides.distribution = .fillEqually
        add(sides)
        var boxes: [NSView] = [check(.description, "Description")]
        if let p = res.priority { boxes.append(check(.priority, "Priority: \(p.capitalized)")) }
        boxes += res.labels.map { check(.label($0), "Label: \($0)") }
        boxes += res.relations.map { r in
            let dup = item.isTicket ? "Relates to (duplicate)" : "Duplicate of"
            let word = ["blocked_by": "Blocked by", "blocks": "Blocks", "duplicate": dup, "relates_to": "Relates to"][r.kind] ?? r.kind
            return check(.relation(r.key), "\(word) \(r.key)" + (r.reason.isEmpty ? "" : " · \(r.reason)"))
        }
        add(NSStackView(v: boxes, spacing: 4))
    }

    private func column(_ title: String, _ text: String, color: NSColor, foot: String? = nil) -> NSView {
        let box = Card(title: nil, padding: 10, spacing: 6, fill: Palette.panel)
        box.add(NSTextField.text(title, size: 11.5, weight: .semibold, color: Palette.dim))
        box.add(NSTextField.text(text, size: 12, color: color, lines: 24))
        if let foot { box.add(NSTextField.text(foot, size: 11.5, color: Palette.dim)) }
        return box
    }

    private func check(_ p: EnhanceAgent.Pick, _ title: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(flip(_:)))
        b.state = agent.isChecked(item, p) ? .on : .off
        b.tag = picks.count
        picks.append(p)
        return b
    }

    @objc private func flip(_ b: NSButton) { agent.toggle(item, picks[b.tag]) }
}

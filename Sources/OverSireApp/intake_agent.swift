import Cocoa
import OverSireCore
import OverSireAI
import RuntimeOrca

// ─── Intake agent (Enhance) ──────────────────────────────────────────────────
// A read-only Orca worker reads the code for a new intake item, asks the user what the code cannot tell
// (the native AskUserQuestion form, shown with QuestionCard), and sends a new description in its `worker_done`. The user then
// checks the properties to write, and accepts the item in the same step.

/// The calls of a runtime that runs an Enhance worker.
protocol EnhanceHost: AnyObject, Sendable {
    var account: AccountID { get }
    var installed: Bool { get }
    func startWorker(spec: String, title: String, path: String, agent: String) async throws -> OrcaWorker
    func workerState(_ w: OrcaWorker) async throws -> OrcaWorkerState
    func stopWorker(_ w: OrcaWorker) async throws
    func releaseWorker(_ w: OrcaWorker) async throws
    func reveal(_ s: SessionRef) async throws
}

extension OrcaRuntime: EnhanceHost {}

/// A tracker with a web page for the intake of a project.
protocol IntakePage: Tracker { func intakeURL(_ p: ProjectRef) -> String }

final class IntakeAgent {
    static let changed = Notification.Name("IntakeAgentChanged")
    /// The most work time of one run. The time that a question waits does not count.
    static let timeout: TimeInterval = 1800

    struct Run: Equatable {
        var worker: OrcaWorker
        var session: SessionRef?       // the worker terminal, that asks the questions
        var item: ItemRef
        var original: String
        var since: Date
        var waited: TimeInterval = 0
        var askedAt: Date?

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

    private(set) var states: [String: State] = [:]     // intake id → state
    private(set) var picks: [String: Set<Pick>] = [:]  // intake id → the unchecked properties
    private var timer: Timer?
    private var autoTried: Set<String> = []
    private let store: ProjectStore
    private let memory: ProjectMemory
    private let questions: QuestionHub
    var host: () -> (any EnhanceHost)? = { ENV.runtime as? any EnhanceHost }
    var now: () -> Date = { Date() }
    /// For `--uishots`: a state for an item that has none.
    var sample: ((IntakeItem) -> State?)?

    init(store: ProjectStore, memory: ProjectMemory, questions: QuestionHub) {
        self.store = store
        self.memory = memory
        self.questions = questions
    }

    var available: Bool { AI_CFG.intakeAgent && host()?.installed == true }

    func state(_ item: IntakeItem) -> State? { states[item.id] ?? sample?(item) }

    func spec(key: String, title: String, url: String, body: String, vision: String?) -> String {
        EnhancePrompt.render(AGENTS.intakePrompt, EnhancePrompt.input(key: key, title: title, url: url, body: body, vision: vision))
    }

    /// A short body with no steps. Quick triage starts Enhance for it when the setting is on.
    static func vague(_ body: String) -> Bool {
        body.split { $0.isWhitespace || $0.isNewline }.count < 25
    }

    /// Starts Enhance for the new vague items of the last day, at most two at a time.
    func autoStart() {
        guard AGENTS.enhanceVague, available else { return }
        var room = 2 - states.values.filter { $0 == .starting || $0.run != nil && !$0.isReady }.count
        for (pk, snap) in store.snapshots {
            for item in snap.intake ?? [] where room > 0 && states[item.id] == nil && !autoTried.contains(item.id) {
                autoTried.insert(item.id)
                guard now().timeIntervalSince(item.createdAt) < 86400 else { continue }
                store.intakeDetail(projectKey: pk, item: item) { [weak self] r in
                    if case .success(let d) = r, IntakeAgent.vague(d.body) { self?.start(projectKey: pk, item: item) }
                }
                room -= 1
            }
        }
    }

    // Starts the worker in the Orca workspace of the project.
    func start(projectKey: String, item: IntakeItem) {
        guard let snap = store.snapshots[projectKey] else { return }
        guard let root = PROJECTS_CFG.orca.roots[projectKey], !root.isEmpty else {
            set(item.id, .failed("Choose an Orca workspace for \(snap.summary.identifier) first: start any item of the project once.", kept: nil))
            return
        }
        guard let rt = host() else { set(item.id, .failed("Add an Orca account in Settings › Accounts and sync.", kept: nil)); return }
        let url = (ENV.tracker(snap.summary.ref.workspace) as? any IntakePage)?.intakeURL(snap.summary.ref) ?? snap.summary.url
        set(item.id, .starting)
        store.intakeDetail(projectKey: projectKey, item: item) { [weak self] r in
            guard let self else { return }
            let detail = try? r.get()
            let body = detail?.body ?? ""
            let key = (self.store.intakeKeys[item.workItemId] ?? detail?.sequence).map { "\(snap.summary.identifier)-\($0)" } ?? snap.summary.identifier
            let ref = ItemRef(project: snap.summary.ref, id: item.workItemId, key: key, url: URL(string: url) ?? URL(fileURLWithPath: "/"))
            let vision = self.memory.vision(of: snap.summary.ref)?.text
            let path = AGENTS.intakeScratch ? root + "/.wt/enhance-" + key.lowercased() : root
            Task {
                if AGENTS.intakeScratch { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
                let spec = self.spec(key: key, title: item.name, url: url, body: body, vision: vision)
                let r = await Result(awaiting: { try await rt.startWorker(spec: spec, title: "Enhance " + key, path: path, agent: "claude") })
                DispatchQueue.main.async {
                    switch r {
                    case .success(let w):
                        let s = w.terminal.map { SessionRef(workspace: WorkspaceRef(account: rt.account, id: "intake"), id: $0) }
                        self.begin(item.id, Run(worker: w, session: s, item: ref, original: body, since: self.now()))
                    case .failure(let e): self.set(item.id, .failed(e.message, kept: nil))
                    }
                }
            }
        }
    }

    /// Tracks the run and polls it. The tests call it with a made worker.
    func begin(_ id: String, _ run: Run) {
        if let s = run.session { questions.track(intake: s, item: run.item) }
        set(id, .enhancing(run))
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One look at each run: its result, its open questions and its time.
    func poll() async {
        let runs = await MainActor.run { states.compactMap { id, s -> (String, Run)? in
            switch s {
            case .enhancing(let r), .asking(let r, _): return (id, r)
            default: return nil
            }
        } }
        guard !runs.isEmpty, let rt = host() else {
            await MainActor.run { timer?.invalidate(); timer = nil }
            return
        }
        for (id, run) in runs {
            let r = await Result(awaiting: { try await rt.workerState(run.worker) })
            await MainActor.run { self.advance(id, run, r) }
        }
    }

    private func advance(_ id: String, _ old: Run, _ r: Result<OrcaWorkerState, ProviderError>) {
        guard states[id]?.run?.worker == old.worker else { return }
        var run = states[id]?.run ?? old
        let t = now()
        switch r {
        case .failure(let e): finish(id, run, .failed(e.message, kept: nil))
        case .success(.done(_, let body)):
            if let result = EnhanceResult.parse(body) {
                if let at = run.askedAt { run.waited += t.timeIntervalSince(at); run.askedAt = nil }
                if let s = run.session { questions.untrack(intake: s) }
                set(id, .ready(result, run))
            } else {
                finish(id, run, .failed("The agent sent no result that OverSire can read. Its text is below.", kept: body))
            }
        case .success(.ended(let why)): finish(id, run, .failed("The worker stopped (\(why)) with no result.", kept: nil))
        case .success(.running):
            let n = run.session.map { questions.count(session: $0) } ?? 0
            if n > 0 {
                if run.askedAt == nil { run.askedAt = t }
                set(id, .asking(run, n: n))
            } else {
                if let at = run.askedAt { run.waited += t.timeIntervalSince(at); run.askedAt = nil }
                if run.worked(t) > Self.timeout {
                    finish(id, run, .failed("No result after 30 minutes of work. Open it in Orca to look.", kept: nil))
                } else {
                    set(id, .enhancing(run))
                }
            }
        }
    }

    private func finish(_ id: String, _ run: Run, _ s: State) {
        if let s = run.session { questions.untrack(intake: s) }
        set(id, s)
    }

    // MARK: Review

    func isChecked(_ item: IntakeItem, _ p: Pick) -> Bool { !(picks[item.id] ?? []).contains(p) }

    func toggle(_ item: IntakeItem, _ p: Pick) {
        if picks[item.id, default: []].remove(p) == nil { picks[item.id, default: []].insert(p) }
    }

    /// The checked properties as one edit. Label names and relation keys that the project does not know drop,
    /// and so does a relation that makes a cycle in `graph`.
    func edit(_ item: IntakeItem, _ result: EnhanceResult, run: Run, labels: [StatusOption], keep: [String], items: [String: ItemRef],
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
            guard let kind = r.relationKind, let ref = items[r.key.uppercased()] else { return nil }
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

    /// The checked duplicate, else nil.
    func duplicate(_ item: IntakeItem, _ result: EnhanceResult, items: [String: ItemRef]) -> ItemRef? {
        guard let d = result.duplicateOf, isChecked(item, .relation(d.key)) else { return nil }
        return items[d.key.uppercased()]
    }

    // Writes the checked properties. With `accept`, also accepts the item, or marks it as a duplicate when that is checked.
    // With `queue`, also adds the start label, so the item joins the lane of its project. It needs no Enhance run.
    func apply(projectKey: String, item: IntakeItem, accept: Bool, queue: Bool = false, done: @escaping (_ error: String?) -> Void) {
        var ready: (EnhanceResult, Run)?
        if case .ready(let result, let run) = states[item.id] { ready = (result, run) }
        guard ready != nil || queue, let snap = store.snapshots[projectKey],
              let tracker = ENV.tracker(snap.summary.ref.workspace) else { done("The project is not loaded."); return }
        let known = Dictionary(snap.items.compactMap { $0.ref(in: snap.summary.ref) }.map { ($0.key.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let graph = BlockGraph(store.relations.byKey)
        let startLabel = AGENTS.startLabel
        store.intakeDetail(projectKey: projectKey, item: item) { [weak self] r in
            guard let self else { return }
            Task {
                let labeler = tracker as? any LabelManaging
                var labels = (try? await labeler?.labels(snap.summary.ref)) ?? []
                let keep = (try? r.get())?.labels.compactMap { n in labels.first { $0.name == n }?.id } ?? []
                var edit = ready.map { self.edit(item, $0.0, run: $0.1, labels: labels, keep: keep, items: known, graph: graph) } ?? IntakeEdit()
                let dup = ready.flatMap { self.duplicate(item, $0.0, items: known) }
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
                        if let run = ready?.1, let rt = self.host() { Task { try? await rt.releaseWorker(run.worker) } }
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

    func reveal(_ item: IntakeItem) {
        guard let s = state(item)?.run?.session, let rt = host() else { return }
        Task { try? await rt.reveal(s) }
    }

    func discard(_ item: IntakeItem) {
        if let run = states[item.id]?.run, let rt = host() {
            if let s = run.session { questions.untrack(intake: s) }
            let ready = states[item.id]?.isReady == true
            Task { ready ? try? await rt.releaseWorker(run.worker) : try? await rt.stopWorker(run.worker) }
        }
        states[item.id] = nil
        picks[item.id] = nil
        NotificationCenter.default.post(name: IntakeAgent.changed, object: self)
    }

    private func set(_ id: String, _ s: State) {
        states[id] = s
        NotificationCenter.default.post(name: IntakeAgent.changed, object: self)
    }

    // MARK: Words

    /// The pill of the row: "Enhancing · 2m", "2 questions", "Enhanced · High", "Clear · Low", "Duplicate of K-1".
    static func pill(_ s: State, now: Date = Date()) -> (tone: Tone, text: String)? {
        switch s {
        case .starting: return (.question, "Enhancing")
        case .enhancing(let r): return (.question, "Enhancing · \(max(1, Int(r.worked(now) / 60)))m")
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

extension IntakeAgent.State {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

// The card under an intake line: progress, the questions, the review with checkboxes, and the actions.
final class IntakePanel: Card {
    private let agent: IntakeAgent
    private let item: IntakeItem
    private var picks: [IntakeAgent.Pick] = []

    init(_ state: IntakeAgent.State, projectKey: String, item: IntakeItem, agent: IntakeAgent, questions: QuestionHub,
         after: @escaping (String?) -> Void) {
        self.agent = agent
        self.item = item
        super.init(title: nil, padding: 12, spacing: 8, fill: Palette.raise)
        var head: [NSView] = [Glyph("sparkles", color: Palette.acc, size: 13), NSTextField.text("Enhance", size: 12.5, weight: .semibold),
                              Chiplet("Runs on: \(IntakePanel.place(agent))", mono: false),
                              Chiplet(AGENTS.intakeScratch ? "scratch worktree" : "main checkout", mono: true), Chiplet("read-only")]
        if let p = IntakeAgent.pill(state) { head.append(Pill(p.tone, text: p.text)) }
        add(NSStackView(h: head, spacing: 6))
        let open = ActionButton("Open in Orca ↗") { agent.reveal(item) }
        switch state {
        case .starting:
            add(NSTextField.text("OverSire starts a worker in Orca.", size: 12, color: Palette.mut))
        case .enhancing:
            add(NSTextField.text("The agent reads the code and the related items. It asks here when the code cannot tell.", size: 12, color: Palette.mut, lines: 2))
            add(NSStackView(h: [open, ActionButton("Stop") { agent.discard(item) }], spacing: 6))
        case .asking(let run, _):
            for e in run.session.map({ questions.open(session: $0) }) ?? [] { add(questions.card(e)) }
            add(NSStackView(h: [open, ActionButton("Stop") { agent.discard(item) }], spacing: 6))
        case .ready(let res, let run):
            review(res, run)
            add(NSStackView(h: [
                ActionButton("Accept", style: .primary) { agent.apply(projectKey: projectKey, item: item, accept: true, done: after) },
                ActionButton("Accept and queue") { agent.apply(projectKey: projectKey, item: item, accept: true, queue: true, done: after) },
                ActionButton("Write to the item") { agent.apply(projectKey: projectKey, item: item, accept: false, done: after) },
                open,
                ActionButton("Discard") { agent.discard(item) },
            ], spacing: 6))
        case .applied:
            add(NSTextField.text("OverSire wrote the checked changes. The original text is in the section \"Original note\".", size: 12, color: Palette.mut, lines: 2))
        case .failed(let msg, let kept):
            add(NSTextField.text(msg, size: 12, color: Palette.mut, lines: 3))
            if let kept, !kept.isEmpty { add(TermView(lines: kept.components(separatedBy: "\n"), height: 96)) }
            add(NSStackView(h: [ActionButton("Try again") { agent.start(projectKey: projectKey, item: item) },
                                ActionButton("Dismiss") { agent.discard(item) }], spacing: 6))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func place(_ agent: IntakeAgent) -> String {
        guard let rt = agent.host() as? OrcaRuntime else { return "Orca" }
        return rt.environment.map { "Orca · \($0)" } ?? "Orca · this Mac"
    }

    private func review(_ res: EnhanceResult, _ run: IntakeAgent.Run) {
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
            let word = ["blocked_by": "Blocked by", "blocks": "Blocks", "duplicate": "Duplicate of", "relates_to": "Relates to"][r.kind] ?? r.kind
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

    private func check(_ p: IntakeAgent.Pick, _ title: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(flip(_:)))
        b.state = agent.isChecked(item, p) ? .on : .off
        b.tag = picks.count
        picks.append(p)
        return b
    }

    @objc private func flip(_ b: NSButton) { agent.toggle(item, picks[b.tag]) }
}

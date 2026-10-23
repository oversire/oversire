import Cocoa
import AgentBinder
import OverSireCore
import OverSireAI
import OverSireSync
import OverSireAssistant

// `oversire --uishots <dir> [path …]` opens the window with real data, read only, and saves
// one PNG per route and theme. It sends no global input, so it is safe while someone uses the Mac.
// Plane state is a copy; re-run, write-back and agent starts do nothing here.
final class UIShots: NSObject, AppData, NSApplicationDelegate {
    var grouped: [(String, [Run])] = []
    let bus = ChangeBus.shared
    var prGrouped: [(String, [ChangeRequest])] = []
    var lastUpdate = Date()
    var firstLoad = true
    let projectStore: ProjectStore
    let writes = StoreWrites(store: LocalStore(dir: URL(fileURLWithPath: UIShots.tmp + "/store")))
    lazy var agentIndex = AgentIndex(writes: writes)
    private var machineHub: MachineHub?
    let workstreams = WorkstreamIndex()
    let cleaner = Cleaner(defaults: UserDefaults(suiteName: "oversire-uishots")!)
    lazy var queue = WorkQueue(writes: writes, store: projectStore, agents: agentIndex)
    lazy var actions = AppActionCatalog(data: self)
    lazy var memory = ProjectMemory(writes: writes)
    lazy var updater = Updater()
    lazy var cloudSetup = UIShots.sampleSetup()
    lazy var repoCatalog = RepoCatalog(path: UIShots.tmp + "/repo-cache.json")
    lazy var projectCatalog = ProjectCatalog(trackers: ENV, path: UIShots.tmp + "/plane-cache.json")
    lazy var areas = ItemAreaBook(writes: writes)
    lazy var suggestions = SuggestionBook(writes: writes)
    lazy var planner = PlannerBook(writes: writes)
    lazy var intakeAgent = IntakeAgent(store: projectStore, memory: memory, questions: questions)
    lazy var sessions = SessionNotes(path: UIShots.tmp + "/sessions.json", agents: agentIndex, store: projectStore,
                                     writeBack: PlaneWriteBack(path: UIShots.tmp + "/wb.json", store: projectStore, trackers: ENV))
    let busy = BusyTracker()
    lazy var ciAssist = CIAssist(path: UIShots.tmp + "/ci.json")
    lazy var questions = QuestionHub(agents: agentIndex, writes: writes)
    lazy var stats: WorkStats = {
        let s = WorkStats(path: UIShots.tmp + "/work-stats.json") { _ in nil }
        let week = WorkStats.week(Date(), calendar: .current)
        let repo = REPOS.first ?? "oversire/oversire"
        s.seed(hours: [3.5, 5, 2.2, 6.1, 4, 0, 0], merged: [0, 0, 1, 2, 2, 3, 4].enumerated().map { n, d in
            WorkStats.Merged(repo: repo, number: 200 + n, at: week[d].addingTimeInterval(36000)) })
        return s
    }()
    lazy var itemSummaries = ItemSummaries(path: UIShots.tmp + "/summaries.json",
                                           ai: { UIShots.aiKey.map { AIClient(cfg: AI_CFG, key: $0) } })
    lazy var statusJob = StatusJob(path: UIShots.tmp + "/session-status.json", agents: agentIndex, queue: queue)
    /// Scripted engines and sample tools. Nil while a shot shows the panel with no assistant.
    lazy var shotAssistant = makeAssistant()
    var assistantOff = false
    var assistant: AssistantController? { assistantOff ? nil : shotAssistant }
    let relay = LiveSync(secrets: SecretStore(service: "com.oversire.app.cloud"), cursors: CursorStore(url: nil))
    private let dir: String
    struct FixturePR: Decodable { let repo: String; let mine: Bool; let pr: ChangeRequest }

    private let paths: [String]
    private var window: AppWindow?
    private var glance: NSWindow?
    private var snapPanel: ShotEditorPanel?
    private var basketPanel: BasketPanel?
    private var sessionWindow: NSWindow?
    var logs: LogStore?

    init(dir: String, paths: [String]) {
        self.dir = dir
        self.paths = paths
        let tmp = UIShots.tmp
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        // Copies of the real files. A run never writes to ~/.config/oversire.
        for (src, name) in [(PROJECT_STATE_PATH, "state.json"), (PROJECT_ACTIVITY_PATH, "activity.jsonl"),
                            (QUEUE_PATH, "queue.json"), (STATUS_PATH, "session-status.json"),
                            (REPO_CACHE_PATH, "repo-cache.json"), (PROJECT_CACHE_PATH, "plane-cache.json")] {
            try? FileManager.default.removeItem(atPath: tmp + "/" + name)
            try? FileManager.default.copyItem(atPath: src, toPath: tmp + "/" + name)
        }
        // Sample queue and checks for screenshots, in place of the real ones.
        if let fx = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_FIXTURES"] {
            if FileManager.default.fileExists(atPath: fx + "/ci.json") {
                try? FileManager.default.removeItem(atPath: tmp + "/ci.json")
                try? FileManager.default.copyItem(atPath: fx + "/ci.json", toPath: tmp + "/ci.json")
            }
            for name in ["queue.json", "checks.json"] where FileManager.default.fileExists(atPath: fx + "/" + name) {
                try? FileManager.default.removeItem(atPath: tmp + "/" + name)
                try? FileManager.default.copyItem(atPath: fx + "/" + name, toPath: tmp + "/" + name)
            }
        }
        if UIShots.loading { try? FileManager.default.removeItem(atPath: tmp + "/state.json") }
        projectStore = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                    statePath: tmp + "/state.json", activityPath: tmp + "/activity.jsonl")
        super.init()
        projectStore.hold = UIShots.loading
        projectStore.busy = busy
        queue.areaBook = { [unowned self] in UIShots.cloud == true ? self.areas : nil }
        queue.planner = { [unowned self] in UIShots.cloud == true ? self.planner : nil }
        if UIShots.loading { RunPage.source = NeverAnswers() }
    }

    func has(_ c: Capability) -> Bool { ENV.has(c) }

    func rerun(repo: String, runs: [Run], failedOnly: Bool) { log.info("uishots: re-run skipped") }
    func setIgnored(_ runs: [Run], ignored: Bool) { IGNORED.set(runs, ignored: ignored) }

    static let tmp = NSTemporaryDirectory() + "oversire-uishots"

    // OVERSIRE_UISHOTS_LOADING=1: no fetch ever ends, so each page shows its loading state.
    static let loading = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_LOADING"] == "1"
    // OVERSIRE_UISHOTS_CLOUD=0 or 1: the Cloud AI sections show without or with a cloud account.
    /// True in a `--uishots` run. Pages then keep view choices in memory, not in the user defaults.
    static var shooting = false
    static let cloud = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_CLOUD"].map { $0 == "1" }
    // OVERSIRE_UISHOTS_COMMANDS=1: Settings › Agents and queue shows one custom start command and one bad draft.
    static let commands = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_COMMANDS"] == "1"
    // OVERSIRE_UISHOTS_PLANNER=1: a vision, relations, areas, a queue lane and a plan change in the OVERSIRE project.
    static let planner = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_PLANNER"] == "1"
    // OVERSIRE_UISHOTS_SESSIONS=1: one OVERSIRE session in each state, a blocked checklist and a quiet check.
    static let sessions = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_SESSIONS"] == "1"
    // OVERSIRE_UISHOTS_SESSION_KEY: the item of the waiting sample session, in place of OVERSIRE-143.
    static let sessionKey = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_SESSION_KEY"] ?? "OVERSIRE-143"
    /// Finished items with leftovers, and OVERSIRE-205 as Done with open sub-items.
    static let cleanup = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_CLEANUP"] == "1"
    // OVERSIRE_UISHOTS_LIVE=on or quota: Settings › Accounts and sync shows a connected cloud, or one near the write quota.
    static let live = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_LIVE"]
    // OVERSIRE_UISHOTS_AI=on: Settings › AI shows a sample key that passed Test. No AI job runs.
    static let aiKey = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_AI"] == "on" ? "sk-ant-uishots-3f9a" : nil
    // OVERSIRE_UISHOTS_OVERRIDES=on: Settings › Notifications shows one muted project and one with custom notifications.
    static let overrides = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_OVERRIDES"] == "on"
    // OVERSIRE_UISHOTS_LOGS=1: sample log lines and two open problems. A partial Status on OVERSIRE-91.
    static let sampleLogs = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_LOGS"] == "1"

    static func sampleSetup() -> CloudSetup {
        let s = CloudSetup()
        s.trackedWorkspaces = { ["ocral"] }
        guard let live else { return s }
        let now = Date().timeIntervalSince1970 * 1000
        let json = """
        {"retentionHours": 168, "head": 9120, "events": 4210, "lastWebhookAt": \(now - 12_000), "rowsWrittenToday": \(live == "quota" ? 99_000 : 1_840),
         "devices": [{"id": "d1", "name": "Studio", "lag": 0, "connected": true}, {"id": "d2", "name": "MacBook Air", "lag": 3, "lastSeen": \(now - 7_200_000), "connected": false}],
         "hooks": [], "planeHooks": []}
        """
        var st = SetupState()
        st.joined = true
        st.version = CLOUD_MIN_VERSION
        st.health = try? JSONDecoder().decode(RelayHealth.self, from: Data(json.utf8))
        s.seed(st)
        for (i, r) in REPOS.enumerated() {
            s.hooks.setStatus(r, i == 1 ? .error("404 from GitHub") : i == 2 || i == 3 ? .unknown : .live("200 · 2m ago"))
        }
        s.hooks.setStatus(HookManager.planeKey("ocral"), .live("200 · 1m ago"))
        return s
    }

    static var heldOrders: [WorkOrder] {
        guard cloud == true, planner else { return [] }
        let item = { (key: String) in
            ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"),
                    id: key, key: key, url: URL(string: "https://app.plane.so/ocral/browse/\(key)/")!)
        }
        let order = { (id: String, key: String, hold: WorkOrderHold) in
            WorkOrder(id: id, runner: "D1", runtime: "orca", order: .start(LaunchRequest(repo: "/home/ada/src/oversire", item: item(key), agent: .claude,
                                                                                          prompt: "work on \(key)")),
                      suggestion: "s-\(id)", createdAt: Date().addingTimeInterval(-1800), expiresAt: Date().addingTimeInterval(86400 * 6),
                      state: .held, hold: hold)
        }
        return [order("o-h1", "OVERSIRE-85", WorkOrderHold(blockers: [item("OVERSIRE-84")], since: Date().addingTimeInterval(-1800))),
                order("o-h2", "OVERSIRE-90", WorkOrderHold(areas: ["contract"], since: Date().addingTimeInterval(-600)))]
    }

    // OVERSIRE_UISHOTS_SUMMARY=KEY-1,KEY-2: a summary for each item. A key with "~" at the end gets a stale summary.
    private func seedSummaries() {
        for k in (ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_SUMMARY"] ?? "").split(separator: ",").map(String.init) {
            let stale = k.hasSuffix("~")
            let key = stale ? String(k.dropLast()) : k
            guard let item = projectStore.item(key: key)?.item else { print("UISHOTS no item \(key)"); continue }
            let body = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            itemSummaries.seed(key, ItemSummary(gist: "\(item.title): a sample summary from `--uishots`, not from the AI.",
                                                points: ["The first key fact of the description.", "A step with the path `Sources/OverSireApp/item_page.swift`.",
                                                         "A decision and its reason."],
                                                open: ["One open question."], hash: stale ? "old" : ItemSummary.hash(body),
                                                at: Date().addingTimeInterval(stale ? -3 * 86_400 : -7200)))
        }
    }

    private func seedSessions() {
        guard UIShots.sessions else { return }
        AGENTS.aiMode = .ask
        AI_CFG.agentChecks = true
        agentIndex.hold = true
        let now = Date()
        let ago = { (m: Double) in now.addingTimeInterval(-m * 60) }
        let blocked = """
        OVERSIRE-109 is released in v1.3.9. I need you for the manual check on a real Mac:
        - Turn on the Screen Recording permission.
        - Take a capture on the second display.
        - Send a capture to Plane.
        - Send a capture to Orca.
        Tell me when you have done it.
        """
        // key, phase, minutes since, live terminals, screen same for, counter moves, shells, message
        let rows: [(String, AgentSession.Phase, Double, Int, Double, Bool, Int, String?)] = [
            (UIShots.sessionKey, .waiting, 3, 1, 3, false, 0, "Do you want the Inbox to show the blocked rows too, or only Sessions?"),
            ("OVERSIRE-109", .done, 26, 1, 26, false, 0, blocked),
            ("OVERSIRE-142", .done, 27, 1, 2, false, 1, "The tests run in the background. I check the result when they end."),
            ("OVERSIRE-91", .done, 44, 1, 44, false, 0, "The Planner page is merged into main. All tests pass."),
            ("OVERSIRE-137", .working, 6, 2, 0.5, false, 0, nil),
            ("OVERSIRE-141", .working, 52, 1, 41, true, 0, nil),
            ("OVERSIRE-140", .working, 30, 1, 12, false, 0, nil),
            ("OVERSIRE-144", .done, 90, 0, 90, false, 0, "Done."),
        ]
        var cards: [Workspace] = []
        for (i, r) in rows.enumerated() {
            let (key, phase, since, live, same, ticking, shells, message) = r
            let card = "uishots-card-\(i)"
            let a = AgentSession(phase: phase, since: ago(since), card: card, paneKey: "p\(i)", repo: "oversire", message: message)
            var w = SessionWatch(at: ago(same))
            w.fingerprint = "fp-\(key)"
            w.counter = ticking ? "41m 12s · ↓ 88.1k tokens" : nil
            w.ticking = ticking
            w.shells = shells
            w.readAt = ago(0.3)
            agentIndex.seed(key, a, watch: w)
            cards.append(Workspace(id: card, repo: "oversire", path: "/Users/ada/src/oversire/.wt/\(key.lowercased())", name: key.lowercased(),
                                   comment: nil, liveTerminals: live, lastActivity: ago(since), agents: [a]))
            guard phase == .done, live > 0 else { continue }
            let status = { (r: StatusReply, st: SessionState, at: Double) in
                SessionStatus(id: "status-\(key)", key: key, reply: r, ticks: r.needsYou.map { _ in false }, at: ago(at), trigger: .turnEnd,
                              byAI: true, phase: st, screen: w.fingerprint, message: a.messageHash, since: w.changedAt,
                              read: "Read 3 turns, 9 closing messages and the description")
            }
            if key == "OVERSIRE-109" {
                guard let r = BlockedText.read(message: blocked, turn: "", recap: nil, status: .progress, key: key) else { print("UISHOTS no steps"); continue }
                var e = status(StatusReply(state: .blocked, headline: "Released in v1.3.9. The manual check on a real Mac is open.",
                                           done: ["The capture code is merged.", "v1.3.9 is released."], needsYou: r.steps,
                                           blockedBy: ["OVERSIRE-117"]), .blocked, 25)
                for j in 0..<min(2, e.ticks.count) { e.ticks[j] = true }
                statusJob.seed(e)
                UIShots.expandBlocked = e.id
            } else if key == "OVERSIRE-91" {
                var s = status(StatusReply(state: .done, headline: "The Planner page is merged into main and all tests pass.",
                                           done: ["The Plan page shows the lanes.", "The tests pass."]), .done, 40)
                if UIShots.sampleLogs { s.partial = "The history read on mbp failed: python3 not found." }
                statusJob.seed(s)
            }
        }
        agentIndex.seed(cards: cards)
        statusJob.seed(SessionStatus(id: "uishots-quiet", key: "OVERSIRE-140",
                                     reply: StatusReply(state: .stuck, headline: "The tests fail in StatusJobTests and the agent does not go on.",
                                                        done: ["The status job is written."], next: ["Fix the failing tests."],
                                                        nudge: "The tests fail in StatusJobTests. Fix them, or tell me what blocks you."),
                                     ticks: [], at: ago(1), trigger: .idle, byAI: true, phase: .quiet, screen: "fp-OVERSIRE-140",
                                     message: agentIndex.agent("OVERSIRE-140")?.messageHash, since: ago(13),
                                     read: "Read 3 turns, 6 closing messages, the screen and the description"))
        seedQuestions(ago)
        guard let found = projectStore.item(key: "OVERSIRE-137") else { print("UISHOTS no OVERSIRE project"); return }
        let snap = found.snap, pk = snap.summary.ref.storeKey
        AGENTS.slots[pk] = 7
        for k in ["OVERSIRE-145", "OVERSIRE-139"] {
            if let f = projectStore.item(key: k), queue.lane(pk)?.entries.contains(where: { $0.key == k }) != true { queue.add(f.item, snap: snap) }
        }
    }

    /// No daemon answers: the sessions come from the seeds.
    struct Offline: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cannotConnectToHost) }
    }

    /// This Mac (mba) and mbp. OVERSIRE_UISHOTS_MACHINE=mbp: mbp runs the sessions. none: no daemon on this Mac.
    private func useSampleMachines() {
        let pick = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_MACHINE"]
        let hub = MachineHub(local: DaemonClient(base: DaemonClient.loopback, token: nil, http: Offline()), http: Offline(), cache: nil)
        hub.config = { MachinesConfig(sessions: pick == "mbp" ? "mbp" : nil) }
        let mbp = MachineLink(machine: "mbp", base: URL(string: "http://mbp:7690")!, token: "uishots", local: false)
        hub.use(pick == "none" ? [mbp] : [MachineLink(machine: "mba", base: DaemonClient.loopback, token: nil, local: true), mbp])
        hub.read = true
        machineHub = hub
        ENV.machines = hub
    }

    private func seedCleanup() {
        guard UIShots.cleanup, let found = projectStore.item(key: "OVERSIRE-205") else { return }
        let snap = found.snap
        guard let done = snap.firstState(group: "completed", else: .done) else { return }
        // OVERSIRE-205 becomes Done in the copy. Its sub-items stay open.
        let items = snap.items.map { i -> Item in
            guard i.id == found.item.id, var o = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(i))) as? [String: Any] else { return i }
            o["statusOptionId"] = done.id
            return (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) } ?? i
        }
        let copy = ProjectSnapshot(summary: snap.summary, statusOptions: snap.statusOptions, items: items, fetchedAt: snap.fetchedAt,
                                   fields: snap.fields, me: snap.me, meId: snap.meId, index: snap.index, intake: snap.intake)
        projectStore.seed(copy)

        // Three finished items: one safe, one with changes and an open PR, one with a live agent.
        let finished = copy.items.filter { copy.isFinished($0) && $0.parentId != found.item.id }.sorted { $0.updatedAt > $1.updatedAt }.prefix(3)
        guard finished.count == 3 else { print("UISHOTS cleanup needs 3 finished items"); return }
        let main = "/Users/ada/src/oversire", repo = "oversire/oversire"
        var f = CleanupFacts()
        f.bases[main] = "main"
        f.repos[main] = repo
        var cards: [Workspace] = []
        func pr(_ n: Int, _ state: String, head: String) -> ChangeRequest {
            ChangeRequest(number: n, title: "t", state: state, author: .init(login: "ada"), headRefName: head, baseRefName: "main",
                          url: "https://github.com/\(repo)/pull/\(n)", createdAt: "", updatedAt: "", reviewDecision: nil, additions: 0, deletions: 0,
                          isDraft: false, labels: [], body: nil)
        }
        for (n, item) in finished.enumerated() {
            let b = item.key.lowercased(), path = "/Users/ada/orca/\(b)"
            let live = n == 2 ? [AgentSession(phase: .waiting, since: Date().addingTimeInterval(-600), card: "uishots-clean-\(n)", paneKey: "c\(n)")] : []
            cards.append(Workspace(id: "uishots-clean-\(n)", repo: "oversire", path: path, name: b, comment: nil, liveTerminals: n == 2 ? 1 : 0,
                                   lastActivity: item.updatedAt, agents: live, branch: b))
            f.states[path] = CheckoutState(branch: b, dirty: n == 1 ? 3 : 0, ahead: 0, base: "main")
            f.remotes[main, default: []].insert(b)
            f.pulls["\(repo)|\(b)"] = [pr(300 + n, n == 1 ? "OPEN" : "MERGED", head: b)]
            if n == 0 { f.branches[main] = [GitBranch(name: b + "-spike", merged: true, checkedOut: false)] }
        }
        print("UISHOTS cleanup \(finished.map(\.key))")
        agentIndex.seed(cards: agentIndex.cards + cards)
        cleaner.load(f, records: [CleanupRecord(at: Date().addingTimeInterval(-1800), key: finished[finished.startIndex].key,
                                         text: "Removed worktree \(finished[finished.startIndex].key.lowercased()) (\(finished[finished.startIndex].key) finished 1 h ago)")])
    }

    /// One ask of OVERSIRE-143 (found by its terminal), one Orca form of OVERSIRE-140, one answer in Orca for OVERSIRE-142.
    private func seedQuestions(_ ago: @escaping (Double) -> Date) {
        let account = ENV.machines?.sessions?.account ?? AccountID(provider: .daemon, id: "mba")
        let s = { (id: String) in SessionRef(workspace: WorkspaceRef(account: account, id: "w-" + id), id: "term-" + id) }
        let store = QuestionItem(id: "q1", header: "Inbox", text: "Do you want the Inbox to show the blocked rows too?",
                                 why: "Sessions shows them now.", kind: .single,
                                 options: [.init(label: "Both"), .init(label: "Only Sessions")], allowsOther: true)
        let tests = QuestionItem(id: "q2", header: "Tests", text: "Which tests do you want?", kind: .multi,
                                 options: [.init(label: "Unit"), .init(label: "uishots")])
        let q = { (id: String, items: [QuestionItem], via: SessionQuestion.Via, at: Double) in
            SessionQuestion(id: QuestionID(rawValue: "daemon:mba:\(id)"), session: s(id), origin: .session, items: items, via: via, askedAt: ago(at))
        }
        let answer = QuestionAnswer(question: "daemon:mba:m3", items: [.init(id: "q1", choices: ["Both"])])
        let runner = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "oversire", id: "local"), id: "r1"), id: "s-1")
        let permission = SessionQuestion(id: "runner:s-1:p-1", session: runner, origin: .session,
                                         items: [.approve(id: "permission", header: "Bash", text: "npm test")], via: .permission,
                                         askedAt: ago(1), expiresAt: Date().addingTimeInterval(240))
        questions.seed([
            QuestionBoard.Entry(question: permission, state: .open, firstSeen: ago(1)),
            QuestionBoard.Entry(question: q("m1", [store, tests], .askReply, 3), state: .open, firstSeen: ago(3)),
            QuestionBoard.Entry(question: q("f2", [store], .form, 41), state: .open, firstSeen: ago(41)),
            QuestionBoard.Entry(question: q("m3", [store], .askReply, 9), state: .answeredElsewhere(answer, at: ago(2)), firstSeen: ago(9)),
            QuestionBoard.Entry(question: q("e1", [UIShots.enhanceAsk, tests], .askReply, 2), state: .open, firstSeen: ago(2)),
        ], keys: [runner: "OVERSIRE-137", s("m1"): UIShots.sessionKey, s("f2"): "OVERSIRE-140", s("m3"): "OVERSIRE-142"],
           intake: [s("e1"): UIShots.intakeRef])
        seedEnhance(ago)
    }

    static let intakeRef = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p-trebi", key: "TREBI"),
                                   id: "w-471", key: "TREBI-471", url: URL(string: "https://app.plane.so/ocral/browse/TREBI-471/")!)
    static let enhanceAsk = QuestionItem(id: "q1", header: "Sync", text: "Which sync drops the labels: Plane to Trebi, or Trebi to Plane?",
                                         why: "Both paths write labels.", kind: .single,
                                         options: [.init(label: "Plane → Trebi"), .init(label: "Trebi → Plane")], allowsOther: true)

    /// The first intake rows of the shot get the Enhance states in this order.
    private func seedEnhance(_ ago: @escaping (Double) -> Date) {
        let session = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "daemon", id: "mba"), id: "intake"), id: "term-e1")
        let run = { (n: String, at: Double, note: String) in
            IntakeAgent.Run(worker: Worker(id: "wk-" + n, runtime: "orca", terminal: "term-" + n, startedAt: ago(at)),
                            session: n == "e1" ? session : nil, item: UIShots.intakeRef, original: note, since: ago(at))
        }
        var asking = run("e1", 6, "labels get lost on sync")
        asking.askedAt = ago(2)
        let note = "label sync is broken again"
        let enhanced = EnhanceResult(verdict: .vague, description: """
            ## Problem
            The Plane to Trebi sync drops the labels of an item when the item has more than 10 labels.

            ## Steps
            1. Add 11 labels to a Plane item.
            2. Wait for the next sync.
            3. The Trebi item has no labels.

            ## Cause
            `LabelMapper.map` reads only the first page of the Plane labels.
            """, priority: "high", labels: ["bug", "sync"],
            relations: [.init(kind: "blocked_by", key: "TREBI-466", reason: "the new label API"),
                        .init(kind: "relates_to", key: "TREBI-402", reason: "the same mapper")],
            findings: ["The mapper reads one page of 10 labels.", "The user said: Plane to Trebi."])
        let states: [IntakeAgent.State] = [
            .asking(asking, n: 2),
            .enhancing(run("e2", 2, "")),
            .ready(enhanced, run("e3", 14, note)),
            .ready(EnhanceResult(verdict: .clear, description: "## Goal\nAdd a dark icon.", priority: "low"), run("e4", 30, "dark icon")),
            .ready(EnhanceResult(verdict: .duplicate, description: "", relations: [.init(kind: "duplicate", key: "TREBI-388", reason: "same crash")]),
                   run("e5", 40, "crash on start")),
            .failed("The agent sent no result that OverSire can read. Its text is below.", kept: "I read the sync code.\nI could not finish the JSON."),
        ]
        var order: [String: Int] = [:]
        intakeAgent.sample = { item in
            if order[item.id] == nil { order[item.id] = order.count }
            return order[item.id].flatMap { $0 < states.count ? states[$0] : nil }
        }
    }

    /// The id of the blocked row that the Sessions shot opens.
    static var expandBlocked: String?

    private func seedPlanner() {
        guard UIShots.planner else { return }
        AI_CFG.queueOrder = false
        func ref(_ k: String) -> ItemRef? { projectStore.item(key: k).flatMap { $0.item.ref(in: $0.snap.summary.ref) } }
        func rel(_ kind: RelationKind, _ k: String) -> ItemRelation? { ref(k).map { ItemRelation(kind: kind, item: $0) } }
        let rc = projectStore.relations
        rc.seed("OVERSIRE-82", [rel(.blockedBy, "OVERSIRE-67"), rel(.blockedBy, "OVERSIRE-80"), rel(.blocks, "OVERSIRE-88"),
                                rel(.relatesTo, "OVERSIRE-62")].compactMap { $0 })
        rc.seed("OVERSIRE-84", [rel(.blockedBy, "OVERSIRE-83")].compactMap { $0 })
        for k in ["OVERSIRE-83", "OVERSIRE-86", "OVERSIRE-87", "OVERSIRE-88", "OVERSIRE-89"] { rc.seed(k, []) }
        let now = Date()
        for (k, a) in [("OVERSIRE-82", ["queue", "app-ui"]), ("OVERSIRE-83", ["contract"]), ("OVERSIRE-84", ["queue"]),
                       ("OVERSIRE-86", ["contract", "cloud"]), ("OVERSIRE-87", ["app-ui"]), ("OVERSIRE-89", ["runner"])] {
            if let r = ref(k) { areas.seed(ItemAreas(item: r, areas: a, updatedAt: now)) }
        }
        agentIndex.seed("OVERSIRE-83", AgentSession(phase: .working, since: now.addingTimeInterval(-900), repo: "oversire"))
        guard let found = projectStore.item(key: "OVERSIRE-84") else { print("UISHOTS no OVERSIRE project"); return }
        let snap = found.snap, pk = snap.summary.ref.storeKey
        for k in queue.lane(pk)?.entries.map(\.key) ?? [] { queue.remove(k) }
        for k in ["OVERSIRE-84", "OVERSIRE-86", "OVERSIRE-87", "OVERSIRE-89"] {
            if let f = projectStore.item(key: k) { queue.add(f.item, snap: snap) }
        }
        try? memory.saveVision("A small, native macOS menu bar app that shows the state of developer work in one place. "
                               + "Minimal by default, accessible, no telemetry. Paid features need the server; each provider works without it.",
                               of: snap.summary.ref)
        let lane = pk
        planner.seed(PlannerSettings(project: lane, mode: .hourly, slots: 5, updatedAt: now))
        planner.seed(AreaCatalog(project: lane, areas: [
            AreaDef(name: "contract", kind: .core, rules: [AreaRule(glob: "Contract/**", source: .user)]),
            AreaDef(name: "cloud", kind: .core, rules: [AreaRule(glob: "src/**", source: .learned)]),
            AreaDef(name: "queue", kind: .feature, rules: [AreaRule(glob: "Sources/OverSireApp/queue*.swift", source: .user)]),
            AreaDef(name: "app-ui", kind: .feature, rules: [AreaRule(glob: "Sources/OverSireApp/*_page.swift", source: .graph)]),
            AreaDef(name: "runner", kind: .feature, rules: [AreaRule(glob: "runtime/**", source: .graph)]),
            AreaDef(name: "store", kind: .core, rules: [AreaRule(glob: "Sources/OverSireCore/Store*.swift", source: .graph)], proposed: true),
        ], updatedAt: now))
        guard let project = ref("OVERSIRE-84")?.project, let i84 = ref("OVERSIRE-84"), let i86 = ref("OVERSIRE-86"),
              let i83 = ref("OVERSIRE-83"), let i89 = ref("OVERSIRE-89") else { return }
        let draft = PlanDraft(
            order: [PlanDraft.OrderLine(item: i86, lane: lane, after: i89,
                                        reason: "OVERSIRE-86 and OVERSIRE-83 both change the core area contract. OVERSIRE-89 can run now.")],
            relations: [PlanDraft.RelationLine(item: i86, add: [ItemRelation(kind: .blockedBy, item: i83)],
                                               reason: "OVERSIRE-86 reads the contract records that OVERSIRE-83 adds.")],
            areas: [PlanDraft.AreaLine(item: i84, add: ["queue-page"], reason: "The diff of OVERSIRE-84 changes Sources/OverSireApp/queue_page.swift.")],
            triggers: [PlannerTrigger(kind: .queued, subject: .item(i89), at: now.addingTimeInterval(-1200))],
            overlaps: PlanDraft.Overlaps(before: 3, after: 0), kinds: ["queue-page": .feature])
        suggestions.seed(Suggestion(id: "s-uishots-plan", subject: .project(project), kind: .plan, title: "Plan change for OVERSIRE",
                                    body: "Start OVERSIRE-89 before OVERSIRE-86, so that two items do not change the core area contract.",
                                    proposal: .plan(draft), subjectVersion: "v1", createdAt: now.addingTimeInterval(-3600),
                                    expiresAt: now.addingTimeInterval(3 * 86400 + 600)))
    }

    static var billing: BillingState? {
        guard cloud == true else { return nil }
        return BillingState(plan: "cloud", periodStart: Date().addingTimeInterval(-20 * 86400), periodEnd: Date().addingTimeInterval(11 * 86400),
                            grantMicroUSD: 2_000_000, grantUsedMicroUSD: 1_684_000, balanceMicroUSD: 8_420_000, dailyCapMicroUSD: 500_000,
                            notice80Sent: true)
    }

    static var runners: [RunnerState] {
        guard cloud == true else { return [] }
        return [RunnerState(device: "D1", version: "0.1.0", contract: 1, runtimes: ["orca"], os: "darwin/arm64", online: true, lastSeen: Date())]
    }

    static var runnerSessions: [RunnerSession] {
        guard cloud == true else { return [] }
        let item = { (key: String) in
            ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: String(key.split(separator: "-")[0])),
                    id: key, key: key, url: URL(string: "https://app.plane.so/ocral/browse/\(key)/")!)
        }
        let ref = { (ws: String, id: String) in
            SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "oversire", id: "local"), id: ws), id: id)
        }
        return [
            RunnerSession(id: "s-7f3a", runner: "D1", session: ref("towertail-workspace/TOWERTAIL-2", "s-7f3a"), order: "o1", agent: "claude",
                          repo: "/home/ada/src/towertail-workspace", branch: "towertail-2", item: item("TOWERTAIL-2"), state: .waitingPermission,
                          summary: "Added the retry to the sync client. Wants to run the tests.",
                          permission: PermissionPrompt(id: "p-1", tool: "Bash", text: "npm test", expiresAt: Date().addingTimeInterval(540)),
                          startedAt: Date().addingTimeInterval(-1680), updatedAt: Date().addingTimeInterval(-60)),
            RunnerSession(id: "s-91c0", runner: "D1", session: ref("oversire/OVERSIRE-80", "s-91c0"), order: "o2", agent: "codex",
                          repo: "/home/ada/src/oversire", branch: "oversire-80", item: item("OVERSIRE-80"), state: .working,
                          summary: "Reads the store tests.", startedAt: Date().addingTimeInterval(-600), updatedAt: Date().addingTimeInterval(-20)),
            RunnerSession(id: "s-2b44", runner: "D1", session: ref("oversire/OVERSIRE-81", "s-2b44"), order: "o3", agent: "claude",
                          repo: "/home/ada/src/oversire", item: item("OVERSIRE-81"), state: .queued,
                          startedAt: Date().addingTimeInterval(-120), updatedAt: Date().addingTimeInterval(-120)),
            RunnerSession(id: "s-0d17", runner: "D1", session: ref("oversire/OVERSIRE-77", "s-0d17"), order: "o4", agent: "gemini",
                          repo: "/home/ada/src/oversire", branch: "oversire-77", item: item("OVERSIRE-77"), state: .failed,
                          error: "The worktree has changes that are not committed.", startedAt: Date().addingTimeInterval(-7200),
                          updatedAt: Date().addingTimeInterval(-6900)),
        ]
    }

    static func explainPhase(_ name: String) -> ExplainPopover.Phase {
        switch name {
        case "loading": return .loading("The AI reads the log")
        case "error": return .failed("Could not explain: the engine answered 429 (rate limit).")
        default:
            return .result(RunExplanation(cause: "StoreTests.testPut expects 3 rows, but the store keeps 2 after the new dedupe step in LocalStore.put.",
                                          fix: "Update the expected count in StoreTests, or keep duplicates when the ids differ.", confidence: "medium"))
        }
    }

    // `kit`: each settings control once, in a window of its own.
    static func kitSample() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 760, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Page kit"
        let page = PageScroll(maxWidth: 760)
        let root = Box(fill: Palette.bg, border: nil, radius: 0)
        root.addSubview(page)
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: root.leadingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     page.topAnchor.constraint(equalTo: root.topAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        w.contentView = root
        page.rebuild { col in
            col.addArrangedSubview(TabStrip(["Projects", "Repos", "Linking and write-back"], selected: 1, counts: [6, 51, nil]))
            let card = ListCard()
            card.add(FieldRow("Theme", Segmented(["Light", "Dark", "System"], selected: 1, label: "Theme") { _ in }))
            let chips = ChipGroup([.init("Runs", on: true) { _ in }, .init("Pull requests", on: true) { _ in }, .init("Insights", on: false) { _ in }],
                                  label: "Tabs")
            card.add(Row([NSTextField.text("Tabs", size: 13, weight: .medium), Spacer(), chips], height: 40))
            let off = ChipGroup([.init("Links", on: true) { _ in }, .init("Session labels", on: false) { _ in }], label: "Write back", enabled: false,
                                note: "Off: the chips do nothing.")
            card.add(Padded(off))
            col.addFull(card)
            let health = HealthCounts([.init(count: 48, kind: .ok, word: "live"), .init(count: 2, kind: .warning, word: "missing"),
                                       .init(count: 1, kind: .failure, word: "failed")])
            let hc = Card()
            hc.add(HealthBar(health, trailing: [ActionButton("Show in the repo list ›", style: .link)]))
            col.addFull(hc)
            let more = ListCard()
            let d = Disclosure("Advanced: event retention, reconcile poll, devices, log", id: "kit")
            if !d.isOpen { d.toggle() }
            d.add(FieldRow("Keep events for", NSTextField.text("7 days", size: 12.5)))
            d.add(FieldRow("Reconcile poll while live", NSTextField.text("10 min", size: 12.5)))
            more.add(d)
            col.addFull(more)
            col.addFull(CardGrid([
                ServiceCard(icon: ServiceCard.icon("P", color: .systemIndigo), name: "Plane", detail: "Tracker · ocral", status: Pill(.ok, text: "OK"),
                            actions: [ActionButton("Edit"), ActionButton("Add account", style: .link)]),
                ServiceCard(icon: ServiceCard.icon("GH", color: .darkGray), name: "GitHub", detail: "Code host and Actions · gh CLI",
                            status: Pill(.warning, text: "Check"), actions: [ActionButton("Test")]),
                ServiceCard(icon: ServiceCard.icon("+", color: nil), name: "Add a service", detail: "Linear, GitLab, Conductor …", status: nil,
                            actions: [], dashed: true),
            ]))
            let list = StickyListCard(header: NSStackView(h: [NSTextField.text("Filter, or type owner/repo to add", size: 12.5, color: Palette.dim), Spacer(),
                                                              ToggleChip("All 212", on: true) {}, ToggleChip("Problems 3", on: false) {}]), maxHeight: 220)
            for owner in ["flarco", "slingdata-io", "oversire"] {
                list.addGroup { Row([NSTextField.text(owner, size: 12, weight: .semibold), Spacer(), ActionButton("Track all", style: .link)], height: 32) }
                for r in 1...4 { list.add(Row([NSTextField.text("\(owner)-repo-\(r)", size: 12.5), Spacer(), Pill(.ok, text: "Webhook")], height: 34)) }
            }
            col.addFull(list)
        }
        w.orderFrontRegardless()
        page.layoutSubtreeIfNeeded()
        list(in: page)?.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        return w
    }

    private static func list(in v: NSView) -> StickyListCard? { find(v) { $0 is StickyListCard } as? StickyListCard }

    // A source that never answers.
    struct NeverAnswers: RunSource {
        func run(_ repo: String, id: String) async -> Run? { await wait(); return nil }
        func jobs(_ repo: String, runId: String) async -> [Job]? { await wait(); return nil }
        private func wait() async { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }

    // OVERSIRE_UISHOTS_RUNNING=1: the newest run of the first three repos shows as running, to check the live clock.
    static func running(_ g: [(String, [Run])]) -> [(String, [Run])] {
        var g = g
        var n = 0
        for i in g.indices where n < 3 {
            guard let r = g[i].1.first else { continue }
            let started = isoFmt.string(from: Date().addingTimeInterval(-[70, 900, 30][n]))
            g[i].1[0] = Run(id: r.id, name: r.name, displayTitle: r.displayTitle, status: "in_progress", conclusion: nil, headBranch: r.headBranch,
                            headSha: r.headSha, event: r.event, url: r.url, updatedAt: started, createdAt: started, startedAt: started,
                            number: r.number, workflowName: r.workflowName, actorLogin: r.actorLogin)
            n += 1
        }
        return g
    }

    func refresh(force: Bool, completion: (() -> Void)?) {
        if UIShots.loading {
            _ = busy.begin("Refreshing runs and pull requests: \(REPOS.count) repos")
            completion?()
            return
        }
        let repos = REPOS
        Task {
            let (found, prs) = await GHActionsBar.fetch(repos, prs: true)
            var runs = found.map { ($0.0, $0.1 ?? []) }
            if ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_RUNNING"] == "1" { runs = UIShots.running(runs) }
            DispatchQueue.main.async {
                self.grouped = runs; self.prGrouped = prs
                if let fx = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_FIXTURES"], let d = FileManager.default.contents(atPath: fx + "/prs.json"),
                   let list = try? JSONDecoder().decode([UIShots.FixturePR].self, from: d) {
                    self.prGrouped = Dictionary(grouping: list, by: \.repo).map { r, ps in (r, ps.map { var p = $0.pr; p.mine = $0.mine; return p }) }
                }
                self.firstLoad = false; self.lastUpdate = Date()
                self.workstreams.scan(cards: self.agentIndex.cards, roots: Array(PROJECTS_CFG.orca.roots.values),
                                      known: Set(self.projectStore.tracked.map { $0.identifier.uppercased() })) {
                    self.workstreams.rebuild(store: self.projectStore, agents: self.agentIndex, runs: self.grouped, prs: self.prGrouped)
                    for s in self.workstreams.streams.values.sorted(by: { $0.key < $1.key }) {
                        print("UISHOTS stream \(s.key) item=\(s.item != nil) agent=\(s.agent.map { "\($0.phase)" } ?? "-") checkouts=\(s.checkouts.map(\.branch)) runs=\(s.runs.map { "\($0.run.workflowName ?? "")#\($0.run.number):\($0.reason)" }.prefix(3)) prs=\(s.prs.map(\.pr.number))")
                    }
                    print("UISHOTS unlinked \(self.workstreams.unlinked.count) checkouts \(self.workstreams.checkouts.count)")
                    // Live write-back test for the items named in OVERSIRE_UISHOTS_WRITEBACK, for example "FRITZ-28".
                    if let keys = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_WRITEBACK"]?.split(separator: ",").map(String.init) {
                        let wb = PlaneWriteBack(path: UIShots.tmp + "/wb-live.json", store: self.projectStore, trackers: ENV)
                        wb.onError = { print("UISHOTS writeback error \($0)") }
                        wb.sync(keys.compactMap { self.workstreams.streams[$0] })
                    }
                    self.bus.post(DataChange(.all))
                }
                self.bus.post(DataChange(.all))
                completion?()
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        loadConfig(save: false)
        if let fx = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_FIXTURES"], FileManager.default.fileExists(atPath: fx + "/ci.json") {
            AI_CFG.digest = true
        }
        REPOS = repoCatalog.resolve(picked: PICKED_REPOS, orgs: PICKED_ORGS)
        assignRepoColors(REPOS)
        projectStore.track(projectCatalog.resolve(PROJECTS_CFG), live: [])
        if let key = UIShots.aiKey {
            AI_CFG.format = .anthropic
            AI_CFG.baseURL = "https://api.anthropic.com"
            AI_CFG.model = "claude-haiku-5-5"
            AI_CFG.enabled = true
            AI_CFG.verified = AI_CFG.fingerprint(key: key)
        }
        if ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_ENGINE"] == "cli" { Self.seedLocalCLI() }
        if UIShots.sampleLogs { seedLogs() }
        if UIShots.overrides {
            PROJECTS_CFG.settings["TREBI", default: ProjectLocalSettings()].muted = true
            var n = PROJECTS_CFG.notifications
            n.comment.any = true
            n.agentDone = false
            PROJECTS_CFG.settings["SLING", default: ProjectLocalSettings()].notifications = n
        }
        if UIShots.commands {
            PROJECTS_CFG.runtime.commands = ["claude": "claude -n {name} --dangerously-skip-permissions"]
            AgentCommandsCard.drafts = ["codex": "codex --full-auto; echo done"]
        }
        useSampleMachines()
        agentIndex.poll()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        refresh(force: true) { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.shoot() } }
    }

    private func shoot() {
        UIShots.shooting = true
        seedPlanner()
        seedSummaries()
        seedSessions()
        seedCleanup()
        // The seeded sessions join their items.
        workstreams.rebuild(store: projectStore, agents: agentIndex, runs: grouped, prs: prGrouped)
        // The heuristics only: a shot never calls the AI.
        statusJob.ai = { nil }
        statusJob.tick(workstreams: workstreams, store: projectStore)
        let w = AppWindow(data: self)
        window = w
        w.window?.setFrameAutosaveName("")
        let env = ProcessInfo.processInfo.environment
        let width = env["OVERSIRE_UISHOTS_WIDTH"].flatMap(Double.init) ?? 1280
        let height = env["OVERSIRE_UISHOTS_HEIGHT"].flatMap(Double.init) ?? 860
        w.window?.setFrame(NSRect(x: 40, y: 40, width: width, height: height), display: true)
        if let side = env["OVERSIRE_UISHOTS_SIDEBAR"].flatMap(Double.init) { w.setSidebarWidth(side) }
        w.window?.orderFrontRegardless()
        let routes = paths.isEmpty ? Route.samples.map(\.path) + ["palette:item"] : paths
        var steps: [() -> Void] = []
        for theme in [Theme.dark, .light] {
            steps.append { NSApp.appearance = theme.appearance }
            for p in routes {
                if p.hasPrefix("wait:") {
                    let n = Int(p.dropFirst(5)) ?? 1
                    steps += Array(repeating: {}, count: n * 2)
                    continue
                }
                steps.append {
                    if !p.hasPrefix("press:") { self.glance?.orderOut(nil); self.glance = nil }
                    if p.hasPrefix("press:") {
                        let spec = p.dropFirst(6).split(separator: "@", maxSplits: 1).map(String.init)
                        if let root = (self.glance ?? QueuePage.openSheet ?? w.window)?.contentView, !UIShots.press(spec[0], scope: spec.count > 1 ? spec[1] : nil, in: root) {
                            print("UISHOTS no button \(p)")
                        }
                    } else if p.hasPrefix("sidebar:") {
                        if !w.sidebar.reopen(title: String(p.dropFirst(8))) { print("UISHOTS no sidebar entry \(p)") }
                    } else if p.hasPrefix("segment:") {
                        // segment:<label>: picks the segment with that label in the first segmented control that has it.
                        let label = String(p.dropFirst(8))
                        if let root = w.window?.contentView, let seg = UIShots.find(root, { s in
                            guard let s = s as? NSSegmentedControl else { return false }
                            return (0..<s.segmentCount).contains { s.label(forSegment: $0) == label }
                        }) as? NSSegmentedControl, let i = (0..<seg.segmentCount).first(where: { seg.label(forSegment: $0) == label }) {
                            seg.selectedSegment = i
                            _ = seg.sendAction(seg.action, to: seg.target)
                        } else { print("UISHOTS no segment \(p)") }
                    } else if p.hasPrefix("toggle:") {
                        let name = String(p.dropFirst(7))
                        if let root = w.window?.contentView, let sw = UIShots.find(root, { ($0 as? NSSwitch)?.accessibilityLabel() == name }) as? NSSwitch {
                            sw.performClick(nil)
                        } else { print("UISHOTS no switch \(p)") }
                    } else if p.hasPrefix("type:") {
                        // type:<label>=<text>, or type:<label>=<text>*<n> for the text n times.
                        let spec = p.dropFirst(5).split(separator: "=", maxSplits: 1).map(String.init)
                        var text = spec.count > 1 ? spec[1] : ""
                        if let star = text.lastIndex(of: "*"), let n = Int(text[text.index(after: star)...]) { text = String(repeating: String(text[..<star]), count: n) }
                        if let root = w.window?.contentView,
                           let f = UIShots.find(root, { ($0 as? NSTextField)?.accessibilityLabel() == spec[0] && ($0 as? NSTextField)?.isEditable == true }) as? NSTextField {
                            f.stringValue = text
                            f.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: f))
                        } else { print("UISHOTS no field \(p)") }
                    } else if p == "end" {
                        w.page?.scroll.toEnd()
                    } else if p.hasPrefix("glance:") {
                        GlanceVC.tab = GlanceVC.Tab.allCases.first { $0.title.lowercased() == p.dropFirst(7) } ?? .now
                        let g = NSWindow(contentRect: NSRect(origin: NSPoint(x: 1360, y: 200), size: GlanceVC.size), styleMask: [.borderless], backing: .buffered, defer: false)
                        g.contentViewController = GlanceVC(data: self) { print("UISHOTS glance open \($0.path)"); w.router.go($0) }
                        g.orderFrontRegardless()
                        self.glance = g
                    } else if p.hasPrefix("explain:"), let root = w.window?.contentView {
                        // explain:loading, explain:result or explain:error, at the first run row, else at the window center.
                        let row = UIShots.find(root) { ($0 as? Row)?.menuItems != nil && ($0.accessibilityLabel() ?? "").contains("#") } ?? root
                        ExplainPopover.sample(at: row, phase: UIShots.explainPhase(String(p.dropFirst(8))))
                    } else if p.hasPrefix("hover:"), let root = w.window?.contentView {
                        // hover:<text>: the summary of the first status pill whose label has the text.
                        let text = String(p.dropFirst(6))
                        if let pill = UIShots.find(root, { ($0 as? StatusPill).map { text.isEmpty || $0.status.label.contains(text) } ?? false }) as? StatusPill {
                            pill.hover?.show()
                        } else { print("UISHOTS no status pill \(p)") }
                    } else if p.hasPrefix("scroll:"), let root = w.window?.contentView {
                        // scroll:<text>: the first row whose label has the text goes to the top.
                        let text = String(p.dropFirst(7))
                        if let row = UIShots.find(root, { ($0 as? Row)?.accessibilityLabel()?.contains(text) == true }),
                           let clip = row.enclosingScrollView?.contentView {
                            clip.scroll(to: NSPoint(x: 0, y: clip.convert(row.bounds, from: row).minY - 60))
                            row.enclosingScrollView?.reflectScrolledClipView(clip)
                        } else { print("UISHOTS no row \(p)") }
                    } else if p.hasPrefix("snap:") {
                        self.snapPanel?.close()
                        self.snapPanel = UIShots.snapSample(String(p.dropFirst(5)), shooting: w)
                    } else if p.hasPrefix("basket:") {
                        self.basketPanel?.orderOut(nil)
                        self.basketPanel = UIShots.basketSample(String(p.dropFirst(7)), shooting: w)
                        if p == "basket:send", let panel = self.basketPanel { self.shootMenu(of: panel, name: "\(theme.rawValue)-basket-send-menu") }
                    } else if p.hasPrefix("session:") {
                        self.sessionWindow?.orderOut(nil)
                        self.sessionWindow = UIShots.sessionSample(String(p.dropFirst(8)), shooting: w)
                    } else if p.hasPrefix("startmenu:"), let found = self.projectStore.item(key: String(p.dropFirst(10))),
                              let more = w.window?.contentView.flatMap({ UIShots.find($0) { $0.accessibilityLabel() == "Start in Orca with" } }) {
                        // startmenu:<KEY>: the agent list of the item page split button.
                        self.shootMenu(SessionStartMenu(self).agents(found.item, snap: found.snap, at: more), under: more, name: "\(theme.rawValue)-startmenu")
                    } else if p == "pill" {
                        // pill: an update waits while the person scrolls.
                        w.gate.begin(.scroll)
                        w.gate.submit {}
                    } else if p.hasPrefix("live:") {
                        // live:on, connecting, error or off: the connection line of the sidebar. "on" shows a burst just now.
                        let state: LiveSync.State
                        switch p.dropFirst(5) {
                        case "on": state = .live
                        case "connecting": state = .connecting
                        case "error": state = .error("The hub did not answer.")
                        default: state = .off
                        }
                        w.sidebar.live.set(LiveLineModel(state: state, lastBurst: state == .live ? Date() : nil, pollEvery: POLL_NORMAL))
                    } else if p == "popover" {
                        self.glance = self.popoverSample()
                    } else if p == "menuicon" {
                        self.glance = UIShots.menuIconSample()
                    } else if p == "kit" {
                        self.glance = UIShots.kitSample()
                    } else if p.hasPrefix("questions:") {
                        self.glance = UIShots.questionsSample(String(p.dropFirst(10)))
                    } else if p.hasPrefix("palette:") {
                        CommandPalette.show(over: w, query: String(p.dropFirst("palette:".count)))
                    } else if p.hasPrefix("assistant:") {
                        self.assistantState(String(p.dropFirst(10)), in: w)
                    } else if MachinesSnapshot.scenes.contains(p) {
                        UIShots.machines(p, in: w)
                    } else if let r = Route(path: p) {
                        w.router.go(r)
                    } else {
                        print("UISHOTS bad path \(p)")
                    }
                }
                // The chat views and the Markdown web views need time.
                if p.hasPrefix("assistant:") { steps += Array(repeating: {}, count: 4) }
                steps.append { self.capture(w, name: "\(theme.rawValue)-" + p.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")) }
                steps.append { w.gate.end(.scroll); w.gate.flushNow(); CommandPalette.dismiss(); ExplainPopover.dismiss(); HoverSummary.dismiss(); self.snapPanel?.close(); self.snapPanel = nil; MachineSheets.open?.dismiss(); self.basketPanel?.orderOut(nil); self.basketPanel = nil
                    self.sessionWindow?.orderOut(nil); self.sessionWindow = nil }
            }
        }
        run(steps, 0)
    }

    private func run(_ steps: [() -> Void], _ i: Int) {
        guard i < steps.count else { print("UISHOTS DONE \(dir)"); exit(0) }
        steps[i]()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.run(steps, i + 1) }
    }

    static func find(_ v: NSView, _ match: (NSView) -> Bool) -> NSView? {
        if match(v) { return v }
        for s in v.subviews { if let f = find(s, match) { return f } }
        return nil
    }

    // Presses the first button whose title starts with `title`, inside the first view whose
    // accessibility label contains `scope`. The title "row" presses the row itself.
    static func press(_ title: String, scope: String?, in root: NSView) -> Bool {
        var base = root
        if title == "row", let scope {
            guard let r = find(root, { ($0 as? Row)?.onClick != nil && ($0.accessibilityLabel() ?? "").contains(scope) }) as? Row else { return false }
            r.onClick?()
            return true
        }
        if let scope {
            guard let s = find(root, { ($0.accessibilityLabel() ?? "").contains(scope) }) else { return false }
            base = s
        }
        if let c = find(base, { ($0 as? Chiplet)?.onClick != nil && $0.accessibilityLabel()?.hasPrefix(title) == true }) as? Chiplet {
            c.onClick?()
            return true
        }
        guard let b = find(base, { ($0 as? NSButton)?.title.hasPrefix(title) == true }) as? NSButton else { return false }
        if let a = b as? ActionButton, let run = a.onClick { run() } else { b.performClick(nil) }
        return true
    }

    private func capture(_ w: AppWindow, name: String) {
        guard let num = w.window?.windowNumber else { return }
        let out = (dir as NSString).appendingPathComponent(name + ".png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let panel: Int? = snapPanel?.windowNumber ?? basketPanel?.windowNumber ?? sessionWindow?.windowNumber ?? glance?.windowNumber
        let popup: Int? = QueuePage.windowNumber ?? MachineSheets.windowNumber ?? CommandPalette.windowNumber
        let tip: Int? = HoverSummary.windowNumber ?? ExplainPopover.windowNumber
        p.arguments = ["-x", "-o", "-l", "\(panel ?? popup ?? tip ?? num)", out]
        try? p.run()
        p.waitUntilExit()
        print("UISHOTS \(out) sidebar=\(Int(w.sidebar.view.frame.width)) page=\(Int(w.page?.view.frame.width ?? 0))")
    }
}

// MARK: Snap editor samples

extension UIShots {
    /// snap:<frame>: the shot editor on a shot of the app window. Frames: new, marks, crop, mismatch, confirm, edit.
    static func snapSample(_ frame: String, shooting w: AppWindow) -> ShotEditorPanel? {
        guard let view = w.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let img = rep.cgImage else { return nil }
        let projects = [SnapProjectChoice(key: "OVERSIRE", title: "OverSire"), SnapProjectChoice(key: "SLING", title: "Sling Platform"),
                        SnapProjectChoice(key: "TREBI", title: "Trebi"), SnapProjectChoice(key: "FRITZ", title: "Fritz")]
        let shot = SnapShot(project: frame == "new" ? "" : "SLING", kind: .window, app: "OverSire", windowTitle: "Runs",
                            pixelSize: CGSize(width: img.width, height: img.height), scale: Double(rep.size.width > 0 ? CGFloat(img.width) / rep.size.width : 2))
        let existing = frame == "edit"
        let basket: String? = frame == "new" ? nil : frame == "mismatch" ? "OVERSIRE" : "SLING"
        var m = SnapEditorModel(shot: shot, existing: existing, basketProject: basket, basketCount: frame == "new" ? 0 : 2, lastProject: nil)
        if frame != "new" {
            let W = Double(img.width), H = Double(img.height)
            m.addMark(SnapRect(x: W * 0.04, y: H * 0.12, w: W * 0.2, h: H * 0.3))
            m.shot.marks[0].note = "This list shows 3 runs. The repo has 4."
            m.addMark(SnapRect(x: W * 0.62, y: H * 0.05, w: W * 0.03, h: H * 0.04))
            m.shot.marks[1].note = "Icon is cut off at 125% zoom."
            m.shot.note = "The runs page is out of date after a re-run."
            m.selected = 1
        }
        if frame == "crop" { m.startCrop(); m.crop = SnapRect(x: 0, y: 0, w: Double(img.width) * 0.7, h: Double(img.height) * 0.6) }
        if frame == "mismatch" { m.pick("SLING") }
        if frame == "confirm" { m.confirming = true }
        let p = ShotEditorPanel(model: m, image: img, projects: projects, near: nil, actions: .init())
        p.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 600), display: true)
        p.present()
        return p
    }
}

// MARK: New session samples

extension UIShots {
    /// session:<frame>: the New panel. Frames: empty, list, files, direct, listening, noworkspace, failed, toast, intake, intakeoff, item, itemtoast.
    static func sessionSample(_ frame: String, shooting w: AppWindow) -> NSWindow? {
        let c = NewSessionController(projects: { [] })
        let choices = [NewSessionModel.Choice(key: "OVERSIRE", name: "OverSire", store: "plane:ocral/OVERSIRE", root: NSHomeDirectory() + "/Projects/oversire"),
                       NewSessionModel.Choice(key: "SLING", name: "Sling Platform", store: "plane:ocral/SLING", root: NSHomeDirectory() + "/Projects/sling"),
                       NewSessionModel.Choice(key: "TREBI", name: "Trebi", store: "plane:ocral/TREBI", root: nil,
                                              states: [StatusOption(id: "b", name: "Backlog", color: "#999", group: "backlog"),
                                                       StatusOption(id: "t", name: "Todo", color: "#999", group: "unstarted"),
                                                       StatusOption(id: "p", name: "In Progress", color: "#999", group: "started")]),
                       NewSessionModel.Choice(key: "FRITZ", name: "Fritz", store: "plane:ocral/FRITZ", root: NSHomeDirectory() + "/notes")]
        var cfg = SessionConfig()
        cfg.lastProject = ["noworkspace", "intake", "intakeoff", "item"].contains(frame) ? "plane:ocral/TREBI" : "plane:ocral/OVERSIRE"
        cfg.mode = frame.hasPrefix("intake") ? .intake : frame == "item" ? .item : .session
        cfg.intake = frame != "direct"
        var m = NewSessionModel(choices: choices, cfg: cfg, agent: "claude")
        if frame == "toast" {
            let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: .daemon, id: "mba"), id: "path:/x"), id: "t1")
            let item = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"), id: "i1", key: "OVERSIRE-153", url: URL(string: "https://app.plane.so")!)
            c.showToast(SessionStarter.Result(session: s, item: item, paths: [], missing: [], terminal: "claude-the-runs-page"),
                        agent: "claude", root: choices[0].root ?? "", files: 2)
            return c.toast
        }
        if frame == "itemtoast" {
            let item = ItemRef(project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "TREBI"), id: "i1", key: "TREBI-42", url: URL(string: "https://app.plane.so/ocral/browse/TREBI-42")!)
            c.showToast(SessionStarter.Made(item: item, missing: []), mode: .item, files: 1)
            return c.toast
        }
        if frame == "list" { m.type("s") }
        if frame == "intakeoff" { m.intakeOff = ["plane:ocral/TREBI"] }
        if frame.hasPrefix("intake") { m.text = "Steps:\n1. Sign in with Google.\n2. The redirect lands on /callback and the page is blank." }
        if frame == "item" { m.titleText = "Add a retry to the OAuth callback"; m.text = "The token exchange fails on a slow network."; m.priority = "medium" }
        if ["files", "direct", "failed", "intake", "item"].contains(frame) {
            if m.text.isEmpty { m.text = "The runs page is out of date after a re-run.\nFix the refresh and add a test." }
            if let view = w.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:]) ?? Data()
                m.add([.init(name: "pasted-1.png", data: png, isImage: true), .init(name: "runs.png", data: png + Data([0]), isImage: true),
                       .init(name: "sync.log", data: Data(repeating: 65, count: 48_000))])
            }
        }
        if frame == "listening" { m.text = "Why is the sync slow"; m.phase = .listening }
        if frame == "wide" { m.text = "When I scroll down tables I want to see the top and the columns." }
        if frame == "failed" { m.intake = false; m.phase = .failed(SessionStartError.hostFiles("runs.png did not arrive whole on the sessions machine.").localizedDescription) }
        let p = c.present(m, near: nil)
        p.promptView.string = m.text
        p.titleField.stringValue = m.titleText
        p.setPhase(m.phase, hostFiles: frame == "failed")
        if frame == "wide" { p.resize(from: p.frameSaved, dx: 180, dy: 90) }
        return p
    }
}

// MARK: Basket panel samples

extension UIShots {
    /// basket:<frame>: the basket panel with 3 shots of the app window. Frames: collapsed, open, remove, send, discard, two.
    static func basketSample(_ frame: String, shooting w: AppWindow) -> BasketPanel? {
        guard let view = w.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let img = rep.cgImage else { return nil }
        let dir = URL(fileURLWithPath: UIShots.tmp + "/captures-\(UUID().uuidString)")
        let store = SnapStore(dir: dir)
        let W = Double(img.width), H = Double(img.height)
        let notes = [("The runs page is out of date after a re-run.", SnapRect(x: 0, y: 0, w: W * 0.5, h: H * 0.5), 2),
                     ("", SnapRect(x: W * 0.3, y: H * 0.2, w: W * 0.4, h: H * 0.3), 0),
                     ("The queue count does not match the list.", SnapRect(x: W * 0.5, y: 0, w: W * 0.5, h: H * 0.6), 1)]
        var ids: [UUID] = []
        for (i, (note, crop, marks)) in notes.enumerated() {
            let m = (0..<marks).map { k in SnapMark(rect: SnapRect(x: crop.x + crop.w * (0.1 + 0.4 * Double(k)), y: crop.y + crop.h * 0.2,
                                                                 w: crop.w * 0.3, h: crop.h * 0.3), note: "") }
            let s = SnapShot(project: "SLING", kind: i == 1 ? .area : .window, app: "OverSire", windowTitle: "Runs",
                             pixelSize: CGSize(width: img.width, height: img.height), scale: 2, crop: crop, note: note, marks: m)
            try? store.add(s, png: rep.representation(using: .png, properties: [:]) ?? Data())
            ids.append(s.id)
        }
        if frame == "two" {
            try? store.add(SnapShot(project: "TREBI", kind: .window, app: "OverSire", windowTitle: "Home",
                                    pixelSize: CGSize(width: img.width, height: img.height), scale: 2), png: rep.representation(using: .png, properties: [:]) ?? Data())
        }
        let projects = [SnapProjectChoice(key: "SLING", title: "Sling Platform"), SnapProjectChoice(key: "TREBI", title: "Trebi")]
        let p = BasketPanel(store: store, projects: { projects }, actions: .init())
        var st = SnapBasketState(baskets: store.openBaskets, project: "SLING")
        st.open = !["collapsed", "send", "sending"].contains(frame)
        if frame == "remove" { st.confirmShot = ids[1] }
        if frame == "discard" { st.confirmAll = true }
        if frame == "sending" { st.sending = st.current?.id }
        if frame == "sent" {
            st = SnapBasketState(baskets: [], project: "SLING")
            st.notice = .init(text: "Created SLING-412 with 3 shots.", link: URL(string: "https://plane.so"))
        }
        if frame == "failed" {
            st.open = false
            st.notice = .init(text: SnapSendError.noAttachments.localizedDescription, bad: true, copy: st.current?.id)
        }
        p.present(st)
        return p
    }

    /// Opens the Send menu, shoots the panel and the menu as one screen area, then closes the menu.
    /// The menu blocks the default run loop mode, so the timer runs in the common modes.
    /// Opens `menu` under `v` and shoots the area around it.
    func shootMenu(_ menu: NSMenu, under v: NSView, name: String) {
        guard let win = v.window else { return }
        let out = (dir as NSString).appendingPathComponent(name + ".png")
        let f = win.convertToScreen(v.convert(v.bounds, to: nil))
        let t = Timer(timeInterval: 0.8, repeats: false) { _ in
            let top = NSScreen.screens[0].frame.maxY
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "\(Int(f.minX) - 300),\(Int(top - f.maxY) - 40),560,340", out]
            try? p.run()
            p.waitUntilExit()
            print("UISHOTS \(out)")
            menu.cancelTracking()
        }
        RunLoop.main.add(t, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.height + 2), in: v)
    }

    func shootMenu(of panel: BasketPanel, name: String) {
        guard let menu = panel.popSendMenu() else { return }
        let out = (dir as NSString).appendingPathComponent(name + ".png")
        let t = Timer(timeInterval: 0.8, repeats: false) { _ in
            let f = panel.frame
            let top = NSScreen.screens[0].frame.maxY
            let r = "\(Int(f.minX) - 10),\(Int(top - f.maxY) - 260),\(Int(f.width) + 240),\(Int(f.height) + 270)"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", r, out]
            try? p.run()
            p.waitUntilExit()
            print("UISHOTS \(out)")
            menu.cancelTracking()
        }
        RunLoop.main.add(t, forMode: .common)
    }
}

// The Local CLI table from fixed detections, with no probe.
extension UIShots {
    // The lines of the Logs design board, in a temp folder.
    private func seedLogs() {
        let dir = UIShots.tmp + "/logs"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { try? FileManager.default.removeItem(atPath: dir + "/" + f) }
        try? FileManager.default.removeItem(atPath: UIShots.tmp + "/problems.json")
        let store = LogStore(dir: dir, problems: ProblemTracker(path: UIShots.tmp + "/problems.json"))
        self.logs = store
        let now = Date()
        func line(_ min: Double, _ level: LogLevel, _ area: LogArea, _ job: String, _ subject: String?, _ host: String?, _ msg: String, _ ms: Int?,
                  _ fill: (inout LogEntry) -> Void = { _ in }) {
            var e = LogEntry(at: now.addingTimeInterval(-min * 60), level: level, area: area, job: job, subject: subject, host: host, message: msg, ms: ms)
            fill(&e)
            store.write(e)
        }
        line(31, .ok, .sync, "GitHub poll", nil, "gh", "4 repos · no change", 1300)
        line(19, .ok, .ai, "CI cause", "oversire #812", "local-cli", "Test timeout in LiveSyncTests", 3200) {
            $0.engine = "local-cli"; $0.model = "claude"; $0.output = "cause: LiveSyncTests waited 30 s for a fake event."
        }
        line(12, .ok, .runner, "Work order", "OVERSIRE-149", "mbp", "The runner has it", nil)
        line(11.9, .ok, .sync, "Plane poll", "OVERSIRE", "ocral", "3 items changed", 800)
        line(11.5, .ok, .ai, "Status", "OVERSIRE-148", "local-cli", "Working · idle 10 min", 5900)
        for m in [29.0, 20, 11] {
            line(m, .warn, .sessions, "History read", "TOWERTAIL-61", "mbp", "Used the screen only: python3 not found on mbp.", 1100) {
                $0.exit = 127; $0.outputTail = "bash: python3: command not found\n(no OVERSIRE-DIGEST-END marker)"
            }
        }
        line(3, .ok, .ai, "Summary", "OVERSIRE-150", "local-cli", "Done", 4800) {
            $0.engine = "local-cli"; $0.model = "claude"; $0.reason = "Auto: updated in the last 7 days"; $0.tokensIn = 1020; $0.tokensOut = 188
            $0.output = "gist: Logs page and problem marks for background jobs."
        }
        line(0.9, .error, .ai, "Summary", "OVERSIRE-152", "api-key", "401 Unauthorized: invalid x-api-key", 400) {
            $0.engine = "api-key"; $0.model = "deepseek"; $0.reason = "Description changed"
            $0.output = #"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        }
        line(0.5, .ok, .ai, "Status", "OVERSIRE-137", "local-cli", "Done", 6200) {
            $0.engine = "local-cli"; $0.model = "claude-haiku-5-5"; $0.reason = "Turn end (Orca: done)"; $0.tokensIn = 2864; $0.tokensOut = 612; $0.stop = "end_turn"
            $0.input = "Item OVERSIRE-137: Status card\nLast turns: 3 · closing messages: 2 · description: yes"
            $0.output = "state: blocked\nheadline: Shipped in v1.3.13; a live test of \"Tell the agent\" still needs you.\nneedsYou: Install v1.3.13"
        }
        LogListView.model = LogListModel()
        LogListView.open = store.entries.first
    }

    // The footer of the popover with the problem line, in a plain window.
    private func popoverSample() -> NSWindow {
        let f = Footer(POP_W, updated: Date(), problems: openProblems)
        let g = NSWindow(contentRect: NSRect(x: 1360, y: 200, width: POP_W, height: f.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        g.contentView = f
        g.orderFrontRegardless()
        return g
    }

    // The menu bar icon at 4x: no problem, a problem, and a problem on a failed run.
    static func menuIconSample() -> NSWindow {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let g = NSWindow(contentRect: NSRect(x: 1360, y: 200, width: 420, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
        let bg = Box(fill: dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.92, alpha: 1), border: nil, radius: 0)
        let cells = [("No problem", C_SUCCESS, "checkmark", false), ("Problem open", C_SUCCESS, "checkmark", true), ("Failed run and problem", C_FAILURE, "xmark", true)]
            .map { title, color, badge, mark -> NSView in
                let img = NSImageView(image: statusBadgedIcon(loadGHIcon(), color: color, badge: badge, problem: mark))
                img.imageScaling = .scaleProportionallyUpOrDown
                img.widthAnchor.constraint(equalToConstant: 72).isActive = true
                img.heightAnchor.constraint(equalToConstant: 72).isActive = true
                let v = NSStackView(v: [img, NSTextField.text(title, size: 11.5, color: Palette.mut)], spacing: 8)
                v.alignment = .centerX
                return v
            }
        let row = NSStackView(h: cells, spacing: 40)
        bg.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: bg.centerXAnchor), row.centerYAnchor.constraint(equalTo: bg.centerYAnchor)])
        g.contentView = bg
        g.orderFrontRegardless()
        return g
    }

    static func seedLocalCLI() {
        AI_CFG.engine = .localCLI
        AI_CFG.cliHarness = "claude"
        AI_CFG.cliModel = "claude-haiku-5-5"
        AI_CFG.cliEffort = "low"
        AI_CFG.enabled = true
        AI_CFG.cliVerified = AI_CFG.cliFingerprint
        let week = Date().addingTimeInterval(3 * 86400)
        let five = Date().addingTimeInterval(2 * 3600)
        let limits = Limits(plan: "max", windows: [LimitWindow(key: .fiveHour, minutes: 300, usedPercent: 18, resetsAt: five),
                                                   LimitWindow(key: .weekly, minutes: 10080, usedPercent: 41, resetsAt: week)])
        let bin = URL(fileURLWithPath: "/opt/homebrew/bin/x")
        LocalCLI.shared.seed([
            Detection(harness: .claude, path: bin, version: "2.3.1 (Claude Code)", supported: true, ready: true, auth: .ok, authDetail: "flarco@…"),
            Detection(harness: .codex, path: bin, version: "codex-cli 0.98.0", supported: true, ready: true, auth: .ok, authDetail: "ChatGPT Plus"),
            Detection(harness: .opencode, path: bin, version: "1.4.2", supported: true, ready: true, auth: .ok, authDetail: "2 providers"),
            Detection(harness: .gemini, path: bin, version: "0.21.0", supported: true, auth: .missing),
            Detection(harness: .cursor, detail: .notInstalled),
            Detection(harness: .copilot, detail: .notInstalled),
        ], plans: ["claude": limits, "codex": Limits(plan: "plus")],
           models: ["claude": [ModelInfo(id: "claude-haiku-5-5", name: "Haiku 5.5"), ModelInfo(id: "claude-sonnet-5-5", name: "Sonnet 5.5", isDefault: true)]],
           limits: limits)
    }
}


// MARK: Question card samples

extension UIShots {
    /// questions:open, questions:closed or questions:pauses: the question card in each state, in two columns.
    static func questionsSample(_ set: String) -> NSWindow {
        let now = Date()
        let ago = { (m: Double) in now.addingTimeInterval(-m * 60) }
        let account = AccountID(provider: .daemon, id: "mba")
        let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
        let item = { (k: String) in ItemRef(project: project, id: k, key: k, url: URL(string: "https://app.plane.so/ocral/browse/\(k)/")!) }
        let session = SessionRef(workspace: WorkspaceRef(account: account, id: "w1"), id: "term_1")
        let store = QuestionItem(id: "q1", header: "Store", text: "Where does the board keep the answered questions?",
                                 why: "Two stores exist. The cloud store is paid.", kind: .single,
                                 options: [.init(label: "Local JSON files", detail: "~/.config/oversire/store"), .init(label: "Cloud store")],
                                 allowsOther: true)
        let tests = QuestionItem(id: "q2", header: "Tests", text: "Which tests do you want for the card?", kind: .multi,
                                 options: [.init(label: "Unit"), .init(label: "uishots"), .init(label: "Live")])
        let free = QuestionItem(id: "q1", text: "What name do you want for the new setting?", kind: .free)
        let q = { (id: String, items: [QuestionItem], via: SessionQuestion.Via, at: Double, origin: SessionQuestion.Origin) in
            SessionQuestion(id: QuestionID(rawValue: "daemon:mba:\(id)"), session: session, origin: origin, items: items, via: via, askedAt: ago(at),
                            expiresAt: via == .permission ? now.addingTimeInterval(240) : nil)
        }
        let e = { (q: SessionQuestion, s: QuestionState) in QuestionBoard.Entry(question: q, state: s, firstSeen: q.askedAt) }
        let here = QuestionPlace(runtime: "OverSire daemon", host: "this Mac")
        let remote = QuestionPlace(runtime: "OverSire daemon", host: "remote: studio", local: false)
        let runner = QuestionPlace(runtime: "OverSire runner", host: "mba", local: false)
        let work = SessionQuestion.Origin.work(item("OVERSIRE-186"))
        let answer = QuestionAnswer(question: "daemon:mba:m1", items: [.init(id: "q1", choices: ["Local JSON files"]), .init(id: "q2", choices: ["Unit", "uishots"])])
        var acts = QuestionCard.Actions()
        acts.reveal = {}
        let cards: [[(QuestionBoard.Entry, QuestionPlace, QuestionCard.Actions, ((QuestionCard) -> Void)?)]]
        let bash = QuestionItem(id: "q1", header: "Bash", text: "git push origin oversire-237", why: "Do you want to proceed?", kind: .single,
                                options: ["Yes", "Yes, and don’t ask again for: git push *", "No"].map { .init(label: $0) }, allowsOther: true)
        let plan = QuestionItem(id: "q1", header: "Plan", text: "Append \"world\" to notes.md",
                                why: "Claude has written up a plan and is ready to execute. Would you like to proceed?", kind: .single,
                                options: ["Yes, and use auto mode", "Yes, manually approve edits", "Tell Claude what to change"].map { .init(label: $0) },
                                allowsOther: true)
        let turn = QuestionItem(id: "q1", text: "Do you want me to add a third line?",
                                why: "The file notes.md has two lines: hello and world.\n\nDo you want me to add a third line?", kind: .free)
        let wait = QuestionItem(id: "q1", text: "The session waits for you. OverSire cannot read the prompt.", kind: .free)
        let review = QuestionItem(id: "review", header: "Review", text: "Ready to submit your answers?",
                                  why: "Which store? → JSON\nWhich tests? → Unit, perf", kind: .single,
                                  options: [.init(label: "Submit answers"), .init(label: "Cancel")])
        let pause = { (id: String, item: QuestionItem, at: Double) in
            e(SessionQuestion(id: QuestionID(rawValue: "daemon:mba:form:\(id)"), session: session, origin: work, items: [item], via: .permission,
                              askedAt: ago(at)), .open)
        }
        if set == "pauses" {
            cards = [
                [(pause("t1", bash, 1), here, acts, nil), (pause("t2", plan, 2), here, acts, nil)],
                [(e(SessionQuestion(id: "daemon:mba:turn:term_1:1", session: session, origin: work, items: [turn], via: .turn, askedAt: ago(3)), .open),
                  here, acts, nil),
                 (e(SessionQuestion(id: "daemon:mba:wait:term_1:1", session: session, origin: work, items: [wait], via: .waiting, askedAt: ago(5)), .open),
                  here, acts, nil),
                 (e(SessionQuestion(id: "daemon:mbp:form:term_1:1", session: session, origin: work, items: [review], via: .form, askedAt: ago(6)), .open),
                  here, acts, nil)],
            ]
        } else if set == "closed" {
            let two = q("m1", [store, tests], .askReply, 6, work)
            cards = [
                [(e(two, .answeredHere(answer, at: ago(1))), here, acts, nil),
                 (e(two, .answeredElsewhere(answer, at: ago(2))), here, acts, nil),
                 (e(two, .answeredElsewhere(nil, at: ago(2))), remote, acts, nil)],
                [(e(two, .raced(at: ago(1))), here, acts, nil),
                 (e(two, .gone(at: ago(3))), here, acts, nil),
                 (e(q("p1", [.approve(id: "q1", header: "Bash", text: "npm test")], .permission, 1, .work(item("TOWERTAIL-2"))), .open), runner, acts, nil),
                 (e(two, .answeredHere(answer, at: ago(1))), QuestionPlace(runtime: "OverSire runner", host: "mba", local: false, offline: true), acts, nil)],
            ]
        } else {
            var enhance = acts
            enhance.stop = {}
            var failed = e(q("m4", [free], .runnerInput, 3, work), .open)
            failed.error = "the runner is offline"
            cards = [
                [(e(q("m1", [store, tests], .askReply, 4, work), .open), here, acts, { c in c.pick(0, of: "q1"); c.pick(1, of: "q2") }),
                 (e(q("m2", [free], .askReply, 2, work), .sending), here, acts, { c in c.write("Ask about questions", in: "q1") }),
                 (failed, runner, acts, nil)],
                [(e(q("f1", [store, tests], .form, 52, work), .open), here, acts, nil),
                 (e(SessionQuestion(id: "daemon:studio:m5", session: session, origin: .intake(item("TREBI-471")), round: 2, items: [tests], via: .askReply,
                                    askedAt: ago(1)), .open), remote, enhance, nil)],
            ]
        }
        let columns = cards.map { col -> NSView in
            let v = NSStackView(v: [], spacing: 14)
            for (entry, place, actions, prep) in col {
                let c = QuestionCard(entry, place: place, checkedAt: now.addingTimeInterval(-8), now: { now }, actions: actions)
                prep?(c)
                v.addFull(c)
            }
            v.widthAnchor.constraint(equalToConstant: 600).isActive = true
            // The shorter column takes the free height here, not in a card.
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            v.addArrangedSubview(fill)
            return v
        }
        let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Question card"
        let page = PageScroll(maxWidth: 1280)
        let root = Box(fill: Palette.bg, border: nil, radius: 0)
        root.addSubview(page)
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: root.leadingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     page.topAnchor.constraint(equalTo: root.topAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        w.contentView = root
        page.rebuild { col in col.addArrangedSubview(NSStackView(h: columns, spacing: 20, align: .top)) }
        w.orderFrontRegardless()
        return w
    }
}

// MARK: Machines samples

extension MachinesSnapshot {
    static let scenes: Set<String> = ["machines-empty", "machines-found", "machines-group", "join-waiting", "approve-dialog", "add-machine"]

    /// mbp is this Mac. mba and devbox are members, or found on the tailnet when this Mac is alone.
    static func sample(_ scene: String, now: Date = Date()) -> MachinesSnapshot {
        var s = MachinesSnapshot()
        s.installed = scene != "machines-empty"
        s.onPath = scene != "machines-found"
        s.latest = scene == "machines-found" ? "0.5.0" : "0.4.0"
        guard scene != "machines-empty" else { return s }
        func info(_ m: MachineName, _ ip: String, roles: [String]) -> DaemonInfo {
            DaemonInfo(machine: m, version: "0.4.0", contract: 1, roles: roles, runtimes: ["orca"], harnesses: [],
                       listen: .init(loopback: "127.0.0.1:7690", tailscale: ip + ":7690"))
        }
        func member(_ m: MachineName, _ ip: String, roles: [String], seen: TimeInterval, version: String = "0.4.0") -> GroupMember {
            GroupMember(machine: m, host: m.rawValue, addrs: [ip], port: 7690, roles: roles, joinedAt: now.addingTimeInterval(-86400 * 9),
                        lastSeen: now.addingTimeInterval(-seen), version: version)
        }
        s.info = info("mbp", "100.97.81.23", roles: ["serve", "runner"])
        s.hooks = [HarnessHooks(name: "claude", hooks: .installed), HarnessHooks(name: "codex", hooks: .untrusted),
                   HarnessHooks(name: "opencode", hooks: .missing)]
        func session(_ n: Int, _ state: DaemonSession.State, on m: MachineName) -> DaemonSession {
            DaemonSession(id: "s-\(m)-\(n)", machine: m, runtime: "orca", harness: "claude", cwd: "/src", state: state,
                          stateSince: now, updatedAt: now, sources: ["hook"])
        }
        s.sessions["mbp"] = [session(1, .working, on: "mbp"), session(2, .working, on: "mbp"), session(3, .waiting, on: "mbp")]
        if scene == "machines-found" || scene == "join-waiting" {
            s.group = Group(id: "g-mbp", name: "My machines", home: "mbp", version: 1,
                            members: [member("mbp", "100.97.81.23", roles: ["serve", "runner"], seen: 0)], devices: [])
            s.peers = [info("mba", "100.71.4.12", roles: ["serve"]), info("devbox", "100.88.20.3", roles: ["serve", "runner"])]
            return s
        }
        s.group = Group(id: "g-mbp", name: "My machines", home: "mbp", version: 4,
                        members: [member("mbp", "100.97.81.23", roles: ["serve", "runner"], seen: 0),
                                  member("mba", "100.71.4.12", roles: ["serve"], seen: 20, version: "0.3.2"),
                                  member("devbox", "100.88.20.3", roles: ["serve", "runner"], seen: 7300)], devices: [])
        s.health = ["mba": .live, "devbox": .failed("no answer")]
        s.latest = "0.4.1"
        s.info?.update = DaemonUpdate(checkedAt: now.addingTimeInterval(-7200), latest: "0.4.1",
                                      error: "update: no write access to /usr/local/bin. Give your user write access to it, or remove /usr/local/bin/oversire and install the CLI again from the OverSire app")
        s.sessions["mba"] = []
        return s
    }
}

extension UIShots {
    /// Settings › Machines with sample data, and its dialogs.
    static func machines(_ scene: String, in w: AppWindow) {
        let c = MachinesController.shared
        c.frozen = true
        c.config = { MachinesConfig(sessions: "mbp", hooksConsent: true) }
        c.installed = { scene != "machines-empty" }
        c.use(MachinesSnapshot.sample(scene))
        w.router.go(.settings(.general))   // a fresh page, so the pane takes the new height
        w.router.go(.settings(.machines))
        let now = Date()
        let r = JoinRequestFrame(request: "r-1", machine: "mba", host: "100.71.4.12", confirm: "4821", expiresAt: now.addingTimeInterval(292))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                switch scene {
                case "join-waiting":
                    MachineSheets.waiting(over: w.window, phase: .waiting(confirm: "4821", host: "mbp"), expires: now.addingTimeInterval(292)) {}
                case "approve-dialog":
                    MachineSheets.approve(r, group: "My machines", over: w.window) { _ in }
                case "add-machine":
                    MachineSheets.add(over: w.window, invite: GroupInvite(code: "K7Q2-M9XD", via: "mbp", expiresAt: now.addingTimeInterval(581)))
                default: break
                }
            }
        }
    }
}

// MARK: Assistant samples

/// A chat engine for the shots. A script belongs to one user text and has one step list for each turn.
final class ShotChatEngine: ChatEngine, @unchecked Sendable {
    enum Step {
        case event(ChatEvent)
        case wait(Double)
        case fail(AIError)
    }

    let id: EngineID
    private let lock = NSLock()
    private var scripts: [String: [[Step]]] = [:]
    private var turns: [String: Int] = [:]

    init(id: EngineID) { self.id = id }

    func script(_ user: String, _ turns: [[Step]]) { lock.withLock { scripts[user] = turns } }

    func available() async -> Bool { true }

    func turn(_ r: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let user = r.messages.last { $0.role == .user }?.parts.compactMap { p -> String? in
            if case .text(let t) = p { return t }
            return nil
        }.joined() ?? ""
        let steps: [Step] = lock.withLock {
            let key = r.thread + "|" + user
            let n = turns[key, default: 0]
            turns[key] = n + 1
            guard let list = scripts[user], n < list.count else { return [.event(.textDelta("Done.")), .event(.end(.done))] }
            return list[n]
        }
        return AsyncThrowingStream { out in
            let task = Task {
                for s in steps {
                    switch s {
                    case .event(let e): out.yield(e)
                    case .wait(let d): try? await Task.sleep(for: .seconds(d))
                    case .fail(let e): out.finish(throwing: e); return
                    }
                }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}

extension UIShots {
    static let assistantPrompts = [
        "working": "Why is the CI of #212 red, and is OVERSIRE-141 stuck?",
        "nav": "Show me the session of FRITZ-17.",
        "approve": "Merge #212 when CI is green.",
        "machines": "What does the agent on studio-mini do now?",
        "problems": "Rerun the Linux tests of SLING-88 on studio-mini.",
    ]

    func makeAssistant() -> AssistantController? {
        let dir = URL(fileURLWithPath: UIShots.tmp + "/assistant")
        try? FileManager.default.removeItem(at: dir)
        let store = ThreadStore(store: LocalStore(dir: dir.appendingPathComponent("store")), blobDir: dir.appendingPathComponent("blobs"))
        let cli = ShotChatEngine(id: .localCLI)
        let key = ShotChatEngine(id: .apiKey)
        Self.script(cli, key)
        let loop = AssistantLoop(router: ChatRouter(engines: [cli, key]), catalog: ActionList(Self.shotActions()),
                                 policy: RuleConfirmPolicy(), store: store, system: { _, _ in "You are the OverSire assistant." })
        return MainActor.assumeIsolated {
            AssistantController(loop: loop, engines: [AssistantEngine(id: .localCLI, label: "Claude Code · this Mac"),
                                                      AssistantEngine(id: .apiKey, label: "API key · Anthropic")],
                                page: { [weak self] in self?.window?.pageContext })
        }
    }

    private static func shotActions() -> [ActionSpec] {
        func spec(_ id: String, _ title: String, _ kind: ActionKind, _ perform: @escaping @Sendable (ActionArgs) async -> ActionResult) -> ActionSpec {
            ActionSpec(id: id, title: title, help: title, kind: kind, perform: perform)
        }
        return [
            spec("item.context", "Read the item", .read) { a in .ok(summary: "\(a.string("key") ?? "Item") · In progress · 3 comments") },
            spec("pr.status", "Read the PR", .read) { _ in .ok(summary: "#212 · CI green · 2 approvals") },
            spec("run.log", "Read the CI log", .read) { _ in .ok(summary: "swift test failed: 2 tests in RouterTests") },
            spec("session.tail", "Read the session", .read) { a in
                if a.string("machine") == "studio-mini" { return .ok(summary: "SLING-88 · Claude Code · runs the tests") }
                try? await Task.sleep(for: .seconds(600))
                return .ok(summary: "The agent runs swift test again")
            },
            spec("machine.sessions", "List the sessions", .read) { a in .ok(summary: "\(a.string("machine") ?? "This Mac") · 2 sessions") },
            spec("machine.status", "Read the machine", .read) { a in .failed("\(a.string("machine") ?? "The Mac") does not answer.") },
            spec("queue.list", "Read the queue", .read) { _ in .ok(summary: "4 items wait") },
            spec("pr.merge", "Merge the PR", .outward) { _ in .ok(summary: "#212 is merged") },
            spec("ui.show", "Show a page", .read) { a in
                let route = a.string("route") ?? "home"
                return .ok(summary: "Shows \(route)", parts: [.navigation(route: route, focus: nil, from: "home")])
            },
        ]
    }

    private static func script(_ cli: ShotChatEngine, _ key: ShotChatEngine) {
        typealias S = ShotChatEngine.Step
        func call(_ id: String, _ tool: String, _ args: [String: JSONValue] = [:]) -> S { .event(.toolCall(ToolCall(id: id, tool: tool, args: .object(args)))) }
        func text(_ t: String) -> S { .event(.textDelta(t)) }
        let end: S = .event(.end(.done))
        let usage: S = .event(.usage(AIUsage(input: 4200, output: 380)))
        let p = assistantPrompts
        cli.script(p["working"]!, [[
            .event(.thoughtDelta("The user asks two things. First I read the PR and its failed run. Then I look at the session of the item.", signature: nil)),
            text("I read the PR, the failed run and the session."),
            call("w1", "item_context", ["key": .string("OVERSIRE-141")]),
            call("w2", "pr_status", ["number": .int(212)]),
            call("w3", "run_log", ["run": .string("9123")]),
            call("w4", "session_tail", ["key": .string("OVERSIRE-141")]),
            call("w5", "queue_list"),
            usage, end,
        ]])
        cli.script(p["nav"]!, [
            [call("n1", "ui_show", ["route": .string("item/FRITZ-17/session")]), usage, end],
            [text("This is the session of **FRITZ-17**. The agent waits for your answer about the test plan.\n\nReplies: Answer it | Open the terminal"), usage, end],
        ])
        cli.script(p["approve"]!, [
            [call("a1", "pr_status", ["number": .int(212)]), usage, end],
            [text("CI is green and #212 has 2 approvals. I merge it with a squash."),
             call("a2", "pr_merge", ["number": .int(212), "method": .string("squash")]), usage, end],
        ])
        cli.script(p["machines"]!, [
            [call("m1", "machine_sessions", ["machine": .string("studio-mini")]),
             call("m2", "session_tail", ["machine": .string("studio-mini")]), usage, end],
            [text("On **studio-mini**, Claude Code works on SLING-88. It runs the Linux tests again after a fix in the parser.\n\n"
                  + "- Started 12 min ago\n- 3 of 5 steps done\n\nReplies: Show the session | Ask it for a status"), usage, end],
        ])
        cli.script(p["problems"]!, [[.fail(.unavailable("Claude Code reached its usage limit."))]])
        key.script(p["problems"]!, [
            [text("First I check that studio-mini is on."),
             call("p1", "machine_status", ["machine": .string("studio-mini")]), usage, end],
            [.event(.error(code: "offline", message: "studio-mini does not answer.")), end],
        ])
    }

    /// assistant:<state>: closed, setup, new, attach, working, nav, approve, machines, chats, problems.
    func assistantState(_ state: String, in w: AppWindow) {
        assistantOff = state == "setup"
        if let p = w.assistantPanel, (p.controller == nil) != assistantOff { w.resetAssistant() }
        if state == "closed" { w.hideAssistant(); return }
        if w.router.current != .home { w.router.go(.home) }
        w.showAssistant()
        guard let p = w.assistantPanel, let c = p.controller else { return }
        MainActor.assumeIsolated { if c.isRunning { c.stop() } }
        p.composer.clear()
        p.composer.showDrop(false)
        p.newChat()
        switch state {
        case "new":
            break
        case "attach":
            p.composer.textView.string = "The page is blank after the sign-in. Compare it with the log."
            p.composer.add(AssistantAttachment(kind: .image(Self.sampleImage())))
            p.composer.add(AssistantAttachment(kind: .file(name: "callback.log", data: Data(repeating: 65, count: 18_400))))
            if let found = projectStore.item(key: "FRITZ-17"), let ref = found.item.ref(in: found.snap.summary.ref) {
                p.composer.add(AssistantAttachment(kind: .mention(.item(ref), key: ref.key)))
            }
            p.composer.showDrop(true)
        case "chats":
            let store = c.loop.store
            Task { @MainActor in
                for t in Self.sampleThreads() { try? await store.save(t) }
                p.showChats(true)
            }
        default:
            guard let text = Self.assistantPrompts[state] else { print("UISHOTS bad assistant state \(state)"); return }
            p.composer.textView.string = text
            p.composer.submit()
        }
    }

    private static func sampleThreads() -> [AssistantThread] {
        let now = Date()
        let day: TimeInterval = 86_400
        let plane = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "SLING")
        let item = ItemRef(project: plane, id: "i88", key: "SLING-88", url: URL(string: "https://plane.so/ocral/SLING-88")!)
        return [
            AssistantThread(title: "Release checklist for v1.4", createdAt: now - 6 * day, updatedAt: now - 2 * day, engine: .localCLI, pinned: true),
            AssistantThread(title: "Why do the Linux tests of SLING-88 fail?", createdAt: now - day - 3600, updatedAt: now - day,
                            engine: .localCLI, subjects: [.item(item)], machines: ["studio-mini"]),
            AssistantThread(title: "Sort the intake of this week", createdAt: now - day - 7200, updatedAt: now - day - 5000, engine: .apiKey),
            AssistantThread(title: "Plan the cloud relay work", createdAt: now - 9 * day, updatedAt: now - 8 * day, engine: .localCLI),
        ]
    }

    /// A small screenshot for the image chip.
    private static func sampleImage() -> Data {
        let img = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { r in
            NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1).setFill()
            r.fill()
            NSColor(srgbRed: 0.34, green: 0.71, blue: 0.91, alpha: 1).setFill()
            NSRect(x: 0, y: 170, width: 320, height: 30).fill()
            NSColor(srgbRed: 0.8, green: 0.8, blue: 0.84, alpha: 1).setFill()
            for i in 0..<4 { NSRect(x: 24, y: 120 - CGFloat(i) * 26, width: CGFloat(220 - i * 30), height: 12).fill() }
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

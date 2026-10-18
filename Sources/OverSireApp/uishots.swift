import Cocoa
import OverSireCore
import OverSireSync

// `oversire --uishots <dir> [path …]` opens the window with real data, read only, and saves
// one PNG per route and theme. It sends no global input, so it is safe while someone uses the Mac.
// Plane state is a copy; re-run, write-back and agent starts do nothing here.
final class UIShots: NSObject, AppData, NSApplicationDelegate {
    var grouped: [(String, [Run])] = []
    var prGrouped: [(String, [ChangeRequest])] = []
    var lastUpdate = Date()
    var firstLoad = true
    let projectStore: ProjectStore
    let writes = StoreWrites(store: LocalStore(dir: URL(fileURLWithPath: NSTemporaryDirectory() + "oversire-uishots/store")))
    lazy var agentIndex = AgentIndex(writes: writes)
    let workstreams = WorkstreamIndex()
    lazy var queue = WorkQueue(writes: writes, store: projectStore, agents: agentIndex)
    lazy var memory = ProjectMemory(writes: writes)
    lazy var areas = ItemAreaBook(writes: writes)
    lazy var suggestions = SuggestionBook(writes: writes)
    lazy var planner = PlannerBook(writes: writes)
    lazy var intakeAgent = IntakeAgent(store: projectStore, writeBack: PlaneWriteBack(path: NSTemporaryDirectory() + "oversire-uishots/wb.json",
                                                                                       store: projectStore, trackers: ENV), memory: memory)
    lazy var sessions = SessionNotes(path: NSTemporaryDirectory() + "oversire-uishots/sessions.json", agents: agentIndex, store: projectStore,
                                     writeBack: PlaneWriteBack(path: NSTemporaryDirectory() + "oversire-uishots/wb.json", store: projectStore, trackers: ENV))
    let busy = BusyTracker()
    lazy var ciAssist = CIAssist(path: NSTemporaryDirectory() + "oversire-uishots/ci.json")
    lazy var aiChecks = AgentJudge(path: NSTemporaryDirectory() + "oversire-uishots/checks.json", agents: agentIndex, queue: queue)
    let relay = LiveSync(secrets: SecretStore(service: "com.oversire.app.cloud"), cursors: CursorStore(url: nil))
    private let dir: String
    struct FixturePR: Decodable { let repo: String; let mine: Bool; let pr: ChangeRequest }

    func settingsVC(_ p: Route.SettingsPage) -> NSViewController? {
        switch p {
        case .general: return GeneralSettingsVC(catalog: RepoCatalog(path: REPO_CACHE_PATH), updater: Updater())
        case .repos: return ActionsSettingsVC(catalog: RepoCatalog(path: REPO_CACHE_PATH), picked: Set(PICKED_REPOS), orgs: Set(PICKED_ORGS))
        case .projects:
            return ProjectSettingsVC(catalog: ProjectCatalog(trackers: ENV, path: NSTemporaryDirectory() + "oversire-uishots/catalog.json"), store: projectStore, cfg: PROJECTS_CFG)
        case .ai: return AISettingsVC()
        case .live: return CloudSettingsVC(setup: CloudSetup(), client: relay)
        default: return nil
        }
    }
    private let paths: [String]
    private var window: AppWindow?
    private var glance: NSWindow?

    init(dir: String, paths: [String]) {
        self.dir = dir
        self.paths = paths
        let tmp = NSTemporaryDirectory() + "oversire-uishots"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        for (src, name) in [(PROJECT_STATE_PATH, "state.json"), (PROJECT_ACTIVITY_PATH, "activity.jsonl"),
                            (QUEUE_PATH, "queue.json"), (CHECKS_PATH, "checks.json")] {
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

    // OVERSIRE_UISHOTS_LOADING=1: no fetch ever ends, so each page shows its loading state.
    static let loading = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_LOADING"] == "1"
    // OVERSIRE_UISHOTS_CLOUD=0 or 1: the Cloud AI sections show without or with a cloud account.
    static let cloud = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_CLOUD"].map { $0 == "1" }
    // OVERSIRE_UISHOTS_COMMANDS=1: Settings › Runtime shows one custom start command and one bad draft.
    static let commands = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_COMMANDS"] == "1"
    // OVERSIRE_UISHOTS_PLANNER=1: a vision, relations, areas, a queue lane and a plan change in the OVERSIRE project.
    static let planner = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_PLANNER"] == "1"

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
                        let wb = PlaneWriteBack(path: NSTemporaryDirectory() + "oversire-uishots/wb-live.json", store: self.projectStore, trackers: ENV)
                        wb.onError = { print("UISHOTS writeback error \($0)") }
                        wb.sync(keys.compactMap { self.workstreams.streams[$0] })
                    }
                    NotificationCenter.default.post(name: AppWindow.changed, object: self)
                }
                NotificationCenter.default.post(name: AppWindow.changed, object: self)
                completion?()
            }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        loadConfig()
        if let fx = ProcessInfo.processInfo.environment["OVERSIRE_UISHOTS_FIXTURES"], FileManager.default.fileExists(atPath: fx + "/ci.json") {
            AI_CFG.digest = true
        }
        REPOS = RepoCatalog(path: REPO_CACHE_PATH).resolve(picked: PICKED_REPOS, orgs: PICKED_ORGS)
        assignRepoColors(REPOS)
        let catalog = ProjectCatalog(trackers: ENV, path: PROJECT_CACHE_PATH)
        projectStore.track(catalog.resolve(PROJECTS_CFG), live: [])
        if UIShots.commands {
            PROJECTS_CFG.runtime.commands = ["claude": "claude -n {name} --dangerously-skip-permissions"]
            AgentCommandsCard.drafts = ["codex": "codex --full-auto; echo done"]
        }
        agentIndex.poll()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        refresh(force: true) { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.shoot() } }
    }

    private func shoot() {
        seedPlanner()
        let w = AppWindow(data: self)
        window = w
        w.window?.setFrameAutosaveName("")
        let env = ProcessInfo.processInfo.environment
        let width = env["OVERSIRE_UISHOTS_WIDTH"].flatMap(Double.init) ?? 1280
        w.window?.setFrame(NSRect(x: 40, y: 40, width: width, height: 860), display: true)
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
                        if let root = (self.glance ?? PlanPage.openSheet ?? w.window)?.contentView, !UIShots.press(spec[0], scope: spec.count > 1 ? spec[1] : nil, in: root) {
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
                    } else if p.hasPrefix("palette:") {
                        CommandPalette.show(over: w, query: String(p.dropFirst("palette:".count)))
                    } else if let r = Route(path: p) {
                        w.router.go(r)
                    } else {
                        print("UISHOTS bad path \(p)")
                    }
                }
                steps.append { self.capture(w, name: "\(theme.rawValue)-" + p.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")) }
                steps.append { CommandPalette.dismiss(); ExplainPopover.dismiss() }
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
        guard let b = find(base, { ($0 as? NSButton)?.title.hasPrefix(title) == true }) as? NSButton else { return false }
        if let a = b as? ActionButton, let run = a.onClick { run() } else { b.performClick(nil) }
        return true
    }

    private func capture(_ w: AppWindow, name: String) {
        guard let num = w.window?.windowNumber else { return }
        let out = (dir as NSString).appendingPathComponent(name + ".png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(glance?.windowNumber ?? PlanPage.windowNumber ?? CommandPalette.windowNumber ?? ExplainPopover.windowNumber ?? num)", out]
        try? p.run()
        p.waitUntilExit()
        print("UISHOTS \(out) sidebar=\(Int(w.sidebar.view.frame.width)) page=\(Int(w.page?.view.frame.width ?? 0))")
    }
}

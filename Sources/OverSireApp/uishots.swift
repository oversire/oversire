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
    lazy var intakeAgent = IntakeAgent(store: projectStore, writeBack: PlaneWriteBack(path: NSTemporaryDirectory() + "oversire-uishots/wb.json",
                                                                                       store: projectStore, accounts: PlaneAccounts()))
    lazy var sessions = SessionNotes(path: NSTemporaryDirectory() + "oversire-uishots/sessions.json", agents: agentIndex, store: projectStore,
                                     writeBack: PlaneWriteBack(path: NSTemporaryDirectory() + "oversire-uishots/wb.json", store: projectStore, accounts: PlaneAccounts()))
    lazy var ciAssist = CIAssist(path: NSTemporaryDirectory() + "oversire-uishots/ci.json")
    lazy var aiChecks = AgentJudge(path: NSTemporaryDirectory() + "oversire-uishots/checks.json", agents: agentIndex, queue: queue)
    let relay = RelayClient(secrets: SecretStore(service: "com.oversire.app.cloud"))
    private let dir: String
    struct FixturePR: Decodable { let repo: String; let mine: Bool; let pr: ChangeRequest }

    func settingsVC(_ p: Route.SettingsPage) -> NSViewController? {
        switch p {
        case .general: return GeneralSettingsVC(catalog: RepoCatalog(path: REPO_CACHE_PATH), updater: Updater())
        case .repos: return ActionsSettingsVC(catalog: RepoCatalog(path: REPO_CACHE_PATH), picked: Set(PICKED_REPOS), orgs: Set(PICKED_ORGS))
        case .accounts:
            let acc = PlaneAccounts()
            return ProjectSettingsVC(catalog: ProjectCatalog(accounts: acc, path: NSTemporaryDirectory() + "oversire-uishots/catalog.json"), store: projectStore, accounts: acc, cfg: PROJECTS_CFG)
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
        projectStore = ProjectStore(accounts: PlaneAccounts(), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                    statePath: tmp + "/state.json", activityPath: tmp + "/activity.jsonl")
        super.init()
    }

    func rerun(repo: String, runs: [Run], failedOnly: Bool) { log.info("uishots: re-run skipped") }

    func refresh(force: Bool, completion: (() -> Void)?) {
        let repos = REPOS
        DispatchQueue.global().async {
            var runs = [(String, [Run])](repeating: ("", []), count: repos.count)
            var prs = [(String, [ChangeRequest])](repeating: ("", []), count: repos.count)
            DispatchQueue.concurrentPerform(iterations: repos.count) { i in
                runs[i] = (repos[i], fetchRuns(repo: repos[i]) ?? [])
                prs[i] = (repos[i], fetchPRs(repo: repos[i]))
            }
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
                        let wb = PlaneWriteBack(path: NSTemporaryDirectory() + "oversire-uishots/wb-live.json", store: self.projectStore, accounts: PlaneAccounts())
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
        let catalog = ProjectCatalog(accounts: PlaneAccounts(), path: PROJECT_CACHE_PATH)
        projectStore.track(catalog.resolve(PROJECTS_CFG), live: [])
        agentIndex.poll()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        refresh(force: true) { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.shoot() } }
    }

    private func shoot() {
        let w = AppWindow(data: self)
        window = w
        w.window?.setFrameAutosaveName("")
        w.window?.setFrame(NSRect(x: 40, y: 40, width: 1280, height: 860), display: true)
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
                        if let root = (self.glance ?? w.window)?.contentView, !UIShots.press(spec[0], scope: spec.count > 1 ? spec[1] : nil, in: root) {
                            print("UISHOTS no button \(p)")
                        }
                    } else if p.hasPrefix("sidebar:") {
                        if !w.sidebar.reopen(title: String(p.dropFirst(8))) { print("UISHOTS no sidebar entry \(p)") }
                    } else if p.hasPrefix("toggle:") {
                        let name = String(p.dropFirst(7))
                        if let root = w.window?.contentView, let sw = UIShots.find(root, { ($0 as? NSSwitch)?.accessibilityLabel() == name }) as? NSSwitch {
                            sw.performClick(nil)
                        } else { print("UISHOTS no switch \(p)") }
                    } else if p == "end" {
                        w.page?.scroll.toEnd()
                    } else if p.hasPrefix("glance:") {
                        GlanceVC.tab = GlanceVC.Tab.allCases.first { $0.title.lowercased() == p.dropFirst(7) } ?? .now
                        let g = NSWindow(contentRect: NSRect(origin: NSPoint(x: 1360, y: 200), size: GlanceVC.size), styleMask: [.borderless], backing: .buffered, defer: false)
                        g.contentViewController = GlanceVC(data: self) { print("UISHOTS glance open \($0.path)"); w.router.go($0) }
                        g.orderFrontRegardless()
                        self.glance = g
                    } else if p.hasPrefix("palette:") {
                        CommandPalette.show(over: w, query: String(p.dropFirst("palette:".count)))
                    } else if let r = Route(path: p) {
                        w.router.go(r)
                    } else {
                        print("UISHOTS bad path \(p)")
                    }
                }
                steps.append { self.capture(w, name: "\(theme.rawValue)-" + p.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "-")) }
                steps.append { CommandPalette.dismiss() }
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
        p.arguments = ["-x", "-o", "-l", "\(glance?.windowNumber ?? CommandPalette.windowNumber ?? num)", out]
        try? p.run()
        p.waitUntilExit()
        print("UISHOTS \(out)")
    }
}

import Cocoa
import OverSireCore
import QuartzCore
import UserNotifications
import os
import GitHubKit
import OverSireSync

let POP_W: CGFloat = 660
// macOS cuts off the top of a popover that is taller than the space below the menu bar.
var POP_MAX_H: CGFloat { min(700, (NSScreen.main?.visibleFrame.height ?? 740) - 40) }
let ROW_H: CGFloat = 56
let HDR_H: CGFloat = 32
let FTR_H: CGFloat = 40
let PAD: CGFloat = 12
let ICON_SZ: CGFloat = 20
let TEXT_X: CGFloat = 42     // PAD + ICON_SZ + 10

// ─── App ─────────────────────────────────────────────────────────────────────

class GHActionsBar: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate, AppData {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var isPulsing = false
    var iconKey: MenuIconState?
    var refreshInFlight = false { didSet { trackRefresh() } }
    private var refreshToken: BusyTracker.Token?
    var pendingCompletion: (() -> Void)?
    var lastPRRefresh = Date.distantPast
    var grouped: [(String, [Run])] = []
    var prGrouped: [(String, [ChangeRequest])] = []
    let bus = ChangeBus.shared
    // The runs and PRs of the last post. A refresh posts only the repos that differ.
    private var postedRuns: [(String, [Run])] = []
    private var postedPRs: [(String, [ChangeRequest])] = []
    var lastFetch = Date()
    /// A poll with no change also means the data is current.
    var lastUpdate: Date { max(lastFetch, relay.lastPoll ?? .distantPast) }
    var closeTime = Date.distantPast
    var firstLoad = true
    var ghIcon: NSImage?
    var prevStatuses: [String: String] = [:]
    var selectedTab: Tab = .actions
    var selectedRepo: String? = nil
    var selectedProject: String?
    var projectView: ProjectView = .board
    var projectAssignedOnly = false
    var projectUnreadOnly = false
    var expandedItem: String?
    var projectStatusFilter: [String: String] = [:]
    var projectShowAll: Set<String> = []
    var projectQuery = ""
    var lastSyncedWorkspaces: [String] = []
    var appearanceObs: NSKeyValueObservation?
    let cloudSetup = CloudSetup()
    let catalog = RepoCatalog(path: REPO_CACHE_PATH)
    var repoCatalog: RepoCatalog { catalog }
    lazy var projectCatalog = ProjectCatalog(trackers: ENV, path: PROJECT_CACHE_PATH)
    lazy var projectNotifier: ProjectNotifier = {
        ProjectNotifier(post: { [weak self] title, subtitle, body, id in
            self?.notify(title: title, subtitle: subtitle, body: body, id: id)
        })
    }()
    lazy var projectStore: ProjectStore = {
        let s = ProjectStore(trackers: ENV, notifier: projectNotifier,
                             statePath: PROJECT_STATE_PATH, activityPath: PROJECT_ACTIVITY_PATH)
        s.relayIsLive = { [weak self] in self?.relay.state == .live }
        s.busy = busy
        s.onChange = { [weak self] c in
            self?.updateIcon()
            self?.reloadList(c)
        }
        return s
    }()
    lazy var agentIndex: AgentIndex = {
        let a = AgentIndex(writes: STORE_WRITES)
        a.visible = { [weak self] in (self?.popover.isShown ?? false) || ItemWindow.isOpen }
        a.onAlert = { [weak self] key, agent in self?.agentAlert(key, agent) }
        a.open = { [weak self] k in self.map { $0.projectStore.item(key: k) != nil && !$0.projectStore.isDone(key: k) } ?? false }
        a.tracked = { [weak self] k in self?.projectStore.item(key: k) != nil }
        return a
    }()
    lazy var machineHub: MachineHub = {
        let h = MachineHub()
        h.onLinks = { [weak self] in
            self?.relay.update()
            self?.startQuestions()
            self?.agentIndex.poll()
        }
        h.onSessions = { [weak self] account in
            self?.agentIndex.hint(account: account)
            self?.questions.board?.poke()
        }
        return h
    }()
    var catalogTimer: Timer?
    var captureHotKey: GlobalHotKey?
    var windowHotKey: GlobalHotKey?
    var assistantHotKey: GlobalHotKey?
    lazy var snap = SnapController(projects: { [weak self] in self?.projectStore.tracked ?? [] })
    lazy var newSession = NewSessionController(projects: { [weak self] in self?.projectStore.tracked ?? [] },
                                               states: { [weak self] k in self?.projectStore.snapshots[k]?.statusOptions ?? [] })
    let workstreams = WorkstreamIndex()
    let cleaner = Cleaner()
    lazy var queue = WorkQueue(writes: STORE_WRITES, store: projectStore, agents: agentIndex)
    lazy var actions = AppActionCatalog(data: self)
    var pages: AppWindow? { appWindow }
    lazy var assistantRoot = AssistantRoot(app: self)
    /// Nil: the panel links to Settings › AI.
    var assistant: AssistantController? { assistantRoot.controller }
    lazy var memory = ProjectMemory(writes: STORE_WRITES)
    lazy var areas = ItemAreaBook(writes: STORE_WRITES)
    lazy var suggestions = SuggestionBook(writes: STORE_WRITES)
    var logs: LogStore?
    private var orderLog: WorkOrderLog?
    lazy var planner = PlannerBook(writes: STORE_WRITES)
    lazy var plannerSignals = PlannerSignals(commands: ProcessRunner(), writes: STORE_WRITES)
    var signalTimer: Timer?
    lazy var statusJob = StatusJob(path: STATUS_PATH, agents: agentIndex, queue: queue)
    lazy var writeBack: PlaneWriteBack = {
        let w = PlaneWriteBack(path: WRITEBACK_PATH, store: projectStore, trackers: ENV)
        w.onError = { log.error("\($0)") }
        return w
    }()
    lazy var enhanceAgent = EnhanceAgent(store: projectStore, memory: memory, questions: questions, agents: agentIndex)
    lazy var groomAgent: GroomAgent = {
        let g = GroomAgent(store: projectStore, memory: memory, questions: questions, agents: agentIndex, queue: queue, enhance: enhanceAgent,
                           journal: GroomJournal(store: STORE_WRITES.files ?? STORE_WRITES.store))
        g.areas = { [unowned self] in self.areas.areas(key: $0) }
        return g
    }()
    lazy var attachments = MainActor.assumeIsolated { AttachmentBook(store: projectStore) }
    lazy var sessions = SessionNotes(path: SESSIONS_PATH, agents: agentIndex, store: projectStore, writeBack: writeBack)
    let busy = BusyTracker()
    lazy var ciAssist = CIAssist(path: CI_ASSIST_PATH)
    lazy var questions: QuestionHub = {
        let h = QuestionHub(agents: agentIndex, writes: STORE_WRITES)
        h.notify = { [weak self] key, title, body in self?.notify(title: title, subtitle: "", body: body, id: "agent:" + (key ?? "question")) }
        return h
    }()
    lazy var itemSummaries = ItemSummaries(path: ITEM_SUMMARIES_PATH)
    lazy var aiOutputs = AIOutputBook(writes: STORE_WRITES)
    lazy var stats = WorkStats(path: WORK_STATS_PATH)
    lazy var appWindow: AppWindow = {
        AppWindow(data: self)
    }()
    let rateLimit = RateLimitMonitor()
    let updater = Updater()
    lazy var relay: LiveSync = {
        let c = LiveSync(secrets: cloudSetup.secrets)
        LiveSync.migrateCursor(into: c.cursors)
        c.sink = self
        c.machines = machineHub
        c.unhooked = { [weak self] in self?.cloudSetup.unhookedRepos(REPOS) ?? [] }
        return c
    }()
    // Targeted refreshes that arrive while another refresh runs.
    var pendingPartial: (repos: Set<String>, prs: Bool, runs: [(String, String)], dones: [(Bool) -> Void])?

    func applicationDidFinishLaunching(_ note: Notification) {
        log.info("OverSire launching — repos: \(REPOS.count), poll: \(POLL_NORMAL)s/\(POLL_ACTIVE)s")
        if LegacyMigration().run() { log.info("migrated the Cat Eye data") }
        loadConfig()
        UILog.watchMenus()
        // The loads of the store owners must see the moved records.
        Task { @MainActor in
            await StoreMigration.runForApp(STORE_WRITES)
            self.launch()
        }
    }

    private func launch() {
        WorkstreamIndex.formats = ENV.keyFormats
        startLogs()
        installMainMenu()
        applyShowIn()
        REPOS = catalog.resolve(picked: PICKED_REPOS, orgs: PICKED_ORGS)
        assignRepoColors(REPOS)
        log.info("Config loaded — tracking \(REPOS.count) repos: \(REPOS.joined(separator: ", "))")
        ghIcon = loadGHIcon()

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        UserJoinNotifier.register(on: nc)
        nc.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted { log.info("Notification permission granted") }
            else { log.warning("Notification permission denied: \(error?.localizedDescription ?? "user declined")") }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Give macOS a stable slot for the item. Anonymous `Item-0` positions can
        // survive monitor-layout changes with an off-screen x coordinate, leaving
        // the process alive but the app completely inaccessible.
        statusItem.autosaveName = "OverSireStatusItem"
        statusItem.isVisible = GENERAL.showIn.menuBar
        if let btn = statusItem.button {
            btn.image = tintedIcon(ghIcon, .secondaryLabelColor)
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(statusItemClicked)
            // Re-render the cached tinted icon when the system flips light/dark.
            appearanceObs = btn.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        applySystemAppearance()   // pins NSApp.appearance + popover.appearance from defaults

        // System-wide light/dark toggle. NSApp.effectiveAppearance is unreliable for
        // .accessory apps, so we listen for the canonical distributed notification.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        if GENERAL.openWindowAtLaunch || !GENERAL.showIn.menuBar {
            DispatchQueue.main.async { self.appWindow.show() }
        }
        if REPOS.isEmpty {
            // First run: open Settings in the window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.closeTime = .distantPast
                self.showSettings()
            }
        } else {
            // Polling gives events for changes only, so the first load reads the PRs too.
            refresh(force: true)
        }
        MachinesController.shared.hub = machineHub
        ENV.machines = machineHub
        MainActor.assumeIsolated {
            machineHub.approvals.onShow = { [weak self] r in
                guard NSApp.isActive, let self else { return }
                self.showJoinRequest(r.request)
            }
        }
        // Before the first reloadList: projectStore.track publishes the cached items at once, and each tick asks the gates.
        startAutomations()
        machineHub.start()
        DaemonSetup.shared.offerUpdateOnce()
        relay.start()
        updatePolling()
        rateLimit.onChange = { [weak self] in
            ((self?.popover.contentViewController as? TabVC)?.footerView as? Footer)?.showQuota(self?.rateLimit.latest)
        }
        rateLimit.start()
        updater.onReady = { [weak self] v in
            self?.notify(title: "OverSire", subtitle: "v\(v) is ready to install", body: "Install it from Settings › General.", id: "update-ready-\(v)")
        }
        updater.start()
        if let v = updater.takeUpdateNotice() {
            notify(title: "OverSire", subtitle: "Updated to v\(v)", body: "The new version is running.", id: "updated-\(v)")
        }

        // New repos of a whole-owner pick start to track after a catalog refresh.
        NotificationCenter.default.addObserver(forName: RepoCatalog.changed, object: catalog, queue: .main) { [weak self] _ in
            guard let self = self, !self.catalog.refreshing else { return }
            self.applyRepoSelection()
        }
        catalog.refreshIfStale()
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.catalog.refreshIfStale()
            self?.projectCatalog.refreshIfStale()
            self?.scanImportGraphs()
        }
        signalTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.sendChangedPaths() }
        cloudSetup.planeClient = { ENV.tracker($0) as? any WebhookManaging }
        ENV.onRemove = { [weak self] id in
            if id.provider == .plane { self?.cloudSetup.removePlaneHook(id.id) }
        }
        NotificationCenter.default.addObserver(forName: AppEnvironment.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            WorkstreamIndex.formats = ENV.keyFormats
            self.applyRepoSelection()
            self.relay.update()
            self.startQuestions()
            for w in ENV.trackerIds where self.projectCatalog.projects(of: w).isEmpty { self.projectCatalog.refresh(w, force: true) }
            self.applyProjectSelection()
            self.bus.post(DataChange(.all, origin: .user))
        }
        cloudSetup.trackedWorkspaces = { [weak self] in self?.trackedPlaneWorkspaces() ?? [] }
        let resolved = projectCatalog.resolve(PROJECTS_CFG)
        let before = PROJECTS_CFG.settings
        PROJECTS_CFG.migrateRoots(resolved)
        if PROJECTS_CFG.settings != before { saveConfig() }
        projectStore.track(resolved, live: liveProjectKeys())
        syncPlaneWorkspaces()
        projectCatalog.refreshIfStale()
        applyCaptureHotKey()
        applyWindowHotKey()
        applyAssistantHotKey()
        snap.applyHotKeys()
        snap.restore()
        newSession.applyHotKey()
        newSession.created = { [weak self] k in self?.projectStore.refresh([k], force: true) { _ in } }
        NotificationCenter.default.addObserver(forName: SnapStore.changed, object: snap.store, queue: .main) { [weak self] _ in self?.updateIcon() }
        NotificationCenter.default.addObserver(forName: AgentIndex.changed, object: agentIndex, queue: .main) { [weak self] _ in
            if let self { self.stats.sample(working: self.agentIndex.agents.keys.filter { self.agentIndex.state($0) == .working }.count) }
            self?.scanCheckouts()
            self?.reloadList(DataChange(.agents, origin: .event))
            self?.updateIcon()
        }
        // The daemon banner of Work and the Session tab.
        NotificationCenter.default.addObserver(forName: MachineHub.changed, object: machineHub, queue: .main) { [weak self] _ in
            self?.reloadList(DataChange(.agents, origin: .event))
        }
        NotificationCenter.default.addObserver(forName: Cleaner.changed, object: cleaner, queue: .main) { [weak self] n in
            let k = n.userInfo?[Cleaner.keyInfo] as? String
            self?.reloadList(DataChange(.agents, items: k.map { [$0] } ?? [], origin: .event))
        }
        agentIndex.startTimer()
        startQuestions()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.agentIndex.didWake()
            self?.questions.didWake()
            self?.machineHub.refresh()
            if let o = self?.automations { Task { await o.refresh() } }
        }
        // A Mac that sleeps gives the automations to the other Macs.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            if let o = self?.automations { Task { await o.release() } }
        }
        NotificationCenter.default.addObserver(forName: QuestionHub.changed, object: questions, queue: .main) { [weak self] _ in
            self?.reloadList(DataChange(.questions, origin: .event))
            self?.updateIcon()
        }
        let sources: [(Notification.Name, DataDomains)] = [
            (WorkQueue.changed, .queue), (WorkStats.changed, .stats), (StatusJob.changed, .summaries), (EnhanceAgent.changed, .intake),
            (SessionNotes.changed, .agents), (CIAssist.changed, .runs), (ItemAreaBook.changed, .planner), (SuggestionBook.changed, .planner),
            (PlannerBook.changed, .planner), (ItemSummaries.changed, .summaries), (AttachmentBook.changed, .projects),
        ]
        for (n, d) in sources {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.bus.post(DataChange(d, origin: .event))
            }
        }
        NotificationCenter.default.addObserver(forName: ProjectStore.changed, object: projectStore, queue: .main) { [weak self] _ in
            self?.enhanceAgent.autoStart()
        }
        queue.areaBook = { [unowned self] in UIShots.cloud ?? self.relay.canRun ? self.areas : nil }
        queue.planner = { [unowned self] in UIShots.cloud ?? self.relay.canRun ? self.planner : nil }
        // A loaded blocker can free or hold a queue entry.
        NotificationCenter.default.addObserver(forName: RelationCache.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.queue.tick(workstreams: self.workstreams)
            self.bus.post(DataChange(.relations, origin: .event))
        }
        NotificationCenter.default.addObserver(forName: ProjectCatalog.changed, object: projectCatalog, queue: .main) { [weak self] _ in
            guard let self = self, !self.projectCatalog.refreshing else { return }
            self.projectStore.track(self.projectCatalog.resolve(PROJECTS_CFG), live: self.liveProjectKeys())
            self.syncPlaneWorkspaces()
        }
    }

    // Registers the quick capture shortcut again. Settings → Projects calls it after a save.
    @discardableResult
    func applyCaptureHotKey() -> Bool {
        captureHotKey?.unregister()
        captureHotKey = nil
        let c = PROJECTS_CFG.capture
        guard c.enabled, c.hasShortcut, PROJECTS_CFG.showTab else { return true }
        captureHotKey = GlobalHotKey(keyCode: c.keyCode, modifiers: c.modifiers) { [weak self] in self?.quickCapture() }
        if captureHotKey == nil { log.warning("Quick capture shortcut \(c.shortcutLabel) is not available") }
        return captureHotKey != nil
    }

    func suspendCaptureHotKey(_ on: Bool) {
        if on { captureHotKey?.unregister(); captureHotKey = nil } else { applyCaptureHotKey() }
    }

    // Opens the Projects tab with the New item sheet, from any app.
    func quickCapture() {
        guard PROJECTS_CFG.showTab else { return }
        let c = PROJECTS_CFG.capture
        let clip = c.pasteClipboard
            ? NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        selectedTab = .projects
        if popover.isShown {
            if let vc = popover.contentViewController as? TabVC, vc.selectedTab == .projects {
                if vc.sheet != nil { return }
            } else {
                showList()
            }
        } else {
            closeTime = .distantPast
            popover.contentViewController = nil
            toggle()
        }
        NSApp.activate(ignoringOtherApps: true)
        (popover.contentViewController as? TabVC)?.presentNewItem(target: nil, prefill: clip, suggest: c.aiTitle)
    }

    // The menu bar of the app. Without a Dock icon it is hidden, but its key equivalents still work.
    func installMainMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            item.submenu = m
            main.addItem(item)
        }
        func mi(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, path: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.representedObject = path
            return i
        }
        sub("OverSire", [
            mi("About OverSire", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            mi("Settings…", #selector(openSettingsPage), ",", target: self),
            .separator(),
            mi("Hide OverSire", #selector(NSApplication.hide(_:)), "h"),
            mi("Quit OverSire", #selector(quitApp), "q", target: self),
        ])
        sub("Edit", [
            mi("Undo", Selector(("undo:")), "z"),
            mi("Redo", Selector(("redo:")), "Z"),
            .separator(),
            mi("Cut", #selector(NSText.cut(_:)), "x"),
            mi("Copy", #selector(NSText.copy(_:)), "c"),
            mi("Paste", #selector(NSText.paste(_:)), "v"),
            mi("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            mi("Find in Settings", #selector(SettingsPage.focusSearch(_:)), "f"),
        ])
        sub("View", [
            mi("Toggle Sidebar", #selector(AppWindow.toggleSidebarNow(_:)), "s", [.command, .control]),
            mi("Refresh", #selector(AppWindow.refreshNow), "r"),
            .separator(),
            mi("Ask the Assistant", #selector(toggleAssistant), "j", target: self),
        ])
        let pages: [(String, String)] = [("Home", "home"), ("Inbox", "inbox"), ("My items", "mine"), ("Sessions", "sessions"),
                                         ("Queue", "queue"), ("Runs", "runs"), ("Pull requests", "prs"), ("Insights", "insights")]
        sub("Go", [
            mi("Back", #selector(AppWindow.goBack(_:)), "["),
            mi("Forward", #selector(AppWindow.goForward(_:)), "]"),
            .separator(),
            mi("Search or Jump To…", #selector(AppWindow.openPalette), "k"),
            .separator(),
        ] + pages.enumerated().map { i, p in mi(p.0, #selector(openPath(_:)), "\(i + 1)", target: self, path: p.1) })
        let window = [
            mi("OverSire", #selector(showWindow), "0", target: self),
            mi("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            mi("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
        sub("Window", window)
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    // Dock icon or not. A menu-only app still opens its window, without a Dock icon.
    func applyShowIn() {
        NSApp.setActivationPolicy(GENERAL.showIn.dock ? .regular : .accessory)
        statusItem?.isVisible = GENERAL.showIn.menuBar
    }

    @discardableResult
    func applyWindowHotKey() -> Bool {
        windowHotKey?.unregister()
        windowHotKey = nil
        let k = GENERAL.windowKey
        guard k.hasShortcut else { return true }
        windowHotKey = GlobalHotKey(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in self?.toggleWindow() }
        if windowHotKey == nil { log.warning("Window shortcut \(k.shortcutLabel) is not available") }
        return windowHotKey != nil
    }

    @discardableResult
    func applyAssistantHotKey() -> Bool {
        assistantHotKey?.unregister()
        assistantHotKey = nil
        let k = AI_CFG.assistant.hotkey
        guard k.hasShortcut else { return true }
        assistantHotKey = GlobalHotKey(keyCode: k.keyCode, modifiers: k.modifiers) { [weak self] in self?.askAssistant() }
        if assistantHotKey == nil { log.warning("Assistant shortcut \(k.shortcutLabel) is not available") }
        return assistantHotKey != nil
    }

    func toggleWindow() {
        if appWindow.isVisible && NSApp.isActive && appWindow.window?.isKeyWindow == true { appWindow.window?.orderOut(nil) }
        else { showWindow() }
    }

    @objc func showWindow() {
        if popover?.isShown == true { popover.close() }
        appWindow.show()
    }

    /// Opens Settings › Machines with the dialog of an open join request.
    func showJoinRequest(_ request: String) {
        MainActor.assumeIsolated {
            let approvals = machineHub.approvals
            guard let r = approvals.request(request), MachineSheets.open == nil else { return }
            open(.settings(.machines))
            MachineSheets.approve(r, group: machineHub.groupName ?? "My machines", over: appWindow.window) { [weak self] yes in
                Task { @MainActor in await approvals.decide(request, approve: yes, in: self?.appWindow.window) }
            }
        }
    }

    func open(_ route: Route, focus: String? = nil) {
        if popover?.isShown == true { popover.close() }
        appWindow.show(route, focus: focus)
    }

    /// ⌘J: shows or hides the assistant panel. A hidden window shows with the panel.
    @objc func toggleAssistant() {
        if appWindow.window?.isKeyWindow == true { appWindow.toggleAssistant(nil) } else { askAssistant() }
    }

    /// The Ask buttons of the menu bar panels: the window with the assistant.
    @objc func askAssistant() {
        if popover?.isShown == true { popover.close() }
        appWindow.show()
        appWindow.showAssistant()
    }

    @objc func openPath(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String, let r = Route(path: p) { open(r) }
    }

    // On a project page, Command-Comma opens the settings of that project.
    @objc func openSettingsPage() {
        if appWindow.window?.isKeyWindow == true, case .project(let k) = appWindow.router.current { open(.projectSettings(k, .appearance)); return }
        open(.settings(.general))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let t = Target(url: url) { open(t.route, focus: t.focus) } else { log.warning("Unknown link: \(url.absoluteString, privacy: .public)") }
        }
    }

    // True when macOS actually placed the status item in a menu bar. A screen left
    // of or below the built-in display has negative coordinates, so "x >= 0" would
    // wrongly call a perfectly good item unplaced — test against the real screens.
    var statusItemIsPlaced: Bool {
        guard let f = statusItem.button?.window?.frame, f.width > 0 else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(f) }
    }

    // OverSire has no Dock icon or normal windows. When Finder, Spotlight, Raycast,
    // or `open` activates an already-running instance, macOS only forwards a reopen
    // event — without this callback nothing appears and the app looks dead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard GENERAL.showIn.dock || self.statusItemIsPlaced else { self.showWindow(); return }
            // A .transient popover closes the moment the app is not active, and a
            // reopen does not activate an .accessory app on its own.
            if GENERAL.showIn.dock || !flag { self.showWindow(); return }
            NSApp.activate(ignoringOtherApps: true)
            self.closeTime = .distantPast
            if !self.popover.isShown { self.toggle() }
        }
        return true
    }

    // MARK: - Polling

    // The fast cadence exists for the person reading the popover. With it shut,
    // the menu bar icon only has to be roughly right, and 10s polling through a
    // long CI run cost a measured 1,148 REST calls/hour that nobody was looking at.
    func updatePolling() {
        relay.setWatching(popover.isShown && hasActive(visibleGrouped(grouped)))
    }

    private func trackRefresh() {
        if refreshInFlight, refreshToken == nil {
            refreshToken = busy.begin("Refreshing runs and pull requests: \(REPOS.count) repos")
        } else if !refreshInFlight, let t = refreshToken {
            busy.end(t)
            refreshToken = nil
        }
    }

    func refresh(force: Bool = false, completion: (() -> Void)? = nil) {
        guard !REPOS.isEmpty else { completion?(); return }
        // Never let refreshes overlap: a slow network poll that outlives the timer
        // interval would otherwise stack concurrent gh-process storms.
        // A coalesced refresh still owes its caller a callback once fresh data lands.
        // Firing it immediately reopened the popover on stale rows. Last one wins:
        // every caller's completion just reopens the popover, so running it once is right.
        guard !refreshInFlight else {
            if let c = completion { pendingCompletion = c }
            return
        }
        refreshInFlight = true
        let repos = REPOS  // snapshot on calling thread
        // PRs don't need the fast active-poll cadence — refresh them on the
        // normal interval (or on demand), halving subprocess spawns while runs
        // are in progress.
        let includePRs = force || Date().timeIntervalSince(lastPRRefresh) >= POLL_NORMAL * 0.9
        let start = Date()
        log.debug("Refresh starting for \(repos.count) repos")
        Task { [weak self] in
            guard let self = self else { return }
            let (found, foundPRs) = await Self.fetch(repos, prs: includePRs)
            let runRes = found.map { ($0.0, $0.1 ?? []) }
            let prRes = foundPRs
            let elapsed = Date().timeIntervalSince(start)
            let totalRuns = runRes.reduce(0) { $0 + $1.1.count }
            let totalPRs = prRes.reduce(0) { $0 + $1.1.count }
            log.info("Refresh done in \(String(format: "%.1f", elapsed), privacy: .public)s — \(totalRuns) runs, \(totalPRs) PRs")
            Self.logPoll(found.filter { $0.1 == nil }.map(\.0), runs: totalRuns, ms: Int(elapsed * 1000))
            DispatchQueue.main.async {
                self.detectTransitions(runRes)
                self.ciAssist.observe(runRes)
                DeployLog.shared.record(runRes)
                self.grouped = runRes
                if includePRs {
                    self.prGrouped = prRes
                    self.lastPRRefresh = Date()
                    self.stats.refreshMerged()
                }
                self.lastFetch = Date()
                let first = self.firstLoad
                self.firstLoad = false
                self.refreshInFlight = false
                self.updateIcon()
                self.reloadList(first ? DataChange(.all) : nil, origin: force ? .user : .poll)
                self.updatePolling()
                completion?()
                let pending = self.pendingCompletion
                self.pendingCompletion = nil
                pending?()
                self.runPendingPartial()
            }
        }
    }

    // One line for each poll. A failed repo makes an error, so a gh login problem shows on the Logs page.
    static func logPoll(_ failed: [String], runs: Int, ms: Int) {
        var e = failed.isEmpty
            ? LogEntry(level: .ok, area: .sync, job: "GitHub poll", host: "gh", message: "\(runs) runs", ms: ms)
            : LogEntry(level: .error, area: .sync, job: "GitHub poll", subject: failed.joined(separator: ", "), host: "gh",
                       message: "Could not read the runs of \(failed.count) repos. Run gh auth status in a terminal.", ms: ms)
        e.verbose = failed.isEmpty ? true : nil
        APP_LOG.write(e)
    }

    // Refreshes only the given repos and merges them into the current data.
    // `done` gets false if a run fetch failed, so the relay does not ack those events.
    func refreshRepos(_ repos: [String], includePRs: Bool, completedRuns: [(String, String)], origin: DataChange.Origin = .event,
                      done: @escaping (Bool) -> Void) {
        guard !refreshInFlight else {
            var p = pendingPartial ?? (Set<String>(), false, [], [])
            p.repos.formUnion(repos); p.prs = p.prs || includePRs
            p.runs += completedRuns; p.dones.append(done)
            pendingPartial = p
            return
        }
        refreshInFlight = true
        Task { [weak self] in
            let (runRes, prRes) = await Self.fetch(repos, prs: includePRs)
            let fresh = runRes.compactMap { r in r.1.map { (r.0, $0) } }
            // Insights backfill: a run that completed and already left the list.
            var backfill: [(String, [Run])] = []
            for (repo, id) in completedRuns {
                let listed = fresh.first { $0.0 == repo }?.1.contains { $0.id == id } ?? false
                if !listed, let run = await REPO_CLIENT.run(repo, id: id), run.status == "completed" {
                    backfill.append((repo, [run]))
                }
            }
            let ok = fresh.count == repos.count
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.detectTransitions(fresh, partial: true)
                self.ciAssist.observe(fresh)
                DeployLog.shared.record(fresh + backfill)
                self.grouped = mergeGrouped(self.grouped, fresh, order: REPOS)
                if includePRs { self.prGrouped = mergeGrouped(self.prGrouped, prRes, order: REPOS) }
                self.lastFetch = Date()
                self.refreshInFlight = false
                self.updateIcon()
                self.reloadList(origin: origin)
                self.updatePolling()
                done(ok)
                let pending = self.pendingCompletion
                self.pendingCompletion = nil
                pending?()
                self.runPendingPartial()
            }
        }
    }

    /// The runs and PRs of each repo, in repo order. A nil run list means the fetch failed.
    /// At most 8 repos load at once.
    static func fetch(_ repos: [String], prs: Bool) async -> ([(String, [Run]?)], [(String, [ChangeRequest])]) {
        var runs = [[Run]?](repeating: nil, count: repos.count)
        var list = [[ChangeRequest]](repeating: [], count: repos.count)
        await withTaskGroup(of: (Int, [Run]?, [ChangeRequest]).self) { g in
            var next = 0
            func add() {
                guard next < repos.count else { return }
                let i = next, repo = repos[i]
                next += 1
                g.addTask {
                    async let r = REPO_CLIENT.runs(repo)
                    async let p = prs ? REPO_CLIENT.changes(repo) : []
                    return (i, await r, await p)
                }
            }
            for _ in 0..<8 { add() }
            for await (i, r, p) in g {
                runs[i] = r
                list[i] = p
                add()
            }
        }
        return (zip(repos, runs).map { ($0, $1) }, prs ? zip(repos, list).map { ($0, $1) } : [])
    }

    func runPendingPartial() {
        guard let p = pendingPartial else { return }
        pendingPartial = nil
        let repos = REPOS.filter { p.repos.contains($0) }
        refreshRepos(repos, includePRs: p.prs, completedRuns: p.runs) { ok in p.dones.forEach { $0(ok) } }
    }

    // Resolves REPOS from the picks. `reopen` is for an explicit save from the settings.
    func applyRepoSelection() {
        let previous = REPOS
        REPOS = catalog.resolve(picked: PICKED_REPOS, orgs: PICKED_ORGS)
        assignRepoColors(REPOS)
        guard REPOS != previous else { return }
        log.info("Repo catalog changed the tracked repos: \(previous.count) -> \(REPOS.count)")
        syncRelayRepos(previous: previous)
        refresh(force: true)
        relay.update()
        updatePolling()
    }

    func syncRelayRepos(previous: [String]) {
        if !RELAY.deviceID.isEmpty && !RELAY.workerURL.isEmpty {
            cloudSetup.registerRepos()
            let added = REPOS.filter { !previous.contains($0) }
            let removed = previous.filter { !REPOS.contains($0) }
            if !added.isEmpty {
                let d = cloudSetup
                d.perform("Install webhooks for new repos", { d.installHooks(repos: added) }) { [weak self] _ in
                    d.refreshHookedRepos { self?.relay.update() }
                }
            }
            cloudSetup.pruneHooks(removed: removed)
            syncPlaneWorkspaces()
        }
    }

    // Workspaces of the tracked projects that have a token.
    func trackedPlaneWorkspaces() -> [String] {
        var seen = Set<String>()
        return projectCatalog.resolve(PROJECTS_CFG).map(\.ref.workspace).filter {
            ENV.tracker($0) != nil && seen.insert($0).inserted
        }
    }

    func liveProjectKeys() -> Set<String> {
        Set(projectCatalog.resolve(PROJECTS_CFG).filter { p in
            switch cloudSetup.hooks.statuses[HookManager.planeKey(p.ref.workspace)] {
            case .live, .waiting: return true
            default: return false
            }
        }.map(\.ref.storeKey))
    }

    func applyProjectSelection() {
        agentIndex.poll()
        projectStore.track(projectCatalog.resolve(PROJECTS_CFG), live: liveProjectKeys())
        projectStore.restartTimer()
        syncPlaneWorkspaces()
        updateIcon()
    }

    // Registers the workspaces with the relay and adds a Plane webhook to new ones.
    func syncPlaneWorkspaces() {
        guard !RELAY.deviceID.isEmpty, !RELAY.workerURL.isEmpty else { return }
        let slugs = trackedPlaneWorkspaces()
        let removed = lastSyncedWorkspaces.filter { !slugs.contains($0) }
        let added = slugs.filter { !lastSyncedWorkspaces.contains($0) }
        lastSyncedWorkspaces = slugs
        cloudSetup.registerRepos()
        cloudSetup.prunePlaneHooks(removed: removed)
        guard !added.isEmpty else { return }
        let d = cloudSetup
        d.perform("Install Plane webhooks", { await d.installPlaneHooks(added) }) { [weak self] _ in
            d.checkPlaneHooks(added)
            self?.projectStore.track(self?.projectCatalog.resolve(PROJECTS_CFG) ?? [], live: self?.liveProjectKeys() ?? [])
        }
    }

    func startQuestions() {
        questions.start(channels: machineHub.questionChannels())
    }

    // MARK: - Icon

    func updateIcon() {
        let k = MenuIconState(runs: visibleGrouped(grouped), waitingAgents: agentIndex.agents.values.filter { $0.phase == .waiting }.count,
                              unread: projectStore.unreadCount(), unreadDot: PROJECTS_CFG.menuDot,
                              problems: openProblems.count, questions: questions.open.count)
        statusItem.button?.toolTip = "OverSire \u{2014} \(k.label)"
        // The shots in the open snap baskets, as a count next to the icon.
        let shots = snap.shotCount
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = shots > 0 ? "\(shots)" : ""
        statusItem.button?.setAccessibilityValue(shots > 0 ? "\(shots) shot\(shots == 1 ? "" : "s") in the snap basket" : nil)
        // Setting the image redraws the item on each display, which fires the appearance
        // observer again. Without this check the two loop and use a full CPU core.
        guard k != iconKey else { return }
        iconKey = k
        statusItem.button?.image = statusBadgedIcon(ghIcon, color: k.color, badge: k.badge, dot: k.dot, problem: k.problems > 0)
        statusItem.button?.setAccessibilityLabel("OverSire, \(k.label)")
        if k.active { startAnimation() } else { stopAnimation() }
    }

    func startAnimation() {
        guard let btn = statusItem.button else { return }
        guard !isPulsing else { return }
        isPulsing = true
        // Breathing pulse via Core Animation: runs entirely in the render server,
        // so the app never wakes per frame (the old 0.15s Timer redrew the status
        // item ~7×/sec for as long as any action was running).
        btn.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        btn.layer?.add(pulse, forKey: "oversire.pulse")
    }

    func stopAnimation() {
        guard isPulsing else { return }
        isPulsing = false
        statusItem.button?.layer?.removeAnimation(forKey: "oversire.pulse")
    }

    // MARK: - Run actions

    // The Planner signals sync only with a cloud account. Without one, the paths stay on this Mac.
    func sendChangedPaths() {
        guard relay.canRun else { return }
        var items: [String: (ItemRef, String)] = [:]
        for (k, a) in agentIndex.agents where [.starting, .working, .waiting].contains(a.phase) {
            guard let path = workstreams.stream(k)?.checkouts.first?.path, let found = projectStore.item(key: k),
                  let ref = found.item.ref(in: found.snap.summary.ref) else { continue }
            items[k] = (ref, path)
        }
        plannerSignals.tick(items)
    }

    func scanImportGraphs(force: Bool = false) {
        guard relay.canRun else { return }
        plannerSignals.scan(PROJECTS_CFG.orca.roots.filter { !$0.value.isEmpty }, force: force)
    }

    func has(_ c: Capability) -> Bool { ENV.has(c) }

    func rerun(repo: String, runs: [Run], failedOnly: Bool) {
        guard !runs.isEmpty else { return }
        let action: RunAction = failedOnly ? .rerunFailed : .rerun
        Task {
            var errors: [String] = []
            for r in runs {
                if let e = await REPO_CLIENT.perform(action, repo: repo, id: r.id) { errors.append("\(r.workflowName ?? r.name): \(e)") }
            }
            DispatchQueue.main.async {
                if errors.isEmpty {
                    log.info("Re-run (\(action.rawValue)) requested for \(runs.count) run(s) in \(repo)")
                } else {
                    log.error("Re-run failed in \(repo): \(errors.joined(separator: "; "))")
                    self.notify(title: repo, subtitle: "Re-run failed", body: errors.joined(separator: "\n"),
                                id: "rerun-\(UUID().uuidString)")
                }
                // GitHub queues the new attempt a moment after the request.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.refreshRepos([repo], includePRs: false, completedRuns: [], origin: .user) { _ in }
                }
            }
        }
    }

    func setIgnored(_ runs: [Run], ignored: Bool) {
        IGNORED.set(runs, ignored: ignored)
        updateIcon()
        (popover.contentViewController as? TabVC)?.rebuildContent()
        bus.post(DataChange(.runs, origin: .user))
    }

    // Git branch and HEAD of the worktrees. At most once a minute, or on demand.
    func scanCheckouts(force: Bool = false, done: (() -> Void)? = nil) {
        guard force || workstreams.scanAge > 60 else { done?(); return }
        let known = Set(projectStore.tracked.map { $0.identifier.uppercased() })
        workstreams.scan(cards: agentIndex.cards, roots: Array(PROJECTS_CFG.orca.roots.values), known: known) { [weak self] in
            self?.reloadList(DataChange(.agents))
            guard let self else { return }
            self.cleaner.refresh(self) { [weak self] in
                guard let self else { return }
                self.cleaner.sweep(self)
                self.reloadList(DataChange(.agents))
                done?()
            }
        }
    }

    /// The app that runs the automatic actions. Each gate asks it first.
    var automations: AutomationOwner? { relay.group?.owner }

    private func startAutomations() {
        let may: () -> Bool = { [weak self] in self?.automations?.mayAct ?? true }
        queue.mayAct = may
        enhanceAgent.mayAct = may
        cleaner.mayAct = may
        writeBack.mayAct = may
        sessions.mayAct = may
        ciAssist.mayAct = may
        itemSummaries.mayAct = may
        statusJob.mayAct = may
        itemSummaries.outputs = aiOutputs
        ciAssist.outputs = aiOutputs
        statusJob.outputs = aiOutputs
        enhanceAgent.outputs = aiOutputs
        groomAgent.outputs = aiOutputs
        guard let o = automations else { return }
        NotificationCenter.default.addObserver(forName: AutomationOwner.changed, object: o, queue: .main) { [weak self] _ in
            log.info("Automations: \(String(describing: o.role), privacy: .public)")
            self?.reloadList(DataChange(.connection, origin: .event))
        }
        o.start()
    }

    func applicationWillTerminate(_ note: Notification) {
        guard let o = automations else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await o.release()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // The popover PRs tab lists review requests only.
    var reviewPRs: [(String, [ChangeRequest])] { prGrouped.map { ($0.0, $0.1.filter { !$0.mine }) } }

    /// Rebuilds the derived state and posts what changed: `change` plus the repos whose runs or PRs differ.
    func reloadList(_ change: DataChange? = nil, origin: DataChange.Origin = .poll) {
        workstreams.rebuild(store: projectStore, agents: agentIndex, runs: grouped, prs: prGrouped)
        queue.tick(workstreams: workstreams)
        statusJob.tick(workstreams: workstreams, store: projectStore)
        sessions.tick()
        if AI_CFG.itemSummary {
            itemSummaries.tick(projectStore.snapshots.values.flatMap { snap in
                snap.items.map { ($0, !snap.isFinished($0)) }
            })
        }
        if !firstLoad, ciAssist.digestDue() {
            let intake = projectStore.snapshots.values.reduce(0) { $0 + ($1.intake?.count ?? 0) }
            ciAssist.makeDigest(facts: CIAssist.digestFacts(runs: grouped, agents: Array(agentIndex.agents.values), queued: queue.count, intake: intake))
        }
        writeBack.sync(Array(workstreams.streams.values))
        var c = change ?? DataChange([], origin: origin)
        let runs = RunDiff.repos(postedRuns, grouped), prs = RunDiff.repos(postedPRs, prGrouped)
        postedRuns = grouped
        postedPRs = prGrouped
        if !runs.isEmpty { c.merge(DataChange(.runs, repos: runs, origin: origin)) }
        if !prs.isEmpty { c.merge(DataChange(.prs, repos: prs, origin: origin)) }
        if !c.domains.isEmpty { bus.post(c) }
        guard popover.isShown, let vc = popover.contentViewController as? TabVC else { return }
        vc.update(grouped: grouped, prGrouped: reviewPRs, updated: lastUpdate, loading: firstLoad)
    }

    // MARK: - Notifications

    // `partial` means newGrouped holds only some repos: the others keep their entries.
    func detectTransitions(_ newGrouped: [(String, [Run])], partial: Bool = false) {
        guard !firstLoad else {
            for run in newGrouped.flatMap({ $0.1 }) { prevStatuses[run.url] = run.status }
            return
        }
        let newRuns = newGrouped.flatMap { $0.1 }
        for (repo, runs) in newGrouped {
            for run in runs {
                let old = prevStatuses[run.url]
                let wf = run.workflowName ?? run.name
                if run.status == "in_progress" && old != "in_progress" {
                    log.info("Transition: \(wf) on \(run.headBranch) → in_progress (was \(old ?? "new"))")
                    if NOTIFICATIONS.started {
                        notify(title: repo, subtitle: "\u{25B6}\u{FE0F} Action Started", body: "\(wf) on \(run.headBranch)", id: "start-\(run.url)")
                    }
                }
                if run.status == "completed" && (old == "in_progress" || old == "queued") {
                    log.info("Transition: \(wf) on \(run.headBranch) → \(run.conclusion ?? "unknown") (was \(old ?? "new"))")
                    let link = workstreams.link(runId: run.id)
                    let watched = link.flatMap { workstreams.stream($0.key)?.agent }.map { $0.phase == .working || $0.phase == .waiting } ?? false
                    if ciAssist.shouldRetry(repo: repo, run, watched: watched) {
                        log.info("Flaky: re-running \(wf) on \(run.headBranch) once before the alert")
                        rerun(repo: repo, runs: [run], failedOnly: true)
                        continue
                    }
                    if let ending = notificationEnding(run) {
                        notify(title: repo, subtitle: ending,
                               body: "\(wf) on \(run.headBranch) \u{2014} \(runDuration(run))", id: "end-\(run.url)")
                    }
                }
            }
        }
        if partial {
            let repos = Set(newGrouped.map { $0.0 })
            for (repo, runs) in grouped where repos.contains(repo) { for r in runs { prevStatuses[r.url] = nil } }
        } else {
            prevStatuses = [:]
        }
        for run in newRuns { prevStatuses[run.url] = run.status }
    }

    // Returns nil when the user has disabled notifications for this conclusion.
    func notificationEnding(_ run: Run) -> String? {
        switch run.conclusion ?? "" {
        case "success":
            return NOTIFICATIONS.succeeded ? "\u{2705} Action Passed" : nil
        case "failure", "timed_out", "startup_failure":
            return NOTIFICATIONS.failed ? "\u{274C} Action Failed" : nil
        case "cancelled":
            return NOTIFICATIONS.cancelled ? "\u{1F6AB} Action Cancelled" : nil
        default:
            return NOTIFICATIONS.other ? "\u{26AA} Action Completed" : nil
        }
    }

    // Only the app writes logs. Tests and the CLI paths keep NoLog.
    private func startLogs() {
        let problems = ProblemTracker(path: PROBLEMS_PATH)
        problems.opened = { [weak self] p in
            guard NOTIFICATIONS.problems else { return }
            self?.notify(title: "OverSire problem", subtitle: p.job + (p.host.map { " · \($0)" } ?? ""), body: p.message, id: "problem-" + p.key)
        }
        let store = LogStore(dir: LOGS_DIR, problems: problems)
        store.secrets = [AIClient.keyStore.get(AIClient.keyName)].compactMap { $0 }
        logs = store
        APP_LOG = store
        orderLog = WorkOrderLog(writes: STORE_WRITES)
        NotificationCenter.default.addObserver(forName: ProblemTracker.changed, object: problems, queue: .main) { [weak self] _ in
            self?.updateIcon()
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in problems.expire() }
    }

    func notify(title: String, subtitle: String, body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.subtitle = subtitle; c.body = body; c.sound = .default
        c.threadIdentifier = title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // "Needs input" and "Agent done" for an item that OverSire tracks.
    func agentAlert(_ key: String, _ agent: AgentSession) {
        let found = projectStore.snapshots.values.lazy.compactMap { s in
            s.items.first { $0.key.uppercased() == key }.map { (s, $0) }
        }.first
        let n = found.map { PROJECTS_CFG.notifications(for: $0.0.summary.identifier) } ?? PROJECTS_CFG.notifications
        guard let n, agent.phase == .waiting ? n.agentWaiting : n.agentDone else { return }
        let title = found.map { $0.0.summary.ref.workspace + " › " + $0.0.summary.title } ?? "Orca"
        let subtitle = found.map { "\($0.1.key) \($0.1.title)" } ?? key
        var body = agent.phase == .waiting ? "Session needs input" : "Session done"
        if let m = agent.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { body += ": " + String(m.prefix(200)) }
        notify(title: title, subtitle: subtitle, body: body, id: "agent:" + (found?.1.id ?? key))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async {
            self.closeTime = .distantPast
            if id.hasPrefix("intake:") {
                if self.popover.isShown { self.popover.close() }
                let parts = id.dropFirst("intake:".count).split(separator: "|").map(String.init)
                if let key = parts.first { self.open(self.projectStore.intakeRoute(key, id: parts.count > 1 ? parts[1] : nil)) }
                return
            }
            if id.hasPrefix(ApproveCenter.prefix) {
                let request = String(id.dropFirst(ApproveCenter.prefix.count))
                switch response.actionIdentifier {
                case UserJoinNotifier.approve, UserJoinNotifier.deny:
                    let yes = response.actionIdentifier == UserJoinNotifier.approve
                    let approvals = self.machineHub.approvals
                    Task { @MainActor in await approvals.decide(request, approve: yes, in: nil) }
                default: self.showJoinRequest(request)
                }
                return
            }
            if id.hasPrefix("project:") || id.hasPrefix("agent:") {
                if self.popover.isShown { self.popover.close() }
                ItemWindow.show(String(id.drop { $0 != ":" }.dropFirst()))
                return
            }
            self.toggle()
        }
        handler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    // MARK: - Popover

    func makeTabVC() -> TabVC {
        let vc = TabVC(grouped: grouped, prGrouped: reviewPRs, updated: lastUpdate, loading: firstLoad,
                       tab: selectedTab, repo: selectedRepo)
        vc.projectView = projectView
        vc.assignedOnly = projectAssignedOnly
        vc.unreadOnly = projectUnreadOnly
        vc.expandedItem = expandedItem
        vc.selectedProject = selectedProject
        vc.statusFilter = projectStatusFilter
        vc.showAllProjects = projectShowAll
        vc.projectQuery = projectQuery
        return vc
    }

    // The rules are in `IconClick`.
    @objc func statusItemClicked() {
        // A transient panel can close on the mouse down, just before this click.
        switch IconClick.action(appWindow.iconClickState, panelShown: popover.isShown || Date().timeIntervalSince(closeTime) <= 0.3) {
        case .raise: showWindow()
        case .panel, .closePanel: toggle()
        }
    }

    @objc func toggle() {
        if popover.isShown { popover.close() }
        else if Date().timeIntervalSince(closeTime) > 0.3 {
            // Pin appearance BEFORE constructing the view tree so .cgColor resolves correctly.
            applySystemAppearance()
            if popover.contentViewController == nil || popover.contentViewController is TabVC || popover.contentViewController is GlanceVC {
                buildWithAppearance {
                    self.popover.contentViewController = GENERAL.smallPopover ? GlanceVC(data: self) { [weak self] in self?.open($0) } : self.makeTabVC()
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
            // No refresh here. makeTabVC() snapshots `grouped` at build time and
            // never re-reads it, so a fetch started now lands in a view nobody is
            // looking at — and doRefresh() already refreshes before
            // it calls toggle(), so it would double the cost.
            updatePolling()
        }
    }

    /// True if the system is currently in Dark Mode. Reads CFPreferences directly because
    /// UserDefaults.standard caches the value and serves stale results immediately after
    /// the user flips appearance.
    func isSystemDarkMode() -> Bool {
        let v = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString,
                                          kCFPreferencesAnyApplication) as? String
        return v == "Dark"
    }

    func applySystemAppearance() {
        let dark = GENERAL.theme == .system ? isSystemDarkMode() : GENERAL.theme == .dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // NSApp.appearance pins how `NSColor.X.cgColor` resolves process-wide.
        NSApp.appearance = appearance
        popover.appearance = appearance
    }

    /// Construct views under the pinned appearance. The popover loads its view
    /// lazily at show time, so load it here or its CGColors bake in a stale appearance.
    func buildWithAppearance(_ block: () -> Void) {
        NSApp.withPinnedAppearance {
            block()
            _ = popover.contentViewController?.view
        }
    }

    @objc func systemAppearanceChanged() {
        // Distributed notifications can arrive on a background thread, and an Auto
        // appearance switch can post before AppleInterfaceStyle is written. Wait a bit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.applySystemAppearance()
            self.iconKey = nil
            self.updateIcon()
            // Discard the stale view tree (its CGColors are baked in the OLD appearance).
            // Next show reconstructs under the new drawing context.
            let wasShown = self.popover.isShown
            self.popover.close()
            self.popover.contentViewController = nil
            if wasShown {
                self.closeTime = .distantPast
                self.toggle()
            }
        }
    }

    // The menu bar gear and the first run open Settings in the window.
    @objc func showSettings() { showSettings(.settings(.general)) }

    func showSettings(_ route: Route) {
        if popover.isShown { popover.performClose(nil) }
        open(route)
    }

    @objc func showLogs() { showSettings(.settings(.logs)) }

    @objc func showUpdates() { showSettings(.settings(.general, anchor: SettingsAnchor.startup.rawValue)) }

    @objc func showRelaySettings() { showSettings(.settings(.accounts, anchor: SettingsAnchor.live.rawValue)) }

    @objc func showList() {
        popover.behavior = .transient
        applySystemAppearance()
        buildWithAppearance { self.popover.contentViewController = self.makeTabVC() }
    }

    @objc func doRefresh() {
        popover.close()
        refresh(force: true) { [weak self] in
            guard let self = self else { return }
            self.closeTime = .distantPast
            self.toggle()
        }
    }

    @objc func quitApp() { log.info("OverSire quitting"); NSApp.terminate(nil) }

    func popoverDidClose(_ notification: Notification) {
        closeTime = Date()
        popover.behavior = .transient
        popover.contentViewController = nil  // Release settings view if open
        updatePolling()                      // nobody is watching: back to the slow cadence
    }
}

extension GHActionsBar: RelaySink {
    func relayRefresh(repos: [String], includePRs: Bool, completedRuns: [(String, String)], done: @escaping (Bool) -> Void) {
        refreshRepos(repos, includePRs: includePRs, completedRuns: completedRuns, done: done)
    }

    // A gap in the log: refresh every repo.
    func relayFullRefresh(done: @escaping (Bool) -> Void) {
        refreshRepos(REPOS, includePRs: true, completedRuns: []) { ok in
            self.projectStore.refresh(self.projectStore.tracked.map(\.ref.storeKey), force: true) { projectOK in
                done(ok && projectOK)
            }
        }
    }

    func relayProjectRefresh(_ events: [(workspace: String, project: String?)], done: @escaping (Bool) -> Void) {
        projectStore.refreshForEvents(events, done: done)
    }

    func relayStateChanged() {
        updatePolling()
        if relay.state == .live { cloudSetup.refreshHookedRepos { [weak self] in self?.relay.update() } }
    }
}

extension NSApplication {
    /// Runs `block` with the pinned appearance as the drawing appearance, so every
    /// `NSColor.X.cgColor` read in it resolves to the right light/dark value.
    func withPinnedAppearance(_ block: () -> Void) {
        (appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance(block)
    }
}

// ─── Main ────────────────────────────────────────────────────────────────────

if CommandLine.arguments.contains("--selftest") { runSelfTest(); exit(0) }

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--uishots"), i + 1 < CommandLine.arguments.count {
    let shots = UIShots(dir: CommandLine.arguments[i + 1], paths: Array(CommandLine.arguments.dropFirst(i + 2)))
    app.setActivationPolicy(.accessory)
    app.delegate = shots
    app.run()
}

app.setActivationPolicy(.accessory)
let delegate = GHActionsBar()
app.delegate = delegate
app.run()

/// What a click on the menu bar icon does. The panel is the popover.
enum IconClick {
    enum Window { case closed, minimized, background, front, elsewhere }
    enum Action: Equatable { case panel, raise, closePanel }

    /// With the panel open, the window is not key, so a second click only closes the panel.
    static func action(_ w: Window, panelShown: Bool) -> Action {
        if panelShown { return .closePanel }
        switch w {
        case .minimized, .background: return .raise
        case .closed, .front, .elsewhere: return .panel
        }
    }
}

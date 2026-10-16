import Cocoa
import OverSireCore
import QuartzCore
import UserNotifications
import os

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
    var timer: Timer?
    var fallbackTimer: Timer?
    var lastFallbackPRRefresh = Date.distantPast
    var isPulsing = false
    var iconKey: MenuIconState?
    var refreshInFlight = false
    var pendingCompletion: (() -> Void)?
    var lastPRRefresh = Date.distantPast
    var grouped: [(String, [Run])] = []
    var prGrouped: [(String, [ChangeRequest])] = []
    var lastUpdate = Date()
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
    var lastSettingsTab: SettingsTab = .general
    var lastSyncedWorkspaces: [String] = []
    var appearanceObs: NSKeyValueObservation?
    let cloudSetup = CloudSetup()
    let catalog = RepoCatalog(path: REPO_CACHE_PATH)
    let planeAccounts = PlaneAccounts()
    lazy var projectCatalog = ProjectCatalog(accounts: planeAccounts, path: PROJECT_CACHE_PATH)
    lazy var projectNotifier: ProjectNotifier = {
        ProjectNotifier(post: { [weak self] title, subtitle, body, id in
            self?.notify(title: title, subtitle: subtitle, body: body, id: id)
        })
    }()
    lazy var projectStore: ProjectStore = {
        let s = ProjectStore(accounts: planeAccounts, notifier: projectNotifier,
                             statePath: PROJECT_STATE_PATH, activityPath: PROJECT_ACTIVITY_PATH)
        s.relayIsLive = { [weak self] in self?.relay.state == .live }
        s.onChange = { [weak self] in
            self?.updateIcon()
            self?.reloadList()
        }
        return s
    }()
    lazy var agentIndex: AgentIndex = {
        let a = AgentIndex()
        a.visible = { [weak self] in (self?.popover.isShown ?? false) || ItemWindow.isOpen }
        a.onAlert = { [weak self] key, agent in self?.agentAlert(key, agent) }
        return a
    }()
    var catalogTimer: Timer?
    var captureHotKey: GlobalHotKey?
    var windowHotKey: GlobalHotKey?
    let workstreams = WorkstreamIndex()
    lazy var queue = WorkQueue(path: QUEUE_PATH, store: projectStore, agents: agentIndex)
    lazy var aiChecks = AgentJudge(path: CHECKS_PATH, agents: agentIndex, queue: queue)
    lazy var writeBack: PlaneWriteBack = {
        let w = PlaneWriteBack(path: WRITEBACK_PATH, store: projectStore, accounts: planeAccounts)
        w.onError = { log.error("\($0)") }
        return w
    }()
    lazy var intakeAgent = IntakeAgent(store: projectStore, writeBack: writeBack)
    lazy var sessions = SessionNotes(path: SESSIONS_PATH, agents: agentIndex, store: projectStore, writeBack: writeBack)
    lazy var ciAssist = CIAssist(path: CI_ASSIST_PATH)
    lazy var appWindow: AppWindow = {
        AppWindow(data: self)
    }()
    let rateLimit = RateLimitMonitor()
    let updater = Updater()
    lazy var relay: RelayClient = {
        let c = RelayClient(secrets: cloudSetup.secrets)
        c.sink = self
        return c
    }()
    // Targeted refreshes that arrive while another refresh runs.
    var pendingPartial: (repos: Set<String>, prs: Bool, runs: [(String, String)], dones: [(Bool) -> Void])?

    func applicationDidFinishLaunching(_ note: Notification) {
        log.info("OverSire launching — repos: \(REPOS.count), poll: \(POLL_NORMAL)s/\(POLL_ACTIVE)s")
        if LegacyMigration().run() { log.info("migrated the Cat Eye data") }
        loadConfig()
        installMainMenu()
        applyShowIn()
        REPOS = catalog.resolve(picked: PICKED_REPOS, orgs: PICKED_ORGS)
        assignRepoColors(REPOS)
        log.info("Config loaded — tracking \(REPOS.count) repos: \(REPOS.joined(separator: ", "))")
        ghIcon = loadGHIcon()

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
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
            btn.action = #selector(toggle)
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
            // First run: open popover with settings
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.closeTime = .distantPast
                self.showSettings()   // opens + shows the popover itself
            }
        } else {
            refresh()
        }
        scheduleTimer()
        if relay.canRun { relay.start() }
        rateLimit.onChange = { [weak self] in
            ((self?.popover.contentViewController as? TabVC)?.footerView as? Footer)?.showQuota(self?.rateLimit.latest)
        }
        rateLimit.start()
        updater.canRestart = { [weak self] in !(self?.popover.isShown ?? false) }
        updater.start()
        if let v = updater.takeUpdateNotice() {
            notify(title: "OverSire", subtitle: "Updated to v\(v)", body: "The new version is running.", id: "updated-\(v)")
        }

        // New repos of a whole-owner pick start to track after a catalog refresh.
        NotificationCenter.default.addObserver(forName: RepoCatalog.changed, object: catalog, queue: .main) { [weak self] _ in
            guard let self = self, !self.catalog.refreshing else { return }
            self.applyRepoSelection(reopen: false)
        }
        catalog.refreshIfStale()
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.catalog.refreshIfStale()
            self?.projectCatalog.refreshIfStale()
        }
        cloudSetup.planeClient = { [weak self] in self?.planeAccounts.client(for: $0) }
        cloudSetup.trackedWorkspaces = { [weak self] in self?.trackedPlaneWorkspaces() ?? [] }
        projectStore.track(projectCatalog.resolve(PROJECTS_CFG), live: liveProjectKeys())
        syncPlaneWorkspaces()
        projectCatalog.refreshIfStale()
        applyCaptureHotKey()
        applyWindowHotKey()
        NotificationCenter.default.addObserver(forName: AgentIndex.changed, object: agentIndex, queue: .main) { [weak self] _ in
            self?.scanCheckouts()
            self?.reloadList()
            self?.updateIcon()
        }
        agentIndex.startTimer()
        for n in [WorkQueue.changed, AgentJudge.changed, IntakeAgent.changed, SessionNotes.changed, CIAssist.changed] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                NotificationCenter.default.post(name: AppWindow.changed, object: self)
            }
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
        ])
        sub("View", [
            mi("Toggle Sidebar", #selector(AppWindow.toggleSidebarNow(_:)), "s", [.command, .control]),
            mi("Refresh", #selector(AppWindow.refreshNow), "r"),
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

    func toggleWindow() {
        if appWindow.isVisible && NSApp.isActive && appWindow.window?.isKeyWindow == true { appWindow.window?.orderOut(nil) }
        else { showWindow() }
    }

    @objc func showWindow() {
        if popover?.isShown == true { popover.close() }
        appWindow.show()
    }

    func open(_ route: Route) {
        if popover?.isShown == true { popover.close() }
        appWindow.show(route)
    }

    @objc func openPath(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String, let r = Route(path: p) { open(r) }
    }

    @objc func openSettingsPage() { open(.settings(.general)) }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let r = Route(url: url) { open(r) } else { log.warning("Unknown link: \(url.absoluteString, privacy: .public)") }
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

    func scheduleTimer() {
        guard !REPOS.isEmpty else {
            timer?.invalidate(); fallbackTimer?.invalidate()
            return
        }
        // The fast cadence exists for the person reading the popover. With it shut,
        // the menu bar icon only has to be roughly right, and 10s polling through a
        // long CI run cost a measured 1,148 REST calls/hour — 23% of the GitHub
        // budget — that nobody was looking at.
        // A healthy relay pushes changes, so polling only reconciles.
        let interval: TimeInterval
        if relay.isHealthy {
            interval = RELAY.reconcileInterval ?? 600
        } else {
            interval = pollInterval(grouped)
        }
        // Each refresh calls this. Keep a timer with the same interval, or frequent
        // refreshes push the reconcile out forever.
        if timer?.isValid != true || timer?.timeInterval != interval {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.refresh()
                if self?.relay.isHealthy == true { self?.relay.sync() }
            }
            // Generous tolerance lets the system coalesce wakeups (and App Nap us)
            // instead of firing on an exact-deadline timer.
            timer?.tolerance = interval * 0.2
        }
        scheduleFallbackTimer()
    }

    func pollInterval(_ g: [(String, [Run])]) -> TimeInterval {
        (popover.isShown && hasActive(visibleGrouped(g))) ? POLL_ACTIVE : POLL_NORMAL
    }

    // Repos without a webhook get no relay events. Poll them at the normal cadence.
    func scheduleFallbackTimer() {
        let repos = relay.isHealthy ? cloudSetup.unhookedRepos(REPOS) : []
        guard !repos.isEmpty else {
            fallbackTimer?.invalidate(); fallbackTimer = nil
            return
        }
        let interval = pollInterval(grouped.filter { repos.contains($0.0) })
        guard fallbackTimer?.isValid != true || fallbackTimer?.timeInterval != interval else { return }
        fallbackTimer?.invalidate()
        log.info("Polling \(repos.count, privacy: .public) repos without a webhook every \(Int(interval), privacy: .public)s")
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let repos = self.cloudSetup.unhookedRepos(REPOS)
            guard !repos.isEmpty else { return }
            let prs = Date().timeIntervalSince(self.lastFallbackPRRefresh) >= POLL_NORMAL * 0.9
            if prs { self.lastFallbackPRRefresh = Date() }
            self.refreshRepos(repos, includePRs: prs, completedRuns: []) { _ in }
        }
        fallbackTimer?.tolerance = interval * 0.2
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var runRes = Array(repeating: (String, [Run])("", []), count: repos.count)
            var prRes = Array(repeating: (String, [ChangeRequest])("", []), count: repos.count)
            let collectQ = DispatchQueue(label: "com.oversire.app.collect")
            var tasks: [() -> Void] = []
            for (i, repo) in repos.enumerated() {
                tasks.append {
                    let runs = fetchRuns(repo: repo) ?? []
                    collectQ.sync { runRes[i] = (repo, runs) }
                }
                if includePRs {
                    tasks.append {
                        let prs = fetchPRs(repo: repo)
                        collectQ.sync { prRes[i] = (repo, prs) }
                    }
                }
            }
            // concurrentPerform caps parallelism at the core count, so many repos
            // no longer launch an unbounded burst of simultaneous gh processes.
            DispatchQueue.concurrentPerform(iterations: tasks.count) { tasks[$0]() }
            let elapsed = Date().timeIntervalSince(start)
            let totalRuns = runRes.reduce(0) { $0 + $1.1.count }
            let totalPRs = prRes.reduce(0) { $0 + $1.1.count }
            log.info("Refresh done in \(String(format: "%.1f", elapsed), privacy: .public)s — \(totalRuns) runs, \(totalPRs) PRs")
            DispatchQueue.main.async {
                self.detectTransitions(runRes)
                self.ciAssist.observe(runRes)
                DeployLog.shared.record(runRes)
                self.grouped = runRes
                if includePRs {
                    self.prGrouped = prRes
                    self.lastPRRefresh = Date()
                }
                self.lastUpdate = Date()
                self.firstLoad = false
                self.refreshInFlight = false
                self.updateIcon()
                self.reloadList()
                self.scheduleTimer()
                completion?()
                let pending = self.pendingCompletion
                self.pendingCompletion = nil
                pending?()
                self.runPendingPartial()
            }
        }
    }

    // Refreshes only the given repos and merges them into the current data.
    // `done` gets false if a run fetch failed, so the relay does not ack those events.
    func refreshRepos(_ repos: [String], includePRs: Bool, completedRuns: [(String, String)],
                      done: @escaping (Bool) -> Void) {
        guard !refreshInFlight else {
            var p = pendingPartial ?? (Set<String>(), false, [], [])
            p.repos.formUnion(repos); p.prs = p.prs || includePRs
            p.runs += completedRuns; p.dones.append(done)
            pendingPartial = p
            return
        }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var runRes = [(String, [Run])?](repeating: nil, count: repos.count)
            var prRes = [(String, [ChangeRequest])?](repeating: nil, count: repos.count)
            let collectQ = DispatchQueue(label: "com.oversire.app.collect-partial")
            var tasks: [() -> Void] = []
            for (i, repo) in repos.enumerated() {
                tasks.append {
                    let runs = fetchRuns(repo: repo)
                    collectQ.sync { runRes[i] = runs.map { (repo, $0) } }
                }
                if includePRs {
                    tasks.append {
                        let prs = fetchPRs(repo: repo)
                        collectQ.sync { prRes[i] = (repo, prs) }
                    }
                }
            }
            DispatchQueue.concurrentPerform(iterations: tasks.count) { tasks[$0]() }
            let fresh = runRes.compactMap { $0 }
            // Insights backfill: a run that completed and already left the list.
            var backfill: [(String, [Run])] = []
            for (repo, id) in completedRuns {
                let listed = fresh.first { $0.0 == repo }?.1.contains { $0.id == id } ?? false
                if !listed, let run = fetchRun(repo: repo, id: id), run.status == "completed" {
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
                if includePRs { self.prGrouped = mergeGrouped(self.prGrouped, prRes.compactMap { $0 }, order: REPOS) }
                self.lastUpdate = Date()
                self.refreshInFlight = false
                self.updateIcon()
                self.reloadList()
                self.scheduleTimer()
                done(ok)
                let pending = self.pendingCompletion
                self.pendingCompletion = nil
                pending?()
                self.runPendingPartial()
            }
        }
    }

    func runPendingPartial() {
        guard let p = pendingPartial else { return }
        pendingPartial = nil
        let repos = REPOS.filter { p.repos.contains($0) }
        refreshRepos(repos, includePRs: p.prs, completedRuns: p.runs) { ok in p.dones.forEach { $0(ok) } }
    }

    // Resolves REPOS from the picks. `reopen` is for an explicit save from the settings.
    func applyRepoSelection(reopen: Bool) {
        let previous = REPOS
        REPOS = catalog.resolve(picked: PICKED_REPOS, orgs: PICKED_ORGS)
        assignRepoColors(REPOS)
        if reopen { onConfigSaved(previous: previous); return }
        guard REPOS != previous else { return }
        log.info("Repo catalog changed the tracked repos: \(previous.count) -> \(REPOS.count)")
        syncRelayRepos(previous: previous)
        refresh(force: true)
        scheduleTimer()
    }

    func syncRelayRepos(previous: [String]) {
        if !RELAY.deviceID.isEmpty && !RELAY.workerURL.isEmpty {
            cloudSetup.registerRepos()
            let added = REPOS.filter { !previous.contains($0) }
            let removed = previous.filter { !REPOS.contains($0) }
            if !added.isEmpty {
                let d = cloudSetup
                d.perform("Install webhooks for new repos", { d.installHooks(repos: added) }) { [weak self] _ in
                    d.refreshHookedRepos { self?.scheduleTimer() }
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
            planeAccounts.hasToken($0) && seen.insert($0).inserted
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
        if popover.isShown, popover.contentViewController is ProjectSettingsVC {
            showList()
        }
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
        d.perform("Install Plane webhooks", { d.installPlaneHooks(added) }) { [weak self] _ in
            d.checkPlaneHooks(added)
            self?.projectStore.track(self?.projectCatalog.resolve(PROJECTS_CFG) ?? [], live: self?.liveProjectKeys() ?? [])
        }
    }

    func onConfigSaved(previous: [String]) {
        syncRelayRepos(previous: previous)
        prevStatuses = [:]
        firstLoad = true
        grouped = []
        popover.close()
        refresh(force: true) { [weak self] in
            guard let self = self else { return }
            self.closeTime = .distantPast
            self.toggle()
        }
    }

    // MARK: - Icon

    func updateIcon() {
        let k = MenuIconState(runs: visibleGrouped(grouped), waitingAgents: agentIndex.agents.values.filter { $0.phase == .waiting }.count,
                              unread: projectStore.unreadCount(), unreadDot: PROJECTS_CFG.menuDot)
        statusItem.button?.toolTip = "OverSire \u{2014} \(k.label)"
        // Setting the image redraws the item on each display, which fires the appearance
        // observer again. Without this check the two loop and use a full CPU core.
        guard k != iconKey else { return }
        iconKey = k
        statusItem.button?.image = statusBadgedIcon(ghIcon, color: k.color, badge: k.badge, dot: k.dot)
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

    func rerun(repo: String, runs: [Run], failedOnly: Bool) {
        guard !runs.isEmpty else { return }
        let endpoint = failedOnly ? "rerun-failed-jobs" : "rerun"
        DispatchQueue.global(qos: .userInitiated).async {
            let errors = runs.compactMap { r -> String? in
                let res = try? ghRun(["api", "-X", "POST", "repos/\(repo)/actions/runs/\(r.id)/\(endpoint)"])
                return res?.ok == true ? nil : "\(r.workflowName ?? r.name): \(res?.stderr ?? "gh did not run")"
            }
            DispatchQueue.main.async {
                if errors.isEmpty {
                    log.info("Re-run (\(endpoint)) requested for \(runs.count) run(s) in \(repo)")
                } else {
                    log.error("Re-run failed in \(repo): \(errors.joined(separator: "; "))")
                    self.notify(title: repo, subtitle: "Re-run failed", body: errors.joined(separator: "\n"),
                                id: "rerun-\(UUID().uuidString)")
                }
                // GitHub queues the new attempt a moment after the request.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.refreshRepos([repo], includePRs: false, completedRuns: []) { _ in }
                }
            }
        }
    }

    func setIgnored(_ runs: [Run], ignored: Bool) {
        IGNORED.set(runs, ignored: ignored)
        updateIcon()
        (popover.contentViewController as? TabVC)?.rebuildContent()
    }

    // Git branch and HEAD of the worktrees. At most once a minute, or on demand.
    func scanCheckouts(force: Bool = false) {
        guard force || workstreams.scanAge > 60 else { return }
        let known = Set(projectStore.tracked.map { $0.identifier.uppercased() })
        workstreams.scan(cards: agentIndex.cards, roots: Array(PROJECTS_CFG.orca.roots.values), known: known) { [weak self] in
            self?.reloadList()
        }
    }

    // The popover PRs tab lists review requests only.
    var reviewPRs: [(String, [ChangeRequest])] { prGrouped.map { ($0.0, $0.1.filter { !$0.mine }) } }

    func reloadList() {
        workstreams.rebuild(store: projectStore, agents: agentIndex, runs: grouped, prs: prGrouped)
        queue.tick(workstreams: workstreams)
        aiChecks.tick(workstreams: workstreams, store: projectStore)
        sessions.tick()
        if !firstLoad, ciAssist.digestDue() {
            let intake = projectStore.snapshots.values.reduce(0) { $0 + ($1.intake?.count ?? 0) }
            ciAssist.makeDigest(facts: CIAssist.digestFacts(runs: grouped, agents: Array(agentIndex.agents.values), queued: queue.count, intake: intake))
        }
        writeBack.sync(Array(workstreams.streams.values))
        NotificationCenter.default.post(name: AppWindow.changed, object: self, userInfo: [AppWindow.pollKey: true])
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

    func notify(title: String, subtitle: String, body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.subtitle = subtitle; c.body = body; c.sound = .default
        c.threadIdentifier = title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // "Needs input" and "Agent done" for an item that OverSire tracks.
    func agentAlert(_ key: String, _ agent: AgentSession) {
        let n = PROJECTS_CFG.notifications
        guard agent.phase == .waiting ? n.agentWaiting : n.agentDone else { return }
        let found = projectStore.snapshots.values.lazy.compactMap { s in
            s.items.first { $0.key.uppercased() == key }.map { (s, $0) }
        }.first
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
                if let key = parts.first { IntakeWindow.show(projectKey: key, workItemId: parts.count > 1 ? parts[1] : nil) }
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
            // looking at — and doRefresh()/onConfigSaved() already refresh before
            // they call toggle(), so it would double their cost.
            scheduleTimer()
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
            let wasSettings = self.popover.contentViewController is GeneralSettingsVC
                || self.popover.contentViewController is ActionsSettingsVC
                || self.popover.contentViewController is ProjectSettingsVC
                || self.popover.contentViewController is CloudSettingsVC
                || self.popover.contentViewController is AISettingsVC
            let settingsTab = self.lastSettingsTab
            let wasShown = self.popover.isShown
            self.popover.close()
            self.popover.contentViewController = nil
            if wasShown {
                self.closeTime = .distantPast
                if wasSettings { self.showSettings(settingsTab) }
                else { self.toggle() }
            }
        }
    }

    @objc func showSettings() { showSettings(lastSettingsTab) }

    func showSettings(_ tab: SettingsTab) {
        lastSettingsTab = tab
        popover.behavior = tab == .live ? .semitransient : .transient
        applySystemAppearance()
        buildWithAppearance {
            switch tab {
            case .general:
                self.popover.contentViewController = GeneralSettingsVC(catalog: self.catalog, updater: self.updater)
            case .actions:
                self.popover.contentViewController = ActionsSettingsVC(catalog: self.catalog, picked: Set(PICKED_REPOS), orgs: Set(PICKED_ORGS))
            case .projects:
                self.popover.contentViewController = ProjectSettingsVC(catalog: self.projectCatalog, store: self.projectStore, accounts: self.planeAccounts, cfg: PROJECTS_CFG)
            case .ai:
                self.popover.contentViewController = AISettingsVC()
            case .live:
                self.popover.contentViewController = CloudSettingsVC(setup: self.cloudSetup, client: self.relay)
            }
        }
        if !popover.isShown {
            closeTime = .distantPast
            toggle()
        }
    }

    @objc func showRelaySettings() { showSettings(.live) }

    // The settings views of the menu bar, for the Settings page of the window.
    func settingsVC(_ p: Route.SettingsPage) -> NSViewController? {
        switch p {
        case .general: return GeneralSettingsVC(catalog: catalog, updater: updater)
        case .repos: return ActionsSettingsVC(catalog: catalog, picked: Set(PICKED_REPOS), orgs: Set(PICKED_ORGS))
        case .accounts: return ProjectSettingsVC(catalog: projectCatalog, store: projectStore, accounts: planeAccounts, cfg: PROJECTS_CFG)
        case .ai: return AISettingsVC()
        case .live: return CloudSettingsVC(setup: cloudSetup, client: relay)
        default: return nil
        }
    }

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
        scheduleTimer()                      // nobody is watching: back to the slow cadence
        updater.installIfIdle()
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
        scheduleTimer()
        if relay.state == .live { cloudSetup.refreshHookedRepos { [weak self] in self?.scheduleTimer() } }
        (popover?.contentViewController as? CloudSettingsVC)?.rebuild()
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

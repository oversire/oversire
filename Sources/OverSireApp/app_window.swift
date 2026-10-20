import Cocoa
import OverSireCore

// What the window pages read and do. The app delegate implements it.
protocol AppData: AnyObject {
    var grouped: [(String, [Run])] { get }
    var prGrouped: [(String, [ChangeRequest])] { get }
    var lastUpdate: Date { get }
    var firstLoad: Bool { get }
    var projectStore: ProjectStore { get }
    var agentIndex: AgentIndex { get }
    var relay: LiveSync { get }
    var workstreams: WorkstreamIndex { get }
    var queue: WorkQueue { get }
    var memory: ProjectMemory { get }
    var areas: ItemAreaBook { get }
    var suggestions: SuggestionBook { get }
    var planner: PlannerBook { get }
    var statusJob: StatusJob { get }
    var intakeAgent: IntakeAgent { get }
    var sessions: SessionNotes { get }
    var ciAssist: CIAssist { get }
    var itemSummaries: ItemSummaries { get }
    var busy: BusyTracker { get }
    var updater: Updater { get }
    var cloudSetup: CloudSetup { get }
    var repoCatalog: RepoCatalog { get }
    var projectCatalog: ProjectCatalog { get }
    /// Nil in tests: only the app writes logs.
    var logs: LogStore? { get }
    func rerun(repo: String, runs: [Run], failedOnly: Bool)
    func setIgnored(_ runs: [Run], ignored: Bool)
    func refresh(force: Bool, completion: (() -> Void)?)
    /// True when an account has the feature. Pages hide what no account has.
    func has(_ c: Capability) -> Bool
}

extension AppData {
    /// The problems for the marks. Empty when the Logs settings turn the mark off.
    var openProblems: [Problem] { LOGS_CFG.menuMark ? logs?.problems.open ?? [] : [] }
}

// A hash of the data that pages show. A poll or event that changes none of it does not rebuild the page.
struct DataFingerprint: Equatable {
    let value: Int

    init(runs: [(String, [Run])], prs: [(String, [ChangeRequest])], agents: [String: AgentSession], snapshots: [ProjectSnapshot], lanes: [QueueLane], laneStates: [String: QueueLaneState] = [:], streams: [Workstream] = []) {
        var h = Hasher()
        for (repo, rs) in runs {
            h.combine(repo)
            for r in rs { h.combine(r.id); h.combine(r.status); h.combine(r.conclusion); h.combine(r.attempt); h.combine(r.updatedAt) }
        }
        for (repo, ps) in prs {
            h.combine(repo)
            for p in ps { h.combine(p.number); h.combine(p.state); h.combine(p.updatedAt); h.combine(p.reviewDecision) }
        }
        for (k, a) in agents.sorted(by: { $0.key < $1.key }) {
            h.combine(k); h.combine("\(a.phase)"); h.combine(a.since); h.combine(a.card); h.combine(a.message)
        }
        for s in snapshots.sorted(by: { $0.summary.ref.storeKey < $1.summary.ref.storeKey }) {
            h.combine(s.summary.ref.storeKey); h.combine(s.items); h.combine(s.intake)
        }
        for l in lanes {
            h.combine(l.project); h.combine(laneStates[l.project]?.error); h.combine(laneStates[l.project]?.lastStarted)
            for e in l.entries { h.combine(e.key); h.combine(e.condition) }
        }
        for s in streams.sorted(by: { $0.key < $1.key }) {
            h.combine(s.key)
            for c in s.checkouts { h.combine(c.path); h.combine(c.branch) }
            for r in s.runs { h.combine(r.run.id) }
        }
        value = h.finalize()
    }

    init(_ d: AppData) {
        self.init(runs: d.grouped, prs: d.prGrouped, agents: d.agentIndex.agents, snapshots: Array(d.projectStore.snapshots.values), lanes: d.queue.lanes, laneStates: d.queue.states,
                  streams: Array(d.workstreams.streams.values))
    }
}

// One page of the window. A page builds its views from the data, and builds again on each change.
class Page: NSViewController {
    let data: AppData
    let router: Router
    private(set) var route: Route
    private(set) lazy var scroll = PageScroll(maxWidth: pageWidth)
    // The widest column of the page.
    var pageWidth: CGFloat { 1100 }
    private let bar = PageBar()
    private var busyToken: BusyTracker.Token?

    // True while the page waits on its own fetch. It shows the page bar and the toolbar spinner.
    var pageBusy = false {
        didSet {
            guard pageBusy != oldValue else { return }
            bar.isHidden = !pageBusy
            if pageBusy { busyToken = data.busy.begin("Loading \(route.title)") } else if let t = busyToken { data.busy.end(t); busyToken = nil }
        }
    }

    init(_ route: Route, data: AppData, router: Router) {
        self.route = route
        self.data = data
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = Box(fill: Palette.bg, border: nil, radius: 0)
        v.addSubview(scroll)
        v.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            bar.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    // False while the page waits in the window cache. A reload then only marks the page stale.
    private(set) var isShown = true
    private(set) var stale = false
    private(set) var builtAt = Date.distantPast
    private var built = false

    // Pages with long lists show a skeleton first and build on the next turn, so a click shows at once.
    var buildsLater: Bool { false }
    static var deferBuilds = true

    // A new tab or filter of the same page.
    func show(_ r: Route) {
        let tabChanged = r != route
        route = r
        reload()
        if tabChanged { scroll.toTop() }
    }

    func reload() {
        guard isShown else { stale = true; return }
        if !built, buildsLater, Self.deferBuilds {
            built = true
            builtAt = Date()
            scroll.rebuild { skeleton($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.reload() }
            return
        }
        built = true
        stale = false
        builtAt = Date()
        scroll.rebuild { build($0) }
    }

    // One build for many async answers that come close together, for example account probes.
    func reloadSoon() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadQueued = false
            self?.reload()
        }
    }
    private var reloadQueued = false

    // The window shows the page again. It builds when the data changed, or the relative times are a minute old.
    func attach() {
        isShown = true
        if stale || -builtAt.timeIntervalSinceNow > 60 { reload() }
    }

    func detach() { isShown = false }

    // The data changed while the page was in the cache.
    func markStale() { stale = true }

    // The first view of a page that builds later.
    func skeleton(_ col: NSStackView) {
        col.addFull(PageHeader(route.title, caption: "Loading…"))
        col.addFull(LoadingNote("Loading \(route.title)", height: 240))
    }

    // Subclasses add their views to the page column.
    func build(_ col: NSStackView) {}

    // Pages that edit text return true, so a data change waits.
    var isEditing: Bool { view.window?.firstResponder is NSTextView }

    func go(_ r: Route) { router.go(r) }
    private(set) lazy var commands = RowCommander(data: data) { [weak self] in self?.go($0) }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pageBusy = false
    }
}

// The desktop window: sidebar, toolbar with back and forward, and the page.
final class AppWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    static let changed = Notification.Name("AppDataChanged")
    static let pollKey = "poll"   // userInfo key: the change comes from a poll and can be the same data

    let data: AppData
    let router = Router()
    private let split = NSSplitViewController()
    let sidebar = SidebarVC()
    private let host = NSViewController()
    private(set) var page: Page?
    // Pages that the window showed last, newest first. Back and forward show them without a new build.
    private var cache: [Page] = []
    private static let cacheSize = 6
    private var navItem: NSToolbarItemGroup?
    private var refreshButton: RefreshButton?
    private var changedWhileHidden = false
    private var pendingReload = false
    private var reloadScheduled = false
    private var forceNext = false
    private var fingerprint: DataFingerprint?
    private var builtAt = Date.distantPast
    private var observers: [Any] = []
    private let makePage: (Route, AppData, Router) -> Page

    init(data: AppData, makePage: @escaping (Route, AppData, Router) -> Page = PageFactory.make) {
        self.data = data
        self.makePage = makePage
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 820, height: 520)
        win.titleVisibility = .visible
        win.toolbarStyle = .unified
        win.tabbingMode = .disallowed
        win.center()
        win.setFrameAutosaveName("OverSireAppWindow")
        super.init(window: win)
        win.delegate = self

        host.view = Box(fill: Palette.bg, border: nil, radius: 0)
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200
        side.maximumThickness = 320
        side.canCollapse = true
        // Pages do not push the divider (PageScroll), but a stray constraint below 485 must not move it either.
        // Below a divider drag (490), so the user can still drag it.
        side.holdingPriority = .init(485)
        side.isCollapsed = GENERAL.sidebarCollapsed
        split.addSplitViewItem(side)
        let main = NSSplitViewItem(viewController: host)
        main.minimumThickness = 520
        split.addSplitViewItem(main)
        split.splitView.autosaveName = "OverSireSplit"
        win.contentViewController = split
        win.setContentSize(NSSize(width: 1180, height: 780))

        let tb = NSToolbar(identifier: "OverSireToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        win.toolbar = tb

        sidebar.onPick = { [weak self] r in if self?.router.current != r { self?.router.go(r) } }
        sidebar.commander = RowCommander(data: data) { [weak self] in self?.router.go($0) }
        router.onChange = { [weak self] r in self?.display(r) }
        observers.append(NotificationCenter.default.addObserver(forName: AppWindow.changed, object: nil, queue: .main) { [weak self] n in
            self?.dataChanged(n)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NewSessionController.changed, object: nil, queue: .main) { [weak self] n in
            self?.newSessionButton?.state = (n.object as? NewSessionController)?.isOpen == true ? .on : .off
        })
        observers.append(NotificationCenter.default.addObserver(forName: BusyTracker.changed, object: data.busy, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshButton?.show(self.data.busy)
        })
        display(router.current)
    }
    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ route: Route? = nil) {
        if let route { router.go(route) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // macOS 14+ can refuse the activation, for example for a link opened from a terminal.
        window?.orderFrontRegardless()
    }

    // MARK: Pages

    private func display(_ r: Route) {
        if let page, page.route.samePage(r) {
            page.show(r)
        } else {
            page?.view.removeFromSuperview()
            page?.removeFromParent()
            page?.detach()
            let cached = cache.first { $0.route.samePage(r) }
            let p = cached ?? makePage(r, data, router)
            cache.removeAll { $0 === p }
            cache.insert(p, at: 0)
            if cache.count > Self.cacheSize { cache.removeLast(cache.count - Self.cacheSize) }
            host.addChild(p)
            p.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(p.view)
            NSLayoutConstraint.activate([
                p.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                p.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                p.view.topAnchor.constraint(equalTo: host.view.topAnchor),
                p.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            ])
            page = p
            p.attach()
            if cached != nil, p.route != r { p.show(r) }
        }
        window?.title = r.title
        window?.subtitle = r.crumbs.joined(separator: " › ")
        window?.setAccessibilityTitle("OverSire, \(r.title)")
        updateNav()
        reloadSidebar()
    }

    // Many sources post a change in one burst: a relay event, the agent poll, Plane. Build once for the burst.
    // A change from a poll builds only when the data is different, or the relative times are a minute old.
    private func dataChanged(_ note: Notification) {
        guard isVisible else { return }
        if note.userInfo?[AppWindow.pollKey] == nil { forceNext = true }
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            let fp = DataFingerprint(self.data)
            guard self.forceNext || fp != self.fingerprint || -self.builtAt.timeIntervalSinceNow > 60 else { return }
            self.forceNext = false
            self.fingerprint = fp
            self.builtAt = Date()
            // A window behind other windows builds when it shows again. A build blocks the main thread and the menu bar panel.
            guard self.isOnScreen else {
                self.changedWhileHidden = true
                self.cache.forEach { $0.markStale() }
                return
            }
            self.reloadSidebar()
            self.cache.forEach { if $0 !== self.page { $0.markStale() } }
            guard let page = self.page else { return }
            if page.isEditing { self.pendingReload = true; return }
            page.reload()
        }
    }

    private var isOnScreen: Bool { isVisible && window?.occlusionState.contains(.visible) == true }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard changedWhileHidden, isOnScreen else { return }
        changedWhileHidden = false
        reloadSidebar()
        page?.attach()
    }

    func windowDidUpdate(_ notification: Notification) {
        guard pendingReload, let page, !page.isEditing else { return }
        pendingReload = false
        page.reload()
    }

    func reloadSidebar() {
        sidebar.set(SidebarModel(data: data).lines(), selected: router.current.sidebarKey)
    }

    func windowWillClose(_ notification: Notification) {
        GENERAL.sidebarCollapsed = split.splitViewItems.first?.isCollapsed ?? false
        saveConfig()
    }

    // MARK: Toolbar

    private let navId = NSToolbarItem.Identifier("nav")
    private let paletteId = NSToolbarItem.Identifier("palette")
    private let refreshId = NSToolbarItem.Identifier("refresh")
    private let settingsId = NSToolbarItem.Identifier("settings")
    private let copyId = NSToolbarItem.Identifier("copy")
    private let newSessionId = NSToolbarItem.Identifier("newSession")
    private var newSessionButton: NSButton?

    // apple.terminal with a small plus at the bottom right. SF Symbols has no such symbol.
    private static let newSessionImage: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let term = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
        let plus = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))!
        let size = NSSize(width: term.size.width + 4, height: term.size.height + 3)
        let img = NSImage(size: size, flipped: false) { _ in
            term.draw(in: NSRect(x: 0, y: 3, width: term.size.width, height: term.size.height))
            plus.draw(in: NSRect(x: size.width - plus.size.width, y: 0, width: plus.size.width, height: plus.size.height))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "New session"
        return img
    }()

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, navId, newSessionId, .sidebarTrackingSeparator, .flexibleSpace, paletteId, copyId, refreshId, settingsId]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case navId:
            let g = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!,
            ], selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navClicked(_:)))
            g.controlRepresentation = .expanded
            g.label = "Back and forward"
            navItem = g
            return g
        case newSessionId:
            let i = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: Self.newSessionImage, target: self, action: #selector(openNewSession(_:)))
            b.bezelStyle = .texturedRounded
            b.setButtonType(.pushOnPushOff)
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.toolTip = "New session (⌃⌥⌘N)"
            b.setAccessibilityLabel("New session, Control Option Command N")
            newSessionButton = b
            i.view = b
            i.label = "New session"
            return i
        case paletteId:
            let i = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(title: "Search or jump to…  ⌘K", target: self, action: #selector(openPalette))
            b.bezelStyle = .texturedRounded
            b.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.setAccessibilityLabel("Search or jump to, Command K")
            i.view = b
            i.label = "Search"
            return i
        case refreshId:
            let i = NSToolbarItem(itemIdentifier: id)
            let b = RefreshButton(target: self, action: #selector(refreshNow))
            refreshButton = b
            b.show(data.busy)
            i.view = b
            i.label = "Refresh"
            return i
        case copyId:
            let i = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "link", accessibilityDescription: "Copy the link of this page")!, target: self,
                             action: #selector(copyLink))
            b.bezelStyle = .texturedRounded
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.toolTip = "Copy the oversire:// link of this page"
            i.view = b
            i.label = "Copy link"
            return i
        case settingsId:
            let i = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self,
                             action: #selector(openSettings))
            b.bezelStyle = .texturedRounded
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.toolTip = "Settings (⌘,)"
            i.view = b
            i.label = "Settings"
            return i
        default:
            return nil
        }
    }

    private func updateNav() {
        navItem?.subitems.first?.isEnabled = router.canGoBack
        navItem?.subitems.last?.isEnabled = router.canGoForward
    }

    @objc private func navClicked(_ g: NSToolbarItemGroup) {
        if g.selectedIndex == 0 { router.back() } else { router.forward() }
    }

    @objc func goBack(_ sender: Any?) { router.back() }
    @objc func goForward(_ sender: Any?) { router.forward() }
    @objc func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(router.current.url.absoluteString, forType: .string)
    }
    @objc func refreshNow() {
        data.refresh(force: true, completion: nil)
        (page as? AgentsPage)?.checkAgain()
    }
    @objc func toggleSidebarNow(_ sender: Any?) { split.toggleSidebar(sender) }
    func setSidebarWidth(_ w: CGFloat) { split.splitView.setPosition(w, ofDividerAt: 0) }
    @objc func openPalette() { CommandPalette.show(over: self) }
    @objc func openNewSession(_ sender: NSButton) {
        guard let s = (NSApp.delegate as? GHActionsBar)?.newSession else { return }
        if s.isOpen { s.panel?.cancelOperation(nil) } else { s.show(near: sender) }
        sender.state = s.isOpen ? .on : .off
    }
    @objc func openSettings() { if case .settings = router.current { return }; router.go(.settings(.general)) }
    @objc func goTo(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let r = Route(path: s) { show(r) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return router.canGoBack
        case #selector(goForward(_:)): return router.canGoForward
        default: return true
        }
    }
}

// The sidebar lines and their counts.
struct SidebarModel {
    let data: AppData

    func lines() -> [SidebarLine] {
        let store = data.projectStore
        let runs = data.grouped.flatMap { $0.1 }
        let running = runs.filter { $0.status != "completed" }.count
        let failing = failingRuns(data.grouped).count
        let agents = data.agentIndex.agents.values
        let waiting = agents.filter { $0.phase == .waiting }.count
        let unread = store.unreadCount()
        let mine = store.snapshots.values.reduce(0) { n, s in
            n + s.rootItems.filter { $0.isMine(s.me) && s.option($0.statusOptionId)?.category != .done }.count
        }
        let prs = data.prGrouped.reduce(0) { $0 + $1.1.count }
        let plans = UIShots.cloud ?? data.relay.canRun ? data.suggestions.openPlans().count : 0
        let intake = store.snapshots.values.reduce(0) { $0 + ($1.intake?.count ?? 0) }

        func e(_ r: Route, _ title: String, _ symbol: String, badge: Int? = nil, alert: Int = 0, tone: NSColor? = nil,
               what: String = "") -> SidebarLine {
            var text: String?
            if alert > 0 { text = "\(alert)" } else if let badge, badge > 0 { text = "\(badge)" }
            let label = text.map { _ in (alert > 0 ? "\(alert) \(what), " : "") + (badge.map { "\($0) total" } ?? "") }
            return .entry(SidebarEntry(key: r.sidebarKey, route: r, title: title, symbol: symbol, badge: text,
                                       badgeTone: alert > 0 ? tone : nil, badgeLabel: label))
        }

        var out: [SidebarLine] = [
            e(.home, "Home", "house"),
            e(.inbox(.all), "Inbox", "tray", badge: unread + intake, alert: intake, tone: Palette.intake, what: "intake"),
            e(.mine, "My items", "person.crop.circle", badge: mine),
            e(.agents, "Sessions", "cpu", badge: agents.count, alert: waiting, tone: Palette.warn, what: "need input"),
            e(.queue, "Queue", "list.number", badge: plans),
            e(.runs(.all), "Runs", "play.circle", badge: running, alert: failing, tone: Palette.bad, what: "failing"),
            e(.prs, "Pull requests", "arrow.triangle.pull", badge: prs),
            e(.insights, "Insights", "chart.bar"),
        ]
        let projects = PROJECTS_CFG.sorted(store.tracked).filter { !PROJECTS_CFG.local($0.identifier).hidden }
        if !projects.isEmpty {
            out.append(.header("Projects"))
            for p in projects {
                let open = store.snapshots[p.ref.storeKey].map { $0.notDoneCount($0.rootItems) } ?? 0
                let r = Route.project(p.identifier.uppercased())
                out.append(.entry(SidebarEntry(key: r.sidebarKey, route: r, title: p.title, symbol: "folder",
                                               badge: open > 0 ? "\(open)" : nil, badgeTone: nil,
                                               badgeLabel: "\(open) open",
                                               initial: (String(p.identifier.prefix(1)), repoColor(p.identifier)))))
            }
        }
        out.append(.header("Views"))
        out.append(e(.runs(.failed), "Failing runs", "xmark.octagon", badge: failing))
        out.append(e(.runs(.unlinked), "Unlinked runs", "link.badge.plus"))
        return out
    }
}

// Makes the page for a route.
enum PageFactory {
    static func make(_ r: Route, data: AppData, router: Router) -> Page {
        switch r {
        case .home: return HomePage(r, data: data, router: router)
        case .inbox: return InboxPage(r, data: data, router: router)
        case .mine: return MyItemsPage(r, data: data, router: router)
        case .project: return ProjectPage(r, data: data, router: router)
        case .projectSettings: return ProjectSettingsPage(r, data: data, router: router)
        case .item: return ItemPage(r, data: data, router: router)
        case .runs: return RunsPage(r, data: data, router: router)
        case .run: return RunPage(r, data: data, router: router)
        case .agents: return AgentsPage(r, data: data, router: router)
        case .queue: return QueuePage(r, data: data, router: router)
        case .settings: return SettingsPage(r, data: data, router: router)
        case .prs: return PRsPage(r, data: data, router: router)
        case .insights: return InsightsPage(r, data: data, router: router)
        }
    }
}

// The toolbar refresh button. It shows a spinner while OverSire loads, and the tooltip names the work.
final class RefreshButton: NSButton {
    private let spinner = Spinner()
    private let arrow = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .texturedRounded
        image = arrow
        imagePosition = .imageOnly
        addSubview(spinner)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        spinner.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ busy: BusyTracker) {
        let on = busy.isBusy
        spinner.isHidden = !on
        image = on ? nil : arrow
        let work = busy.labels.joined(separator: "\n")
        toolTip = on ? work + "\n\nRefresh now (⌘R)" : "Refresh now (⌘R)"
        setAccessibilityLabel(on ? "Refresh. " + busy.labels.joined(separator: ". ") : "Refresh")
    }
}

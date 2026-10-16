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
    var aiChecks: AgentJudge { get }
    var intakeAgent: IntakeAgent { get }
    var sessions: SessionNotes { get }
    var ciAssist: CIAssist { get }
    func rerun(repo: String, runs: [Run], failedOnly: Bool)
    func settingsVC(_ p: Route.SettingsPage) -> NSViewController?
    func refresh(force: Bool, completion: (() -> Void)?)
    /// True when an account has the feature. Pages hide what no account has.
    func has(_ c: Capability) -> Bool
}

// A hash of the data that pages show. A poll or event that changes none of it does not rebuild the page.
struct DataFingerprint: Equatable {
    let value: Int

    init(runs: [(String, [Run])], prs: [(String, [ChangeRequest])], agents: [String: AgentSession], snapshots: [ProjectSnapshot], lanes: [QueueLane], streams: [Workstream] = []) {
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
            h.combine(l.project); h.combine(l.error); h.combine(l.lastStarted)
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
        self.init(runs: d.grouped, prs: d.prGrouped, agents: d.agentIndex.agents, snapshots: Array(d.projectStore.snapshots.values), lanes: d.queue.lanes,
                  streams: Array(d.workstreams.streams.values))
    }
}

// One page of the window. A page builds its views from the data, and builds again on each change.
class Page: NSViewController {
    let data: AppData
    let router: Router
    private(set) var route: Route
    let scroll = PageScroll()

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
        NSLayoutConstraint.activate([
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

    // A new tab or filter of the same page.
    func show(_ r: Route) {
        let tabChanged = r != route
        route = r
        reload()
        if tabChanged { scroll.toTop() }
    }

    func reload() { scroll.rebuild { build($0) } }

    // Subclasses add their views to the page column.
    func build(_ col: NSStackView) {}

    // Pages that edit text return true, so a data change waits.
    var isEditing: Bool { view.window?.firstResponder is NSTextView }

    func go(_ r: Route) { router.go(r) }
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
    private var navItem: NSToolbarItemGroup?
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
        router.onChange = { [weak self] r in self?.display(r) }
        observers.append(NotificationCenter.default.addObserver(forName: AppWindow.changed, object: nil, queue: .main) { [weak self] n in
            self?.dataChanged(n)
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
            let p = makePage(r, data, router)
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
        }
        window?.title = r.title
        window?.subtitle = r.url.absoluteString
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
            self.reloadSidebar()
            guard let page = self.page else { return }
            if page.isEditing { self.pendingReload = true; return }
            page.reload()
        }
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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, navId, .flexibleSpace, paletteId, refreshId]
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
            i.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            i.label = "Refresh"
            i.toolTip = "Refresh now (⌘R)"
            i.target = self
            i.action = #selector(refreshNow)
            i.isBordered = true
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
    @objc func refreshNow() { data.refresh(force: true, completion: nil) }
    @objc func toggleSidebarNow(_ sender: Any?) { split.toggleSidebar(sender) }
    @objc func openPalette() { CommandPalette.show(over: self) }
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
        let failing = latestPerWorkflow(runs).filter { $0.isFailure && !IGNORED.contains($0) }.count
        let agents = data.agentIndex.agents.values
        let waiting = agents.filter { $0.phase == .waiting }.count
        let unread = store.unreadCount()
        let mine = store.snapshots.values.reduce(0) { n, s in
            n + s.rootItems.filter { $0.isMine(s.me) && s.option($0.statusOptionId)?.category != .done }.count
        }
        let prs = data.prGrouped.reduce(0) { $0 + $1.1.count }
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
            e(.queue, "Queue", "list.number"),
            e(.runs(.all), "Runs", "play.circle", badge: running, alert: failing, tone: Palette.bad, what: "failing"),
            e(.prs, "Pull requests", "arrow.triangle.pull", badge: prs),
            e(.insights, "Insights", "chart.bar"),
        ]
        let projects = PROJECTS_CFG.sorted(store.tracked)
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
        out.append(.header(" "))
        out.append(e(.settings(.general), "Settings", "gearshape"))
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

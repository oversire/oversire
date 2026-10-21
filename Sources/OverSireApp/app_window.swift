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
    var cleaner: Cleaner { get }
    var queue: WorkQueue { get }
    var memory: ProjectMemory { get }
    var areas: ItemAreaBook { get }
    var suggestions: SuggestionBook { get }
    var planner: PlannerBook { get }
    var statusJob: StatusJob { get }
    var intakeAgent: IntakeAgent { get }
    var sessions: SessionNotes { get }
    var questions: QuestionHub { get }
    var ciAssist: CIAssist { get }
    var itemSummaries: ItemSummaries { get }
    var stats: WorkStats { get }
    var busy: BusyTracker { get }
    var updater: Updater { get }
    var cloudSetup: CloudSetup { get }
    var repoCatalog: RepoCatalog { get }
    var projectCatalog: ProjectCatalog { get }
    /// Nil in tests: only the app writes logs.
    var logs: LogStore? { get }
    /// The changes of the data. Pages and windows observe it.
    var bus: ChangeBus { get }
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

// One page of the window. A page gives its rows from the data. A change updates only the rows that changed.
// Pages that override `sections()` update in place. The others (settings) build all views again.
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
        reload(reason: "open")
    }

    // False while the page waits in the window cache. A change then only marks the page stale.
    private(set) var isShown = true
    private(set) var stale = false
    private var built = false
    // The fingerprint of the last build. A change with the same fingerprint does not build.
    private var builtPrint: Int?

    /// The builds of this page, and why the last one ran. The self-test and the tests read them.
    private(set) var buildCount = 0
    private(set) var lastBuildReason: String?
    /// The rows that the last build changed.
    private(set) var lastResult: RowReconciler.Result?

    // A table page: the page does not scroll. Its title and tabs stay at the top, and the table takes the free height.
    var fillsHeight: Bool { false }

    // Pages with long lists show a skeleton first and build on the next turn, so a click shows at once.
    var buildsLater: Bool { false }
    static var deferBuilds = true

    // MARK: What the page shows

    /// The data that this page shows. A change outside it does not touch the page.
    var watches: DataDomains { DataDomains.all.subtracting([.logs, .connection]) }
    /// The repos, store keys and item keys that the page shows. Nil: all of them.
    var shownRepos: Set<String>? { nil }
    var shownProjects: Set<String>? { nil }
    var shownItems: Set<String>? { nil }

    /// The rows of the page. Nil: the page builds all its views in `build(_:)`.
    func sections() -> [PageSection]? { nil }

    /// A hash of only the data that this page shows. The page builds when it changes. Nil: no hash, each change builds.
    func fingerprint() -> Int? { sections().map(PageSection.fingerprint) }

    /// Called by the window for each coalesced change.
    func receive(_ c: DataChange) {
        guard c.touches(watches, repos: shownRepos, projects: shownProjects, items: shownItems) else { return }
        guard isShown, isViewLoaded else { stale = true; return }
        let forced = c.domains.contains(.config) && c.origin == .user
        let rows = sections()
        if !forced, let rows, PageSection.fingerprint(rows) == builtPrint { return }
        if !forced, rows == nil, watches.isSubset(of: .config) { return }
        reload(reason: "data: " + c.reason, rows: rows)
    }

    // MARK: Builds

    // A new tab or filter of the same page.
    func show(_ r: Route) {
        let tabChanged = r != route
        route = r
        reload(reason: "route")
        if tabChanged { scroll.toTop() }
    }

    func reload() { reload(reason: "page") }

    func reload(reason: String) { reload(reason: reason, rows: nil) }

    private func reload(reason: String, rows given: [PageSection]?) {
        guard isShown else { stale = true; return }
        if !built, buildsLater, Self.deferBuilds {
            built = true
            if sections() == nil { scroll.rebuild { skeleton($0) } } else { scroll.apply(skeletonRows(), fills: false, mark: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.reload(reason: reason) }
            return
        }
        built = true
        stale = false
        buildCount += 1
        lastBuildReason = reason
        let start = Date()
        if let rows = given ?? sections() {
            builtPrint = PageSection.fingerprint(rows)
            lastResult = scroll.apply(rows, fills: fillsHeight)
        } else {
            builtPrint = nil
            lastResult = nil
            scroll.rebuild(fills: fillsHeight) { build($0) }
        }
        logBuild(reason, ms: Int(Date().timeIntervalSince(start) * 1000))
    }

    private func logBuild(_ reason: String, ms: Int) {
        let rows = lastResult.map { " · \($0.changed) rows changed, \($0.kept) kept" } ?? " · full build"
        var e = LogEntry(level: .ok, area: .ui, job: "Page build", subject: route.title, message: reason + rows, ms: ms)
        e.verbose = true
        APP_LOG.write(e)
    }

    // One build for many async answers that come close together, for example account probes.
    func reloadSoon() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadQueued = false
            self?.reload(reason: "page")
        }
    }
    private var reloadQueued = false

    // The window shows the page again. It builds only when its data changed while it waited.
    func attach() {
        isShown = true
        guard stale else { return }
        if let rows = sections(), PageSection.fingerprint(rows) == builtPrint { stale = false; return }
        reload(reason: "attach stale")
    }

    func detach() { isShown = false }

    // The data changed while the page was in the cache.
    func markStale() { stale = true }

    // The first view of a page that builds later.
    func skeleton(_ col: NSStackView) {
        col.addFull(PageHeader(route.title, caption: "Loading…"))
        col.addFull(LoadingNote("Loading \(route.title)", height: 240))
    }

    private func skeletonRows() -> [PageSection] {
        [PageSection("skeleton", rows: [PageRow("header", route.title) { [route] in PageHeader(route.title, caption: "Loading…") },
                                        PageRow("loading", route.title) { [route] in LoadingNote("Loading \(route.title)", height: 240) }])]
    }

    // Pages with no `sections()` add their views to the page column.
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
    // The change that waits for the gate or for the window to show.
    private var held: DataChange?
    /// Holds page updates while the person scrolls, clicks, uses a menu or edits.
    let gate = UpdateGate()
    let pill = HeldUpdatesPill()
    private var busObservation: ChangeBus.Observation?
    private var observers: [Any] = []
    private var monitor: Any?
    private var wheelEnd: DispatchWorkItem?
    private var holdCheck: Timer?
    private var popovers = Set<ObjectIdentifier>()
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
        host.view.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            pill.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
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
        sidebar.onLive = { [weak self] in self?.router.go(.activity) }
        router.onChange = { [weak self] r in self?.display(r) }
        busObservation = data.bus.observe { [weak self] c in self?.dataChanged(c) }
        gate.onHeldChange = { [weak self] on in
            self?.pill.set(held: on)
            self?.watchHold(on)
        }
        pill.onShow = { [weak self] in self?.gate.flushNow() }
        observers.append(NotificationCenter.default.addObserver(forName: NewSessionController.changed, object: nil, queue: .main) { [weak self] n in
            self?.newSessionButton?.state = (n.object as? NewSessionController)?.isOpen == true ? .on : .off
        })
        observers.append(NotificationCenter.default.addObserver(forName: BusyTracker.changed, object: data.busy, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshButton?.show(self.data.busy)
        })
        observers.append(NotificationCenter.default.addObserver(forName: Updater.changed, object: data.updater, queue: .main) { [weak self] _ in
            self?.syncUpdateItem()
        })
        installSignals()
        display(router.current)
        syncUpdateItem()
        sidebar.live.show(data.relay)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        monitor.map(NSEvent.removeMonitor)
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isVisible: Bool { window?.isVisible == true }

    /// The window state that a click on the menu bar icon reads. A full-screen app is a Space of its own.
    var iconClickState: IconClick.Window {
        guard let w = window else { return .closed }
        if w.isMiniaturized { return .minimized }
        guard w.isVisible else { return .closed }
        if !w.isOnActiveSpace { return .elsewhere }
        return NSApp.isActive && w.isKeyWindow ? .front : .background
    }

    func show(_ route: Route? = nil) {
        if let route { router.go(route) }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // macOS 14+ can refuse the activation, for example for a link opened from a terminal.
        window?.orderFrontRegardless()
    }

    // MARK: Pages

    private func display(_ r: Route) {
        // A route change never waits. The held change is in the new build, or marks the old page stale.
        if held != nil, let page, !page.route.samePage(r) { page.markStale() }
        held = nil
        gate.flushNow()
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
            host.view.addSubview(p.view, positioned: .below, relativeTo: pill)
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

    // The bus gives one change for each burst. Pages that do not show the changed data drop it.
    // The shown page updates through the gate, so it does not change under the cursor.
    private func dataChanged(_ c: DataChange) {
        if c.domains.contains(.connection) { sidebar.live.show(data.relay) }
        for p in cache where p !== page { p.receive(c) }
        if held == nil { held = c } else { held?.merge(c) }
        // A window behind other windows builds when it shows again. A build blocks the main thread and the menu bar panel.
        guard isOnScreen else { changedWhileHidden = true; return }
        reloadSidebar()
        gate.submit { [weak self] in self?.applyHeld() }
    }

    private func applyHeld() {
        guard let c = held else { return }
        held = nil
        page?.receive(c)
    }

    private var isOnScreen: Bool { isVisible && window?.occlusionState.contains(.visible) == true }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard changedWhileHidden, isOnScreen else { return }
        changedWhileHidden = false
        reloadSidebar()
        gate.submit { [weak self] in self?.applyHeld() }
    }

    func windowDidUpdate(_ notification: Notification) {
        if page?.isEditing == true { gate.begin(.editing) } else { gate.end(.editing) }
    }

    // MARK: Update gate

    // The signals that hold a page update: a scroll, a mouse press, a menu, a sheet or popover, text editing.
    private func installSignals() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] e in
            self?.signal(e)
            return e
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.gate.begin(.menu)
        })
        observers.append(nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            // A menu takes the mouse up of the press that opened it.
            self?.gate.end(.mouse)
            self?.gate.end(.menu)
        })
        observers.append(nc.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
            self?.gate.begin(.sheet)
        })
        observers.append(nc.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            self?.gate.end(.sheet)
        })
        observers.append(nc.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let p = n.object as? NSPopover, p.contentViewController?.view.window?.parent === self.window else { return }
            self.popovers.insert(ObjectIdentifier(p))
            self.gate.begin(.sheet)
        })
        observers.append(nc.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let p = n.object as? NSPopover, self.popovers.remove(ObjectIdentifier(p)) != nil, self.popovers.isEmpty else { return }
            self.gate.end(.sheet)
        })
    }

    private func signal(_ e: NSEvent) {
        guard e.window === window else { return }
        switch e.type {
        case .scrollWheel:
            // A wheel has no end event. The scroll ends 0.3 s after the last wheel event, momentum included.
            gate.begin(.scroll)
            wheelEnd?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.gate.end(.scroll) }
            wheelEnd = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        case .leftMouseDown, .rightMouseDown: gate.begin(.mouse)
        case .leftMouseUp, .rightMouseUp: gate.end(.mouse)
        default: break
        }
    }

    // While an update waits, a lost mouse up must not hold it for ever.
    private func watchHold(_ on: Bool) {
        holdCheck?.invalidate()
        holdCheck = nil
        guard on else { return }
        holdCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if NSEvent.pressedMouseButtons == 0 { self?.gate.end(.mouse) }
        }
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
    private let updateId = NSToolbarItem.Identifier("update")
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
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + [updateId] }

    // The "Update ready" chip shows only while a downloaded update waits for a click.
    private func syncUpdateItem() {
        guard let tb = window?.toolbar else { return }
        let at = tb.items.firstIndex { $0.itemIdentifier == updateId }
        if let at { tb.removeItem(at: at) }
        guard data.updater.readyVersion != nil, let p = tb.items.firstIndex(where: { $0.itemIdentifier == paletteId }) else { return }
        tb.insertItem(withItemIdentifier: updateId, at: p)
    }

    @objc private func openUpdates() { router.go(.settings(.general, anchor: SettingsAnchor.startup.rawValue)) }

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
        case updateId:
            let i = NSToolbarItem(itemIdentifier: id)
            let v = data.updater.readyVersion ?? ""
            let b = NSButton(title: "Update ready · v\(v)", target: self, action: #selector(openUpdates))
            b.bezelStyle = .texturedRounded
            b.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.contentTintColor = Palette.ok
            b.toolTip = "v\(v) is downloaded and verified. Open Settings › General to install."
            b.setAccessibilityLabel("Update ready, version \(v). Open the update settings")
            i.view = b
            i.label = "Update ready"
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
        let mine = store.snapshots.values.reduce(0) { n, s in
            n + s.rootItems.filter { $0.isMine(s.me) && !s.isFinished($0) }.count
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
            e(.home, "Home", "house", alert: NeedsYou.collect(data).count, tone: Palette.bad, what: "need you"),
            e(.work(.items), "Work", "person.crop.circle", badge: mine, alert: waiting, tone: Palette.warn, what: "need input"),
            e(.runs(.all), "Runs", "play.circle", badge: running, alert: failing, tone: Palette.bad, what: "failing"),
            e(.prs, "Pull requests", "arrow.triangle.pull", badge: prs),
            e(.insights, "Insights", "chart.bar"),
        ]
        // Intake needs a tracker with intake.
        if data.has(.intake) { out.insert(e(.intake(nil), "Intake", "tray.and.arrow.down", badge: intake, alert: intake, tone: Palette.intake, what: "wait for triage"), at: 2) }
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
        out.append(e(.activity, "Activity", "clock.arrow.circlepath"))
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
        case .intake: return IntakeListPage(r, data: data, router: router)
        case .activity: return ActivityPage(r, data: data, router: router)
        case .work(.items): return WorkPage(r, data: data, router: router)
        case .work(.worktrees): return AgentsPage(r, data: data, router: router)
        case .work(.lanes): return QueuePage(r, data: data, router: router)
        case .project: return ProjectPage(r, data: data, router: router)
        case .projectSettings: return ProjectSettingsPage(r, data: data, router: router)
        case .item: return ItemPage(r, data: data, router: router)
        case .runs: return RunsPage(r, data: data, router: router)
        case .run: return RunPage(r, data: data, router: router)
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

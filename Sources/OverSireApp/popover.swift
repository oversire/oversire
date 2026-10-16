import Cocoa

// ─── Tab View ────────────────────────────────────────────────────────────────

enum Tab: Int, CaseIterable {
    case actions, prs, projects, insights

    var title: String {
        switch self {
        case .actions: return "Actions"
        case .prs: return "PRs"
        case .projects: return "Projects"
        case .insights: return "Insights"
        }
    }

    var isVisible: Bool {
        switch self {
        case .actions: return TABS.actions
        case .prs: return TABS.prs
        case .projects: return PROJECTS_CFG.showTab
        case .insights: return TABS.insights
        }
    }

    static var visible: [Tab] {
        let tabs = allCases.filter(\.isVisible)
        return tabs.isEmpty ? [.actions] : tabs
    }
}

let TAB_H: CGFloat = 36
let SUB_H: CGFloat = 32

class TabVC: NSViewController {
    var grouped: [(String, [Run])]
    var prGrouped: [(String, [PR])]
    var updated: Date
    var loading: Bool
    var selectedTab: Tab
    var selectedRepo: String?
    var expandedPR: String?
    var expandedRun: String?
    var expandedItem: String?
    var projectView: ProjectView = PROJECTS_CFG.defaultView
    var assignedOnly = false
    var unreadOnly = false
    var statusFilter: [String: String] = [:]
    var showAllProjects: Set<String> = []
    var selectedProject: String?
    var projectQuery = ""
    var projectNotice: String?
    var sheet: NewItemSheet?
    var searchField: NSSearchField?
    var keyMonitor: Any?
    var dragLine: NSView?
    var dragTarget: Int?
    var scrollView: NSScrollView!
    var doc: Flipped!
    var footerView: NSView!

    var showsSubBar: Bool { selectedTab == .actions || selectedTab == .projects }
    var chrome: CGFloat { TAB_H + (showsSubBar ? SUB_H : 0) }

    init(grouped: [(String, [Run])], prGrouped: [(String, [PR])], updated: Date, loading: Bool,
         tab: Tab, repo: String?, expandedPR: String? = nil) {
        self.grouped = grouped; self.prGrouped = prGrouped
        self.updated = updated; self.loading = loading
        self.selectedTab = tab; self.selectedRepo = repo; self.expandedPR = expandedPR
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let w = POP_W
        let container = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: POP_MAX_H))
        container.wantsLayer = true

        // ── Top bar: tabs + repo or project filter ──
        let topBar = NSView(frame: NSRect(x: 0, y: 0, width: w, height: TAB_H))
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor

        let tabs = Tab.visible
        let unread = (NSApp.delegate as? GHActionsBar)?.projectStore.unreadCount() ?? 0
        let labels = tabs.map { tab -> String in
            if tab == .projects && unread > 0 { return "Projects \(unread)" }
            return tab.title
        }
        let seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        seg.selectedSegment = tabs.firstIndex(of: selectedTab) ?? 0
        seg.frame = NSRect(x: 8, y: 6, width: min(420, w - 200), height: 24)
        seg.font = .systemFont(ofSize: 11, weight: .medium)
        topBar.addSubview(seg)
        buildFilterPopup(in: topBar, w: w)
        container.addSubview(topBar)
        if showsSubBar { container.addSubview(subBar(w)) }

        // ── Footer (fixed at bottom) ──
        let footer = Footer(w, updated: updated)

        // ── Scroll content ──
        let scrollH = POP_MAX_H - chrome - FTR_H
        scrollView = NSScrollView(frame: NSRect(x: 0, y: chrome, width: w, height: scrollH))
        scrollView.hasVerticalScroller = true; scrollView.drawsBackground = false; scrollView.autohidesScrollers = true
        doc = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: scrollH))
        doc.wantsLayer = true
        doc.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        scrollView.documentView = doc
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        container.addSubview(scrollView)

        container.addSubview(footer)
        footerView = footer
        self.view = container
        rebuildContent()
    }

    // Shows fresh data in the open panel. Keeps the expanded row and the scroll position.
    func update(grouped: [(String, [Run])], prGrouped: [(String, [PR])], updated: Date, loading: Bool) {
        self.grouped = grouped; self.prGrouped = prGrouped
        self.updated = updated; self.loading = loading
        guard isViewLoaded else { return }
        (footerView as? Footer)?.showUpdated(updated)
        if dragLine != nil { return }
        JobSummary.close()  // the rebuild removes its chip
        rebuildContent()
    }

    // Keeps the scroll position. With `anchor`, that row keeps its place on screen.
    // With `reveal`, that row scrolls into view, but the anchor row stays visible.
    func rebuildContent(anchor: String? = nil, reveal: String? = nil) {
        func row(_ id: String?) -> NSView? { id.flatMap { id in doc.subviews.first { $0.identifier?.rawValue == id } } }
        var top = scrollView.contentView.bounds.origin.y
        let anchorOffset = row(anchor).map { $0.frame.minY - top }
        NSApp.withPinnedAppearance {
            doc.subviews.forEach { $0.removeFromSuperview() }
            let w = POP_W
            var rows: [NSView] = []

            switch selectedTab {
            case .projects:
                rows = buildProjectsContent(w)
            case .actions where REPOS.isEmpty, .prs where REPOS.isEmpty, .insights where REPOS.isEmpty:
                rows.append(EmptyRow("No repos configured. Open Settings to get started.", w: w, icon: "gearshape"))
            case .actions:
                rows = buildActionsContent(w)
            case .prs:
                rows = buildPRContent(w)
            case .insights:
                rows = buildInsightsContent(w)
            }

            var y: CGFloat = 0
            for row in rows { row.frame.origin = NSPoint(x: 0, y: y); doc.addSubview(row); y += row.frame.height }
            doc.frame.size.height = max(y, 60)
            relayout()
        }
        let visH = scrollView.contentView.bounds.height
        if let a = row(anchor), let off = anchorOffset { top = a.frame.minY - off }
        if let r = row(reveal), r.frame.maxY > top + visH {
            top = min(r.frame.maxY - visH, row(anchor)?.frame.minY ?? r.frame.minY)
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, top), max(0, doc.frame.height - visH))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // Resize the scroll area / footer / popover to fit the content, so inline
    // expansions grow the popover instead of forcing a scroll.
    func relayout() {
        guard footerView != nil else { return }
        let scrollHMax = POP_MAX_H - chrome - FTR_H
        let visScrollH = min(doc.frame.height, scrollHMax)
        scrollView.frame.origin.y = chrome
        scrollView.frame.size.height = visScrollH
        footerView.frame.origin.y = chrome + visScrollH
        var totalH = chrome + visScrollH + FTR_H
        if let sheet {
            totalH = max(totalH, sheet.cardHeight)
            sheet.frame = NSRect(x: 0, y: 0, width: POP_W, height: totalH)
        }
        view.frame.size.height = totalH
        preferredContentSize = NSSize(width: POP_W, height: totalH)
        // An open popover does not always shrink to a new preferredContentSize.
        if let pop = (NSApp.delegate as? GHActionsBar)?.popover, pop.contentViewController === self, pop.isShown {
            pop.contentSize = preferredContentSize
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window == self.view.window, self.sheet == nil, self.selectedTab == .projects else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 53, self.view.window?.firstResponder === self.searchField?.currentEditor(), !self.projectQuery.isEmpty {
                self.searchField?.stringValue = ""
                self.projectQuery = ""
                (NSApp.delegate as? GHActionsBar)?.projectQuery = ""
                self.rebuildContent()
                return nil
            }
            guard mods == .command else { return e }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "n": self.presentNewItem(target: self.selectedProject, prefill: nil); return nil
            case "f": self.view.window?.makeFirstResponder(self.searchField); return nil
            default: return e
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // ⌘N or "+": the sheet sits over the list. `target` nil lets AI pick the project.
    func presentNewItem(target: String?, prefill: String?, suggest: Bool = false) {
        guard let app = NSApp.delegate as? GHActionsBar else { return }
        let projects = app.projectCatalog.resolve(PROJECTS_CFG).filter { app.projectStore.snapshots[$0.ref.key] != nil }
        guard !projects.isEmpty else { return }
        sheet?.removeFromSuperview()
        let s = NewItemSheet(store: app.projectStore, projects: projects, target: target, prefill: prefill, w: POP_W)
        s.onClose = { [weak self] key, notice in self?.closeNewItem(key: key, notice: notice) }
        s.onResize = { [weak self] in self?.relayout() }
        view.addSubview(s)
        sheet = s
        app.popover.behavior = .semitransient
        relayout()
        s.focus()
        if suggest && s.aiDraft && !s.body.isEmpty { s.suggest() }
    }

    func closeNewItem(key: String?, notice: String?) {
        sheet?.removeFromSuperview()
        sheet = nil
        let app = NSApp.delegate as? GHActionsBar
        app?.popover.behavior = .transient
        if let key, PROJECTS_CFG.isFolded(key) {
            PROJECTS_CFG.setFolded(key, false)
            saveConfig()
        }
        if let notice {
            projectNotice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.projectNotice == notice else { return }
                self.projectNotice = nil
                self.rebuildContent()
            }
        }
        rebuildContent()
    }


    func buildFilterPopup(in topBar: NSView, w: CGFloat) {
        let popup = NSPopUpButton(frame: NSRect(x: w - 188, y: 6, width: 176, height: 24), pullsDown: false)
        popup.font = .systemFont(ofSize: 11)
        if selectedTab == .projects {
            popup.addItem(withTitle: "All projects")
            let projects = (NSApp.delegate as? GHActionsBar)?.projectCatalog.resolve(PROJECTS_CFG) ?? []
            var lastWorkspace = ""
            for p in projects {
                if p.ref.workspace != lastWorkspace {
                    let head = NSMenuItem(title: p.ref.workspace, action: nil, keyEquivalent: "")
                    head.isEnabled = false
                    popup.menu?.addItem(head)
                    lastWorkspace = p.ref.workspace
                }
                let item = NSMenuItem(title: "  " + p.title, action: nil, keyEquivalent: "")
                item.representedObject = p.ref.key
                popup.menu?.addItem(item)
                if selectedProject == p.ref.key { popup.select(item) }
            }
            if selectedProject == nil { popup.selectItem(at: 0) }
            popup.action = #selector(projectChanged(_:))
        } else {
            popup.addItem(withTitle: "All Repos")
            for repo in REPOS { popup.addItem(withTitle: repo) }
            if let sel = selectedRepo, let idx = REPOS.firstIndex(of: sel) { popup.selectItem(at: idx + 1) }
            else { popup.selectItem(at: 0) }
            popup.action = #selector(repoChanged(_:))
        }
        popup.target = self
        topBar.addSubview(popup)
    }

    func subBar(_ w: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: TAB_H, width: w, height: SUB_H))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.75).cgColor
        if selectedTab == .actions {
            let cb = NSButton(checkboxWithTitle: "Default only", target: self, action: #selector(toggleBranchFilter(_:)))
            cb.font = .systemFont(ofSize: 11)
            cb.state = FILTER_DEFAULT_BRANCHES ? .on : .off
            cb.frame = NSRect(x: 12, y: 6, width: 110, height: 20)
            cb.toolTip = "Hide workflow runs from branches other than main or develop"
            bar.addSubview(cb)
            let sortCB = NSButton(checkboxWithTitle: "Recent first", target: self, action: #selector(toggleSortByRecent(_:)))
            sortCB.font = .systemFont(ofSize: 11)
            sortCB.state = SORT_BY_RECENT ? .on : .off
            sortCB.frame = NSRect(x: 130, y: 6, width: 110, height: 20)
            sortCB.toolTip = "Show each run in its own row, newest first. Turn off to group the workflows of one commit."
            bar.addSubview(sortCB)
        } else {
            let seg = NSSegmentedControl(labels: ["By project", "Activity"], trackingMode: .selectOne,
                                         target: self, action: #selector(projectViewChanged(_:)))
            seg.selectedSegment = projectView == .activity ? 1 : 0
            seg.font = .systemFont(ofSize: 11)
            seg.frame = NSRect(x: 8, y: 4, width: 180, height: 24)
            bar.addSubview(seg)
            let mine = NSButton(checkboxWithTitle: "Assigned to me", target: self, action: #selector(toggleAssigned(_:)))
            mine.font = .systemFont(ofSize: 11)
            mine.state = assignedOnly ? .on : .off
            mine.frame = NSRect(x: 200, y: 6, width: 120, height: 20)
            bar.addSubview(mine)
            let unread = NSButton(checkboxWithTitle: "Unread only", target: self, action: #selector(toggleUnread(_:)))
            unread.font = .systemFont(ofSize: 11)
            unread.state = unreadOnly ? .on : .off
            unread.frame = NSRect(x: 326, y: 6, width: 104, height: 20)
            bar.addSubview(unread)
            let search = NSSearchField(frame: NSRect(x: 436, y: 5, width: w - 436 - 44, height: 22))
            search.placeholderString = "Filter  ⌘F"
            search.font = .systemFont(ofSize: 11)
            search.stringValue = projectQuery
            search.sendsSearchStringImmediately = true
            search.target = self; search.action = #selector(queryChanged(_:))
            search.isEnabled = projectView == .board
            bar.addSubview(search)
            searchField = search
            let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New item")!,
                               target: self, action: #selector(newItem))
            // A rounded bezel has a minimum width and draws too thin here.
            add.isBordered = false
            add.wantsLayer = true
            add.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            add.layer?.cornerRadius = 6
            add.contentTintColor = .white
            add.symbolConfiguration = .init(pointSize: 12, weight: .bold)
            add.frame = NSRect(x: w - 36, y: 5, width: 28, height: 22)
            add.toolTip = "New item (⌘N)"
            bar.addSubview(add)
        }
        return bar
    }

    @objc func tabChanged(_ sender: NSSegmentedControl) {
        let tabs = Tab.visible
        let idx = min(max(0, sender.selectedSegment), tabs.count - 1)
        selectedTab = tabs[idx]
        // Reassigning contentViewController is what NSPopover observes at show time;
        // calling loadView() alone leaves stale tab body visible in an already-shown popover.
        let appDel = NSApp.delegate as? GHActionsBar
        rememberProjectUI()
        appDel?.selectedTab = selectedTab
        appDel?.selectedRepo = selectedRepo
        expandedPR = nil
        expandedRun = nil
        appDel?.applySystemAppearance()
        appDel?.buildWithAppearance { appDel?.popover.contentViewController = appDel?.makeTabVC() }
    }

    func rememberProjectUI() {
        let app = NSApp.delegate as? GHActionsBar
        app?.projectView = projectView
        app?.projectAssignedOnly = assignedOnly
        app?.projectUnreadOnly = unreadOnly
        app?.expandedItem = expandedItem
        app?.selectedProject = selectedProject
        app?.projectStatusFilter = statusFilter
        app?.projectShowAll = showAllProjects
    }

    @objc func projectViewChanged(_ sender: NSSegmentedControl) {
        projectView = sender.selectedSegment == 1 ? .activity : .board
        rememberProjectUI()
        rebuildContent()
    }
    @objc func queryChanged(_ sender: NSSearchField) {
        projectQuery = sender.stringValue
        (NSApp.delegate as? GHActionsBar)?.projectQuery = projectQuery
        rebuildContent()
    }
    @objc func newItem() { presentNewItem(target: selectedProject, prefill: nil) }
    @objc func toggleAssigned(_ sender: NSButton) {
        assignedOnly = sender.state == .on
        rememberProjectUI()
        rebuildContent()
    }
    @objc func toggleUnread(_ sender: NSButton) {
        unreadOnly = sender.state == .on
        rememberProjectUI()
        rebuildContent()
    }
    @objc func projectChanged(_ sender: NSPopUpButton) {
        selectedProject = sender.selectedItem?.representedObject as? String
        rememberProjectUI()
        expandedItem = nil
        rebuildContent()
    }

    @objc func toggleBranchFilter(_ sender: NSButton) {
        FILTER_DEFAULT_BRANCHES = (sender.state == .on)
        saveConfig()
        rebuildContent()
        let appDel = NSApp.delegate as? GHActionsBar
        appDel?.updateIcon()
        // Cadence follows visibility too, so filtering a branch out stops the fast poll.
        appDel?.scheduleTimer()
    }

    @objc func scrolled(_ note: Notification) {
        for row in doc.subviews {
            (row as? RunRow)?.syncHover()
            (row as? PRRow)?.syncHover()
        }
        // Project rows can be inside group views.
        func projectRows(_ v: NSView) {
            for s in v.subviews { if let r = s as? ProjectItemRow { r.syncHover() } else { projectRows(s) } }
        }
        projectRows(doc)
    }

    @objc func toggleSortByRecent(_ sender: NSButton) {
        SORT_BY_RECENT = (sender.state == .on)
        saveConfig()
        rebuildContent()
    }

    @objc func repoChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 {
            selectedRepo = nil
        } else {
            let idx = sender.indexOfSelectedItem - 1
            if idx < REPOS.count { selectedRepo = REPOS[idx] }
        }
        (NSApp.delegate as? GHActionsBar)?.selectedRepo = selectedRepo
        expandedPR = nil
        expandedRun = nil
        rebuildContent()
    }
}


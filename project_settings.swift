import Cocoa

// Settings → Projects: Plane workspaces, which projects to track, notifications,
// display, and the poll interval.
final class ProjectSettingsVC: NSViewController {
    let catalog: ProjectCatalog
    let store: ProjectStore
    let accounts: PlaneAccounts
    var cfg: ProjectsConfig
    var slugField: NSTextField?
    var tokenField: NSSecureTextField?
    var hostField: NSTextField?
    static var addStatus: (text: String, error: Bool)?
    static var testing = false
    var filterField: NSTextField?
    var doc: Flipped?
    var scroll: NSScrollView?
    var observer: NSObjectProtocol?
    var shortcutField: ShortcutField?
    static var captureError: String?
    static var expanded: Set<String> = []

    init(catalog: ProjectCatalog, store: ProjectStore, accounts: PlaneAccounts, cfg: ProjectsConfig) {
        self.catalog = catalog
        self.store = store
        self.accounts = accounts
        self.cfg = cfg
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override func loadView() {
        let w = POP_W
        let container = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: POP_MAX_H))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        container.addSubview(SettingsNav(w: w, selected: .projects))
        container.addSubview(SeparatorLine(y: 44, w: w))
        scroll = NSScrollView(frame: NSRect(x: 0, y: 44.5, width: w, height: POP_MAX_H - 44.5))
        scroll?.hasVerticalScroller = true
        scroll?.drawsBackground = false
        scroll?.autohidesScrollers = true
        doc = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        scroll?.documentView = doc
        container.addSubview(scroll!)
        view = container
        preferredContentSize = NSSize(width: w, height: POP_MAX_H)
        observer = NotificationCenter.default.addObserver(forName: ProjectCatalog.changed, object: catalog, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
        catalog.refreshIfStale()
    }

    func rebuild() {
        guard let doc = doc else { return }
        NSApp.withPinnedAppearance {
            doc.subviews.forEach { $0.removeFromSuperview() }
            let w = POP_W
            var y: CGFloat = 0
            y = header("PLANE WORKSPACES", y: y, button: nil)
            y = workspaceSection(y: y, w: w, in: doc)
            y = header("PROJECTS TO TRACK", y: y, button: ("Refresh all", #selector(refreshAll)))
            let filter = NSTextField(frame: NSRect(x: 16, y: y + 4, width: w - 32, height: 22))
            filter.placeholderString = "Filter projects"
            filter.font = .systemFont(ofSize: 12)
            filter.stringValue = filterField?.stringValue ?? ""
            filter.target = self; filter.action = #selector(filterChanged)
            doc.addSubview(filter); filterField = filter
            y += 32
            y = tree(y: y, w: w, in: doc)
            y += 8
            y = header("NOTIFY ME WHEN", y: y, button: nil)
            y = matrix(y: y, w: w, in: doc)
            y = header("DISPLAY", y: y, button: nil)
            y = display(y: y, w: w, in: doc)
            y = header("REFRESH", y: y, button: nil)
            y = refreshSection(y: y, w: w, in: doc)
            y = header("QUICK CAPTURE", y: y, button: nil)
            y = captureSection(y: y, w: w, in: doc)
            y = header("ORCA", y: y, button: nil)
            y = orcaSection(y: y, w: w, in: doc)
            let save = NSButton(title: "Save & Apply", target: self, action: #selector(doSave))
            save.bezelStyle = .inline; save.font = .systemFont(ofSize: 12, weight: .semibold)
            save.frame = NSRect(x: w / 2 - 60, y: y + 12, width: 120, height: 28)
            doc.addSubview(save)
            y += 52
            doc.frame.size.height = y
        }
    }

    func header(_ title: String, y: CGFloat, button: (String, Selector)?) -> CGFloat {
        let hdr = SettingsHeader(title, y: y, w: POP_W)
        if let (t, sel) = button {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .inline; b.font = .systemFont(ofSize: 10)
            b.frame = NSRect(x: POP_W - 96, y: 4, width: 84, height: 20)
            b.isEnabled = !catalog.workspaces.isEmpty
            hdr.addSubview(b)
        }
        doc?.addSubview(hdr)
        return y + 28
    }

    func workspaceSection(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        var y = y
        for ws in accounts.workspaces {
            let host = ws.host == PlaneWorkspace.cloudHost ? "Plane Cloud" : ws.host
            let token = accounts.hasToken(ws.slug) ? "token in Keychain" : "no token"
            let l = NSTextField(labelWithString: "\(ws.slug)  ·  \(host)  ·  \(token)")
            l.font = .systemFont(ofSize: 12)
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: 16, y: y + 3, width: w - 170, height: 18)
            doc.addSubview(l)
            let open = NSButton(title: "Open", target: self, action: #selector(openWorkspace(_:)))
            open.bezelStyle = .inline; open.font = .systemFont(ofSize: 11)
            open.frame = NSRect(x: w - 146, y: y + 2, width: 60, height: 20)
            open.identifier = NSUserInterfaceItemIdentifier(ws.slug)
            doc.addSubview(open)
            let rm = NSButton(title: "Remove", target: self, action: #selector(removeWorkspace(_:)))
            rm.bezelStyle = .inline; rm.font = .systemFont(ofSize: 11)
            rm.frame = NSRect(x: w - 80, y: y + 2, width: 66, height: 20)
            rm.identifier = NSUserInterfaceItemIdentifier(ws.slug)
            doc.addSubview(rm)
            y += 26
        }
        let slug = NSTextField(frame: NSRect(x: 16, y: y + 4, width: 150, height: 22))
        slug.placeholderString = "Workspace slug"
        slug.toolTip = "The part after the host in the Plane URL, for example app.plane.so/<slug>/"
        slug.stringValue = slugField?.stringValue ?? ""
        let token = NSSecureTextField(frame: NSRect(x: 172, y: y + 4, width: 170, height: 22))
        token.placeholderString = "API token"
        token.toolTip = "Plane → Profile settings → Personal access tokens. A token works only in its own workspace."
        token.stringValue = tokenField?.stringValue ?? ""
        let host = NSTextField(frame: NSRect(x: 348, y: y + 4, width: w - 348 - 112, height: 22))
        host.placeholderString = PlaneWorkspace.cloudHost
        host.toolTip = "Change it only for a self-hosted Plane"
        host.stringValue = hostField?.stringValue ?? ""
        for f in [slug, token, host] as [NSTextField] { f.font = .systemFont(ofSize: 12); doc.addSubview(f) }
        slugField = slug; tokenField = token; hostField = host
        let add = NSButton(title: ProjectSettingsVC.testing ? "Testing…" : "Test & Add", target: self, action: #selector(addWorkspace))
        add.bezelStyle = .rounded; add.font = .systemFont(ofSize: 11)
        add.frame = NSRect(x: w - 108, y: y + 2, width: 96, height: 26)
        add.isEnabled = !ProjectSettingsVC.testing
        doc.addSubview(add)
        y += 30
        let note = ProjectSettingsVC.addStatus
            ?? (accounts.workspaces.isEmpty ? ("Add one workspace for each token. OverSire keeps the tokens in the Keychain.", false) : nil)
        if let note {
            let l = NSTextField(labelWithString: note.text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = note.error ? C_FAILURE : .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
            l.toolTip = note.text
            l.frame = NSRect(x: 16, y: y, width: w - 32, height: 16)
            doc.addSubview(l)
            y += 20
        }
        return y + 6
    }

    func tree(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        var y = y
        let q = (filterField?.stringValue ?? "").lowercased()
        let workspaces = catalog.workspaces
        if workspaces.isEmpty {
            let l = NSTextField(labelWithString: "Add a Plane workspace above.")
            l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 16, y: y + 4, width: w - 32, height: 18)
            doc.addSubview(l)
            return y + 28
        }
        for ws in workspaces {
            let slug = ws.slug
            let projects = cfg.sorted(catalog.projects(of: slug)).filter { p in
                q.isEmpty || p.title.lowercased().contains(q) || p.identifier.lowercased().contains(q) || slug.lowercased().contains(q)
            }
            if !q.isEmpty && projects.isEmpty && !slug.lowercased().contains(q) { continue }
            let open = ProjectSettingsVC.expanded.contains(slug) || !q.isEmpty
            let disc = NSButton(frame: NSRect(x: 10, y: y + 4, width: 16, height: 16))
            disc.bezelStyle = .disclosure; disc.setButtonType(.pushOnPushOff); disc.title = ""
            disc.state = open ? .on : .off
            disc.target = self; disc.action = #selector(toggleExpand(_:))
            disc.identifier = NSUserInterfaceItemIdentifier(slug)
            doc.addSubview(disc)
            let countLabel: String
            switch catalog.fetch(slug) {
            case .loading: countLabel = "…"
            case .failed: countLabel = "failed"
            case .idle: countLabel = "\(projects.count)"
            }
            let cb = NSButton(checkboxWithTitle: " \(slug)  ·  \(countLabel)", target: self, action: #selector(toggleAll(_:)))
            cb.font = .systemFont(ofSize: 12, weight: .semibold)
            cb.state = cfg.allOf.contains(slug) ? .on : .off
            cb.toolTip = "Track all, also new ones"
            cb.frame = NSRect(x: 30, y: y + 2, width: 280, height: 22)
            cb.identifier = NSUserInterfaceItemIdentifier(slug)
            doc.addSubview(cb)
            let rb = NSButton(frame: NSRect(x: w - 36, y: y + 2, width: 22, height: 20))
            rb.bezelStyle = .inline; rb.isBordered = false
            rb.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh \(slug)")
            rb.target = self; rb.action = #selector(refreshOwner(_:))
            rb.identifier = NSUserInterfaceItemIdentifier(slug)
            doc.addSubview(rb)
            y += 26
            guard open else { continue }
            let live = isLive(slug)
            for p in projects {
                let row = NSButton(checkboxWithTitle: " \(p.title)  \(p.identifier)", target: self, action: #selector(toggleProject(_:)))
                row.font = .systemFont(ofSize: 12)
                row.identifier = NSUserInterfaceItemIdentifier(p.ref.key)
                let on = cfg.allOf.contains(slug) || cfg.picked.contains(p.ref.key)
                row.state = on && !p.closed ? .on : .off
                row.isEnabled = !p.closed
                row.frame = NSRect(x: 52, y: y, width: w - 180, height: 22)
                if p.closed { row.alphaValue = 0.45 }
                doc.addSubview(row)
                let chip = Badge(live ? "Live" : "\(cfg.pollMinutes) min")
                chip.frame.origin = NSPoint(x: w - 90, y: y + 1)
                doc.addSubview(chip)
                y += 22
            }
            if projects.isEmpty {
                let text: String
                let color: NSColor
                switch catalog.fetch(slug) {
                case .loading:
                    text = "Loading projects…"
                    color = .secondaryLabelColor
                case .failed(let msg):
                    text = msg
                    color = .systemRed
                case .idle:
                    text = "No projects"
                    color = .secondaryLabelColor
                }
                let l = NSTextField(labelWithString: text)
                l.font = .systemFont(ofSize: 12)
                l.textColor = color
                l.lineBreakMode = .byTruncatingTail
                l.toolTip = text
                l.frame = NSRect(x: 54, y: y + 2, width: w - 80, height: 18)
                doc.addSubview(l)
                y += 22
            }
            y += 4
        }
        return y
    }

    func isLive(_ slug: String) -> Bool {
        let st = (NSApp.delegate as? GHActionsBar)?.cloudSetup.hooks.statuses["plane:\(slug)"]
        if case .live = st { return true }
        if case .waiting = st { return true }
        return false
    }

    @objc func addWorkspace() {
        let slug = (slugField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let token = (tokenField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var host = (hostField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") { host.removeLast() }
        if host.isEmpty { host = PlaneWorkspace.cloudHost }
        guard !slug.isEmpty, !slug.contains("/"), !token.isEmpty else {
            ProjectSettingsVC.addStatus = ("Type the workspace slug and the token.", true)
            rebuild(); return
        }
        guard host.hasPrefix("https://") || host.hasPrefix("http://") else {
            ProjectSettingsVC.addStatus = ("The host must start with https://", true)
            rebuild(); return
        }
        let ws = PlaneWorkspace(slug: slug, host: host)
        ProjectSettingsVC.testing = true
        ProjectSettingsVC.addStatus = ("Testing the token…", false)
        rebuild()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let client = PlaneClient(workspace: ws, token: token)
            let result = client.me().flatMap { me in client.projects().map { (me.name, $0.count) } }
            DispatchQueue.main.async {
                ProjectSettingsVC.testing = false
                guard let self = self else { return }
                switch result {
                case .success(let (name, count)):
                    self.accounts.save(ws, token: token)
                    self.cfg.workspaces = PROJECTS_CFG.workspaces
                    ProjectSettingsVC.addStatus = ("Added \(slug) as \(name). \(count) projects. Pick them below.", false)
                    ProjectSettingsVC.expanded.insert(slug)
                    self.slugField?.stringValue = ""; self.tokenField?.stringValue = ""; self.hostField?.stringValue = ""
                    self.catalog.refresh(slug, force: true)
                    (NSApp.delegate as? GHActionsBar)?.applyProjectSelection()
                case .failure(let e):
                    ProjectSettingsVC.addStatus = ("\(slug): \(e.message) Nothing was saved.", true)
                }
                self.rebuild()
            }
        }
    }

    @objc func removeWorkspace(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the workspace \(slug)?"
        alert.informativeText = "OverSire deletes the token from the Keychain and stops to track its projects. OverSire also deletes its Plane webhook, if it has one."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let app = NSApp.delegate as? GHActionsBar
        app?.cloudSetup.removePlaneHook(slug)
        accounts.remove(slug)
        cfg.workspaces = PROJECTS_CFG.workspaces
        cfg.allOf.removeAll { $0 == slug }
        cfg.picked.removeAll { $0.hasPrefix(slug + "/") }
        ProjectSettingsVC.addStatus = nil
        app?.applyProjectSelection()
        rebuild()
    }

    @objc func openWorkspace(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue, let ws = accounts.workspace(slug), let url = URL(string: ws.url) else { return }
        NSWorkspace.shared.open(url)
    }

    func matrix(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        var y = y
        let heads = NSTextField(labelWithString: "Any item")
        heads.font = .systemFont(ofSize: 10, weight: .semibold); heads.textColor = .secondaryLabelColor
        heads.frame = NSRect(x: w - 180, y: y, width: 70, height: 14)
        doc.addSubview(heads)
        let mine = NSTextField(labelWithString: "My items")
        mine.font = .systemFont(ofSize: 10, weight: .semibold); mine.textColor = .secondaryLabelColor
        mine.frame = NSRect(x: w - 100, y: y, width: 70, height: 14)
        doc.addSubview(mine)
        y += 18
        let rows: [(String, String, Bool, Bool)] = [
            ("Someone mentions me", "mention", false, cfg.notifications.mention),
            ("New comment", "comment", cfg.notifications.comment.any, cfg.notifications.comment.mine),
            ("Status changes", "status", cfg.notifications.status.any, cfg.notifications.status.mine),
            ("Item is added to a project", "added", cfg.notifications.added.any, cfg.notifications.added.mine),
            ("Item is assigned to me", "assigned", false, cfg.notifications.assigned),
            ("Item is closed or set to Done", "closed", cfg.notifications.closed.any, cfg.notifications.closed.mine),
            ("Other field changes", "other", cfg.notifications.otherFields.any, cfg.notifications.otherFields.mine),
            ("Intake item is new, changed or closed", "intake", cfg.notifications.intake, false),
            ("Orca session needs input", "agentWaiting", cfg.notifications.agentWaiting, false),
            ("Orca session is done", "agentDone", cfg.notifications.agentDone, false),
        ]
        let anyDisabled: Set<String> = ["mention", "assigned"]
        let mineDisabled: Set<String> = ["intake", "agentWaiting", "agentDone"]
        for row in rows {
            let l = NSTextField(labelWithString: row.0)
            l.font = .systemFont(ofSize: 12)
            l.frame = NSRect(x: 16, y: y, width: w - 220, height: 18)
            doc.addSubview(l)
            let any = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleNotify(_:)))
            any.identifier = NSUserInterfaceItemIdentifier(row.1 + ":any")
            any.state = row.2 ? .on : .off
            any.isEnabled = !anyDisabled.contains(row.1)
            any.frame = NSRect(x: w - 164, y: y - 2, width: 24, height: 20)
            doc.addSubview(any)
            let my = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleNotify(_:)))
            my.identifier = NSUserInterfaceItemIdentifier(row.1 + ":mine")
            my.state = row.3 ? .on : .off
            my.isHidden = mineDisabled.contains(row.1)
            my.frame = NSRect(x: w - 84, y: y - 2, width: 24, height: 20)
            doc.addSubview(my)
            y += 24
        }
        return y + 4
    }

    func display(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        var y = y
        y = popupRow("Default view", ["Board", "Activity"], cfg.defaultView == .activity ? 1 : 0, #selector(viewChanged(_:)), y: y, in: doc)
        let itemIdx = cfg.itemsPerProject == 0 ? 2 : (cfg.itemsPerProject == 25 ? 1 : 0)
        y = popupRow("Items per project", ["10", "25", "All"], itemIdx, #selector(itemsChanged(_:)), y: y, in: doc)
        let hideIdx = ProjectSettingsVC.hideDays.firstIndex(of: cfg.hideDoneAfterDays) ?? 1
        y = popupRow("Hide Done items", ["Always", "Older than 1 day", "Older than 7 days", "Older than 30 days", "Never"],
                     hideIdx, #selector(hideChanged(_:)), y: y, in: doc)
        let dot = NSButton(checkboxWithTitle: "Show a blue dot on the menu bar icon", target: self, action: #selector(toggleDot(_:)))
        dot.font = .systemFont(ofSize: 12)
        dot.state = cfg.menuDot ? .on : .off
        dot.frame = NSRect(x: 16, y: y, width: w - 32, height: 22)
        doc.addSubview(dot)
        let sub = NSButton(checkboxWithTitle: "List sub-items as rows (an open item always shows its sub-items)",
                           target: self, action: #selector(toggleSubItems(_:)))
        sub.font = .systemFont(ofSize: 12)
        sub.state = cfg.showSubItems ? .on : .off
        sub.frame = NSRect(x: 16, y: y + 28, width: w - 32, height: 22)
        doc.addSubview(sub)
        return y + 56
    }

    func refreshSection(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        let idx = [2, 5, 10, 15, 30].firstIndex(of: cfg.pollMinutes) ?? 1
        let y = popupRow("Poll projects without live updates every", ["2 min", "5 min", "10 min", "15 min", "30 min"], idx, #selector(pollChanged(_:)), y: y, in: doc)
        let help = NSTextField(wrappingLabelWithString: "A Plane webhook covers a whole workspace. Settings → Live updates adds it, if you are an admin of the workspace. Workspaces without a webhook use this interval. Live projects also use it when the relay is disconnected.")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 16, y: y, width: w - 32, height: 44)
        doc.addSubview(help)
        return y + 48
    }

    func captureSection(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        var y = y + 4
        let sw = NSSwitch(frame: NSRect(x: 16, y: y, width: 40, height: 22))
        sw.state = cfg.capture.enabled ? .on : .off
        sw.target = self; sw.action = #selector(toggleCapture(_:))
        doc.addSubview(sw)
        let l = NSTextField(labelWithString: "Global shortcut opens New item from any app")
        l.font = .systemFont(ofSize: 12)
        l.frame = NSRect(x: 64, y: y + 2, width: 300, height: 18)
        doc.addSubview(l)
        let field = ShortcutField(cfg.capture.shortcut)
        field.frame = NSRect(x: w - 230, y: y - 2, width: 110, height: 26)
        field.isEnabled = cfg.capture.enabled
        field.onChange = { [weak self] code, mods in
            self?.cfg.capture.keyCode = code
            self?.cfg.capture.modifiers = mods
        }
        field.onRecording = { on in (NSApp.delegate as? GHActionsBar)?.suspendCaptureHotKey(on) }
        doc.addSubview(field)
        shortcutField = field
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut))
        clear.bezelStyle = .rounded; clear.font = .systemFont(ofSize: 11)
        clear.frame = NSRect(x: w - 116, y: y - 2, width: 60, height: 26)
        doc.addSubview(clear)
        let tryIt = NSButton(title: "Try", target: self, action: #selector(tryCapture))
        tryIt.bezelStyle = .rounded; tryIt.font = .systemFont(ofSize: 11)
        tryIt.frame = NSRect(x: w - 60, y: y - 2, width: 48, height: 26)
        tryIt.toolTip = "Open the New item sheet as the shortcut does"
        doc.addSubview(tryIt)
        y += 32
        let rows: [(String, String, String, Bool)] = [
            ("paste", "Put the clipboard text in the description", "Only when the clipboard has text.", cfg.capture.pasteClipboard),
            ("ai", "Write the title with AI at once", "Needs Settings → AI. AI also picks the project.", cfg.capture.aiTitle),
        ]
        for r in rows {
            let cb = NSButton(checkboxWithTitle: r.1, target: self, action: #selector(toggleCaptureOption(_:)))
            cb.font = .systemFont(ofSize: 12)
            cb.identifier = NSUserInterfaceItemIdentifier(r.0)
            cb.state = r.3 ? .on : .off
            cb.frame = NSRect(x: 64, y: y, width: w - 80, height: 18)
            doc.addSubview(cb)
            let d = NSTextField(labelWithString: r.2)
            d.font = .systemFont(ofSize: 10.5); d.textColor = .tertiaryLabelColor
            d.frame = NSRect(x: 84, y: y + 18, width: w - 100, height: 14)
            doc.addSubview(d)
            y += 38
        }
        if let msg = ProjectSettingsVC.captureError {
            let e = NSTextField(labelWithString: msg)
            e.font = .systemFont(ofSize: 11); e.textColor = C_FAILURE
            e.frame = NSRect(x: 64, y: y, width: w - 80, height: 16)
            doc.addSubview(e)
            y += 20
        }
        return y + 4
    }

    @objc func toggleCapture(_ sender: NSSwitch) {
        cfg.capture.enabled = sender.state == .on
        shortcutField?.isEnabled = cfg.capture.enabled
    }
    @objc func clearShortcut() {
        cfg.capture.modifiers = 0
        shortcutField?.set(cfg.capture.shortcut)
    }
    @objc func toggleCaptureOption(_ sender: NSButton) {
        let on = sender.state == .on
        if sender.identifier?.rawValue == "paste" { cfg.capture.pasteClipboard = on } else { cfg.capture.aiTitle = on }
    }
    @objc func tryCapture() { (NSApp.delegate as? GHActionsBar)?.quickCapture() }

    func popupRow(_ title: String, _ items: [String], _ selected: Int, _ action: Selector, y: CGFloat, in doc: NSView) -> CGFloat {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12)
        l.frame = NSRect(x: 16, y: y + 4, width: 280, height: 18)
        doc.addSubview(l)
        let pop = NSPopUpButton(frame: NSRect(x: 310, y: y, width: 160, height: 24), pullsDown: false)
        pop.addItems(withTitles: items)
        pop.selectItem(at: selected)
        pop.target = self; pop.action = action
        pop.font = .systemFont(ofSize: 12)
        doc.addSubview(pop)
        return y + 30
    }

    @objc func filterChanged() { rebuild() }
    @objc func refreshAll() { catalog.refreshAll(force: true) }
    @objc func refreshOwner(_ sender: NSButton) { if let o = sender.identifier?.rawValue { catalog.refresh(o, force: true) } }
    @objc func toggleExpand(_ sender: NSButton) {
        guard let o = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            ProjectSettingsVC.expanded.insert(o)
            if catalog.projects(of: o).isEmpty {
                if case .loading = catalog.fetch(o) {} else { catalog.refresh(o, force: true) }
            }
        } else {
            ProjectSettingsVC.expanded.remove(o)
        }
        rebuild()
    }
    @objc func toggleAll(_ sender: NSButton) {
        guard let owner = sender.identifier?.rawValue else { return }
        cfg.allOf.removeAll { $0 == owner }
        cfg.picked.removeAll { $0.hasPrefix(owner + "/") }
        if sender.state == .on { cfg.allOf.append(owner) }
        rebuild()
    }
    @objc func toggleProject(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let owner = key.split(separator: "/").first.map(String.init) ?? key
        if cfg.allOf.contains(owner) {
            cfg.allOf.removeAll { $0 == owner }
            cfg.picked = catalog.projects(of: owner).filter { !$0.closed && $0.ref.key != key }.map(\.ref.key)
        } else if sender.state == .on {
            if !cfg.picked.contains(key) { cfg.picked.append(key) }
        } else {
            cfg.picked.removeAll { $0 == key }
        }
        rebuild()
    }
    @objc func toggleNotify(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").split(separator: ":").map(String.init)
        guard parts.count == 2 else { return }
        let on = sender.state == .on
        switch (parts[0], parts[1]) {
        case ("mention", "mine"): cfg.notifications.mention = on
        case ("comment", "any"): cfg.notifications.comment.any = on
        case ("comment", "mine"): cfg.notifications.comment.mine = on
        case ("status", "any"): cfg.notifications.status.any = on
        case ("status", "mine"): cfg.notifications.status.mine = on
        case ("added", "any"): cfg.notifications.added.any = on
        case ("added", "mine"): cfg.notifications.added.mine = on
        case ("assigned", "mine"): cfg.notifications.assigned = on
        case ("closed", "any"): cfg.notifications.closed.any = on
        case ("closed", "mine"): cfg.notifications.closed.mine = on
        case ("other", "any"): cfg.notifications.otherFields.any = on
        case ("other", "mine"): cfg.notifications.otherFields.mine = on
        case ("intake", "any"): cfg.notifications.intake = on
        case ("agentWaiting", "any"): cfg.notifications.agentWaiting = on
        case ("agentDone", "any"): cfg.notifications.agentDone = on
        default: break
        }
    }
    @objc func viewChanged(_ sender: NSPopUpButton) { cfg.defaultView = sender.indexOfSelectedItem == 1 ? .activity : .board }
    @objc func itemsChanged(_ sender: NSPopUpButton) { cfg.itemsPerProject = [10, 25, 0][sender.indexOfSelectedItem] }
    static let hideDays = [-1, 1, 7, 30, 0]
    @objc func hideChanged(_ sender: NSPopUpButton) { cfg.hideDoneAfterDays = ProjectSettingsVC.hideDays[sender.indexOfSelectedItem] }
    @objc func toggleDot(_ sender: NSButton) { cfg.menuDot = sender.state == .on }
    @objc func toggleSubItems(_ sender: NSButton) { cfg.showSubItems = sender.state == .on }
    @objc func pollChanged(_ sender: NSPopUpButton) { cfg.pollMinutes = [2, 5, 10, 15, 30][sender.indexOfSelectedItem] }

    @objc func doSave() {
        cfg.workspaces = PROJECTS_CFG.workspaces
        if let f = doc?.subviews.first(where: { $0.identifier?.rawValue == "orca-prompt" }) as? NSTextField {
            cfg.orca.prompt = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        PROJECTS_CFG = cfg
        saveConfig()
        let app = NSApp.delegate as? GHActionsBar
        let ok = app?.applyCaptureHotKey() ?? true
        ProjectSettingsVC.captureError = ok ? nil : "macOS did not accept \(cfg.capture.shortcutLabel). Another app may use it."
        app?.applyProjectSelection()
        if !ok { app?.showSettings(.projects) }
    }
}

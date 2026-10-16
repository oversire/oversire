import Cocoa

// Settings → General: account, which tabs are shown, and updates.
final class GeneralSettingsVC: NSViewController {
    let catalog: RepoCatalog
    let updater: Updater
    var statusLabel: NSTextField?
    var updateLabel: NSTextField?
    var updateBtn: NSButton?
    var observer: NSObjectProtocol?
    var updateObserver: NSObjectProtocol?

    init(catalog: RepoCatalog, updater: Updater) {
        self.catalog = catalog
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { for o in [observer, updateObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) } }

    override func loadView() {
        let w = POP_W
        let container = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: 500))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        var y: CGFloat = 0
        container.addSubview(SettingsNav(w: w, selected: .general)); y += 44
        container.addSubview(SeparatorLine(y: y, w: w)); y += 0.5

        container.addSubview(SettingsHeader("GITHUB ACCOUNT", y: y, w: w)); y += 28
        let acc = NSView(frame: NSRect(x: 0, y: y, width: w, height: 40))
        let sl = NSTextField(labelWithString: "Checking…")
        sl.font = .systemFont(ofSize: 12); sl.textColor = .secondaryLabelColor
        sl.frame = NSRect(x: 16, y: 10, width: w - 180, height: 20)
        acc.addSubview(sl); statusLabel = sl
        let login = NSButton(title: "Login...", target: self, action: #selector(doLogin))
        login.bezelStyle = .inline; login.font = .systemFont(ofSize: 11)
        login.frame = NSRect(x: w - 160, y: 10, width: 64, height: 24)
        acc.addSubview(login)
        let logout = NSButton(title: "Logout", target: self, action: #selector(doLogout))
        logout.bezelStyle = .inline; logout.font = .systemFont(ofSize: 11)
        logout.frame = NSRect(x: w - 88, y: 10, width: 64, height: 24)
        acc.addSubview(logout)
        container.addSubview(acc); y += 40
        container.addSubview(SeparatorLine(y: y, w: w)); y += 0.5

        container.addSubview(SettingsHeader("TAB VISIBILITY", y: y, w: w)); y += 28
        let tabs = NSView(frame: NSRect(x: 0, y: y, width: w, height: 36))
        let options: [(String, String, Bool)] = [
            ("Actions", "actions", TABS.actions),
            ("PRs", "prs", TABS.prs),
            ("Projects", "projects", PROJECTS_CFG.showTab),
            ("Insights", "insights", TABS.insights),
        ]
        var x: CGFloat = 16
        for opt in options {
            let cb = NSButton(checkboxWithTitle: opt.0, target: self, action: #selector(toggleTab(_:)))
            cb.font = .systemFont(ofSize: 12)
            cb.identifier = NSUserInterfaceItemIdentifier(opt.1)
            cb.state = opt.2 ? .on : .off
            cb.sizeToFit()
            cb.frame.origin = NSPoint(x: x, y: 8)
            tabs.addSubview(cb)
            x += ceil(cb.frame.width) + 18
        }
        container.addSubview(tabs); y += 36
        container.addSubview(SeparatorLine(y: y, w: w)); y += 0.5

        container.addSubview(SettingsHeader("UPDATES", y: y, w: w)); y += 28
        let upd = NSView(frame: NSRect(x: 0, y: y, width: w, height: 40))
        let auto = NSButton(checkboxWithTitle: "Automatically install updates", target: self, action: #selector(toggleAutoUpdate(_:)))
        auto.font = .systemFont(ofSize: 12)
        auto.state = AUTO_UPDATE ? .on : .off
        auto.isEnabled = !updater.isDev
        auto.frame = NSRect(x: 16, y: 10, width: 220, height: 20)
        upd.addSubview(auto)
        let ul = NSTextField(labelWithString: "")
        ul.font = .systemFont(ofSize: 11); ul.textColor = .secondaryLabelColor
        ul.alignment = .right; ul.lineBreakMode = .byTruncatingTail
        ul.frame = NSRect(x: 240, y: 12, width: w - 350, height: 16)
        upd.addSubview(ul); updateLabel = ul
        let ub = NSButton(title: "Check now", target: self, action: #selector(checkOrRestart))
        ub.bezelStyle = .inline; ub.font = .systemFont(ofSize: 11)
        ub.frame = NSRect(x: w - 104, y: 10, width: 88, height: 24)
        upd.addSubview(ub); updateBtn = ub
        container.addSubview(upd); y += 48

        container.frame.size.height = y
        view = container
        preferredContentSize = NSSize(width: w, height: min(y, POP_MAX_H))
        observer = NotificationCenter.default.addObserver(forName: RepoCatalog.changed, object: catalog, queue: .main) { [weak self] _ in
            self?.updateAuth()
        }
        updateObserver = NotificationCenter.default.addObserver(forName: Updater.changed, object: updater, queue: .main) { [weak self] _ in
            self?.updateUpdater()
        }
        updateAuth(); updateUpdater()
        catalog.checkAuth()
    }

    func updateAuth() {
        guard let sl = statusLabel, catalog.authChecked else { return }
        if let user = catalog.user {
            sl.stringValue = "Authenticated as \(user)"
            sl.textColor = .secondaryLabelColor
        } else {
            sl.stringValue = lastFetchError?.contains("not found") == true ? (lastFetchError ?? "") : "Not authenticated — click Login"
            sl.textColor = .systemRed
        }
    }

    func updateUpdater() {
        let status = updater.statusText
        updateLabel?.stringValue = "Version \(updater.current)" + (status.isEmpty ? "" : " · \(status)")
        updateLabel?.textColor = { if case .failed = updater.state { return NSColor.systemRed }; return .secondaryLabelColor }()
        updateBtn?.title = { if case .ready = updater.state { return "Restart now" }; return "Check now" }()
        updateBtn?.isEnabled = !updater.busy
    }

    @objc func toggleTab(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.identifier?.rawValue {
        case "actions": TABS.actions = on
        case "prs": TABS.prs = on
        case "projects": PROJECTS_CFG.showTab = on
        case "insights": TABS.insights = on
        default: return
        }
        if !TABS.actions && !TABS.prs && !PROJECTS_CFG.showTab && !TABS.insights {
            TABS.actions = true
            sender.state = .on
        }
        saveConfig()
    }

    @objc func toggleAutoUpdate(_ sender: NSButton) {
        AUTO_UPDATE = sender.state == .on
        saveConfig()
        if AUTO_UPDATE { updater.check(manual: false) }
    }
    @objc func checkOrRestart() {
        if case .ready = updater.state { updater.install() } else { updater.check(manual: true) }
    }
    @objc func doLogin() { runInTerminal("gh auth login --web -p https") }
    @objc func doLogout() { runInTerminal("gh auth logout") }
}

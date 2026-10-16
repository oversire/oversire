import Cocoa

// ─── Settings → Live updates ─────────────────────────────────────────────────

enum SetupStep: Int, CaseIterable {
    case node, wrangler, login, relay, join, hooks, live
}

final class RelaySettingsVC: NSViewController {
    let deployer: RelayDeployer
    let client: RelayClient
    var body: Flipped!
    var scroll: NSScrollView!
    var logView: NSTextView?
    var retentionField: NSTextField?
    var retentionUnit: NSPopUpButton?
    var reconcileField: NSTextField?
    var retentionDraft: String?
    var reconcileDraft: String?
    var unitDraft: Int?
    var checked = false
    private var inspecting = false
    var autoSetup = false
    var triedUpdate = false
    var lastHealthCheck = Date.distantPast

    init(deployer: RelayDeployer, client: RelayClient) {
        self.deployer = deployer
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let w = POP_W
        let container = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: POP_MAX_H))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        container.addSubview(SettingsNav(w: w, selected: .live))
        container.addSubview(SeparatorLine(y: 44, w: w))

        scroll = NSScrollView(frame: NSRect(x: 0, y: 44.5, width: w, height: POP_MAX_H - 44.5))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.height]
        body = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        scroll.documentView = body
        container.addSubview(scroll)
        view = container
        preferredContentSize = NSSize(width: w, height: POP_MAX_H)

        deployer.onChange = { [weak self] in
            guard let self else { return }
            // A task ran when the page loaded, so the first check waited for it.
            if !self.checked, !self.inspecting, self.deployer.busy == nil {
                self.inspecting = true
                self.deployer.refreshState { [weak self] in self?.inspecting = false; self?.afterInspect() }
            }
            self.rebuild()
        }
        deployer.onLog = { [weak self] in self?.updateLog() }
        rebuild()
        if deployer.busy == nil {
            inspecting = true
            deployer.refreshState { [weak self] in self?.inspecting = false; self?.afterInspect() }
        }
    }

    // MARK: Steps

    func isDone(_ step: SetupStep) -> Bool {
        let s = deployer.state
        switch step {
        case .node: return s.nodeOK
        case .wrangler: return s.wrangler != nil
        case .login: return s.email != nil && !RELAY.accountID.isEmpty
        case .relay: return s.relayVersion != nil && !s.needsRelayUpdate
        case .join: return s.joined
        case .hooks: return !REPOS.isEmpty && REPOS.allSatisfy { deployer.hooks.statuses[$0]?.isDone == true }
        case .live: return client.state == .live
        }
    }

    var nextStep: SetupStep? { SetupStep.allCases.first { !isDone($0) } }

    func afterInspect() {
        checked = true
        if deployer.state.joined && !lastHealthCheckRecent {
            deployer.checkHooks(repos: REPOS)
            deployer.checkPlaneHooks((NSApp.delegate as? GHActionsBar)?.trackedPlaneWorkspaces() ?? [])
            lastHealthCheck = Date()
        }
        rebuild()
        if autoSetup { runNext(); return }
        // An old relay updates as soon as this Mac can deploy.
        let s = deployer.state
        if !triedUpdate, s.relayVersion != nil, s.needsRelayUpdate, isDone(.login), deployer.busy == nil {
            triedUpdate = true
            run(.relay)
        }
    }

    var lastHealthCheckRecent: Bool { Date().timeIntervalSince(lastHealthCheck) < 5 }

    // Runs the next step that is not done. With autoSetup, it continues until all are done or one fails.
    func runNext() {
        guard deployer.busy == nil, let step = nextStep else { autoSetup = false; rebuild(); return }
        run(step)
    }

    func run(_ step: SetupStep) {
        let d = deployer
        let after: (Bool) -> Void = { [weak self] ok in
            guard let self = self else { return }
            if !ok { self.autoSetup = false }
            d.refreshState { self.afterInspect() }
        }
        switch step {
        case .node:
            if d.state.hasBrew {
                d.perform("Install Node.js with Homebrew", d.installNode, then: after)
            } else {
                autoSetup = false
                if let u = URL(string: "https://nodejs.org/en/download") { NSWorkspace.shared.open(u) }
                d.append("Install Node.js 20 or later, then click Check again.")
            }
        case .wrangler:
            d.perform("Install wrangler", { d.installWrangler() }, then: after)
        case .login:
            if d.state.email == nil {
                d.perform("Log in to Cloudflare (finish in the browser)", d.login, then: after)
            } else {
                autoSetup = false
                d.append("Select a Cloudflare account.")
                rebuild()
            }
        case .relay:
            if d.state.relayVersion == nil {
                d.perform("Deploy relay", d.deploy, then: after)
            } else {
                d.perform(d.state.needsRelayUpdate ? "Update relay" : "Redeploy relay", d.updateRelay, then: after)
            }
        case .join:
            d.perform("Join this Mac", d.joinThisMac) { [weak self] ok in
                if ok { RELAY.enabled = true; saveConfig(); self?.client.start() }
                after(ok)
            }
        case .hooks:
            let repos = REPOS
            let slugs = (NSApp.delegate as? GHActionsBar)?.trackedPlaneWorkspaces() ?? []
            d.perform("Install webhooks", {
                let reposOK = d.installHooks(repos: repos)
                let planeOK = slugs.isEmpty || d.installPlaneHooks(slugs)
                return reposOK && planeOK
            }) { ok in
                d.checkHooks(repos: repos)
                d.checkPlaneHooks(slugs)
                after(ok)
            }
        case .live:
            RELAY.enabled = true
            saveConfig()
            client.start()
            autoSetup = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.rebuild() }
        }
    }

    // MARK: Layout

    func rebuild() {
        NSApp.withPinnedAppearance {
            guard body != nil else { return }
            retentionDraft = retentionField?.stringValue
            reconcileDraft = reconcileField?.stringValue
            unitDraft = retentionUnit?.indexOfSelectedItem
            body.subviews.forEach { $0.removeFromSuperview() }
            let w = POP_W
            var y: CGFloat = 0
            let s = deployer.state

            // Enable + status
            let top = NSView(frame: NSRect(x: 0, y: y, width: w, height: 40))
            let en = NSButton(checkboxWithTitle: "Enable live updates", target: self, action: #selector(toggleEnabled(_:)))
            en.font = .systemFont(ofSize: 12, weight: .medium)
            en.state = RELAY.enabled ? .on : .off
            en.isEnabled = s.joined || RELAY.enabled
            en.frame = NSRect(x: 16, y: 10, width: 220, height: 20)
            top.addSubview(en)
            let (dotColor, statusText) = liveStatus()
            top.addSubview(label(statusText, x: w - 236, y: 12, width: 200, size: 11, color: .secondaryLabelColor, align: .right))
            top.addSubview(Dot(color: dotColor, frame: NSRect(x: w - 28, y: 15, width: 10, height: 10)))
            body.addSubview(top); y += 40

            // Setup
            y = section("SETUP", y: y, buttons: [
                (checked ? "Check again" : "Checking…", #selector(checkAgain)),
                (deployer.busy != nil ? "Working…" : (nextStep == nil ? "All set" : "Set up"), #selector(setUp)),
            ], enabled: [deployer.busy == nil, deployer.busy == nil && nextStep != nil && checked])
            for step in SetupStep.allCases { y = stepRow(step, y: y) }
            if !REPOS.isEmpty && s.joined {
                for repo in REPOS {
                    let st = deployer.hooks.statuses[repo] ?? .unknown
                    let row = NSView(frame: NSRect(x: 0, y: y, width: w, height: 18))
                    row.addSubview(label(repo, x: 64, y: 1, width: 240, size: 11, color: .secondaryLabelColor))
                    row.addSubview(label(deployer.describe(st), x: 310, y: 1, width: w - 326, size: 11, color: hookColor(st)))
                    body.addSubview(row); y += 18
                }
                y += 6
            }

            let slugs = (NSApp.delegate as? GHActionsBar)?.trackedPlaneWorkspaces() ?? []
            if s.joined || !slugs.isEmpty {
                y = section("PLANE WEBHOOKS", y: y, buttons: [("Check again", #selector(checkPlaneHooks))],
                            enabled: [deployer.busy == nil && s.joined && !slugs.isEmpty])
                if slugs.isEmpty {
                    y = line("Track a Plane project to add a workspace webhook.", y: y)
                } else {
                    for slug in slugs { y = planeRow(slug, y: y) }
                }
                y = pollNote(y)
                y += 6
            }

            // Health
            if let h = s.health {
                y = section("HEALTH", y: y, buttons: [("Check now", #selector(checkAgain))], enabled: [deployer.busy == nil])
                let oldest = h.oldestAt.map { relativeAgo(Date(timeIntervalSince1970: $0 / 1000)) } ?? "none"
                let lastHook = h.lastWebhookAt.map { relativeAgo(Date(timeIntervalSince1970: $0 / 1000)) } ?? "never"
                y = line("Events kept: \(h.events) · oldest \(oldest) · last webhook \(lastHook)", y: y)
                y = line("Project events (24h): \(h.projectEventsToday)", y: y)
                let q = WriteQuota(rowsToday: h.rowsWrittenToday, now: Date())
                let pct = Int((q.fraction * 100).rounded())
                y = line("Writes today: about \(h.rowsWrittenToday) · projected \(q.projected) / \(FREE_ROWS_PER_DAY) per day (free plan, \(pct)%)",
                         y: y, color: q.warn ? C_FAILURE : .secondaryLabelColor)
                if q.warn { y = line("Warning: near the free write quota. Use Workers Paid, or track fewer repos.", y: y, color: C_FAILURE) }
                y += 6

                // Configuration
                y = section("CONFIGURATION", y: y, buttons: [("Save", #selector(saveConfiguration))], enabled: [deployer.busy == nil])
                let row = NSView(frame: NSRect(x: 0, y: y, width: w, height: 30))
                row.addSubview(label("Keep events for", x: 16, y: 7, width: 120, size: 12))
                let days = h.retentionHours % 24 == 0 && h.retentionHours >= 24
                let rf = NSTextField(frame: NSRect(x: 136, y: 4, width: 50, height: 22))
                rf.stringValue = retentionDraft ?? String(days ? h.retentionHours / 24 : h.retentionHours)
                rf.font = .systemFont(ofSize: 12); rf.alignment = .right
                row.addSubview(rf); retentionField = rf
                let unit = NSPopUpButton(frame: NSRect(x: 192, y: 2, width: 90, height: 26), pullsDown: false)
                unit.addItems(withTitles: ["hours", "days"])
                unit.selectItem(at: unitDraft ?? (days ? 1 : 0))
                unit.font = .systemFont(ofSize: 12)
                row.addSubview(unit); retentionUnit = unit
                row.addSubview(label("1 hour to 30 days", x: 290, y: 7, width: 200, size: 11, color: .secondaryLabelColor))
                body.addSubview(row); y += 30

                let row2 = NSView(frame: NSRect(x: 0, y: y, width: w, height: 30))
                row2.addSubview(label("Reconcile poll every", x: 16, y: 7, width: 140, size: 12))
                let cf = NSTextField(frame: NSRect(x: 156, y: 4, width: 50, height: 22))
                cf.stringValue = reconcileDraft ?? String(Int((RELAY.reconcileInterval ?? 600) / 60))
                cf.font = .systemFont(ofSize: 12); cf.alignment = .right
                row2.addSubview(cf); reconcileField = cf
                row2.addSubview(label("min (while live)", x: 212, y: 7, width: 200, size: 12))
                body.addSubview(row2); y += 36

                // Devices
                y = section("DEVICES", y: y, buttons: [], enabled: [])
                for dev in h.devices {
                    let r = NSView(frame: NSRect(x: 0, y: y, width: w, height: 24))
                    let me = dev.id == RELAY.deviceID
                    r.addSubview(label((dev.name ?? dev.id) + (me ? " (this Mac)" : ""), x: 16, y: 4, width: 240, size: 12))
                    let seen = dev.connected ? "connected" : (dev.lastSeen.map { "seen " + relativeAgo(Date(timeIntervalSince1970: $0 / 1000)) } ?? "never seen")
                    r.addSubview(label("\(seen) · lag \(dev.lag)", x: 260, y: 5, width: 260, size: 11, color: .secondaryLabelColor))
                    if !me {
                        let b = button("Remove", #selector(removeDevice(_:)), x: w - 86, y: 1, width: 70)
                        b.identifier = NSUserInterfaceItemIdentifier(dev.id)
                        b.isEnabled = deployer.busy == nil
                        r.addSubview(b)
                    }
                    body.addSubview(r); y += 24
                }
                y += 6
            }

            // Log
            y = section("LOG", y: y, buttons: [], enabled: [])
            let ls = NSScrollView(frame: NSRect(x: 12, y: y, width: w - 24, height: 140))
            ls.hasVerticalScroller = true; ls.borderType = .bezelBorder
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: w - 28, height: 140))
            tv.isEditable = false; tv.isRichText = false
            tv.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            tv.textContainerInset = NSSize(width: 4, height: 4)
            tv.autoresizingMask = [.width]
            ls.documentView = tv
            body.addSubview(ls); logView = tv; y += 148
            updateLog()

            // Danger zone
            let bottom = NSView(frame: NSRect(x: 0, y: y, width: w, height: 40))
            let rot = button("Rotate webhook secret", #selector(rotateSecret), x: 12, y: 8, width: 170)
            rot.isEnabled = s.joined && deployer.busy == nil
            bottom.addSubview(rot)
            let rm = button("Remove relay…", #selector(removeRelay), x: w - 142, y: 8, width: 130)
            rm.isEnabled = !RELAY.workerURL.isEmpty && s.wrangler != nil && deployer.busy == nil
            bottom.addSubview(rm)
            body.addSubview(bottom); y += 44

            body.frame.size.height = y
            // The popover sizes the view; never set it here, or the nav bar can go off the top.
            let screenH = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? POP_MAX_H
            preferredContentSize = NSSize(width: w, height: min(44.5 + y, POP_MAX_H, screenH - 40))
        }
    }

    func liveStatus() -> (NSColor, String) {
        if let busy = deployer.busy { return (.systemGray, busy) }
        if let (c, t) = client.statusDot { return (c, client.isHealthy ? "Live" : t) }
        return (.systemGray, RELAY.workerURL.isEmpty ? "Not set up" : "Off · polling")
    }

    func stepRow(_ step: SetupStep, y: CGFloat) -> CGFloat {
        let s = deployer.state
        let w = POP_W
        let done = isDone(step)
        let row = NSView(frame: NSRect(x: 0, y: y, width: w, height: 26))
        let mark = checked ? (done ? "✓" : (step == nextStep ? "→" : "○")) : "…"
        row.addSubview(label(mark, x: 20, y: 5, width: 20, size: 12, color: done ? C_SUCCESS : .secondaryLabelColor))
        var text = ""
        var action: (String, Selector)?
        switch step {
        case .node:
            text = s.node.map { s.nodeOK ? "Node.js \($0)" : "Node.js \($0) is too old (need 20+)" } ?? "Node.js not found"
            if !done { action = (s.hasBrew ? "Install Node" : "Get Node", #selector(stepNode)) }
        case .wrangler:
            text = s.wrangler.map { "Wrangler \($0) (local)" } ?? "Wrangler not installed"
            action = (done ? "Update" : "Install", #selector(stepWrangler))
        case .login:
            if let e = s.email {
                let acct = s.accounts.first { $0.id == RELAY.accountID }?.name
                text = "Cloudflare: \(acct ?? "choose an account") · \(e)"
                action = ("Log out", #selector(stepLogout))
                if s.accounts.count > 1 {
                    let pop = NSPopUpButton(frame: NSRect(x: w - 330, y: 1, width: 220, height: 24), pullsDown: false)
                    pop.font = .systemFont(ofSize: 11)
                    pop.addItem(withTitle: "Choose account…")
                    for a in s.accounts { pop.addItem(withTitle: a.name) }
                    if let i = s.accounts.firstIndex(where: { $0.id == RELAY.accountID }) { pop.selectItem(at: i + 1) }
                    pop.target = self; pop.action = #selector(accountChanged(_:))
                    row.addSubview(pop)
                }
            } else {
                text = "Cloudflare: not logged in"
                action = ("Log in", #selector(stepLogin))
            }
        case .relay:
            if let v = s.relayVersion {
                text = "Relay v\(v)  \(RELAY.workerURL)" + (s.needsRelayUpdate ? " (update available)" : "")
                action = (s.needsRelayUpdate ? "Update relay" : "Redeploy", #selector(stepRelay))
            } else {
                text = RELAY.workerURL.isEmpty ? "Relay not deployed" : "Relay not reachable at \(RELAY.workerURL)"
                action = ("Deploy relay", #selector(stepRelay))
            }
        case .join:
            if s.joined { text = "This Mac: \"\(Host.current().localizedName ?? "Mac")\" joined" }
            else { text = s.joinError.map { "This Mac: \($0)" } ?? "This Mac has not joined" }
            action = (done ? "Rejoin" : "Join", #selector(stepJoin))
        case .hooks:
            let sts = REPOS.map { deployer.hooks.statuses[$0] ?? .unknown }
            var live = 0, polling = 0, errors = 0, other = 0
            for st in sts {
                switch st {
                case .live, .waiting: live += 1
                case .pollingOnly: polling += 1
                case .error: errors += 1
                case .unknown: other += 1
                }
            }
            text = "Webhooks: \(live) live · \(polling) polling only · \(errors) error" + (other > 0 ? " · \(other) not checked" : "")
            action = (done ? "Repair" : "Install hooks", #selector(stepHooks))
        case .live:
            switch client.state {
            case .live:
                let last = client.lastEventAt.map { " · last event " + relativeAgo($0) } ?? ""
                text = "Connected\(last)"
            case .connecting: text = "Connecting…"
            case .error(let m): text = "Error: \(m)"
            case .off: text = RELAY.enabled ? "Not connected" : "Live updates are off"
            }
            action = ("Reconnect", #selector(stepLive))
        }
        row.addSubview(label(text, x: 42, y: 5, width: w - 380, size: 12, color: .labelColor))
        if let (title, sel) = action {
            let b = button(title, sel, x: w - 106, y: 1, width: 90)
            b.isEnabled = deployer.busy == nil && checked && prerequisitesDone(step)
            row.addSubview(b)
        }
        body.addSubview(row)
        return y + 26
    }

    func prerequisitesDone(_ step: SetupStep) -> Bool {
        SetupStep.allCases.filter { $0.rawValue < step.rawValue }.allSatisfy { isDone($0) || $0 == .hooks }
    }

    func planeRow(_ slug: String, y: CGFloat) -> CGFloat {
        let st = deployer.hooks.statuses[HookManager.planeKey(slug)] ?? .unknown
        let row = NSView(frame: NSRect(x: 0, y: y, width: POP_W, height: 26))
        row.addSubview(Dot(color: hookColor(st), frame: NSRect(x: 18, y: 8, width: 8, height: 8)))
        row.addSubview(label(slug, x: 34, y: 5, width: 110, size: 12))
        let pills = label("work item · comment · project", x: 148, y: 5, width: 250, size: 11, color: .secondaryLabelColor)
        pills.toolTip = deployer.describe(st)
        row.addSubview(pills)
        let title: String
        switch st {
        case .live, .waiting: title = "Check again"
        default: title = "Add webhook"
        }
        let b = button(title, #selector(planeHookAction(_:)), x: POP_W - 156, y: 2, width: 140)
        b.identifier = NSUserInterfaceItemIdentifier(slug)
        b.isEnabled = deployer.busy == nil && deployer.state.joined
        b.toolTip = deployer.describe(st)
        row.addSubview(b)
        body.addSubview(row)
        return y + 26
    }

    func pollNote(_ y: CGFloat) -> CGFloat {
        let row = NSView(frame: NSRect(x: 0, y: y, width: POP_W, height: 24))
        let minutes = min(30, max(2, PROJECTS_CFG.pollMinutes))
        row.addSubview(label("Workspaces without a webhook poll every \(minutes) min.", x: 16, y: 4, width: 340, size: 11, color: .secondaryLabelColor))
        let b = button("Settings → Projects", #selector(openProjectSettings), x: 360, y: 1, width: 150)
        row.addSubview(b)
        body.addSubview(row)
        return y + 28
    }

    func hookColor(_ s: HookStatus) -> NSColor {
        switch s {
        case .live, .waiting: return C_SUCCESS
        case .error: return C_FAILURE
        default: return .secondaryLabelColor
        }
    }

    func section(_ title: String, y: CGFloat, buttons: [(String, Selector)], enabled: [Bool]) -> CGFloat {
        let hdr = SettingsHeader(title, y: y, w: POP_W)
        var x = POP_W - 12
        for (i, (t, sel)) in buttons.enumerated().reversed() {
            let width: CGFloat = max(70, CGFloat(t.count) * 7 + 16)
            x -= width
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .inline; b.font = .systemFont(ofSize: 10)
            b.frame = NSRect(x: x, y: 5, width: width, height: 18)
            b.isEnabled = enabled[i]
            hdr.addSubview(b)
            x -= 6
        }
        body.addSubview(hdr)
        return y + 28 + 4
    }

    func line(_ text: String, y: CGFloat, color: NSColor = .secondaryLabelColor) -> CGFloat {
        body.addSubview(label(text, x: 16, y: y + 2, width: POP_W - 32, size: 11, color: color))
        return y + 20
    }

    func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
               color: NSColor = .labelColor, align: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size); l.textColor = color; l.alignment = align
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: x, y: y, width: width, height: 16)
        return l
    }

    func button(_ title: String, _ sel: Selector, x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11)
        b.frame = NSRect(x: x, y: y, width: width, height: 22)
        return b
    }

    func updateLog() {
        guard let tv = logView else { return }
        tv.string = deployer.log.joined(separator: "\n")
        tv.scrollToEndOfDocument(nil)
    }

    // MARK: Actions

    @objc func toggleEnabled(_ sender: NSButton) {
        RELAY.enabled = sender.state == .on
        saveConfig()
        RELAY.enabled ? client.start() : client.stop()
        (NSApp.delegate as? GHActionsBar)?.scheduleTimer()
        rebuild()
    }

    @objc func checkAgain() {
        checked = false
        rebuild()
        deployer.refreshState { [weak self] in self?.lastHealthCheck = .distantPast; self?.afterInspect() }
    }

    @objc func setUp() { autoSetup = true; runNext() }

    @objc func stepNode() { run(.node) }
    @objc func stepWrangler() {
        if isDone(.wrangler) {
            let d = deployer
            d.perform("Update wrangler", { d.installWrangler(update: true) }) { _ in d.refreshState { [weak self] in self?.afterInspect() } }
        } else { run(.wrangler) }
    }
    @objc func stepLogin() { run(.login) }
    @objc func stepLogout() {
        let d = deployer
        d.perform("Log out of Cloudflare", d.logout) { _ in d.refreshState { [weak self] in self?.afterInspect() } }
    }
    @objc func stepRelay() { run(.relay) }
    @objc func stepJoin() { run(.join) }
    @objc func stepHooks() { run(.hooks) }

    @objc func checkPlaneHooks() {
        deployer.checkPlaneHooks((NSApp.delegate as? GHActionsBar)?.trackedPlaneWorkspaces() ?? [])
    }

    @objc func planeHookAction(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue else { return }
        let st = deployer.hooks.statuses[HookManager.planeKey(slug)] ?? .unknown
        switch st {
        case .live, .waiting:
            deployer.checkPlaneHooks([slug])
        default:
            let d = deployer
            d.perform("Install Plane webhook for \(slug)", { d.installPlaneHooks([slug]) }) { [weak self] _ in
                d.checkPlaneHooks([slug])
                self?.rebuild()
            }
        }
    }

    @objc func openProjectSettings() {
        (NSApp.delegate as? GHActionsBar)?.showSettings(.projects)
    }
    @objc func stepLive() { run(.live) }

    @objc func accountChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem - 1
        guard i >= 0, i < deployer.state.accounts.count else { return }
        RELAY.accountID = deployer.state.accounts[i].id
        saveConfig()
        checkAgain()
    }

    @objc func saveConfiguration() {
        let n = Int(retentionField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let hours = retentionUnit?.indexOfSelectedItem == 1 ? n * 24 : n
        let minutes = Int(reconcileField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 10
        guard (1...720).contains(hours) else { deployer.append("Retention must be from 1 hour to 30 days."); return }
        RELAY.reconcileInterval = TimeInterval(min(max(minutes, 1), 120) * 60)
        saveConfig()
        (NSApp.delegate as? GHActionsBar)?.scheduleTimer()
        retentionField = nil; reconcileField = nil; retentionUnit = nil
        let d = deployer
        d.perform("Set retention to \(hours) h", { d.setRetention(hours: hours) }) { _ in
            d.refreshState { [weak self] in self?.afterInspect() }
        }
    }

    @objc func removeDevice(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let d = deployer
        d.perform("Remove device \(id)", { d.removeDevice(id) }) { _ in d.refreshState { [weak self] in self?.afterInspect() } }
    }

    @objc func rotateSecret() {
        guard confirm("Rotate the webhook secret?",
                      "OverSire sets a new secret on the relay and on each webhook. Hooks on repos that this Mac cannot administer must be repaired from another Mac.",
                      ok: "Rotate") else { return }
        let d = deployer
        d.perform("Rotate webhook secret", d.rotateWebhookSecret) { _ in d.refreshState { [weak self] in self?.afterInspect() } }
    }

    @objc func removeRelay() {
        guard confirm("Remove the relay?",
                      "This deletes all webhooks, the Cloudflare Worker and its event log. All Macs that use this relay go back to polling.",
                      ok: "Remove relay") else { return }
        client.stop()
        let d = deployer
        d.perform("Remove relay", d.removeRelay) { _ in
            (NSApp.delegate as? GHActionsBar)?.scheduleTimer()
            d.refreshState { [weak self] in self?.afterInspect() }
        }
    }

    func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
}

class Dot: NSView {
    init(color: NSColor, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

import Cocoa
import OverSireCore
import TrackerPlane

// ─── Settings → Cloud (beta) ─────────────────────────────────────────────────

final class CloudSettingsVC: NSViewController {
    let setup: CloudSetup
    let client: RelayClient
    var body: Flipped!
    var scroll: NSScrollView!
    var logView: NSTextView?
    var urlField: NSTextField?
    var tokenField: NSSecureTextField?
    var retentionField: NSTextField?
    var retentionUnit: NSPopUpButton?
    var reconcileField: NSTextField?
    var urlDraft: String?
    var retentionDraft: String?
    var reconcileDraft: String?
    var unitDraft: Int?
    var checked = false
    var lastHealthCheck = Date.distantPast

    init(setup: CloudSetup, client: RelayClient) {
        self.setup = setup
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

        setup.onChange = { [weak self] in self?.rebuild() }
        setup.onLog = { [weak self] in self?.updateLog() }
        rebuild()
        if setup.busy == nil { checkAgain() }
    }

    var connected: Bool { setup.state.joined }

    func afterInspect() {
        checked = true
        if connected && Date().timeIntervalSince(lastHealthCheck) > 5 {
            setup.checkHooks(repos: REPOS)
            setup.checkPlaneHooks(workspaces)
            lastHealthCheck = Date()
        }
        rebuild()
    }

    var workspaces: [String] { (NSApp.delegate as? GHActionsBar)?.trackedPlaneWorkspaces() ?? [] }

    // MARK: Layout

    func rebuild() {
        NSApp.withPinnedAppearance {
            guard body != nil else { return }
            urlDraft = urlField?.stringValue
            retentionDraft = retentionField?.stringValue
            reconcileDraft = reconcileField?.stringValue
            unitDraft = retentionUnit?.indexOfSelectedItem
            body.subviews.forEach { $0.removeFromSuperview() }
            let w = POP_W
            var y: CGFloat = 0
            let s = setup.state
            let idle = setup.busy == nil

            // Enable + status
            let top = NSView(frame: NSRect(x: 0, y: y, width: w, height: 40))
            let en = NSButton(checkboxWithTitle: "Enable live updates", target: self, action: #selector(toggleEnabled(_:)))
            en.font = .systemFont(ofSize: 12, weight: .medium)
            en.state = RELAY.enabled ? .on : .off
            en.isEnabled = connected || RELAY.enabled
            en.frame = NSRect(x: 16, y: 10, width: 220, height: 20)
            top.addSubview(en)
            let (dotColor, statusText) = liveStatus()
            top.addSubview(label(statusText, x: w - 236, y: 12, width: 200, size: 11, color: .secondaryLabelColor, align: .right))
            top.addSubview(Dot(color: dotColor, frame: NSRect(x: w - 28, y: 15, width: 10, height: 10)))
            body.addSubview(top); y += 40

            // Connection
            y = section("CONNECTION", y: y, buttons: [(checked ? "Check again" : "Checking…", #selector(checkAgain))], enabled: [idle])
            let urlRow = NSView(frame: NSRect(x: 0, y: y, width: w, height: 30))
            urlRow.addSubview(label("URL", x: 16, y: 7, width: 60, size: 12))
            let uf = NSTextField(frame: NSRect(x: 80, y: 4, width: w - 96, height: 22))
            uf.placeholderString = "https://oversire-cloud.example.workers.dev"
            uf.stringValue = urlDraft ?? RELAY.workerURL
            uf.font = .systemFont(ofSize: 12)
            urlRow.addSubview(uf); urlField = uf
            body.addSubview(urlRow); y += 30
            let tokRow = NSView(frame: NSRect(x: 0, y: y, width: w, height: 30))
            tokRow.addSubview(label("Token", x: 16, y: 7, width: 60, size: 12))
            let tf = NSSecureTextField(frame: NSRect(x: 80, y: 4, width: w - 96, height: 22))
            tf.placeholderString = connected ? "Saved in the Keychain" : "Device token from npm run add-device"
            tf.font = .systemFont(ofSize: 12)
            tokRow.addSubview(tf); tokenField = tf
            body.addSubview(tokRow); y += 32
            let actRow = NSView(frame: NSRect(x: 0, y: y, width: w, height: 30))
            let state = connected ? "This Mac: \"\(Host.current().localizedName ?? "Mac")\" connected" + (s.version.map { " · cloud v\($0)" } ?? "")
                : (s.joinError ?? (RELAY.workerURL.isEmpty ? "Not connected" : "Cannot reach the cloud"))
            actRow.addSubview(label(state, x: 16, y: 7, width: w - 230, size: 12, color: connected ? C_SUCCESS : .secondaryLabelColor))
            let conn = button(connected ? "Reconnect" : "Connect", #selector(connect), x: w - 206, y: 4, width: 90)
            conn.isEnabled = idle
            actRow.addSubview(conn)
            let disc = button("Disconnect", #selector(disconnect), x: w - 106, y: 4, width: 90)
            disc.isEnabled = idle && !RELAY.workerURL.isEmpty
            actRow.addSubview(disc)
            body.addSubview(actRow); y += 36

            // Repo webhooks
            if connected {
                y = section("GITHUB WEBHOOKS", y: y, buttons: [(hooksDone ? "Repair" : "Install hooks", #selector(installHooks))], enabled: [idle && !REPOS.isEmpty])
                if REPOS.isEmpty { y = line("Track a repo to add a webhook.", y: y) }
                for repo in REPOS {
                    let st = setup.hooks.statuses[repo] ?? .unknown
                    let row = NSView(frame: NSRect(x: 0, y: y, width: w, height: 18))
                    row.addSubview(label(repo, x: 16, y: 1, width: 280, size: 11, color: .secondaryLabelColor))
                    row.addSubview(label(setup.describe(st), x: 300, y: 1, width: w - 316, size: 11, color: hookColor(st)))
                    body.addSubview(row); y += 18
                }
                y += 6
            }

            let slugs = workspaces
            if connected {
                y = section("PLANE WEBHOOKS", y: y, buttons: [("Check again", #selector(checkPlaneHooks))], enabled: [idle && !slugs.isEmpty])
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
                y = section("HEALTH", y: y, buttons: [("Check now", #selector(checkAgain))], enabled: [idle])
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

                y = section("CONFIGURATION", y: y, buttons: [("Save", #selector(saveConfiguration))], enabled: [idle])
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
                        b.isEnabled = idle
                        r.addSubview(b)
                    }
                    body.addSubview(r); y += 24
                }
                y += 6
            }

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

            body.frame.size.height = y
            // The popover sizes the view; never set it here, or the nav bar can go off the top.
            let screenH = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? POP_MAX_H
            preferredContentSize = NSSize(width: w, height: min(44.5 + y, POP_MAX_H, screenH - 40))
        }
    }

    var hooksDone: Bool { !REPOS.isEmpty && REPOS.allSatisfy { setup.hooks.statuses[$0]?.isDone == true } }

    func liveStatus() -> (NSColor, String) {
        if let busy = setup.busy { return (.systemGray, busy) }
        if let (c, t) = client.statusDot { return (c, client.isHealthy ? "Live" : t) }
        return (.systemGray, RELAY.workerURL.isEmpty ? "Not connected" : "Off · polling")
    }

    func planeRow(_ slug: String, y: CGFloat) -> CGFloat {
        let st = setup.hooks.statuses[HookManager.planeKey(slug)] ?? .unknown
        let row = NSView(frame: NSRect(x: 0, y: y, width: POP_W, height: 26))
        row.addSubview(Dot(color: hookColor(st), frame: NSRect(x: 18, y: 8, width: 8, height: 8)))
        row.addSubview(label(slug, x: 34, y: 5, width: 110, size: 12))
        let pills = label("work item · comment · project", x: 148, y: 5, width: 250, size: 11, color: .secondaryLabelColor)
        pills.toolTip = setup.describe(st)
        row.addSubview(pills)
        let title: String
        switch st {
        case .live, .waiting: title = "Check again"
        default: title = "Add webhook"
        }
        let b = button(title, #selector(planeHookAction(_:)), x: POP_W - 156, y: 2, width: 140)
        b.identifier = NSUserInterfaceItemIdentifier(slug)
        b.isEnabled = setup.busy == nil && connected
        b.toolTip = setup.describe(st)
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
        tv.string = setup.log.joined(separator: "\n")
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
        setup.refreshState { [weak self] in self?.lastHealthCheck = .distantPast; self?.afterInspect() }
    }

    @objc func connect() {
        let url = urlField?.stringValue ?? ""
        let typed = tokenField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let token = typed.isEmpty ? setup.secrets.get(SecretStore.deviceToken) : typed else {
            setup.append("Enter the device token"); return
        }
        let s = setup
        s.perform("Connect to \(url)", { s.connect(url: url, token: token) }) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.urlDraft = nil
                self.client.start()
                (NSApp.delegate as? GHActionsBar)?.scheduleTimer()
            }
            self.checkAgain()
        }
    }

    @objc func disconnect() {
        guard confirm("Disconnect this Mac?",
                      "OverSire deletes the device token from the Keychain and goes back to polling. The webhooks and the other Macs stay.",
                      ok: "Disconnect") else { return }
        client.stop()
        setup.disconnect()
        urlDraft = nil
        (NSApp.delegate as? GHActionsBar)?.scheduleTimer()
        rebuild()
    }

    @objc func installHooks() {
        let s = setup, repos = REPOS
        s.perform("Install webhooks", { s.installHooks(repos: repos) }) { [weak self] _ in
            s.checkHooks(repos: repos)
            self?.checkAgain()
        }
    }

    @objc func checkPlaneHooks() { setup.checkPlaneHooks(workspaces) }

    @objc func planeHookAction(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue else { return }
        switch setup.hooks.statuses[HookManager.planeKey(slug)] ?? .unknown {
        case .live, .waiting:
            setup.checkPlaneHooks([slug])
        default:
            let s = setup
            s.perform("Install Plane webhook for \(slug)", { s.installPlaneHooks([slug]) }) { [weak self] _ in
                s.checkPlaneHooks([slug])
                self?.rebuild()
            }
        }
    }

    @objc func openProjectSettings() {
        (NSApp.delegate as? GHActionsBar)?.showSettings(.projects)
    }

    @objc func saveConfiguration() {
        let n = Int(retentionField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let hours = retentionUnit?.indexOfSelectedItem == 1 ? n * 24 : n
        let minutes = Int(reconcileField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 10
        guard (1...720).contains(hours) else { setup.append("Retention must be from 1 hour to 30 days."); return }
        RELAY.reconcileInterval = TimeInterval(min(max(minutes, 1), 120) * 60)
        saveConfig()
        (NSApp.delegate as? GHActionsBar)?.scheduleTimer()
        retentionField = nil; reconcileField = nil; retentionUnit = nil
        let s = setup
        s.perform("Set retention to \(hours) h", { s.setRetention(hours: hours) }) { [weak self] _ in self?.checkAgain() }
    }

    @objc func removeDevice(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let s = setup
        s.perform("Remove device \(id)", { s.removeDevice(id) }) { [weak self] _ in self?.checkAgain() }
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

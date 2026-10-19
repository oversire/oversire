import Cocoa
import OverSireCore

// The state of the Live updates section that a rebuild keeps.
final class LiveForm {
    weak var url: NSTextField?
    weak var code: NSSecureTextField?
    weak var log: TermView?
    weak var retention: NSTextField?
    weak var unit: NSPopUpButton?
    var checked = false
    var lastHookCheck = Date.distantPast
}

// Settings › Accounts and sync: services, live updates and polling.
extension SettingsPage {
    static let liveForm = LiveForm()
    static let pollNormal = [15, 30, 60, 120, 300]
    static let pollActive = [5, 10, 20, 30]
    private var lf: LiveForm { SettingsPage.liveForm }
    private var setup: CloudSetup { data.cloudSetup }

    func accounts(_ b: NSStackView) {
        providers(b)
        live(b)
        if let records = cloudAIRecords, UIShots.cloud == nil { RunnerSetup.shared.offerOnce(records: records) }
    }

    private func live(_ b: NSStackView) {
        setup.onChange = { [weak self] in self?.reloadSoon() }
        setup.onLog = { [weak self] in
            guard let self else { return }
            self.lf.log?.set(self.setup.log)
        }
        // No app delegate in --uishots: the shots never call the cloud.
        if !lf.checked, setup.busy == nil, app != nil { checkCloud() }

        let s = setup.state
        let idle = setup.busy == nil
        let (tone, title) = liveStatus()
        var rows: [NSView] = []
        var acts: [NSView] = []
        if s.joined {
            let check = ActionButton("Check again") { [weak self] in self?.checkCloud() }
            check.isEnabled = idle
            let disc = ActionButton("Disconnect") { [weak self] in self?.disconnect() }
            disc.isEnabled = idle
            acts = [check, disc]
        } else {
            let conn = ActionButton("Connect", style: .primary) { [weak self] in self?.connect() }
            conn.isEnabled = idle
            acts = [conn]
        }
        rows.append(Row([Glyph(tone, size: 14), TwoLine(title, liveDetail(), weight: .medium), Spacer()] + acts, height: 56, label: title))

        if s.joined {
            rows.append(SwitchRow("Live updates", note: "Off: this Mac polls, and the cloud keeps the webhooks.", on: RELAY.enabled) { [weak self] in
                RELAY.enabled = $0
                saveConfig()
                self?.data.relay.start()
                self?.reload()
            })
            rows.append(githubHooks())
            rows += planeHooks()
        } else {
            let url = NSTextField(string: lf.url?.stringValue ?? RELAY.workerURL)
            url.placeholderString = "https://oversire-cloud.example.workers.dev"
            url.setAccessibilityLabel("Cloud URL")
            url.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let code = NSSecureTextField()
            code.placeholderString = "Pairing code or device token"
            code.setAccessibilityLabel("Pairing code")
            code.widthAnchor.constraint(equalToConstant: 300).isActive = true
            lf.url = url
            lf.code = code
            rows.append(FieldRow("Cloud URL", note: "The OverSire Cloud console shows it.", url))
            rows.append(FieldRow("Pairing code", note: "Get one in the console. OverSire keeps the device token in the Keychain.", code))
        }
        if let h = s.health {
            let q = WriteQuota(rowsToday: h.rowsWrittenToday, now: Date())
            if q.warn {
                rows.append(Padded(Banner(.warning, title: "Near the free write quota.",
                                          body: "Projected \(q.projected.formatted()) of \(FREE_ROWS_PER_DAY.formatted()) writes today. Use Workers Paid, or track fewer repos.")))
            }
        }
        rows.append(FieldRow("Poll every", note: "For repos without a webhook, and when the cloud is off.",
                             Segmented(Self.pollNormal.map(Self.seconds), selected: Self.pollNormal.firstIndex(of: Int(POLL_NORMAL)) ?? 2, label: "Poll every") { [weak self] i in
            POLL_NORMAL = TimeInterval(Self.pollNormal[i])
            self?.pollChanged()
        }))
        rows.append(FieldRow("Poll a run in progress every", note: "While the popover is open.",
                             Segmented(Self.pollActive.map(Self.seconds), selected: Self.pollActive.firstIndex(of: Int(POLL_ACTIVE)) ?? 1,
                                       label: "Poll a run in progress every") { [weak self] i in
            POLL_ACTIVE = TimeInterval(Self.pollActive[i])
            self?.pollChanged()
        }))
        rows.append(advanced())

        let head = NSStackView(h: [NSTextField.text("LIVE UPDATES", size: 11, weight: .semibold, color: Palette.dim), Pill(.idle, text: "Beta"), Spacer()], spacing: 8)
        let v = NSStackView(v: [head], spacing: 6)
        let card = ListCard()
        rows.forEach { card.add($0) }
        v.addFull(card)
        v.addFull(NSTextField.text("OverSire cloud sends GitHub and Plane webhooks to this Mac, so pages update in seconds. With the cloud live, a poll only checks the state at the reconcile time.",
                                   size: 11.5, color: Palette.dim, lines: 0))
        v.identifier = SettingsAnchor.live.id
        b.addFull(v)
    }

    static func seconds(_ s: Int) -> String { s < 60 ? "\(s) s" : "\(s / 60) min" }

    func liveStatus() -> (Tone, String) {
        let s = setup.state
        if let busy = setup.busy { return (.running, busy) }
        if s.joined {
            if !RELAY.enabled { return (.idle, "Off · polling") }
            if data.relay.isHealthy || UIShots.live != nil { return (.ok, "Live via OverSire cloud") }
            return (.warning, data.relay.statusDot?.1 ?? "Connecting · polling meanwhile")
        }
        if RELAY.workerURL.isEmpty { return (.idle, "Not connected") }
        if !lf.checked { return (.running, "Checks the cloud…") }
        return (.bad, s.joinError ?? "Cannot reach the cloud")
    }

    private func liveDetail() -> String {
        let s = setup.state
        guard s.joined else { return "Pair this Mac to get webhooks in place of polls." }
        guard let h = s.health else { return "This Mac is connected" + (s.version.map { " · cloud v\($0)" } ?? "") }
        let n = h.devices.count
        let last = h.lastWebhookAt.map { "last event " + relativeAgo(Date(timeIntervalSince1970: $0 / 1000)) } ?? "no event yet"
        return "\(n) device\(n == 1 ? "" : "s") · \(last) · \(h.rowsWrittenToday.formatted()) of \(FREE_ROWS_PER_DAY / 1000)k writes today"
    }

    private func githubHooks() -> NSView {
        let health = HookHealth(repos: REPOS, statuses: setup.hooks.statuses)
        let repair = health.repair
        var top: [NSView] = [NSTextField.text("GitHub webhooks", size: 13, weight: .medium), Spacer(),
                             NSTextField.text("\(health.live.count) of \(REPOS.count) repos", size: 12, color: Palette.dim)]
        if !repair.isEmpty {
            let fix = ActionButton("Repair \(repair.count)", style: .primary) { [weak self] in self?.installHooks(repair) }
            fix.isEnabled = setup.busy == nil
            top.append(fix)
        }
        let col = NSStackView(v: [], spacing: 10)
        col.addFull(NSStackView(h: top, spacing: 12))
        if REPOS.isEmpty {
            col.addFull(NSTextField.text("Track a repo to add a webhook.", size: 12, color: Palette.dim))
        } else {
            col.addFull(HealthBar(health.counts, trailing: [ActionButton("Show in the repo list ›", style: .link) { [weak self] in
                self?.go(.settings(.projects, tab: .repos, anchor: "problems"))
            }]))
        }
        return Padded(col)
    }

    private func planeHooks() -> [NSView] {
        let slugs = setup.trackedWorkspaces()
        guard !slugs.isEmpty else { return [FieldRow("Plane webhooks", note: "Track a Plane project to add a workspace webhook.", NSView())] }
        return slugs.map { slug in
            let st = setup.hooks.statuses[HookManager.planeKey(slug)] ?? .unknown
            let pill: Pill
            var done = false
            switch st {
            case .live: pill = Pill(.ok, text: "Live"); done = true
            case .waiting: pill = Pill(.ok, text: "No delivery yet"); done = true
            case .pollingOnly: pill = Pill(.warning, text: "Polls · needs an admin")
            case .error: pill = Pill(.bad, text: "Failed")
            case .unknown: pill = Pill(.queued, text: "Not checked")
            }
            pill.toolTip = setup.describe(st)
            let act = ActionButton(done ? "Check again" : "Add webhook") { [weak self] in self?.planeHookAction(slug, done: done) }
            act.isEnabled = setup.busy == nil
            return Row([TwoLine("Plane webhooks", "Workspace \(slug)", weight: .medium), Spacer(), pill, act], height: 52, label: "Plane webhooks \(slug)")
        }
    }

    private func advanced() -> NSView {
        let d = Disclosure("Advanced: event retention, reconcile poll, devices, log", id: "live-advanced")
        if let h = setup.state.health {
            let days = h.retentionHours % 24 == 0 && h.retentionHours >= 24
            let n = NSTextField(string: String(days ? h.retentionHours / 24 : h.retentionHours))
            n.alignment = .right
            n.setAccessibilityLabel("Keep events for")
            n.widthAnchor.constraint(equalToConstant: 56).isActive = true
            n.target = self
            n.action = #selector(retentionChanged)
            let unit = NSPopUpButton()
            unit.addItems(withTitles: ["hours", "days"])
            unit.selectItem(at: days ? 1 : 0)
            unit.setAccessibilityLabel("Unit")
            unit.target = self
            unit.action = #selector(retentionChanged)
            lf.retention = n
            lf.unit = unit
            d.add(FieldRow("Keep events for", note: "1 hour to 30 days.", NSStackView(h: [n, unit], spacing: 6)))
        }
        let rec = TextInput(String(Int((RELAY.reconcileInterval ?? 600) / 60)), label: "Reconcile poll") { [weak self] v in
            RELAY.reconcileInterval = TimeInterval(min(max(Int(v) ?? 10, 1), 120) * 60)
            saveConfig()
            self?.data.relay.update()
        }
        rec.alignment = .right
        rec.widthAnchor.constraint(equalToConstant: 56).isActive = true
        d.add(FieldRow("Reconcile poll while live", note: "Minutes, from 1 to 120.", rec))
        for dev in setup.state.health?.devices ?? [] {
            let me = dev.id == RELAY.deviceID
            let seen = dev.connected ? "Connected" : (dev.lastSeen.map { "Seen " + relativeAgo(Date(timeIntervalSince1970: $0 / 1000)) } ?? "Never seen")
            var row: [NSView] = [Glyph(dev.connected ? .ok : .idle, size: 13), TwoLine((dev.name ?? dev.id) + (me ? " (this Mac)" : ""), "\(seen) · lag \(dev.lag)"), Spacer()]
            if !me {
                let rm = ActionButton("Remove") { [weak self] in self?.removeDevice(dev.id) }
                rm.isEnabled = setup.busy == nil
                row.append(rm)
            }
            d.add(Row(row, height: 44, label: dev.name ?? dev.id))
        }
        let log = TermView(lines: setup.log, height: 140)
        log.setAccessibilityLabel("Cloud log")
        lf.log = log
        d.add(Padded(log, vertical: 10))
        return d
    }

    func pollChanged() {
        saveConfig()
        app?.relay.update()
        app?.updatePolling()
        NotificationCenter.default.post(name: AppWindow.changed, object: nil)
    }

    // MARK: Actions

    private func checkCloud() {
        lf.checked = true
        setup.refreshState { [weak self] in
            guard let self else { return }
            if self.setup.state.joined, Date().timeIntervalSince(self.lf.lastHookCheck) > 5 {
                self.setup.checkHooks(repos: REPOS)
                self.setup.checkPlaneHooks(self.setup.trackedWorkspaces())
                self.lf.lastHookCheck = Date()
            }
        }
    }

    private func connect() {
        let url = lf.url?.stringValue ?? ""
        let typed = lf.code?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let token = typed.isEmpty ? setup.secrets.get(SecretStore.deviceToken) : typed else {
            setup.append("Enter a pairing code from the console")
            return
        }
        let s = setup
        s.perform("Connect to \(url)", { await s.connect(url: url, credential: token) }) { [weak self] ok in
            if ok { self?.data.relay.start() }
            self?.lf.lastHookCheck = .distantPast
            self?.checkCloud()
        }
    }

    private func disconnect() {
        let a = NSAlert()
        a.messageText = "Disconnect this Mac?"
        a.informativeText = "OverSire deletes the device token from the Keychain and goes back to polling. The webhooks and the other Macs stay."
        a.alertStyle = .warning
        a.addButton(withTitle: "Disconnect")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        setup.disconnect()
        data.relay.forgetCloudCursor()
        data.relay.start()
        reload()
    }

    private func installHooks(_ repos: [String]) {
        let s = setup
        s.perform("Install webhooks", { s.installHooks(repos: repos) }) { [weak self] _ in
            s.checkHooks(repos: REPOS)
            self?.reload()
        }
    }

    private func planeHookAction(_ slug: String, done: Bool) {
        if done { setup.checkPlaneHooks([slug]); return }
        let s = setup
        s.perform("Install Plane webhook for \(slug)", { await s.installPlaneHooks([slug]) }) { _ in s.checkPlaneHooks([slug]) }
    }

    @objc private func retentionChanged() {
        let n = Int(lf.retention?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let hours = lf.unit?.indexOfSelectedItem == 1 ? n * 24 : n
        guard (1...720).contains(hours) else { setup.append("Retention must be from 1 hour to 30 days."); return }
        guard hours != setup.state.health?.retentionHours else { return }
        let s = setup
        s.perform("Set retention to \(hours) h", { s.setRetention(hours: hours) }) { [weak self] _ in self?.checkCloud() }
    }

    private func removeDevice(_ id: String) {
        let s = setup
        s.perform("Remove device \(id)", { s.removeDevice(id) }) { [weak self] _ in self?.checkCloud() }
    }
}

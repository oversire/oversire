import Cocoa
import OverSireCore
import OverSireAI
import AIEngineAgentBinder
import AgentBinder
import OverSireAssistant

// An API key field with Show and Hide. It commits on end editing only.
final class KeyField: NSStackView, NSTextFieldDelegate {
    private let secure = NSSecureTextField()
    private let plain = NSTextField()
    private let show = ActionButton("Show")
    private let commit: (String) -> Void

    init(_ value: String, label: String, _ commit: @escaping (String) -> Void) {
        self.commit = commit
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        for f in [secure, plain] {
            f.stringValue = value
            f.placeholderString = "Stored in the Keychain"
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.delegate = self
            f.setAccessibilityLabel(label)
            f.widthAnchor.constraint(equalToConstant: 220).isActive = true
            addArrangedSubview(f)
        }
        plain.isHidden = true
        show.onClick = { [weak self] in self?.toggle() }
        show.setAccessibilityLabel("Show the API key")
        addArrangedSubview(show)
    }
    required init(coder: NSCoder) { fatalError() }

    private func toggle() {
        let showing = plain.isHidden
        (showing ? plain : secure).stringValue = (showing ? secure : plain).stringValue
        plain.isHidden = !showing
        secure.isHidden = showing
        show.title = showing ? "Hide" : "Show"
        show.setAccessibilityLabel(showing ? "Hide the API key" : "Show the API key")
    }

    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        commit(f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// Settings › AI: the engine (local CLI or API key), a Test for each, and the jobs that use AI. Each change saves at once.
// AI stays off until Test passes for the chosen engine.
extension SettingsPage {
    static var aiTesting = false
    static var aiTestResult: (ok: Bool, text: String)?
    static var cliTesting = false
    static var cliTestResult: (ok: Bool, text: String)?

    func ai(_ b: NSStackView) {
        if !AI_CFG.isOn(key: aiKey) {
            b.addFull(Banner(.idle, title: "AI is off.",
                             body: "Pick the engine and press Test. The switches take effect when AI is on. The intake agent and flaky marks work without it."))
        }
        engine(b)
        if AI_CFG.engine == .localCLI { localCLI(b) }
        apiKey(b)
        useAIFor(b)
        assistant(b)
        app?.assistantRoot.configChanged()
        let cloud = CloudAICard(cloudAIRecords)
        cloud.identifier = SettingsAnchor.cloudAI.id
        b.addFull(cloud)
    }

    private var aiKey: String { UIShots.aiKey ?? AIClient.keyStore.get(AIClient.keyName) ?? "" }

    private func engine(_ b: NSStackView) {
        let cfg = AI_CFG
        let local = cfg.engine == .localCLI
        let pick = Segmented(["Local CLI · Free", "API key", "Cloud credits · Pro"], selected: local ? 0 : 1, label: "Engine") { [weak self] i in
            if i < 2 {
                AI_CFG.engine = i == 0 ? .localCLI : .apiKey
                saveConfig()
            }
            self?.reloadSoon()
        }
        pick.setEnabled(false, forSegment: 2)
        pick.setToolTip("Later. Cloud credits need OverSire Cloud.", forSegment: 2)
        let verified = cfg.engineVerified(key: aiKey)
        var rows: [NSView] = [
            FieldRow("Engine", note: local ? "Your coding agent CLI with its own login and plan." : "Your own endpoint and key.", pick),
            SwitchRow("Use AI", note: verified ? "Turn off to stop all AI jobs." : "Test must pass first.", on: cfg.enabled && verified, enabled: verified) {
                AI_CFG.enabled = $0
            },
        ]
        let extra = TextInput(cfg.extraContext, placeholder: "Titles start with a verb.", label: "Extra context", lines: 3) { v in
            AI_CFG.extraContext = v
            saveConfig()
        }
        let extraRow = NSStackView(v: [], spacing: 6)
        extraRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        extraRow.addArrangedSubview(NSTextField.text("Extra context", size: 13, weight: .medium))
        extraRow.addFull(extra)
        extraRow.addArrangedSubview(NSTextField.text("Sent with each request. For example: the product names and how titles start.", size: 11.5, color: Palette.dim))
        rows.append(extraRow)
        b.addFull(section(.engine, rows))
    }

    // The CLIs on this Mac, the model, the effort, the plan limits, the fallback and a Test.
    private func localCLI(_ b: NSStackView) {
        let cli = LocalCLI.shared
        cli.detect()
        let cfg = AI_CFG
        if cfg.cliHarness.isEmpty, let first = cli.detections?.first(where: { $0.ready && Self.listed($0) }) {
            AI_CFG.cliHarness = first.harness.rawValue
            saveConfig()
        }
        let h = AI_CFG.cliHarness
        cli.loadModels(h)
        let changed: () -> Void = { [weak self] in
            Self.cliTestResult = nil
            saveConfig()
            self?.reloadSoon()
        }
        var rows: [NSView] = [Padded(NSTextField.text(
            "OverSire runs your coding agent CLI through AgentBinder. Each job runs with no tools, in an empty folder, and uses your own login and plan. "
                + "The text goes only to the vendor of that CLI. A call takes 4 to 10 s in the background.",
            size: 12, color: Palette.mut, lines: 3), vertical: 8)]
        rows.append(cliTable(h, pick: { name in
            guard name != AI_CFG.cliHarness else { return }
            AI_CFG.cliHarness = name
            AI_CFG.cliModel = ""
            changed()
        }))

        let models = cli.models[h] ?? []
        var ids = [""] + models.map(\.id)
        if !cfg.cliModel.isEmpty, !ids.contains(cfg.cliModel) { ids.append(cfg.cliModel) }
        let titles = ids.map { id in id.isEmpty ? "Default of the CLI" : models.first { $0.id == id }?.name ?? id }
        rows.append(FieldRow("Model", note: "From the model list of the CLI. Pick a small, fast model.",
                             PopUp(titles, selected: ids.firstIndex(of: cfg.cliModel) ?? 0, label: "Model") { i in
            AI_CFG.cliModel = ids[i]
            saveConfig()
        }))
        let efforts = ["", "low", "medium", "high"]
        rows.append(FieldRow("Effort", note: "For CLIs that have an effort level.",
                             PopUp(["Default", "Low", "Medium", "High"], selected: efforts.firstIndex(of: cfg.cliEffort) ?? 0, label: "Effort") { i in
            AI_CFG.cliEffort = efforts[i]
            saveConfig()
        }))
        rows.append(limitsRow(cli.lastLimits ?? cli.plans[h]))
        let fallbacks: [AIFallback] = [.apiKey, .wait, .skip]
        let keyOK = cfg.keyVerified(aiKey)
        rows.append(FieldRow("If it fails", note: cfg.fallback == .apiKey && !keyOK
                                ? "The API key has no passed Test, so the job is skipped. Each fallback goes to the log."
                                : "Wait tries once more after 2 min. Each fallback goes to the log.",
                             PopUp(["Use the API key", "Wait and try again", "Skip the job"], selected: fallbacks.firstIndex(of: cfg.fallback) ?? 0,
                                   label: "If it fails") { [weak self] i in
            AI_CFG.fallback = fallbacks[i]
            saveConfig()
            self?.reloadSoon()
        }))
        rows.append(testRow(note: "Asks the CLI for one short answer.", testing: Self.cliTesting, result: Self.cliTestResult,
                            verified: cfg.cliVerifiedNow, tested: !cfg.cliVerified.isEmpty, enabled: !h.isEmpty) { [weak self] in self?.runCLITest() })
        let again: NSView = cli.detecting ? InlineSpinner("Detecting…") : ActionButton("Detect again", symbol: "arrow.clockwise") { cli.detect(again: true) }
        rows.append(Row([TwoLine("Detection", "AgentBinder finds each CLI on PATH and reads its login. Press after you install or log in.", lines: 2),
                         Spacer(), again], height: 52, label: "Detection"))
        b.addFull(section(.localCLI, rows))
    }

    // The chat panel: its engine, what its tools may do without a question, Follow along, the shortcut and the history.
    private func assistant(_ b: NSStackView) {
        let cfg = AI_CFG.assistant
        let sources: [AssistantConfig.Source] = [.jobs, .localCLI, .apiKey]
        let pick = Segmented(["Same as AI jobs", "Local CLI", "API key", "Cloud · Pro"], selected: sources.firstIndex(of: cfg.source) ?? 0,
                             label: "Assistant source") { [weak self] i in
            if i < sources.count {
                AI_CFG.assistant.source = sources[i]
                saveConfig()
            }
            self?.reloadSoon()
        }
        pick.setEnabled(false, forSegment: 3)
        pick.setToolTip("Later. Cloud credits need OverSire Cloud.", forSegment: 3)
        var rows: [NSView] = [FieldRow("Source", note: "The engine of the chat panel. The other engine is the fallback.", pick)]
        if cfg.engine(jobs: AI_CFG.engine) == .localCLI, let note = Self.cliChatNote(AI_CFG.cliHarness) {
            rows.append(Padded(Banner(.warning, title: "This CLI cannot chat.", body: note), vertical: 8))
        }

        let rules: [PermissionRule] = [.allow, .askOnce, .askEach, .never]
        let names = ["Run", "Ask once in each chat", "Ask each time", "Never"]
        let rule: (String, String, PermissionRule, @escaping (PermissionRule) -> Void) -> NSView = { title, note, now, set in
            FieldRow(title, note: note, PopUp(names, selected: rules.firstIndex(of: now) ?? 0, label: title) { i in
                set(rules[i])
                saveConfig()
            })
        }
        rows.append(rule("Read tools", "Look at items, PRs, runs, sessions and pages.", cfg.permissions.read) { AI_CFG.assistant.permissions.read = $0 })
        rows.append(rule("Change tools", "Change OverSire or the tracker: queue, states, comments.", cfg.permissions.change) {
            AI_CFG.assistant.permissions.change = $0
        })
        rows.append(FieldRow("Outward tools", note: "Merge, re-run, start a session, send to an agent. Fixed for safety.",
                             NSTextField.text("Ask each time", size: 12, color: Palette.mut)))
        rows.append(FieldRow("Settings", note: "The assistant tells you where a setting is. Only you change it.",
                             NSTextField.text("Never", size: 12, color: Palette.mut)))
        rows.append(SwitchRow("Follow along", note: "New chats move the window to the pages they talk about. Each chat can turn it off.",
                              on: cfg.follow) { AI_CFG.assistant.follow = $0 })

        let key = ShortcutField(cfg.hotkey)
        key.setAccessibilityLabel("Assistant shortcut")
        let set: (KeyShortcut) -> Void = { [weak self, weak key] k in
            AI_CFG.assistant.hotkey = k
            saveConfig()
            key?.set(k)
            _ = self?.app?.applyAssistantHotKey()
        }
        key.onChange = { set(KeyShortcut(keyCode: $0, modifiers: $1)) }
        let clear = ActionButton("Clear") { set(KeyShortcut(keyCode: cfg.hotkey.keyCode, modifiers: 0)) }
        rows.append(FieldRow("Open from any app", note: "In the window, ⌘J opens the panel.", NSStackView(h: [key, clear], spacing: 6)))

        let keeps: [ChatRetention] = [.days7, .days30, .always]
        rows.append(FieldRow("Keep chats", note: "Older chats go away. Pinned chats stay.",
                             PopUp(["7 days", "30 days", "Always"], selected: keeps.firstIndex(of: cfg.retention) ?? 1, label: "Keep chats") { i in
            AI_CFG.assistant.retention = keeps[i]
            saveConfig()
        }))
        b.addFull(section(.assistant, rows))
    }

    /// Why the CLI cannot chat, or nil when it can. A chat needs MCP for the tools.
    static func cliChatNote(_ harness: String) -> String? {
        guard !harness.isEmpty else { return "Pick a CLI in Local CLI. The chat uses the API key until then." }
        guard let d = LocalCLI.shared.detections?.first(where: { $0.harness.rawValue == harness }) else { return nil }
        guard d.features.mcpInject == .none else { return nil }
        return "\(d.harness.binaryName) has no MCP, so it cannot call the tools. The chat uses the API key."
    }

    // The CLI and the agent library are not in the table.
    private static func listed(_ d: Detection) -> Bool { d.harness != .fake && d.harness != .native }

    private func cliTable(_ selected: String, pick: @escaping (String) -> Void) -> NSView {
        let v = NSStackView(v: [], spacing: 0)
        let head = Row([NSTextField.text("CLI", size: 11, weight: .semibold, color: Palette.dim), NSTextField.text("VERSION", size: 11, weight: .semibold, color: Palette.dim),
                        NSTextField.text("LOGIN", size: 11, weight: .semibold, color: Palette.dim), NSTextField.text("PLAN", size: 11, weight: .semibold, color: Palette.dim),
                        Spacer()], height: 28)
        Self.columns(head)
        v.addFull(head)
        guard let all = LocalCLI.shared.detections else {
            v.addFull(Padded(InlineSpinner("Looking for the CLIs on this Mac…"), vertical: 8))
            return v
        }
        for d in all where Self.listed(d) {
            let name = d.harness.rawValue
            let login = Self.login(d)
            let plan = LocalCLI.shared.plans[name].map(Self.planText) ?? (d.ready ? "—" : "")
            let row = Row([NSTextField.text(d.harness.binaryName, size: 12.5, weight: .medium, mono: true),
                           NSTextField.text(d.version.flatMap { v in v.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init) } ?? "—", size: 12, color: Palette.mut, mono: true),
                           NSStackView(h: [Glyph(login.symbol, color: login.color, size: 11),
                                           TwoLine(login.text, d.authDetail ?? login.hint, titleSize: 12, weight: .regular)], spacing: 5),
                           NSTextField.text(plan, size: 12, color: Palette.mut), Spacer()],
                          height: 46, label: "\(d.harness.binaryName), \(login.text)")
            Self.columns(row)
            if d.supported {
                row.selected = name == selected
                row.onClick = { pick(name) }
                row.toolTip = name == selected ? "OverSire uses this CLI" : "Use this CLI"
            } else {
                row.alphaValue = 0.6
            }
            v.addFull(row)
        }
        return v
    }

    private static func columns(_ r: Row) {
        for (v, w) in zip(r.stack.arrangedSubviews, [120, 80, 230, 200] as [CGFloat]) {
            v.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
    }

    // A shape and a word for the login state. Color is not the only signal.
    private static func login(_ d: Detection) -> (symbol: String, color: NSColor, text: String, hint: String?) {
        switch d.detail {
        case .notInstalled?: return ("circle", Palette.dim, "Not installed", nil)
        case .belowFloor(let f)?: return ("exclamationmark.triangle.fill", Palette.warn, "Needs \(f) or newer", "Update the CLI")
        case .sandboxed?, .noDriver?: return ("circle", Palette.dim, "Not available", nil)
        case nil: break
        }
        switch d.auth {
        case .ok: return ("checkmark.circle.fill", Palette.ok, "Logged in", nil)
        case .missing: return ("exclamationmark.triangle.fill", Palette.warn, "Not logged in", "Run \(d.harness.binaryName) once")
        case .unknown: return ("questionmark.circle", Palette.dim, "Login not known", "Test to check")
        }
    }

    private static func planText(_ l: Limits) -> String {
        let windows = l.windows.filter { $0.key == .fiveHour || $0.key == .weekly }.map { PlanLimits.name($0) }
        let plan = l.plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
        let limits = windows.isEmpty ? "" : windows.joined(separator: " and ") + " limits"
        return [plan, limits].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func limitsRow(_ l: Limits?) -> NSView {
        let steps = [70, 80, 90, 95]
        let pause = PopUp(steps.map { "\($0)%" }, selected: steps.firstIndex(of: AI_CFG.cliLimitPause) ?? 2, label: "Jobs pause above") { i in
            AI_CFG.cliLimitPause = steps[i]
            saveConfig()
        }
        var bars: [NSView] = []
        for w in (l?.windows ?? []).filter({ $0.key != .custom }).prefix(3) {
            let over = w.usedPercent >= Double(AI_CFG.cliLimitPause)
            bars.append(NSStackView(h: [NSTextField.text(PlanLimits.name(w), size: 12, color: Palette.mut),
                                        UsageBar(w.usedPercent / 100, color: over ? Palette.warn : Palette.acc),
                                        NSTextField.text("\(Int(w.usedPercent))%" + (over ? " ▲" : ""), size: 12, color: over ? Palette.warn : Palette.mut, mono: true)],
                                    spacing: 6))
        }
        if bars.isEmpty { bars = [NSTextField.text("No limits read yet. Test reads them.", size: 12, color: Palette.dim)] }
        return Row([TwoLine("Plan limits", "From the last call. Jobs pause above", lines: 2), Spacer()] + bars + [pause], height: 52, label: "Plan limits")
    }

    private func testRow(note: String, testing: Bool, result: (ok: Bool, text: String)?, verified: Bool, tested: Bool, enabled: Bool,
                         run: @escaping () -> Void) -> NSView {
        let test = ActionButton(testing ? "Testing…" : "Test", run)
        test.isEnabled = !testing && enabled
        let pill: Pill
        if testing { pill = Pill(.running, text: "Testing") }
        else if let r = result { pill = Pill(r.ok ? .ok : .bad, text: r.ok ? r.text : "Failed"); pill.toolTip = r.text }
        else if verified { pill = Pill(.ok, text: "Passed") }
        else { pill = Pill(.idle, text: tested ? "Changed · test again" : "Not tested") }
        return Row([TwoLine("Test", result.flatMap { $0.ok ? nil : $0.text } ?? note, lines: 2), Spacer(), pill, test], height: 52, label: "Test")
    }

    private func apiKey(_ b: NSStackView) {
        let cfg = AI_CFG
        let openai = cfg.format == .openai
        let changed: () -> Void = { [weak self] in
            Self.aiTestResult = nil
            saveConfig()
            self?.reloadSoon()
        }
        let format = Segmented(["OpenAI compatible", "Anthropic"], selected: openai ? 0 : 1, label: "Format") { i in
            AI_CFG.format = i == 1 ? .anthropic : .openai
            changed()
        }
        let urlHint = openai ? "https://api.openai.com/v1" : "https://api.anthropic.com"
        let url = TextInput(cfg.baseURL, placeholder: urlHint, label: "Endpoint", mono: true) { v in
            AI_CFG.baseURL = v.trimmingCharacters(in: .whitespaces)
            changed()
        }
        let model = TextInput(cfg.model, placeholder: openai ? "gpt-5-mini" : "claude-haiku-5-5", label: "Model", mono: true) { v in
            AI_CFG.model = v.trimmingCharacters(in: .whitespaces)
            changed()
        }
        for f in [url, model] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        let key = KeyField(aiKey, label: "API key") { v in
            if v.isEmpty { AIClient.keyStore.delete(AIClient.keyName) } else { AIClient.keyStore.set(AIClient.keyName, v) }
            changed()
        }
        let base = cfg.baseURL.isEmpty ? urlHint : cfg.baseURL
        var rows: [NSView] = []
        if cfg.engine == .localCLI {
            rows.append(Padded(NSTextField.text("The fallback for Local CLI. A call takes 1 to 3 s and bills your key.", size: 12, color: Palette.mut, lines: 2), vertical: 8))
        }
        rows += [
            FieldRow("Format", format),
            FieldRow("Endpoint", note: "POST " + (openai ? OpenAIDialect.endpoint(base) : AnthropicDialect.endpoint(base)), url),
            FieldRow("Model", model),
            FieldRow("API key", note: "The key stays in the Keychain.", key),
        ]
        if openai {
            let efforts = OpenAIDialect.efforts
            rows.append(FieldRow("Reasoning effort", PopUp(efforts, selected: efforts.firstIndex(of: cfg.effort) ?? efforts.firstIndex(of: "low") ?? 0,
                                                          label: "Reasoning effort") { i in
                AI_CFG.effort = efforts[i]
                saveConfig()
            }))
        } else {
            let tokens = TextInput("\(cfg.maxTokens)", placeholder: "1024", label: "Max tokens", mono: true) { v in
                AI_CFG.maxTokens = min(32000, max(64, Int(v) ?? 1024))
                changed()
            }
            tokens.widthAnchor.constraint(equalToConstant: 100).isActive = true
            rows.append(FieldRow("Max tokens", tokens))
        }
        rows.append(testRow(note: "Sends one short request to the endpoint.", testing: Self.aiTesting, result: Self.aiTestResult,
                            verified: cfg.keyVerified(aiKey), tested: !cfg.verified.isEmpty, enabled: !cfg.baseURL.isEmpty && !cfg.model.isEmpty) { [weak self] in
            self?.runAITest()
        })
        b.addFull(section(.apiKey, rows))
    }

    private func runAITest() {
        Self.aiTesting = true
        Self.aiTestResult = nil
        reload()
        let tested = AI_CFG
        let key = aiKey
        AIClient(cfg: tested, router: AIRouter(engines: [APIKeyEngine(config: tested.apiKey, key: key, http: URLSessionTransport())])).test { [weak self] r in
            Self.aiTesting = false
            switch r {
            case .success(let t):
                // A pass counts only for the values that were tested.
                if tested.fingerprint(key: key) == AI_CFG.fingerprint(key: self?.aiKey ?? "") {
                    if AI_CFG.verified.isEmpty, AI_CFG.engine == .apiKey { AI_CFG.enabled = true }
                    AI_CFG.verified = AI_CFG.fingerprint(key: key)
                }
                Self.aiTestResult = (true, String(format: "Passed in %.1f s", t))
            case .failure(let e):
                AI_CFG.verified = ""
                Self.aiTestResult = (false, e.message)
            }
            settingsChanged()
            self?.reload()
        }
    }

    private func runCLITest() {
        Self.cliTesting = true
        Self.cliTestResult = nil
        reload()
        let tested = AI_CFG
        AIClient(cfg: tested, router: AIRouter(engines: [LocalCLI.shared.engine(tested)])).test { [weak self] r in
            Self.cliTesting = false
            switch r {
            case .success(let t):
                if tested.cliFingerprint == AI_CFG.cliFingerprint {
                    if AI_CFG.cliVerified.isEmpty, AI_CFG.engine == .localCLI { AI_CFG.enabled = true }
                    AI_CFG.cliVerified = AI_CFG.cliFingerprint
                }
                Self.cliTestResult = (true, String(format: "Passed in %.1f s", t))
            case .failure(let e):
                AI_CFG.cliVerified = ""
                Self.cliTestResult = (false, e.message)
            }
            LocalCLI.shared.refreshLimits()
            settingsChanged()
            self?.reload()
        }
    }

    private func useAIFor(_ b: NSStackView) {
        func card(_ title: String, _ rows: [NSView]) -> NSView {
            let c = ListCard()
            c.add(Row([NSTextField.text(title, size: 12.5, weight: .semibold, color: Palette.mut)], height: 34))
            rows.forEach { c.add($0) }
            return c
        }
        func sw(_ title: String, _ tip: String, _ on: Bool, _ flip: @escaping (Bool) -> Void) -> NSView {
            let r = SwitchRow(title, on: on, flip)
            r.toolTip = tip
            return r
        }
        let hour = MenuChip(String(format: "%02d:00", AI_CFG.digestHour), symbol: "sunrise") {
            (5...11).map { h in MenuAction(String(format: "%02d:00", h)) { AI_CFG.digestHour = h; settingsChanged() } }
        }
        hour.setAccessibilityLabel("Digest time")
        let v = NSStackView(v: [SectionTitle("Use AI for")], spacing: 6)
        v.identifier = SettingsAnchor.use.id
        v.addFull(CardGrid([
            card("Sessions", [
                sw("Session status", "Read the history of a session at a turn end and after it goes quiet. Say where the work stands.", AI_CFG.agentChecks) { AI_CFG.agentChecks = $0 },
                sw("Queue order", "Suggest an order for each lane.", AI_CFG.queueOrder) { AI_CFG.queueOrder = $0 },
                sw("Intake agent", "Check intake items in an Orca terminal in plan mode. Needs Orca, not an AI key.", AI_CFG.intakeAgent) { AI_CFG.intakeAgent = $0 },
                sw("Session summary", "Summarize the session on the item page.", AI_CFG.sessionSummary) { AI_CFG.sessionSummary = $0 },
                sw("Item summary", "Summarize the long description of each open item that changed in the last 7 days. A new description gets a new summary.",
                   AI_CFG.itemSummary) { AI_CFG.itemSummary = $0 },
            ]),
            card("CI", [
                sw("Explain failures", "A short cause for a failed run that no session watches.", AI_CFG.ciExplain) { AI_CFG.ciExplain = $0 },
                sw("Flaky workflows", "Mark a workflow that failed and then passed on the same commit. Re-run its next failure once before the alert.", AI_CFG.flaky) { AI_CFG.flaky = $0 },
                sw("Morning digest", "A short digest on Home once a day.", AI_CFG.digest) { AI_CFG.digest = $0 },
                Row([NSTextField.text("Digest time", size: 13, weight: .medium), Spacer(), hour], height: 40, label: "Digest time"),
            ]),
            card("New items", [
                sw("Title and fields", "Write the title, then set Size, Priority and other single-select fields.", AI_CFG.titleAndFields) { AI_CFG.titleAndFields = $0 },
                sw("Tidy the text", "Rewrite a rough paste as a clear description.", AI_CFG.tidy) { AI_CFG.tidy = $0 },
                sw("Pick the project", "With ⌘N, choose the project from your tracked projects.", AI_CFG.pickProject) { AI_CFG.pickProject = $0 },
            ]),
        ], minWidth: 240))
        b.addFull(v)
    }
}

// A thin bar for the use of one plan window. The percent text goes next to it.
final class UsageBar: NSView {
    private let fraction: CGFloat
    private let color: NSColor

    init(_ fraction: Double, color: NSColor) {
        self.fraction = CGFloat(min(1, max(0, fraction)))
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 70).isActive = true
        heightAnchor.constraint(equalToConstant: 6).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let clip = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
            Palette.raise.setFill()
            clip.fill()
            clip.addClip()
            color.setFill()
            NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height).fill()
        }
    }
}

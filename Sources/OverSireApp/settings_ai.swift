import Cocoa
import OverSireCore
import OverSireAI

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

// Settings › AI: the engine, a Test, and the jobs that use AI. Each change saves at once.
// AI stays off until Test passes for the current format, URL, model and key.
extension SettingsPage {
    static var aiTesting = false
    static var aiTestResult: (ok: Bool, text: String)?

    func ai(_ b: NSStackView) {
        if !AI_CFG.isOn(key: aiKey) {
            b.addFull(Banner(.idle, title: "AI is off.",
                             body: "Set the engine and press Test. The switches take effect when AI is on. The intake agent and flaky marks work without it."))
        }
        engine(b)
        useAIFor(b)
        let cloud = CloudAICard(cloudAIRecords)
        cloud.identifier = SettingsAnchor.cloudAI.id
        b.addFull(cloud)
    }

    private var aiKey: String { UIShots.aiKey ?? AIClient.keyStore.get(AIClient.keyName) ?? "" }

    private func engine(_ b: NSStackView) {
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
        var rows: [NSView] = [
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
        let verified = !aiKey.isEmpty && cfg.verified == cfg.fingerprint(key: aiKey)
        let test = ActionButton(Self.aiTesting ? "Testing…" : "Test") { [weak self] in self?.runAITest() }
        test.isEnabled = !Self.aiTesting && !cfg.baseURL.isEmpty && !cfg.model.isEmpty
        let pill: Pill
        if Self.aiTesting { pill = Pill(.running, text: "Testing") }
        else if let r = Self.aiTestResult { pill = Pill(r.ok ? .ok : .bad, text: r.ok ? r.text : "Failed") ; pill.toolTip = r.text }
        else if verified { pill = Pill(.ok, text: "Passed") }
        else { pill = Pill(.idle, text: cfg.verified.isEmpty ? "Not tested" : "Changed · test again") }
        rows.append(Row([TwoLine("Test", Self.aiTestResult.flatMap { $0.ok ? nil : $0.text } ?? "Sends one short request to the endpoint.", lines: 2),
                         Spacer(), pill, test], height: 52, label: "Test"))
        rows.append(SwitchRow("Use AI", note: verified ? "Turn off to stop all AI jobs." : "Test must pass first.", on: cfg.enabled && verified, enabled: verified) {
            AI_CFG.enabled = $0
        })
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

    private func runAITest() {
        Self.aiTesting = true
        Self.aiTestResult = nil
        reload()
        let tested = AI_CFG
        let key = aiKey
        AIClient(cfg: tested, key: key).test { [weak self] r in
            Self.aiTesting = false
            switch r {
            case .success(let t):
                // A pass counts only for the values that were tested.
                if tested.fingerprint(key: key) == AI_CFG.fingerprint(key: self?.aiKey ?? "") {
                    if AI_CFG.verified.isEmpty { AI_CFG.enabled = true }
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
                sw("Done and stuck checks", "Check a session that goes quiet. The queue can start the next item.", AI_CFG.agentChecks) { AI_CFG.agentChecks = $0 },
                sw("Queue order", "Suggest an order for each lane.", AI_CFG.queueOrder) { AI_CFG.queueOrder = $0 },
                sw("Intake agent", "Check intake items in an Orca terminal in plan mode. Needs Orca, not an AI key.", AI_CFG.intakeAgent) { AI_CFG.intakeAgent = $0 },
                sw("Session summary", "Summarize the session on the item page.", AI_CFG.sessionSummary) { AI_CFG.sessionSummary = $0 },
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

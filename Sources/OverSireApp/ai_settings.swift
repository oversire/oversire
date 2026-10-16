import Cocoa

// Settings → AI: the user's endpoint, a Test, and which AI features to use.
// AI stays off until Test passes for the current format, URL, model and key.
final class AISettingsVC: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private var cfg = AI_CFG
    private var key = AIClient.keyStore.get(AIClient.keyName) ?? ""
    private var testing = false
    private var testResult: (ok: Bool, text: String)?

    private let formatSeg = NSSegmentedControl(labels: ["OpenAI compatible", "Anthropic"], trackingMode: .selectOne, target: nil, action: nil)
    private let urlField = NSTextField()
    private let urlHelp = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField()
    private let keyPlain = NSTextField()
    private let showKey = NSButton(title: "Show", target: nil, action: nil)
    private let modelField = NSTextField()
    private let effortLabel = NSTextField(labelWithString: "Reasoning effort")
    private let effortPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tokensField = NSTextField()
    private let testBtn = NSButton(title: "Test", target: nil, action: nil)
    private let testDot = Dot(color: .tertiaryLabelColor, frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    private let testLabel = NSTextField(labelWithString: "")
    private let enableSwitch = NSSwitch()
    private let enableLabel = NSTextField(labelWithString: "Use AI when you make items")
    private let extraView = NSTextView()

    override func loadView() {
        let w = POP_W
        let container = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: POP_MAX_H))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        container.addSubview(SettingsNav(w: w, selected: .ai))
        container.addSubview(SeparatorLine(y: 44, w: w))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44.5, width: w, height: POP_MAX_H - 44.5))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        scroll.documentView = doc
        container.addSubview(scroll)

        let labelW: CGFloat = 130
        let fx: CGFloat = 16 + labelW
        let fw = w - fx - 16
        var y: CGFloat = 0
        func label(_ text: String, _ y: CGFloat, _ l: NSTextField = NSTextField(labelWithString: "")) {
            if !text.isEmpty { l.stringValue = text }
            l.font = .systemFont(ofSize: 12); l.alignment = .right; l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 16, y: y + 3, width: labelW - 12, height: 18)
            doc.addSubview(l)
        }
        func help(_ text: String, _ y: CGFloat, _ l: NSTextField = NSTextField(labelWithString: "")) {
            if !text.isEmpty { l.stringValue = text }
            l.font = .systemFont(ofSize: 10.5); l.textColor = .tertiaryLabelColor
            l.lineBreakMode = .byTruncatingMiddle
            l.frame = NSRect(x: fx, y: y, width: fw, height: 14)
            doc.addSubview(l)
        }
        func field(_ f: NSTextField, _ placeholder: String, _ value: String, _ y: CGFloat, width: CGFloat? = nil) {
            f.placeholderString = placeholder
            f.stringValue = value
            f.font = .systemFont(ofSize: 12)
            f.delegate = self
            f.frame = NSRect(x: fx, y: y, width: width ?? fw, height: 24)
            doc.addSubview(f)
        }

        doc.addSubview(SettingsHeader("AI", y: y, w: w)); y += 28
        let intro = NSTextField(wrappingLabelWithString: "OverSire calls your endpoint directly to write titles, set fields, tidy descriptions and pick the project. The API key stays in the Keychain.")
        intro.font = .systemFont(ofSize: 11); intro.textColor = .secondaryLabelColor
        intro.frame = NSRect(x: 16, y: y + 6, width: w - 32, height: 30)
        doc.addSubview(intro); y += 42

        label("Format", y)
        formatSeg.selectedSegment = cfg.format == .anthropic ? 1 : 0
        formatSeg.font = .systemFont(ofSize: 11)
        formatSeg.target = self; formatSeg.action = #selector(formatChanged)
        formatSeg.frame = NSRect(x: fx, y: y, width: 260, height: 24)
        doc.addSubview(formatSeg); y += 34

        label("Base URL", y)
        field(urlField, "", cfg.baseURL, y); y += 28
        help("", y, urlHelp); y += 22

        label("API key", y)
        field(keyField, "Stored in the Keychain", key, y, width: fw - 70)
        field(keyPlain, "Stored in the Keychain", key, y, width: fw - 70)
        keyPlain.isHidden = true
        showKey.bezelStyle = .rounded; showKey.font = .systemFont(ofSize: 11)
        showKey.target = self; showKey.action = #selector(toggleShowKey)
        showKey.frame = NSRect(x: fx + fw - 64, y: y - 1, width: 66, height: 26)
        doc.addSubview(showKey); y += 34

        label("Model", y)
        field(modelField, "", cfg.model, y); y += 34

        label("", y, effortLabel)
        effortPop.addItems(withTitles: OpenAIDialect.efforts)
        effortPop.selectItem(withTitle: cfg.effort)
        if effortPop.indexOfSelectedItem < 0 { effortPop.selectItem(withTitle: "low") }
        effortPop.font = .systemFont(ofSize: 12)
        effortPop.target = self; effortPop.action = #selector(effortChanged)
        effortPop.frame = NSRect(x: fx - 2, y: y, width: 140, height: 24)
        doc.addSubview(effortPop)
        field(tokensField, "1024", "\(cfg.maxTokens)", y, width: 100)
        y += 38

        testBtn.bezelStyle = .rounded; testBtn.font = .systemFont(ofSize: 12)
        testBtn.target = self; testBtn.action = #selector(runTest)
        testBtn.frame = NSRect(x: fx - 4, y: y - 2, width: 80, height: 28)
        doc.addSubview(testBtn)
        testDot.frame.origin = NSPoint(x: fx + 86, y: y + 8)
        doc.addSubview(testDot)
        testLabel.font = .systemFont(ofSize: 11.5)
        testLabel.lineBreakMode = .byTruncatingTail
        testLabel.frame = NSRect(x: fx + 100, y: y + 3, width: fw - 100, height: 18)
        doc.addSubview(testLabel); y += 38

        enableSwitch.target = self; enableSwitch.action = #selector(enableChanged)
        enableSwitch.frame = NSRect(x: fx, y: y, width: 40, height: 22)
        doc.addSubview(enableSwitch)
        enableLabel.font = .systemFont(ofSize: 12)
        enableLabel.frame = NSRect(x: fx + 48, y: y + 2, width: fw - 48, height: 18)
        doc.addSubview(enableLabel); y += 34

        let features: [(String, String, String, Bool)] = [
            ("titleAndFields", "Title and fields", "Write the title, then set Size, Priority and other single-select fields.", cfg.titleAndFields),
            ("tidy", "Tidy description", "Rewrite a rough paste as a clear issue description.", cfg.tidy),
            ("pickProject", "Pick the project", "With ⌘N, choose the project from your tracked projects.", cfg.pickProject),
        ]
        for f in features {
            let cb = NSButton(checkboxWithTitle: f.1, target: self, action: #selector(featureChanged(_:)))
            cb.font = .systemFont(ofSize: 12)
            cb.identifier = NSUserInterfaceItemIdentifier(f.0)
            cb.state = f.3 ? .on : .off
            cb.frame = NSRect(x: fx, y: y, width: fw, height: 18)
            doc.addSubview(cb)
            let d = NSTextField(labelWithString: f.2)
            d.font = .systemFont(ofSize: 10.5); d.textColor = .tertiaryLabelColor
            d.frame = NSRect(x: fx + 20, y: y + 18, width: fw - 20, height: 14)
            doc.addSubview(d)
            y += 38
        }
        y += 4

        doc.addSubview(SettingsHeader("EXTRA CONTEXT", y: y, w: w)); y += 28
        let tvScroll = NSScrollView(frame: NSRect(x: 16, y: y + 8, width: w - 32, height: 96))
        tvScroll.hasVerticalScroller = true; tvScroll.autohidesScrollers = true; tvScroll.borderType = .bezelBorder
        extraView.frame = NSRect(x: 0, y: 0, width: tvScroll.contentSize.width, height: 96)
        extraView.string = cfg.extraContext
        extraView.font = .systemFont(ofSize: 12)
        extraView.isRichText = false; extraView.allowsUndo = true
        extraView.textContainerInset = NSSize(width: 4, height: 6)
        extraView.isVerticallyResizable = true; extraView.autoresizingMask = [.width]
        extraView.textContainer?.widthTracksTextView = true
        extraView.delegate = self
        tvScroll.documentView = extraView
        doc.addSubview(tvScroll); y += 110
        let eh = NSTextField(wrappingLabelWithString: "Sent with every request. For example: \"Titles start with a verb. Product is Trebi.ai for anything about jobs or agents.\"")
        eh.font = .systemFont(ofSize: 10.5); eh.textColor = .tertiaryLabelColor
        eh.frame = NSRect(x: 16, y: y, width: w - 32, height: 28)
        doc.addSubview(eh); y += 34

        let save = NSButton(title: "Save & Apply", target: self, action: #selector(doSave))
        save.bezelStyle = .inline; save.font = .systemFont(ofSize: 12, weight: .semibold)
        save.frame = NSRect(x: w / 2 - 60, y: y + 8, width: 120, height: 28)
        doc.addSubview(save); y += 52

        doc.frame.size.height = y
        let h = min(POP_MAX_H, y + 44.5)
        container.frame.size.height = h
        scroll.frame.size.height = h - 44.5
        view = container
        preferredContentSize = NSSize(width: w, height: h)
        refresh()
    }

    private var verified: Bool { !key.isEmpty && cfg.verified == cfg.fingerprint(key: key) }

    // Updates the parts that depend on the state. It does not rebuild, so the focus stays.
    private func refresh() {
        let openai = cfg.format == .openai
        urlField.placeholderString = openai ? "https://api.openai.com/v1" : "https://api.anthropic.com"
        modelField.placeholderString = openai ? "gpt-5-mini" : "claude-haiku-5-5"
        let base = cfg.baseURL.isEmpty ? (urlField.placeholderString ?? "") : cfg.baseURL
        urlHelp.stringValue = "POST " + (openai ? OpenAIDialect.endpoint(base) : AnthropicDialect.endpoint(base))
        effortLabel.stringValue = openai ? "Reasoning effort" : "Max tokens"
        effortPop.isHidden = !openai
        tokensField.isHidden = openai
        testBtn.isEnabled = !testing && !cfg.baseURL.isEmpty && !cfg.model.isEmpty
        if testing {
            testLabel.stringValue = "Testing…"; testLabel.textColor = .secondaryLabelColor
            setDot(C_RUNNING)
        } else if let r = testResult {
            testLabel.stringValue = r.text; testLabel.textColor = r.ok ? .secondaryLabelColor : C_FAILURE
            testLabel.toolTip = r.text
            setDot(r.ok ? C_SUCCESS : C_FAILURE)
        } else if verified {
            testLabel.stringValue = "Passed"; testLabel.textColor = .secondaryLabelColor
            setDot(C_SUCCESS)
        } else {
            testLabel.stringValue = cfg.verified.isEmpty ? "Not tested" : "Settings changed. Test again."
            testLabel.textColor = .secondaryLabelColor
            setDot(.tertiaryLabelColor)
        }
        enableSwitch.isEnabled = verified
        enableSwitch.state = cfg.enabled && verified ? .on : .off
        enableLabel.textColor = verified ? .labelColor : .tertiaryLabelColor
        enableLabel.stringValue = verified ? "Use AI when you make items" : "Use AI when you make items (Test must pass first)"
    }

    private func setDot(_ c: NSColor) {
        NSApp.withPinnedAppearance { testDot.layer?.backgroundColor = c.cgColor }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        switch f {
        case urlField: cfg.baseURL = f.stringValue.trimmingCharacters(in: .whitespaces)
        case modelField: cfg.model = f.stringValue.trimmingCharacters(in: .whitespaces)
        case keyField: key = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); keyPlain.stringValue = key
        case keyPlain: key = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); keyField.stringValue = key
        case tokensField: cfg.maxTokens = min(32000, max(64, Int(f.stringValue) ?? 1024))
        default: return
        }
        testResult = nil
        refresh()
    }

    func textDidChange(_ notification: Notification) { cfg.extraContext = extraView.string }

    @objc func formatChanged() {
        cfg.format = formatSeg.selectedSegment == 1 ? .anthropic : .openai
        testResult = nil
        refresh()
    }
    @objc func effortChanged() { cfg.effort = effortPop.titleOfSelectedItem ?? "low" }
    @objc func toggleShowKey() {
        keyPlain.isHidden.toggle()
        keyField.isHidden = !keyPlain.isHidden
        showKey.title = keyPlain.isHidden ? "Show" : "Hide"
    }
    @objc func enableChanged() { cfg.enabled = enableSwitch.state == .on }
    @objc func featureChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.identifier?.rawValue {
        case "titleAndFields": cfg.titleAndFields = on
        case "tidy": cfg.tidy = on
        case "pickProject": cfg.pickProject = on
        default: break
        }
    }

    @objc func runTest() {
        testing = true
        testResult = nil
        refresh()
        let tested = cfg
        let testedKey = key
        AIClient(cfg: tested, key: testedKey).test { [weak self] r in
            guard let self else { return }
            self.testing = false
            switch r {
            case .success(let t):
                // A pass counts only for the values that were tested.
                if tested.fingerprint(key: testedKey) == self.cfg.fingerprint(key: self.key) {
                    let first = self.cfg.verified.isEmpty
                    self.cfg.verified = self.cfg.fingerprint(key: self.key)
                    if first { self.cfg.enabled = true }
                }
                self.testResult = (true, String(format: "Passed in %.1f s", t))
            case .failure(let e):
                self.cfg.verified = ""
                self.testResult = (false, e.message)
            }
            self.refresh()
        }
    }

    @objc func doSave() {
        if key.isEmpty { AIClient.keyStore.delete(AIClient.keyName) }
        else { AIClient.keyStore.set(AIClient.keyName, key) }
        AI_CFG = cfg
        saveConfig()
        testResult = (verified, verified ? (cfg.enabled ? "Saved. AI is on." : "Saved. AI is off.") : "Saved. AI stays off until Test passes.")
        refresh()
    }
}

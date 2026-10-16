import Cocoa

// ─── New item sheet ──────────────────────────────────────────────────────────
// An overlay on the Projects tab. AI controls (✦) show only when AI is on.

final class NewItemSheet: Flipped, NSTextViewDelegate, NSTextFieldDelegate {
    static let autoTitle = "✦ Auto: AI picks the project"

    var onClose: ((_ projectKey: String?, _ notice: String?) -> Void)?
    private let store: ProjectStore
    private let projects: [ProjectSummary]
    private let ai: AIClient?
    private var target: String?          // nil = Auto
    private var picked: String?          // the project AI chose in Auto
    private var pickReason: String?
    private var lastSuggestedBody: String?
    private var preTidy: String?
    private var suggested = Set<String>()  // field ids that AI set
    private var suggesting = false
    private var tidying = false
    private var creating = false
    private var notice: (text: String, error: Bool)?
    private var monitor: Any?

    private let card = Flipped()
    private let projectPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let why = NSTextField(labelWithString: "")
    private let titleHint = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let suggestBtn = NSButton(title: "✦ Suggest", target: nil, action: nil)
    private let alts = Flipped()
    private let tidyNote = Flipped()
    private let bodyScroll = NSScrollView()
    private let bodyView = NSTextView()
    private let pasteBtn = NSButton(title: "Paste clipboard  ⇧⌘V", target: nil, action: nil)
    private let tidyBtn = NSButton(title: "✦ Tidy", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "0 chars")
    private let fieldsBox = Flipped()
    private var fieldPops: [(field: ProjectField, pop: NSPopUpButton, mark: NSTextField)] = []
    private let noticeLabel = NSTextField(labelWithString: "")
    private let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
    private let createBtn = NSButton(title: "Create  ⌘↩", target: nil, action: nil)

    private let cardW: CGFloat
    private var pad: CGFloat { 16 }
    private var innerW: CGFloat { cardW - 2 * pad }

    init(store: ProjectStore, projects: [ProjectSummary], target: String?, prefill: String?, w: CGFloat) {
        self.store = store
        self.projects = projects
        self.ai = AIClient.current
        self.cardW = w - 40
        let auto = ai != nil && AI_CFG.pickProject && projects.count > 1
        self.target = target ?? (auto ? nil : projects.first?.ref.key)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        build(auto: auto)
        if let prefill, !prefill.isEmpty { bodyView.string = prefill }
        rebuildFields()
        relayoutCard()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    var aiDraft: Bool { ai != nil && AI_CFG.titleAndFields }
    var effectiveKey: String? { target ?? picked }
    var body: String { bodyView.string }

    // MARK: Build

    private func build(auto: Bool) {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.shadow = NSShadow()
        card.layer?.shadowOpacity = 0.25
        card.layer?.shadowRadius = 12
        card.layer?.shadowOffset = NSSize(width: 0, height: -4)
        addSubview(card)

        let head = NSTextField(labelWithString: "New item")
        head.font = .systemFont(ofSize: 14, weight: .semibold)
        head.frame = NSRect(x: pad, y: 14, width: 90, height: 20)
        card.addSubview(head)
        let inLabel = NSTextField(labelWithString: "in")
        inLabel.font = .systemFont(ofSize: 12); inLabel.textColor = .secondaryLabelColor
        inLabel.frame = NSRect(x: pad + 92, y: 16, width: 16, height: 16)
        card.addSubview(inLabel)
        projectPop.font = .systemFont(ofSize: 12)
        projectPop.frame = NSRect(x: pad + 110, y: 11, width: 300, height: 24)
        if auto {
            projectPop.addItem(withTitle: NewItemSheet.autoTitle)
            projectPop.lastItem?.representedObject = nil
        }
        for p in projects {
            projectPop.addItem(withTitle: "\(p.ref.workspace) › \(p.title)")
            projectPop.lastItem?.representedObject = p.ref.key
            if p.ref.key == target { projectPop.select(projectPop.lastItem) }
        }
        projectPop.target = self; projectPop.action = #selector(projectChanged)
        card.addSubview(projectPop)
        why.font = .systemFont(ofSize: 11); why.textColor = .secondaryLabelColor
        why.lineBreakMode = .byTruncatingTail
        why.frame = NSRect(x: pad + 420, y: 16, width: innerW - 420, height: 16)
        card.addSubview(why)

        card.addSubview(fieldLabel("Title", x: pad, y: 50))
        titleHint.font = .systemFont(ofSize: 10.5); titleHint.textColor = .tertiaryLabelColor
        titleHint.alignment = .right
        titleHint.stringValue = aiDraft ? "Leave empty and AI writes it from the description" : ""
        titleHint.frame = NSRect(x: pad + 100, y: 50, width: innerW - 100, height: 14)
        card.addSubview(titleHint)
        titleField.placeholderString = "Short, specific title"
        titleField.font = .systemFont(ofSize: 13)
        titleField.delegate = self
        card.addSubview(titleField)
        suggestBtn.bezelStyle = .rounded; suggestBtn.font = .systemFont(ofSize: 11, weight: .medium)
        suggestBtn.target = self; suggestBtn.action = #selector(suggestClicked)
        suggestBtn.isHidden = !aiDraft
        card.addSubview(suggestBtn)
        card.addSubview(alts)

        let desc = fieldLabel("Description", x: pad, y: 0)
        desc.identifier = NSUserInterfaceItemIdentifier("descLabel")
        card.addSubview(desc)
        tidyNote.wantsLayer = true
        tidyNote.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        tidyNote.layer?.cornerRadius = 5
        let tn = NSTextField(labelWithString: "✦ AI tidied the description")
        tn.font = .systemFont(ofSize: 11); tn.textColor = .controlAccentColor
        tn.frame = NSRect(x: 8, y: 3, width: 300, height: 16)
        tidyNote.addSubview(tn)
        let undo = NSButton(title: "Undo", target: self, action: #selector(undoTidy))
        undo.bezelStyle = .inline; undo.font = .systemFont(ofSize: 11)
        undo.frame = NSRect(x: innerW - 60, y: 1, width: 54, height: 20)
        tidyNote.addSubview(undo)
        card.addSubview(tidyNote)

        bodyView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        bodyView.isRichText = false
        bodyView.allowsUndo = true
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyView.isAutomaticDashSubstitutionEnabled = false
        bodyView.textContainerInset = NSSize(width: 4, height: 6)
        bodyView.delegate = self
        bodyView.isVerticallyResizable = true
        bodyView.autoresizingMask = [.width]
        bodyView.textContainer?.widthTracksTextView = true
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .bezelBorder
        card.addSubview(bodyScroll)

        for b in [pasteBtn, tidyBtn] {
            b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11)
            b.target = self
            card.addSubview(b)
        }
        pasteBtn.action = #selector(paste)
        tidyBtn.action = #selector(tidy)
        tidyBtn.toolTip = "Rewrite as a clear issue description"
        tidyBtn.isHidden = !(ai != nil && AI_CFG.tidy)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor; countLabel.alignment = .right
        card.addSubview(countLabel)

        card.addSubview(fieldsBox)

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(noticeLabel)
        cancelBtn.bezelStyle = .rounded; cancelBtn.target = self; cancelBtn.action = #selector(cancel)
        createBtn.bezelStyle = .rounded; createBtn.target = self; createBtn.action = #selector(create)
        createBtn.keyEquivalent = ""
        createBtn.bezelColor = .controlAccentColor
        card.addSubview(cancelBtn)
        card.addSubview(createBtn)
    }

    private func fieldLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: x, y: y, width: 100, height: 14)
        return l
    }

    // Single-select fields of the project. Status comes first.
    private func fields(of key: String?) -> [ProjectField] {
        guard let key, let snap = store.snapshots[key] else { return [] }
        var list = snap.fields
        if list.isEmpty, let id = snap.statusFieldId {
            list = [ProjectField(id: id, name: "Status", options: snap.statusOptions)]
        }
        let status = list.filter { $0.id == snap.statusFieldId || $0.name == "Status" }
        return status + list.filter { f in !status.contains { $0.id == f.id } }
    }

    private func rebuildFields() {
        let previous = Dictionary(fieldPops.map { ($0.field.name, $0.pop.titleOfSelectedItem ?? "") }, uniquingKeysWith: { a, _ in a })
        fieldsBox.subviews.forEach { $0.removeFromSuperview() }
        fieldPops = []
        let list = fields(of: effectiveKey)
        let cols = 3
        let gap: CGFloat = 12
        let colW = (innerW - gap * CGFloat(cols - 1)) / CGFloat(cols)
        if list.isEmpty {
            let l = NSTextField(labelWithString: effectiveKey == nil
                                ? "AI picks the project. Its fields show here."
                                : "This project has no single-select fields.")
            l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: 0, y: 4, width: innerW, height: 16)
            fieldsBox.addSubview(l)
            fieldsBox.frame.size = NSSize(width: innerW, height: 24)
            return
        }
        let snap = effectiveKey.flatMap { store.snapshots[$0] }
        for (i, f) in list.enumerated() {
            let x = CGFloat(i % cols) * (colW + gap)
            let y = CGFloat(i / cols) * 46
            let name = fieldLabel(f.name, x: x, y: y)
            name.frame.size.width = colW - 70
            fieldsBox.addSubview(name)
            let mark = NSTextField(labelWithString: "✦ suggested")
            mark.font = .systemFont(ofSize: 10); mark.textColor = .controlAccentColor
            mark.alignment = .right
            mark.frame = NSRect(x: x + colW - 70, y: y, width: 70, height: 14)
            mark.isHidden = !suggested.contains(f.id)
            fieldsBox.addSubview(mark)
            let pop = NSPopUpButton(frame: NSRect(x: x - 2, y: y + 16, width: colW + 4, height: 24), pullsDown: false)
            pop.font = .systemFont(ofSize: 12)
            pop.addItem(withTitle: "None")
            for o in f.options { pop.addItem(withTitle: o.name) }
            let isStatus = f.id == snap?.statusFieldId || f.name == "Status"
            if let prev = previous[f.name], pop.item(withTitle: prev) != nil {
                pop.selectItem(withTitle: prev)
            } else if isStatus, let todo = f.options.first(where: { $0.category == .todo }) {
                pop.selectItem(withTitle: todo.name)
            }
            pop.target = self; pop.action = #selector(fieldChanged(_:))
            pop.identifier = NSUserInterfaceItemIdentifier(f.id)
            fieldsBox.addSubview(pop)
            fieldPops.append((f, pop, mark))
        }
        let rows = (list.count + cols - 1) / cols
        fieldsBox.frame.size = NSSize(width: innerW, height: CGFloat(rows) * 46)
    }

    private func rebuildAlts(_ list: [String]) {
        alts.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for t in list {
            let b = NSButton(title: t, target: self, action: #selector(pickAlt(_:)))
            b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11)
            b.lineBreakMode = .byTruncatingTail
            b.sizeToFit()
            let w = min(b.frame.width + 8, innerW - x)
            guard w > 60 else { break }
            b.frame = NSRect(x: x, y: 0, width: w, height: 20)
            b.toolTip = "Use this title"
            alts.addSubview(b)
            x += w + 6
        }
        alts.frame.size = NSSize(width: innerW, height: list.isEmpty ? 0 : 22)
    }

    // Positions every part from the top. Call after a state change.
    func relayoutCard() {
        var y: CGFloat = 70
        titleField.frame = NSRect(x: pad, y: y, width: aiDraft ? innerW - 104 : innerW, height: 26)
        suggestBtn.frame = NSRect(x: pad + innerW - 98, y: y, width: 100, height: 26)
        y += 32
        alts.frame.origin = NSPoint(x: pad, y: y)
        if alts.frame.height > 0 { y += alts.frame.height + 4 }
        y += 6
        card.subviews.first { $0.identifier?.rawValue == "descLabel" }?.frame.origin.y = y
        y += 18
        tidyNote.isHidden = preTidy == nil
        if preTidy != nil {
            tidyNote.frame = NSRect(x: pad, y: y, width: innerW, height: 22)
            y += 26
        }
        bodyScroll.frame = NSRect(x: pad, y: y, width: innerW, height: 150)
        bodyView.frame.size.width = bodyScroll.contentSize.width
        y += 154
        pasteBtn.sizeToFit(); tidyBtn.sizeToFit()
        pasteBtn.frame = NSRect(x: pad, y: y, width: pasteBtn.frame.width + 10, height: 22)
        tidyBtn.frame = NSRect(x: pasteBtn.frame.maxX + 6, y: y, width: tidyBtn.frame.width + 10, height: 22)
        countLabel.frame = NSRect(x: pad + innerW - 120, y: y + 3, width: 120, height: 16)
        y += 32
        fieldsBox.frame.origin = NSPoint(x: pad, y: y)
        y += fieldsBox.frame.height + 8
        noticeLabel.frame = NSRect(x: pad, y: y, width: innerW, height: 16)
        noticeLabel.isHidden = notice == nil
        if let n = notice {
            noticeLabel.stringValue = n.text
            noticeLabel.toolTip = n.text
            noticeLabel.textColor = n.error ? C_FAILURE : .secondaryLabelColor
            y += 20
        }
        let sep = card.subviews.first { $0.identifier?.rawValue == "footSep" } ?? {
            let v = SeparatorLine(y: 0, w: cardW)
            v.identifier = NSUserInterfaceItemIdentifier("footSep")
            card.addSubview(v)
            return v
        }()
        sep.frame.origin.y = y + 4
        y += 14
        createBtn.frame = NSRect(x: pad + innerW - 110, y: y - 2, width: 112, height: 28)
        cancelBtn.frame = NSRect(x: createBtn.frame.minX - 84, y: y - 2, width: 80, height: 28)
        y += 38
        card.frame = NSRect(x: 20, y: 12, width: cardW, height: y)
        refreshState()
    }

    var cardHeight: CGFloat { card.frame.maxY + 12 }

    private func refreshState() {
        let n = body.count
        countLabel.stringValue = "\(n) chars"
        let changed = body != lastSuggestedBody
        suggestBtn.title = suggesting ? "Writing…" : (lastSuggestedBody == nil ? "✦ Suggest" : "✦ Suggest again")
        suggestBtn.isEnabled = !suggesting && n >= 20 && changed
        suggestBtn.toolTip = n < 20 ? "Write or paste at least 20 characters" : changed ? "Write the title from the description" : "Change the description to suggest again"
        tidyBtn.title = tidying ? "✦ Tidying…" : "✦ Tidy"
        tidyBtn.isEnabled = !tidying && n >= 20
        createBtn.title = creating ? "Creating…" : "Create  ⌘↩"
        createBtn.isEnabled = !creating && !suggesting
        if let key = picked, target == nil {
            let title = projects.first { $0.ref.key == key }?.title ?? key
            why.stringValue = "✦ " + title + (pickReason.map { " · " + $0 } ?? "")
            why.toolTip = why.stringValue
        } else {
            why.stringValue = ""
        }
    }

    // MARK: Events

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window == self.window else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 53 { self.cancel(); return nil }
            if e.keyCode == 36 && mods.contains(.command) { self.create(); return nil }
            if e.charactersIgnoringModifiers?.lowercased() == "v" && mods == [.command, .shift] { self.paste(); return nil }
            return e
        }
    }

    func focus() { window?.makeFirstResponder(body.isEmpty ? bodyView : titleField) }

    func textDidChange(_ notification: Notification) { refreshState() }

    override func mouseDown(with event: NSEvent) {}

    @objc func projectChanged() {
        target = projectPop.selectedItem?.representedObject as? String
        if target != nil { picked = nil; pickReason = nil }
        suggested = []
        rebuildFields()
        relayoutCard()
        sizeChanged()
    }

    @objc func fieldChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier?.rawValue else { return }
        suggested.remove(id)
        fieldPops.first { $0.field.id == id }?.mark.isHidden = true
    }

    @objc func pickAlt(_ sender: NSButton) {
        let old = titleField.stringValue
        titleField.stringValue = sender.title
        if !old.isEmpty { sender.title = old }
    }

    @objc func paste() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            show("The clipboard has no text", error: true)
            return
        }
        bodyView.string = body.isEmpty ? text : body + "\n\n" + text
        refreshState()
        if titleField.stringValue.isEmpty && aiDraft { suggest() }
    }

    @objc func cancel() { onClose?(nil, nil) }

    @objc func undoTidy() {
        guard let old = preTidy else { return }
        bodyView.string = old
        preTidy = nil
        relayoutCard()
        sizeChanged()
    }

    private func show(_ text: String?, error: Bool = false) {
        notice = text.map { ($0, error) }
        relayoutCard()
        sizeChanged()
    }

    var onResize: (() -> Void)?
    private func sizeChanged() { onResize?() }

    // MARK: AI

    private func context() -> DraftContext {
        var ctx = DraftContext()
        if target == nil && AI_CFG.pickProject {
            ctx.projects = projects.map { ($0.ref.key, "\($0.ref.workspace) › \($0.title)") }
        }
        if let key = effectiveKey {
            let snap = store.snapshots[key]
            ctx.fields = fields(of: key).filter { $0.id != snap?.statusFieldId && $0.name != "Status" }
        }
        return ctx
    }

    @objc func suggestClicked() { suggest(then: nil) }
    func suggest() { suggest(then: nil) }

    private func suggest(then next: (() -> Void)?) {
        guard let ai, !suggesting, !body.isEmpty else { return }
        suggesting = true
        let sent = body
        refreshState()
        let ctx = context()
        ai.draft(body: sent, ctx: ctx) { [weak self] r in
            guard let self else { return }
            self.suggesting = false
            switch r {
            case .failure(let e):
                self.show(e.message, error: true)
            case .success(let s):
                self.lastSuggestedBody = sent
                self.apply(s)
                // The project is known now, so ask once more for its fields.
                if ctx.fields.isEmpty, s.project != nil, !self.context().fields.isEmpty {
                    self.lastSuggestedBody = nil
                    self.suggest(then: next)
                    return
                }
                next?()
            }
            self.refreshState()
        }
    }

    private func apply(_ s: DraftSuggestion) {
        if AI_CFG.titleAndFields {
            titleField.stringValue = s.title
            rebuildAlts(s.alternatives)
        }
        if target == nil, let p = s.project, p != picked {
            picked = p
            pickReason = s.reason
            suggested = []
            rebuildFields()
        }
        for entry in fieldPops {
            guard let value = s.fields[entry.field.name], entry.pop.item(withTitle: value) != nil else { continue }
            entry.pop.selectItem(withTitle: value)
            entry.mark.isHidden = false
            suggested.insert(entry.field.id)
        }
        notice = nil
        relayoutCard()
        sizeChanged()
    }

    @objc func tidy() {
        guard let ai, !tidying, !body.isEmpty else { return }
        tidying = true
        refreshState()
        let before = body
        ai.tidy(body: before) { [weak self] r in
            guard let self else { return }
            self.tidying = false
            switch r {
            case .failure(let e): self.show(e.message, error: true)
            case .success(let text):
                self.preTidy = before
                self.bodyView.string = text
                self.notice = nil
                self.relayoutCard()
                self.sizeChanged()
            }
            self.refreshState()
        }
    }

    // MARK: Create

    @objc func create() {
        guard !creating else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || effectiveKey == nil {
            if ai != nil && !body.isEmpty && !suggesting {
                lastSuggestedBody = nil
                suggest { [weak self] in
                    guard let self, !self.titleField.stringValue.isEmpty, self.effectiveKey != nil else { return }
                    self.create()
                }
                return
            }
            show(effectiveKey == nil ? "Pick a project" : "Add a title", error: true)
            return
        }
        guard let key = effectiveKey else { return }
        var options: [String: String] = [:]
        for entry in fieldPops {
            let i = entry.pop.indexOfSelectedItem - 1
            if i >= 0 && i < entry.field.options.count { options[entry.field.id] = entry.field.options[i].id }
        }
        creating = true
        show(nil)
        let name = projects.first { $0.ref.key == key }?.title ?? key
        store.create(NewItem(projectKey: key, title: title, body: body, fieldOptions: options)) { [weak self] ok, msg in
            guard let self else { return }
            self.creating = false
            if ok {
                self.onClose?(key, msg.map { "Added to \(name). \($0)" } ?? "Added to \(name)")
            } else {
                self.show(msg ?? "Could not create the item", error: true)
            }
        }
    }
}

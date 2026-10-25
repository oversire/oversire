import Cocoa
import OverSireCore
import Quartz
import UniformTypeIdentifiers

// ─── New panel ───────────────────────────────────────────────────────────────
// Pick a mode and a project, type or speak, attach files, press ⌘↩. The controller starts the session
// or makes the item.

final class NewSessionPanel: NSPanel, NSTextFieldDelegate, NSTextViewDelegate, QLPreviewPanelDataSource {
    struct Actions {
        var start: (NewSessionModel) -> Void = { _ in }
        var chooseRoot: (String) -> Void = { _ in }
        var closed: () -> Void = {}
        /// Asks the tracker if the intake of a project (store key) is on.
        var checkIntake: (String) -> Void = { _ in }
        var enableIntake: (String) -> Void = { _ in }
    }

    private static let highlight = NSColor(srgbRed: 0x3d / 255, green: 0x7f / 255, blue: 0xd6 / 255, alpha: 1)
    private static let listen = NSColor(srgbRed: 0xD5 / 255, green: 0x5E / 255, blue: 0, alpha: 1)

    private(set) var model: NewSessionModel
    private let actions: Actions
    private let voice = SnapVoice()
    private var hostFilesFailed = false
    private var preview: [URL] = []
    private(set) var frameSaved: NewPanelFrame
    private let remembers: Bool
    private var placing = false
    private var widthC: NSLayoutConstraint!
    private var promptC: NSLayoutConstraint!

    private let column = NSStackView(v: [], spacing: 12)
    private let modeControl = NSSegmentedControl()
    private let titleBox = Box(fill: Palette.bg, border: Palette.line, radius: 7)
    let titleField = NSTextField()
    private let fieldsHolder = NSStackView(v: [], spacing: 0)
    private let statePop = NSPopUpButton()
    private let priorityPop = NSPopUpButton()
    private let comboBox = Box(fill: Palette.bg, border: Palette.line, radius: 7)
    private let comboKey = NSStackView(h: [], spacing: 0)
    private let comboTag = NSTextField.text("last used", size: 11, color: Palette.dim)
    let comboField = SessionComboField()
    private let listHolder = NSStackView(v: [], spacing: 0)
    private let promptBox = Box(fill: Palette.bg, border: Palette.line, radius: 8)
    let promptView = SessionTextView()
    private let promptHint = NSStackView(h: [], spacing: 6)
    private let micButton = NSButton()
    private let filesHolder = NSStackView(v: [], spacing: 0)
    private let intakeBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let intakeHint = NSTextField.text("", size: 11.5, color: Palette.dim, lines: 2)
    private let workspaceHolder = NSStackView(v: [], spacing: 0)
    private let errorHolder = NSStackView(v: [], spacing: 0)
    private let footerHolder = NSStackView(v: [], spacing: 0)

    /// `saved` nil: the default size, and no save (--uishots).
    init(model: NewSessionModel, actions: Actions, saved: NewPanelFrame? = nil) {
        self.model = model
        self.actions = actions
        frameSaved = saved ?? NewPanelFrame()
        remembers = saved != nil
        super.init(contentRect: NSRect(x: 0, y: 0, width: frameSaved.width, height: 420), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setAccessibilityLabel("New")

        let root = SessionDropView()
        root.onFiles = { [weak self] in self?.addFiles($0) }
        contentView = root
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.addSubview(column)
        let grip = SessionSizeGrip()
        grip.onDrag = { [weak self] dx, dy, start in self?.resize(from: start, dx: dx, dy: dy) }
        grip.onEnd = { [weak self] in if self?.remembers == true { self?.frameSaved.save() } }
        root.addSubview(grip)
        widthC = column.widthAnchor.constraint(equalToConstant: frameSaved.width)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor), column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor), widthC,
            grip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2), grip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
        ])
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: nil) { [weak self] _ in
            if self?.placing == false { self?.remember() }
        }
        NotificationCenter.default.addObserver(forName: AgentModelBook.changed, object: nil, queue: .main) { [weak self] _ in
            if self?.model.picksAgent == true { self?.refresh() }
        }

        let header = NSStackView(h: [Glyph("circle.grid.3x3.fill", color: Palette.dim, size: 9, label: "Drag to move"),
                                     NSTextField.text("New", size: 14, weight: .semibold), buildModes(), Spacer(),
                                     NSTextField.text("⌘1–3 · Esc closes", size: 11.5, color: Palette.dim)], spacing: 10)
        column.addFull(header)
        column.addFull(buildCombo())
        column.addFull(listHolder)
        column.setCustomSpacing(6, after: comboBox)
        column.addFull(buildTitle())
        column.addFull(buildPrompt())
        column.addFull(filesHolder)
        column.addFull(buildFields())
        intakeBox.target = self
        intakeBox.action = #selector(flipIntake)
        column.addFull(NSStackView(v: [intakeBox, intakeHint], spacing: 3))
        column.addFull(workspaceHolder)
        column.addFull(errorHolder)
        column.addFull(footerHolder)
        refresh()
    }

    override var canBecomeKey: Bool { true }

    // MARK: Build

    private func buildCombo() -> NSView {
        comboField.isBordered = false
        comboField.drawsBackground = false
        comboField.focusRingType = .none
        comboField.font = .systemFont(ofSize: 13)
        comboField.delegate = self
        comboField.setAccessibilityLabel("Project")
        comboField.onClick = { [weak self] in self?.setList(true) }
        let chevron = NSButton(image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Show the projects")!,
                               target: self, action: #selector(flipList))
        chevron.isBordered = false
        chevron.contentTintColor = Palette.mut
        let row = NSStackView(h: [comboKey, comboField, comboTag, chevron], spacing: 8)
        comboBox.addSubview(row)
        NSLayoutConstraint.activate([
            comboBox.heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: comboBox.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: comboBox.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: comboBox.centerYAnchor),
        ])
        return comboBox
    }

    private func buildModes() -> NSView {
        let modes = NewSessionModel.Mode.allCases
        modeControl.segmentCount = modes.count
        for (i, m) in modes.enumerated() {
            modeControl.setLabel(m.label, forSegment: i)
            modeControl.setImage(NSImage(systemSymbolName: m.symbol, accessibilityDescription: nil), forSegment: i)
            modeControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
            modeControl.setToolTip("\(m.label) (⌘\(i + 1))", forSegment: i)
        }
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        modeControl.target = self
        modeControl.action = #selector(modePicked)
        modeControl.setAccessibilityLabel("What to create")
        return modeControl
    }

    private func buildTitle() -> NSView {
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = .systemFont(ofSize: 13)
        titleField.delegate = self
        titleField.setAccessibilityLabel("Title")
        titleBox.addSubview(titleField)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleBox.heightAnchor.constraint(equalToConstant: 32),
            titleField.leadingAnchor.constraint(equalTo: titleBox.leadingAnchor, constant: 8), titleField.trailingAnchor.constraint(equalTo: titleBox.trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: titleBox.centerYAnchor),
        ])
        return titleBox
    }

    /// State and priority of the Item mode.
    private func buildFields() -> NSView {
        statePop.target = self
        statePop.action = #selector(fieldPicked)
        statePop.setAccessibilityLabel("State")
        priorityPop.target = self
        priorityPop.action = #selector(fieldPicked)
        priorityPop.setAccessibilityLabel("Priority")
        for o in StatusOption.priorities.reversed() {
            priorityPop.addItem(withTitle: o.name)
            priorityPop.lastItem?.representedObject = o.id
        }
        let col = { (name: String, pop: NSPopUpButton) in
            NSStackView(v: [NSTextField.text(name, size: 11.5, color: Palette.dim), pop], spacing: 4, align: .leading)
        }
        let row = NSStackView(h: [col("State", statePop), col("Priority", priorityPop), Spacer()], spacing: 16)
        fieldsHolder.addFull(row)
        return fieldsHolder
    }

    private func buildPrompt() -> NSView {
        promptView.font = .systemFont(ofSize: 13)
        promptView.textColor = Palette.fg
        promptView.drawsBackground = false
        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.textContainerInset = NSSize(width: 6, height: 8)
        promptView.isVerticallyResizable = true
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.widthTracksTextView = true
        promptView.delegate = self
        promptView.setAccessibilityLabel("Prompt")
        promptView.onFiles = { [weak self] in self?.addFiles($0) }
        promptView.onImage = { [weak self] data in
            guard let self else { return }
            self.add([NewSessionModel.Attachment(name: self.model.pasteName, data: data, isImage: true)])
        }
        promptView.onFocus = { [weak self] on in self?.promptFocus(on) }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = promptView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSButton(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach files")!, target: self, action: #selector(pickFiles))
        clip.bezelStyle = .texturedRounded
        clip.toolTip = "Attach files (⌘O)"
        micButton.target = self
        micButton.action = #selector(flipVoice)
        micButton.bezelStyle = .texturedRounded
        for b in [clip, micButton] {
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let bottom = NSStackView(h: [promptHint, Spacer(), clip, micButton], spacing: 6)
        promptBox.addSubview(scroll)
        promptBox.addSubview(bottom)
        promptC = promptBox.heightAnchor.constraint(equalToConstant: frameSaved.prompt)
        NSLayoutConstraint.activate([
            promptC,
            scroll.leadingAnchor.constraint(equalTo: promptBox.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: promptBox.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: promptBox.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -4),
            bottom.leadingAnchor.constraint(equalTo: promptBox.leadingAnchor, constant: 10), bottom.trailingAnchor.constraint(equalTo: promptBox.trailingAnchor, constant: -6),
            bottom.bottomAnchor.constraint(equalTo: promptBox.bottomAnchor, constant: -6),
        ])
        return promptBox
    }

    // MARK: State

    /// Shows the state again. The combo field and the prompt keep their focus.
    func refresh() {
        let sel = model.selection
        let session = model.mode == .session
        modeControl.selectedSegment = NewSessionModel.Mode.allCases.firstIndex(of: model.mode) ?? 0
        modeControl.isEnabled = !model.isStarting
        titleBox.isHidden = session
        titleField.placeholderString = model.text.isEmpty ? "Title" : "Title (empty: \u{201C}\(model.title)\u{201D})"
        promptView.placeholder = session ? "What should the agent do? Paste or drop screenshots and files."
                                         : "Description in Markdown. Paste or drop screenshots and files."
        fieldsHolder.isHidden = model.mode != .item
        if model.mode == .item { refreshFields(sel) }
        comboKey.clear()
        if let s = sel { comboKey.addArrangedSubview(Chiplet(s.key, mono: true)) }
        comboField.placeholderAttributedString = NSAttributedString(string: sel?.name ?? "Track a project first",
                                                                    attributes: [.foregroundColor: sel == nil ? Palette.dim : Palette.fg, .font: NSFont.systemFont(ofSize: 13)])
        if comboField.stringValue != model.query { comboField.stringValue = model.query }
        comboTag.isHidden = sel == nil || sel?.store != model.lastUsed || !model.query.isEmpty
        comboBox.border = model.listOpen ? Palette.acc : Palette.line

        listHolder.clear()
        if model.listOpen { listHolder.addFull(buildList()) }
        listHolder.isHidden = !model.listOpen

        let listening = model.phase == .listening
        promptBox.border = listening ? Self.listen : Palette.line
        promptHint.clear()
        if listening {
            promptHint.addArrangedSubview(Glyph("circle.fill", color: Self.listen, size: 8, label: "Listening"))
            promptHint.addArrangedSubview(NSTextField.text("Listening · click the mic or press ⌘D to stop", size: 11.5, color: Self.listen))
        } else {
            promptHint.addArrangedSubview(NSTextField.text("↩ new line · ⌘↩ \(session ? "starts" : "creates") · ⌘V pastes images", size: 11.5, color: Palette.dim))
        }
        micButton.image = NSImage(systemSymbolName: listening ? "mic.fill" : "mic", accessibilityDescription: listening ? "Stop dictation" : "Dictate")
        micButton.contentTintColor = listening ? Self.listen : nil
        micButton.toolTip = listening ? "Stop dictation (⌘D)" : "Dictate on this Mac (⌘D)"

        filesHolder.clear()
        if !model.files.isEmpty { filesHolder.addFull(buildFiles()) }
        filesHolder.isHidden = model.files.isEmpty

        intakeBox.title = "Also create an intake item in \(sel?.key ?? "the project")"
        intakeBox.state = model.intake ? .on : .off
        intakeBox.isEnabled = !model.isStarting
        intakeBox.isHidden = !session
        intakeHint.stringValue = model.intakeHint

        workspaceHolder.clear()
        if let s = sel, session { workspaceHolder.addFull(buildWorkspace(s)) }
        workspaceHolder.isHidden = workspaceHolder.arrangedSubviews.isEmpty

        errorHolder.clear()
        if model.mode == .intake, let s = sel { actions.checkIntake(s.store) }
        if let note = model.intakeOffNote, let s = sel {
            errorHolder.addFull(Banner(.warning, title: note, body: "Turn on Intake for \(s.key), or create a work item with the same text and files.", actions: [
                ActionButton("Turn on Intake", style: .primary) { [weak self] in self?.actions.enableIntake(s.store) },
                ActionButton("Create as item") { [weak self] in self?.setMode(.item) },
            ]))
        } else if case .failed(let e) = model.phase {
            var acts: [NSView] = []
            if hostFilesFailed && !model.intake && session {
                acts.append(ActionButton("Send with intake") { [weak self] in
                    self?.model.intake = true
                    self?.start()
                })
            }
            errorHolder.addFull(Banner(.bad, title: session ? "The session did not start." : "The item was not created.", body: e, actions: acts))
        }
        errorHolder.isHidden = errorHolder.arrangedSubviews.isEmpty

        footerHolder.clear()
        footerHolder.addFull(buildFooter())
        fit()
    }

    private func refreshFields(_ sel: NewSessionModel.Choice?) {
        let states = sel?.states ?? []
        if statePop.itemArray.map({ $0.representedObject as? String }) != states.map(\.id) {
            statePop.removeAllItems()
            for o in states {
                statePop.addItem(withTitle: o.name)
                statePop.lastItem?.representedObject = o.id
            }
        }
        statePop.isEnabled = !states.isEmpty && !model.isStarting
        if let id = model.itemState, let i = statePop.itemArray.firstIndex(where: { $0.representedObject as? String == id }) { statePop.selectItem(at: i) }
        if let i = priorityPop.itemArray.firstIndex(where: { $0.representedObject as? String == model.priority }) { priorityPop.selectItem(at: i) }
        priorityPop.isEnabled = !model.isStarting
    }

    private func buildList() -> NSView {
        let box = Box(fill: Palette.raise, border: Palette.line, radius: 7)
        let rows = NSStackView(v: [], spacing: 0)
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let m = model.matches
        if m.isEmpty {
            rows.addFull(Padded(NSTextField.text("No project matches \u{201C}\(model.query)\u{201D}.", size: 12, color: Palette.dim), vertical: 6, side: 8))
        }
        for (i, c) in m.prefix(8).enumerated() {
            let on = i == model.highlight
            let key = NSTextField.text(c.key, size: 12, weight: .medium, color: on ? .white : Palette.fg, mono: true)
            key.widthAnchor.constraint(equalToConstant: 84).isActive = true
            let folder: NSView = (c.root ?? "").isEmpty
                ? NSTextField.text("△ no Orca workspace", size: 11.5, color: on ? .white : Palette.warn)
                : NSTextField.text(((c.root ?? "") as NSString).lastPathComponent, size: 11.5, color: on ? .white : Palette.dim, mono: true)
            let r = SessionPickRow([key, NSTextField.text(c.name, size: 12.5, color: on ? .white : Palette.fg), Spacer(), folder]) { [weak self] in
                self?.pick(c.store)
            }
            r.fill = on ? Self.highlight : nil
            r.setAccessibilityLabel("\(c.key), \(c.name)" + ((c.root ?? "").isEmpty ? ", no Orca workspace" : ""))
            rows.addFull(r)
        }
        box.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor), rows.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            rows.topAnchor.constraint(equalTo: box.topAnchor), rows.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func buildFiles() -> NSView {
        let items: [NSView] = model.files.map { f in
            f.isImage ? SessionThumb(f, open: { [weak self] in self?.quickLook(f.id) }, remove: { [weak self] in self?.remove(f.id) })
                      : SessionFileChip(f, open: { [weak self] in self?.quickLook(f.id) }, remove: { [weak self] in self?.remove(f.id) })
        }
        return Wrap(items)
    }

    private func buildWorkspace(_ s: NewSessionModel.Choice) -> NSView {
        guard let root = s.root, !root.isEmpty else {
            let b = Box(fill: Palette.warn.withAlphaComponent(0.12), border: Palette.warn.withAlphaComponent(0.6), radius: 7)
            let row = NSStackView(h: [Glyph("exclamationmark.triangle", color: Palette.warn, size: 12, label: "Warning"),
                                      NSTextField.text("\(s.key) has no Orca workspace yet.", size: 12, color: Palette.fg), Spacer(),
                                      ActionButton("Choose folder…") { [weak self] in self?.actions.chooseRoot(s.store) }], spacing: 8)
            b.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -8),
                row.topAnchor.constraint(equalTo: b.topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -6),
            ])
            return b
        }
        let path = NSTextField.text((root as NSString).abbreviatingWithTildeInPath, size: 11.5, color: Palette.mut, mono: true)
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = root
        let change = ActionButton("Change", style: .link) { [weak self] in self?.actions.chooseRoot(s.store) }
        change.setAccessibilityLabel("Change the Orca workspace folder of \(s.key)")
        return NSStackView(h: [Glyph("apple.terminal", size: 12, label: "Orca workspace"), path, Spacer(), change], spacing: 6)
    }

    private func buildFooter() -> NSView {
        var lead: [NSView] = []
        if model.picksAgent { lead = [agentChip()] }
        let cancel = ActionButton("Cancel") { [weak self] in self?.dismiss() }
        let title: String
        if case .starting(let label) = model.phase { title = label } else { title = "\(model.button)  ⌘↩" }
        let start = ActionButton(title, style: .primary) { [weak self] in self?.start() }
        start.isEnabled = model.canStart
        start.toolTip = model.blocker
        start.setAccessibilityLabel(model.button)
        if let b = model.blocker { start.setAccessibilityHelp(b) }
        let row = NSStackView(h: lead + [Spacer(), cancel, start], spacing: 8)
        if let b = model.blocker, model.phase == .edit, model.selection != nil {
            return NSStackView(v: [row, NSTextField.text(b, size: 11.5, color: Palette.warn)], spacing: 4, align: .trailing)
        }
        return row
    }

    /// Keeps the top edge in place when the height changes.
    private func fit() {
        column.layoutSubtreeIfNeeded()
        let h = column.fittingSize.height
        guard abs(frame.height - h) > 0.5 || abs(frame.width - frameSaved.width) > 0.5 else { return }
        placing = true
        setFrame(NSRect(x: frame.minX, y: frame.maxY - h, width: frameSaved.width, height: h), display: true)
        placing = false
    }

    /// The grip: `dx` changes the width, `dy` (down) the prompt height.
    func resize(from start: NewPanelFrame, dx: CGFloat, dy: CGFloat) {
        frameSaved = start.resized(width: start.width + dx, prompt: start.prompt + dy)
        widthC.constant = frameSaved.width
        promptC.constant = frameSaved.prompt
        fit()
    }

    /// The controller places the panel. Only a move by the user saves the place.
    func place(topLeft p: NSPoint) {
        placing = true
        setFrameTopLeftPoint(p)
        placing = false
    }

    private func remember() {
        guard remembers else { return }
        frameSaved.topLeft = [frame.minX, frame.maxY]
        frameSaved.save()
    }

    // MARK: Actions

    func setPhase(_ p: NewSessionModel.Phase, hostFiles: Bool = false) {
        model.phase = p
        hostFilesFailed = hostFiles
        refresh()
    }

    func setIntake(_ store: String, off: Bool) {
        if off { model.intakeOff.insert(store) } else { model.intakeOff.remove(store) }
        refresh()
    }

    /// The controller sets new choices after a folder change.
    func setChoices(_ c: [NewSessionModel.Choice]) {
        model.choices = c
        refresh()
    }

    func add(_ a: [NewSessionModel.Attachment]) {
        model.add(a)
        if case .failed = model.phase { model.phase = .edit }
        refresh()
    }

    private func remove(_ id: UUID) {
        model.remove(id)
        refresh()
    }

    private func pick(_ store: String) {
        model.pick(store)
        refresh()
        makeFirstResponder(promptView)
    }

    private func setList(_ on: Bool) {
        guard model.listOpen != on else { return }
        if on { model.move(0) } else { model.pick(model.selected) }
        refresh()
    }

    @objc private func flipList() {
        setList(!model.listOpen)
        if model.listOpen { makeFirstResponder(comboField) }
    }

    @objc private func modePicked() { setMode(NewSessionModel.Mode.allCases[max(0, modeControl.selectedSegment)]) }

    func setMode(_ m: NewSessionModel.Mode) {
        guard !model.isStarting else { return }
        model.mode = m
        if case .failed = model.phase { model.phase = .edit }
        refresh()
        if m != .session && firstResponder === promptView && model.titleText.isEmpty && model.text.isEmpty { makeFirstResponder(titleField) }
        if m == .session && firstResponder === titleField.currentEditor() { makeFirstResponder(promptView) }
    }

    /// "claude-max · Opus 5.5 · Max ⌄". A click opens the agent menu. A warning mark tells that the model can fail.
    private func agentChip() -> NSView {
        let book = AgentModelBook.shared, a = model.agent, p = PROJECTS_CFG.runtime.profile(a)
        if let c = p.cli, !p.model.isEmpty { book.load(c) }
        let warn = book.warning(p)
        let chip = ActionButton((warn == nil ? "" : "△ ") + book.label(a, p) + "  ⌄")
        chip.isEnabled = !model.isStarting
        chip.onClick = { [weak self, weak chip] in
            guard let self, let chip else { return }
            let menu = NSMenu()
            AgentMenu.build(into: menu, picked: self.model.agent, standard: self.model.standard) { [weak self] a in
                self?.model.pickAgent(a)
                self?.refresh()
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: chip.bounds.height + 2), in: chip)
        }
        chip.toolTip = warn ?? (p.cli == nil ? "No base CLI. Only a terminal runtime (Orca) can start it." : "The agent of this start. Settings › Agents has the default.")
        let effort = p.hasEffort ? ", effort \(AgentProfile.effortName(p.effort))" : ""
        chip.setAccessibilityLabel("Agent \(a), model \(p.cli == nil ? "terminal only" : p.model.isEmpty ? "Auto" : book.name(p.model, cli: p.cli!))\(effort)")
        if let warn { chip.setAccessibilityHelp(warn) }
        return chip
    }

    @objc private func fieldPicked() {
        model.state = statePop.selectedItem?.representedObject as? String
        model.priority = priorityPop.selectedItem?.representedObject as? String ?? "none"
    }

    @objc private func flipIntake() {
        model.intake = intakeBox.state == .on
        if case .failed = model.phase { model.phase = .edit }
        refresh()
    }

    func start() {
        model.text = promptView.string
        model.titleText = titleField.stringValue
        guard model.canStart else { return NSSound.beep() }
        if voice.isRecording { voice.stop() }
        actions.start(model)
    }

    private func dismiss() {
        voice.stop()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        orderOut(nil)
        actions.closed()
    }

    @objc private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = "Attach files to the new session"
        NSApp.activate(ignoringOtherApps: true)
        p.beginSheetModal(for: self) { [weak self] r in
            guard r == .OK else { return }
            self?.addFiles(p.urls)
        }
    }

    private func addFiles(_ urls: [URL]) {
        let files = urls.compactMap { u -> NewSessionModel.Attachment? in
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue, let d = try? Data(contentsOf: u) else { return nil }
            return NewSessionModel.Attachment(name: u.lastPathComponent, data: d)
        }
        if files.count < urls.count { NSSound.beep() }
        add(files)
    }

    @objc private func flipVoice() {
        if voice.isRecording { voice.stop(); return }
        model.phase = .listening
        refresh()
        voice.start(level: { _ in }, done: { [weak self] result in
            guard let self else { return }
            self.model.phase = .edit
            switch result {
            case .success(let t) where !t.isEmpty:
                let s = self.promptView.string
                self.promptView.string = s.isEmpty ? t : s + (s.hasSuffix("\n") || s.hasSuffix(" ") ? "" : " ") + t
                self.model.text = self.promptView.string
            case .success: break
            case .failure(let e): self.model.phase = .failed(e.localizedDescription)
            }
            self.refresh()
        })
    }

    private func promptFocus(_ on: Bool) {
        if model.phase != .listening { promptBox.border = on ? Palette.acc : Palette.line }
        if on && model.listOpen { setList(false) }
    }

    // MARK: Keys

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if [36, 76].contains(e.keyCode) && (mods == .command || mods == .control) { start(); return true }
        if mods == .command, let c = e.charactersIgnoringModifiers?.lowercased() {
            if c == "d" { flipVoice(); return true }
            if c == "o" { pickFiles(); return true }
            if let n = Int(c), (1...NewSessionModel.Mode.allCases.count).contains(n) { setMode(NewSessionModel.Mode.allCases[n - 1]); return true }
        }
        if (mods == .command || mods == .control) && e.charactersIgnoringModifiers?.lowercased() == "v" { return paste(control: mods == .control) }
        return super.performKeyEquivalent(with: e)
    }

    /// ⌘V and ⌃V put files and images in the list from any field. ⌃V also pastes text, as a text view reads it as page down.
    func paste(control: Bool, from pb: NSPasteboard = .general) -> Bool {
        switch PasteContent(pb) {
        case .files(let urls): addFiles(urls)
        case .image(let png): add([NewSessionModel.Attachment(name: model.pasteName, data: png, isImage: true)])
        case .text:
            guard control else { return false }
            (firstResponder as? NSText)?.paste(nil)
        }
        return true
    }

    /// Esc closes the list, then the dictation, then Quick Look, then the panel.
    override func cancelOperation(_ sender: Any?) {
        if model.listOpen { setList(false); makeFirstResponder(promptView); return }
        if voice.isRecording { voice.stop(); return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil); return }
        dismiss()
    }

    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === titleField {
            model.titleText = titleField.stringValue
            if case .failed = model.phase { model.phase = .edit }
        } else {
            model.type(comboField.stringValue)
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === titleField {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)): makeFirstResponder(promptView); return true
            case #selector(NSResponder.cancelOperation(_:)): cancelOperation(nil); return true
            default: return false
            }
        }
        switch sel {
        case #selector(NSResponder.moveUp(_:)): model.move(-1); refresh(); return true
        case #selector(NSResponder.moveDown(_:)): model.move(1); refresh(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let c = model.matches.indices.contains(model.highlight) ? model.matches[model.highlight] : nil { pick(c.store) } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): cancelOperation(nil); return true
        default: return false
        }
    }

    func textDidChange(_ n: Notification) {
        model.text = promptView.string
        if case .failed = model.phase { model.phase = .edit }
        refresh()
    }

    func textView(_ v: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelOperation(nil); return true }
        if sel == #selector(NSResponder.insertNewline(_:)), let e = NSApp.currentEvent, e.modifierFlags.contains(.control) || e.modifierFlags.contains(.command) {
            start()
            return true
        }
        return false
    }

    // MARK: Quick Look

    private func quickLook(_ id: UUID) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oversire-session")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        preview = model.files.map { f in
            let u = dir.appendingPathComponent(f.id.uuidString + "-" + f.name)
            if !FileManager.default.fileExists(atPath: u.path) { try? f.data.write(to: u) }
            return u
        }
        guard let i = model.files.firstIndex(where: { $0.id == id }), let ql = QLPreviewPanel.shared() else { return }
        ql.dataSource = self
        ql.reloadData()
        ql.currentPreviewItemIndex = i
        ql.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { preview.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { preview[index] as NSURL }
}

// ─── Controller ──────────────────────────────────────────────────────────────
// Owns the shortcut, the panel, the starter and the toast.

final class NewSessionController {
    static let changed = Notification.Name("NewSessionChanged")

    private let projects: () -> [ProjectSummary]
    private let states: (String) -> [StatusOption]
    private(set) var panel: NewSessionPanel?
    var created: (String) -> Void = { _ in }     // gets the store key of the project with a new item
    private(set) var toast: SessionToast?
    private var hotKey: GlobalHotKey?
    private var intakeOn: [String: Bool] = [:]
    private var intakeAsked: Set<String> = []
    private(set) lazy var starter = SessionStarter(
        project: { [weak self] k in self?.summary(k)?.ref },
        tracker: { ENV.tracker($0.workspace) },
        terminal: { ENV.runtime as? AgentTerminal },
        hostFiles: { ENV.runtime as? HostFileWriting },
        root: { [weak self] k in self?.summary(k).flatMap { PROJECTS_CFG.orcaRoot($0) } })

    /// `states` gives the status options of a project by its store key.
    init(projects: @escaping () -> [ProjectSummary], states: @escaping (String) -> [StatusOption] = { _ in [] }) {
        self.projects = projects
        self.states = states
    }

    var cfg: SessionConfig { PROJECTS_CFG.capture.session }
    var isOpen: Bool { panel?.isVisible == true }

    /// Registers the shortcut again. False: macOS did not accept it.
    @discardableResult
    func applyHotKey() -> Bool {
        suspendHotKey(true)
        guard cfg.enabled, cfg.hasShortcut else { return true }
        hotKey = GlobalHotKey(keyCode: cfg.keyCode, modifiers: cfg.modifiers) { [weak self] in self?.toggle() }
        if hotKey == nil { log.warning("New session shortcut \(self.cfg.shortcutLabel, privacy: .public) is not available") }
        return hotKey != nil
    }

    func suspendHotKey(_ on: Bool) {
        if on { hotKey?.unregister(); hotKey = nil } else { applyHotKey() }
    }

    /// ⌃⌥⌘N: opens the panel, or closes it when it has the focus.
    func toggle() {
        if let p = panel, p.isKeyWindow { return p.cancelOperation(nil) }
        show(near: nil)
    }

    /// Under `near` (the toolbar button), else at the top of the screen with the mouse.
    func show(near: NSView?) {
        let p = panel ?? makePanel(NewSessionModel(choices: choices(), cfg: cfg, agent: PROJECTS_CFG.runtime.agent), saved: .load())
        place(p, near: near)
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(p.model.selection == nil ? p.comboField : p.model.makesItem ? p.titleField : p.promptView)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// A panel with a fixed state, for --uishots.
    func present(_ m: NewSessionModel, near: NSView?) -> NewSessionPanel {
        panel?.orderOut(nil)
        let p = makePanel(m, saved: nil)
        place(p, near: near)
        p.orderFrontRegardless()
        return p
    }

    private func makePanel(_ m: NewSessionModel, saved: NewPanelFrame?) -> NewSessionPanel {
        var m = m
        m.intakeOff.formUnion(intakeOn.filter { !$0.value }.keys)
        var a = NewSessionPanel.Actions()
        a.start = { [weak self] m in self?.start(m) }
        a.chooseRoot = { [weak self] k in self?.chooseRoot(k) }
        a.checkIntake = { [weak self] k in self?.checkIntake(k) }
        a.enableIntake = { [weak self] k in self?.enableIntake(k) }
        a.closed = { [weak self] in
            self?.panel = nil
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
        let p = NewSessionPanel(model: m, actions: a, saved: saved)
        panel = p
        return p
    }

    /// The saved place first, kept on the screen.
    private func place(_ p: NewSessionPanel, near: NSView?) {
        if let t = p.frameSaved.topLeft, let s = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: t[0] + 1, y: t[1] - 1)) }) {
            let v = s.visibleFrame
            return p.place(topLeft: NSPoint(x: min(t[0], v.maxX - p.frame.width), y: max(t[1], v.minY + p.frame.height)))
        }
        if let v = near, let w = v.window {
            let r = w.convertToScreen(v.convert(v.bounds, to: nil))
            p.place(topLeft: NSPoint(x: r.minX - 12, y: r.minY - 6))
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let v = s.visibleFrame
        p.place(topLeft: NSPoint(x: v.midX - p.frame.width / 2, y: v.maxY - v.height * 0.18))
    }

    private func summary(_ store: String) -> ProjectSummary? { projects().first { $0.ref.storeKey == store } }

    func choices() -> [NewSessionModel.Choice] {
        projects().map { NewSessionModel.Choice(key: $0.identifier, name: $0.title, store: $0.ref.storeKey, root: PROJECTS_CFG.orcaRoot($0),
                                                states: states($0.ref.storeKey), agent: PROJECTS_CFG.local($0.identifier).agent.flatMap { $0.isEmpty ? nil : $0 }) }
    }

    private func chooseRoot(_ store: String) {
        guard let s = summary(store), let p = panel else { return }
        let o = NSOpenPanel()
        o.canChooseDirectories = true
        o.canChooseFiles = false
        o.canCreateDirectories = true
        o.message = "Choose the Orca workspace folder of \(s.identifier)"
        if let r = PROJECTS_CFG.orcaRoot(s) { o.directoryURL = URL(fileURLWithPath: r) }
        NSApp.activate(ignoringOtherApps: true)
        o.beginSheetModal(for: p) { [weak self] r in
            guard r == .OK, let u = o.url, let self else { return }
            PROJECTS_CFG.setOrcaRoot(s, u.path)
            saveConfig()
            self.panel?.setChoices(self.choices())
        }
    }

    private func start(_ m: NewSessionModel) {
        guard let p = panel else { return }
        if m.mode == .session { PROJECTS_CFG.capture.session.intake = m.intake }
        PROJECTS_CFG.capture.session.mode = m.mode
        PROJECTS_CFG.capture.session.lastProject = m.selected
        saveConfig()
        if m.makesItem { return create(m, in: p) }
        let req = SessionStarter.Request(project: m.selected, text: m.text, files: m.files, intake: m.intake,
                                         title: m.titleText.isEmpty ? nil : m.itemTitle, agent: m.agent)
        let root = m.selection?.root ?? ""
        p.setPhase(.starting("Starting…"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let r = try await self.starter.start(req) { label in DispatchQueue.main.async { p.setPhase(.starting(label)) } }
                p.orderOut(nil)
                self.panel = nil
                NotificationCenter.default.post(name: Self.changed, object: self)
                self.showToast(r, agent: m.agent, root: root, files: m.files.count)
            } catch {
                log.error("New session: start failed: \(error.localizedDescription, privacy: .public)")
                if case SessionStartError.hostFiles = error { p.setPhase(.failed(error.localizedDescription), hostFiles: true) }
                else { p.setPhase(.failed(error.localizedDescription)) }
            }
        }
    }

    // Once for each project while the app runs. A failed create with the intake off also sets it.
    private func checkIntake(_ store: String) {
        if let on = intakeOn[store] {
            if panel?.model.intakeOff.contains(store) != !on { panel?.setIntake(store, off: !on) }
            return
        }
        guard !intakeAsked.contains(store) else { return }
        intakeAsked.insert(store)
        Task { @MainActor [weak self] in
            guard let self, let on = await self.starter.intakeOn(store) else { return }
            self.intakeOn[store] = on
            if !on { self.panel?.setIntake(store, off: true) }
        }
    }

    // Only on a click: it changes the project in the tracker.
    private func enableIntake(_ store: String) {
        guard let p = panel else { return }
        p.setPhase(.starting("Turning on Intake…"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.starter.enableIntake(store)
                self.intakeOn[store] = true
                p.setIntake(store, off: false)
                p.setPhase(.edit)
            } catch {
                log.error("New intake: turn on failed: \(error.localizedDescription, privacy: .public)")
                p.setPhase(.failed(error.localizedDescription))
            }
        }
    }

    private func create(_ m: NewSessionModel, in p: NewSessionPanel) {
        let req = SessionStarter.Request(project: m.selected, text: m.text, files: m.files, intake: m.mode == .intake,
                                         title: m.itemTitle, state: m.itemState, priority: m.priority)
        p.setPhase(.starting("Creating…"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let r = try await self.starter.create(req, intake: m.mode == .intake) { label in DispatchQueue.main.async { p.setPhase(.starting(label)) } }
                p.orderOut(nil)
                self.panel = nil
                NotificationCenter.default.post(name: Self.changed, object: self)
                self.created(m.selected)
                self.showToast(r, mode: m.mode, files: m.files.count)
            } catch {
                log.error("New \(m.mode.rawValue, privacy: .public): create failed: \(error.localizedDescription, privacy: .public)")
                if (error as? ProviderError)?.isIntakeOff == true {
                    self.intakeOn[m.selected] = false
                    p.setIntake(m.selected, off: true)
                    p.setPhase(.edit)
                } else {
                    p.setPhase(.failed(error.localizedDescription))
                }
            }
        }
    }

    func showToast(_ r: SessionStarter.Result, agent: String, root: String, files: Int) {
        let term = ENV.runtime as? AgentTerminal
        let local = ENV.runtime is any Revealing
        var actions: [(String, () -> Void)] = [("New session", { [weak self] in self?.show(near: nil) })]
        if local { actions.insert(("Show in Orca", { Task { try? await term?.show(r.session) } }), at: 0) }
        present(SessionToast(title: "Started \(agent) in \((root as NSString).lastPathComponent)",
                             subtitle: "Terminal \(r.terminal) on \(local ? "this Mac" : r.session.workspace.account.id)",
                             detail: r.detail(files: files), bad: !r.missing.isEmpty, actions: actions))
    }

    func showToast(_ r: SessionStarter.Made, mode: NewSessionModel.Mode, files: Int) {
        present(SessionToast(title: "Created \(mode == .intake ? "intake " : "")\(r.item.key)", subtitle: r.item.url.absoluteString,
                             detail: r.detail(files: files), bad: !r.missing.isEmpty, actions: [
                                ("Open", { (NSApp.delegate as? GHActionsBar)?.open(.item(r.item.key, .overview)) }),
                                ("New \(mode.label.lowercased())", { [weak self] in self?.show(near: nil) }),
                             ]))
    }

    private func present(_ t: SessionToast) {
        toast?.orderOut(nil)
        toast = t
        t.present()
    }
}

// ─── Toast ───────────────────────────────────────────────────────────────────
// The result at the bottom right of the screen. It hides after 10 s.

final class SessionToast: NSPanel {
    init(title: String, subtitle: String, detail: String, bad: Bool, actions: [(String, () -> Void)]) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = Box(fill: Palette.panel, border: Palette.line, radius: 10)
        contentView = root
        let closeAct = ActionButton("", symbol: "xmark") { [weak self] in self?.orderOut(nil) }
        closeAct.isBordered = false
        closeAct.contentTintColor = Palette.dim
        closeAct.setAccessibilityLabel("Close")
        let col = NSStackView(v: [
            NSStackView(h: [Glyph(bad ? .warning : .ok, size: 13), NSTextField.text(title, size: 13, weight: .semibold), Spacer(), closeAct], spacing: 6),
            NSTextField.text(subtitle, size: 11.5, color: Palette.mut, mono: true),
            NSTextField.text(detail, size: 12, color: bad ? Palette.bad : Palette.fg, lines: 3),
            NSStackView(h: actions.map { a in ActionButton(a.0, style: .link) { [weak self] in self?.orderOut(nil); a.1() } }, spacing: 14),
        ], spacing: 5)
        col.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 10)
        root.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: root.leadingAnchor), col.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            col.topAnchor.constraint(equalTo: root.topAnchor), col.widthAnchor.constraint(equalToConstant: 380),
        ])
        setAccessibilityLabel(title + ". " + detail)
        col.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: 380, height: col.fittingSize.height))
    }

    func present() {
        if let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            setFrameOrigin(NSPoint(x: v.maxX - frame.width - 16, y: v.minY + 16))
        }
        orderFrontRegardless()
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard !UIShots.shooting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.orderOut(nil) }
    }
}

// ─── Small views ─────────────────────────────────────────────────────────────

/// A click opens the list. The first focus does not.
final class SessionComboField: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        onClick?()
    }
}

/// What a paste adds: files, one image, or text.
enum PasteContent: Equatable {
    case files([URL])
    case image(Data)
    case text

    /// An image wins over text that only names it (a URL or an image file name), as browsers and chat apps copy.
    init(_ pb: NSPasteboard) {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            self = .files(urls)
            return
        }
        guard pb.availableType(from: [.png, .tiff]) != nil, Self.namesImage(pb.string(forType: .string)),
              let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { self = .text; return }
        self = .image(png)
    }

    private static func namesImage(_ s: String?) -> Bool {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return true }
        guard !s.contains(where: \.isNewline) else { return false }
        if s.contains("://") { return true }
        return UTType(filenameExtension: (s as NSString).pathExtension)?.conforms(to: .image) ?? false
    }
}

/// Takes pasted and dropped files and images. Text pastes as text.
final class SessionTextView: SnapTextView {
    var onFiles: (([URL]) -> Void)?
    var onImage: ((Data) -> Void)?

    /// Keeps Edit › Paste on when the clipboard holds only an image or files.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { super.readablePasteboardTypes + [.png, .tiff, .fileURL] }

    override func paste(_ sender: Any?) {
        switch PasteContent(.general) {
        case .files(let urls): onFiles?(urls)
        case .image(let png): onImage?(png)
        case .text: super.paste(sender)
        }
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }
        return super.performDragOperation(s)
    }
}

/// The panel background. It takes dropped files.
final class SessionDropView: Box {
    var onFiles: (([URL]) -> Void)?

    init() {
        super.init(fill: Palette.panel, border: Palette.line, radius: 12)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }
}

final class SessionPickRow: Box {
    private let onClick: () -> Void

    init(_ views: [NSView], onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(fill: nil, border: nil, radius: 5)
        let row = NSStackView(h: views, spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with e: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// An image file: a thumbnail with its name. Click: Quick Look.
final class SessionThumb: NSView {
    private let open: () -> Void

    init(_ f: NewSessionModel.Attachment, open: @escaping () -> Void, remove: @escaping () -> Void) {
        self.open = open
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let img = NSImageView(image: NSImage(data: f.data) ?? NSImage())
        img.imageScaling = .scaleProportionallyUpOrDown
        img.wantsLayer = true
        img.layer?.cornerRadius = 5
        img.layer?.masksToBounds = true
        img.layer?.borderWidth = 1
        img.layer?.borderColor = Palette.line.cgColor
        img.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField.text(f.name, size: 10.5, color: Palette.mut)
        name.lineBreakMode = .byTruncatingMiddle
        let x = SessionRemove(f.name, remove)
        for v in [img, name, x] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 64),
            img.leadingAnchor.constraint(equalTo: leadingAnchor), img.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            img.widthAnchor.constraint(equalToConstant: 56), img.heightAnchor.constraint(equalToConstant: 44),
            name.leadingAnchor.constraint(equalTo: leadingAnchor), name.widthAnchor.constraint(equalToConstant: 56),
            name.topAnchor.constraint(equalTo: img.bottomAnchor, constant: 2),
            x.centerXAnchor.constraint(equalTo: img.trailingAnchor, constant: -2), x.centerYAnchor.constraint(equalTo: img.topAnchor, constant: 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(f.name), image. Press to preview.")
        toolTip = f.name
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with e: NSEvent) { open() }
    override func accessibilityPerformPress() -> Bool { open(); return true }
}

/// A file that is not an image: icon, name, size and ×.
final class SessionFileChip: Box {
    private let open: () -> Void

    init(_ f: NewSessionModel.Attachment, open: @escaping () -> Void, remove: @escaping () -> Void) {
        self.open = open
        super.init(fill: Palette.raise, border: Palette.line, radius: 6)
        let size = ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file)
        let name = NSTextField.text(f.name, size: 11.5, color: Palette.fg, mono: true)
        name.lineBreakMode = .byTruncatingMiddle
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        let row = NSStackView(h: [Glyph("doc", size: 11), name, NSTextField.text(size, size: 11, color: Palette.dim), SessionRemove(f.name, remove)], spacing: 6)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(f.name), \(size). Press to preview.")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with e: NSEvent) { open() }
    override func accessibilityPerformPress() -> Bool { open(); return true }
}

/// The round × of a file.
final class SessionRemove: NSButton {
    private let run: () -> Void

    init(_ name: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(name)")
        isBordered = false
        contentTintColor = Palette.mut
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = "Remove \(name)"
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// The corner grip of the New panel. It reports the drag from the mouse down.
final class SessionSizeGrip: NSView {
    var onDrag: (_ dx: CGFloat, _ dy: CGFloat, _ start: NewPanelFrame) -> Void = { _, _, _ in }
    var onEnd: () -> Void = {}
    private var from: (point: NSPoint, frame: NewPanelFrame)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        toolTip = "Drag to resize"
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 14, y: 10)); p.line(to: NSPoint(x: 6, y: 2))
        p.move(to: NSPoint(x: 14, y: 6)); p.line(to: NSPoint(x: 10, y: 2))
        p.lineWidth = 1.4
        p.lineCapStyle = .round
        Palette.dim.setStroke()
        p.stroke()
    }

    override func resetCursorRects() {
        if #available(macOS 15, *) { addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all)) }
        else { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with e: NSEvent) {
        guard let p = window as? NewSessionPanel else { return }
        from = (NSEvent.mouseLocation, p.frameSaved)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let f = from else { return }
        let m = NSEvent.mouseLocation
        onDrag(m.x - f.point.x, f.point.y - m.y, f.frame)
    }

    override func mouseUp(with e: NSEvent) {
        if from != nil { onEnd() }
        from = nil
    }
}

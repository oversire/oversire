import Cocoa

// ─── Shot editor ─────────────────────────────────────────────────────────────
// A floating panel: the project field, the image with its marks, the notes, and the footer.
// SnapEditorModel holds the state. The panel and the canvas show it and change it.

/// The state of one shot in the editor. Undo covers the marks and the crop, not the text.
struct SnapEditorModel {
    enum Reason: Equatable {
        case basket(looksLike: String?), windowTitle, lastUsed, picked, newBasket

        var label: String {
            switch self {
            case .basket(let o?): return "this basket · window looks like \(o)"
            case .basket: return "this basket"
            case .windowTitle: return "from window title"
            case .lastUsed: return "last used"
            case .picked: return "you picked"
            case .newBasket: return "new basket"
            }
        }
    }

    /// What ⎋ did. The order: crop, confirm, mismatch, text field, selection, discard.
    enum Escape: Equatable { case cancelCrop, cancelConfirm, cancelMismatch, leaveField, clearSelection, askDiscard, discard }

    enum Block: Equatable { case mismatch, empty }

    var shot: SnapShot
    let existing: Bool
    let basketProject: String?    // the project of the open basket in view
    let basketCount: Int
    var reason: Reason
    var selected: Int?
    var crop: SnapRect?           // the crop frame while the crop mode is on
    var mismatch: String?         // the project that the user picked, while the bar asks
    var confirming = false
    var lastNote: Int?            // nil is the shot note, else the mark index
    private(set) var undoStack: [SnapEdit] = []
    private(set) var redoStack: [SnapEdit] = []

    /// `shot.project` is the guess from the window title, or empty.
    init(shot: SnapShot, existing: Bool = false, basketProject: String?, basketCount: Int, lastProject: String?) {
        var s = shot
        let guess = shot.project.isEmpty ? nil : shot.project
        if existing {
            reason = .basket(looksLike: nil)
        } else if let b = basketProject {
            reason = .basket(looksLike: guess.flatMap { $0 == b ? nil : $0 })
            s.project = b
        } else if let g = guess {
            reason = .windowTitle
            s.project = g
        } else {
            reason = .lastUsed
            s.project = lastProject ?? ""
        }
        self.shot = s
        self.existing = existing
        self.basketProject = basketProject
        self.basketCount = basketCount
    }

    var isCropping: Bool { crop != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call after a change, with the state from before it. A change that changes nothing is not kept.
    mutating func record(_ before: SnapEdit) {
        guard before != shot.edit else { return }
        undoStack.append(before)
        redoStack = []
    }

    mutating func undo() {
        guard let e = undoStack.popLast() else { return }
        redoStack.append(shot.edit)
        shot.edit = e
        selected = nil
    }

    mutating func redo() {
        guard let e = redoStack.popLast() else { return }
        undoStack.append(shot.edit)
        shot.edit = e
        selected = nil
    }

    /// Adds a mark inside the crop and selects it. Returns its index.
    @discardableResult
    mutating func addMark(_ r: SnapRect) -> Int {
        let before = shot.edit
        var r = r
        r.w = min(r.w, shot.crop.w)
        r.h = min(r.h, shot.crop.h)
        shot.marks.append(SnapMark(rect: r.clamped(to: shot.crop), note: ""))
        record(before)
        selected = shot.marks.count - 1
        lastNote = selected
        return shot.marks.count - 1
    }

    mutating func deleteMark(_ i: Int) {
        guard shot.marks.indices.contains(i) else { return }
        let before = shot.edit
        shot.marks.remove(at: i)
        record(before)
        selected = nil
        if lastNote == i { lastNote = nil } else if let l = lastNote, l > i { lastNote = l - 1 }
    }

    mutating func nudge(_ i: Int, by d: CGVector) {
        let before = shot.edit
        shot.move(mark: i, by: d)
        record(before)
    }

    mutating func startCrop() {
        crop = shot.crop
        selected = nil
    }

    /// Applies the crop frame. Returns the number of marks that went.
    @discardableResult
    mutating func applyCrop() -> Int {
        guard let c = crop else { return 0 }
        let before = shot.edit
        let (out, removed) = shot.apply(crop: c)
        shot = out
        crop = nil
        record(before)
        if let l = lastNote, !shot.marks.indices.contains(l) { lastNote = nil }
        return removed
    }

    /// Picks a project. A project other than the basket's opens the mismatch bar. Returns true when it is set.
    @discardableResult
    mutating func pick(_ project: String) -> Bool {
        guard !existing else { return false }
        if let b = basketProject, project.caseInsensitiveCompare(b) != .orderedSame {
            mismatch = project
            return false
        }
        shot.project = project
        reason = basketProject == nil ? .picked : .basket(looksLike: nil)
        mismatch = nil
        return true
    }

    /// "Start a basket for X" (newBasket) or "Keep in Y".
    mutating func resolveMismatch(newBasket: Bool) {
        guard let m = mismatch else { return }
        if newBasket {
            shot.project = m
            reason = .newBasket
        } else if let b = basketProject {
            shot.project = b
            reason = .basket(looksLike: nil)
        }
        mismatch = nil
    }

    mutating func escape(inField: Bool) -> Escape {
        if crop != nil { crop = nil; return .cancelCrop }
        if confirming { confirming = false; return .cancelConfirm }
        if mismatch != nil { mismatch = nil; return .cancelMismatch }
        if inField { return .leaveField }
        if selected != nil { selected = nil; return .clearSelection }
        if !existing && !shot.isBlank { confirming = true; return .askDiscard }
        return .discard
    }

    /// Why Add does not work now, or nil.
    var addBlock: Block? {
        if mismatch != nil { return .mismatch }
        if shot.isBlank { return .empty }
        return nil
    }

    /// The shot to add or save. A crop frame that is still open is applied first.
    mutating func finish() -> SnapShot {
        if crop != nil { applyCrop() }
        return shot
    }
}

/// One project in the project list.
struct SnapProjectChoice: Equatable {
    var key: String
    var title: String

    /// Each word of the query is in the key or the title. Titles that start with the query come first.
    static func filter(_ all: [SnapProjectChoice], _ q: String) -> [SnapProjectChoice] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return all }
        let hits = all.filter { c in
            let hay = (c.key + " " + c.title).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return hits.filter { $0.title.lowercased().hasPrefix(first) || $0.key.lowercased().hasPrefix(first) }
            + hits.filter { !($0.title.lowercased().hasPrefix(first) || $0.key.lowercased().hasPrefix(first)) }
    }
}

// MARK: Panel

final class ShotEditorPanel: NSPanel, NSTextFieldDelegate {
    struct Actions {
        var add: (SnapShot, _ again: Bool) -> Void = { _, _ in }
        var save: (SnapShot) -> Void = { _ in }
        var remove: (SnapShot) -> Void = { _ in }
        var closed: () -> Void = {}
    }

    private(set) var model: SnapEditorModel
    private let projects: [SnapProjectChoice]
    private let actions: Actions
    private let canvas: SnapCanvasView
    private let voice = SnapVoice()

    private let projectField = NSTextField()
    private let projectIcon = NSImageView()
    private let reasonLabel = NSTextField.text("", size: 11.5, color: Palette.acc)
    private let countLabel = NSTextField.text("", size: 11.5, color: Palette.dim)
    private let list = SnapProjectList()
    private var listShown: [SnapProjectChoice] = []
    private let mismatchBar = Box(fill: Palette.warn.withAlphaComponent(0.09), border: Palette.warn.withAlphaComponent(0.6), radius: 8)
    private let mismatchText = NSTextField.text("", size: 12, lines: 2)
    private let mismatchNew = ActionButton("", style: .primary)
    private let mismatchKeep = ActionButton("")
    private let noteView = SnapNoteView(placeholder: "What is wrong, or what do you want? Optional when the marks say it all.")
    private let marksHeader = NSTextField.text("MARKS", size: 11, weight: .semibold, color: Palette.dim)
    private let marksStack = NSStackView(v: [], spacing: 6)
    private let emptyMarks = NSTextField.text("No marks yet. Drag on the image to mark an area, or click to mark a spot. Each mark gets a number and its own note.",
                                              size: 11.5, color: Palette.dim, lines: 4)
    private var markNotes: [SnapNoteView] = []
    private let footer = NSStackView(h: [], spacing: 6)
    private let sizeLabel = NSTextField.text("", size: 11.5, color: Palette.dim)
    private let tipLabel = NSTextField.text("", size: 11, color: Palette.mut)
    private let toastBox = Box(fill: Palette.raise, border: Palette.line, radius: 8)
    private let toastLabel = NSTextField.text("", size: 12)
    private var toastTimer: Timer?
    private var voiceButton: ActionButton?

    init(model: SnapEditorModel, image: CGImage, projects: [SnapProjectChoice], near: CGRect?, actions: Actions) {
        self.model = model
        self.projects = projects
        self.actions = actions
        canvas = SnapCanvasView(image: image)
        let screen = near.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: min(900, screen.visibleFrame.width - 40), height: min(520, screen.visibleFrame.height - 40))
        super.init(contentRect: Self.place(size, near: near, in: screen.visibleFrame), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 640, height: 420)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setAccessibilityLabel("Shot editor")
        build()
        canvas.panel = self
        reload()
    }

    /// Right of the selection, else left of it, else in the middle of the screen.
    static func place(_ size: NSSize, near r: CGRect?, in v: CGRect) -> NSRect {
        var o = CGPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2)
        if let r {
            if r.maxX + 16 + size.width <= v.maxX { o.x = r.maxX + 16 } else if r.minX - 16 - size.width >= v.minX { o.x = r.minX - 16 - size.width }
            o.y = r.midY - size.height / 2
        }
        o.x = min(max(o.x, v.minX + 8), v.maxX - size.width - 8)
        o.y = min(max(o.y, v.minY + 8), v.maxY - size.height - 8)
        return NSRect(origin: o, size: size)
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel and puts the focus on the project field (no basket) or on the shot note.
    func present() {
        orderFrontRegardless()
        makeKey()
        if model.basketProject == nil && !model.existing {
            makeFirstResponder(projectField)
            projectField.currentEditor()?.selectAll(nil)
            showList()
        } else {
            makeFirstResponder(noteView.text)
        }
    }

    // MARK: Layout

    private func build() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.state = .active
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        contentView = root

        projectField.font = .systemFont(ofSize: 13, weight: .semibold)
        projectField.delegate = self
        projectField.focusRingType = .exterior
        projectField.placeholderString = "Project"
        projectField.setAccessibilityLabel("Project")
        projectField.translatesAutoresizingMaskIntoConstraints = false
        projectField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        projectIcon.translatesAutoresizingMaskIntoConstraints = false
        projectIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let close = ActionButton("", symbol: "xmark", style: .link) { [weak self] in self?.discard() }
        close.setAccessibilityLabel(model.existing ? "Close without saving" : "Discard shot")
        close.toolTip = (model.existing ? "Close without saving" : "Discard") + " (⎋)"
        let head = NSStackView(h: [projectIcon, projectField, reasonLabel, Spacer(), countLabel, close], spacing: 8)
        head.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        mismatchNew.onClick = { [weak self] in self?.resolveMismatch(newBasket: true) }
        mismatchKeep.onClick = { [weak self] in self?.resolveMismatch(newBasket: false) }
        let mm = NSStackView(v: [mismatchText, NSStackView(h: [mismatchNew, mismatchKeep], spacing: 6)], spacing: 6)
        mm.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        mismatchBar.addSubview(mm)
        pin(mm, in: mismatchBar)
        let mmWrap = NSStackView(v: [mismatchBar], spacing: 0)
        mmWrap.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
        mismatchBar.widthAnchor.constraint(equalTo: mmWrap.widthAnchor, constant: -20).isActive = true
        mismatchWrap = mmWrap

        let checker = SnapChecker()
        checker.addSubview(canvas)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        checker.addSubview(tipLabel)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: checker.leadingAnchor, constant: 10),
            canvas.trailingAnchor.constraint(equalTo: checker.trailingAnchor, constant: -10),
            canvas.topAnchor.constraint(equalTo: checker.topAnchor, constant: 10),
            canvas.bottomAnchor.constraint(equalTo: checker.bottomAnchor, constant: -10),
            tipLabel.centerXAnchor.constraint(equalTo: checker.centerXAnchor),
            tipLabel.bottomAnchor.constraint(equalTo: checker.bottomAnchor, constant: -14),
        ])
        tipLabel.drawsBackground = true
        tipLabel.backgroundColor = Palette.panel.withAlphaComponent(0.9)

        let noteLabel = NSTextField.text("SHOT NOTE", size: 11, weight: .semibold, color: Palette.dim)
        noteView.onFocus = { [weak self] in self?.focusedNote(nil) }
        noteView.onChange = { [weak self] t in self?.model.shot.note = t }
        noteView.text.setAccessibilityLabel("Shot note")
        noteView.heightAnchor.constraint(equalToConstant: 62).isActive = true
        let notes = NSStackView(v: [noteLabel, noteView, marksHeader, emptyMarks, marksStack], spacing: 6)
        notes.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        notes.setCustomSpacing(12, after: noteView)
        for v in [noteView, emptyMarks, marksStack] { v.widthAnchor.constraint(equalTo: notes.widthAnchor, constant: -20).isActive = true }
        let side = NSScrollView()
        side.drawsBackground = false
        side.hasVerticalScroller = true
        side.autohidesScrollers = true
        let flip = SnapFlipped()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(notes)
        pin(notes, in: flip)
        side.documentView = flip
        flip.widthAnchor.constraint(equalTo: side.contentView.widthAnchor).isActive = true
        side.translatesAutoresizingMaskIntoConstraints = false
        side.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let body = NSStackView(h: [checker, SnapLine(vertical: true), side], spacing: 0, align: .height)
        checker.setContentHuggingPriority(.init(1), for: .horizontal)

        footer.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let toastStack = NSStackView(h: [toastLabel], spacing: 0)
        toastStack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        toastBox.addSubview(toastStack)
        pin(toastStack, in: toastBox)
        toastBox.isHidden = true

        let col = NSStackView(v: [head, SnapLine(vertical: false), mmWrap, body, SnapLine(vertical: false), footer], spacing: 0, align: .leading)
        for v in [head, mmWrap, body, footer] { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        root.addSubview(col)
        pin(col, in: root)
        root.addSubview(toastBox)
        root.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toastBox.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toastBox.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            list.leadingAnchor.constraint(equalTo: projectField.leadingAnchor, constant: -26),
            list.topAnchor.constraint(equalTo: projectField.bottomAnchor, constant: 3),
            list.widthAnchor.constraint(equalToConstant: 240),
        ])
        list.isHidden = true
        list.onPick = { [weak self] c in self?.pick(c.key) }
    }

    private var mismatchWrap: NSView?

    private func pin(_ v: NSView, in p: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: p.leadingAnchor), v.trailingAnchor.constraint(equalTo: p.trailingAnchor),
            v.topAnchor.constraint(equalTo: p.topAnchor), v.bottomAnchor.constraint(equalTo: p.bottomAnchor),
        ])
    }

    // MARK: State to views

    private func title(of key: String) -> String { projects.first { $0.key == key }?.title ?? key }

    /// Shows the model. Keeps the text of the note fields that have the focus.
    func reload() {
        let key = model.shot.project
        projectIcon.image = key.isEmpty ? nil : PROJECT_ICONS.image(for: key, size: 18)
        if !(firstResponder === projectField.currentEditor()) { projectField.stringValue = model.shot.project.isEmpty ? "" : title(of: model.shot.project) }
        projectField.isEnabled = !model.existing
        if model.existing { projectField.toolTip = "To change the project, remove the shot and snap again" }
        reasonLabel.stringValue = key.isEmpty ? "" : model.reason.label
        let n = model.basketCount
        countLabel.stringValue = model.existing ? "Edit shot" : n > 0 ? "Basket · \(n) shot\(n == 1 ? "" : "s")" : "New basket"

        mismatchWrap?.isHidden = model.mismatch == nil
        if let m = model.mismatch, let b = model.basketProject {
            mismatchText.stringValue = "The basket has \(n) shot\(n == 1 ? "" : "s") for \(title(of: b)). One basket makes one ticket."
            mismatchNew.title = "Start a basket for \(title(of: m))"
            mismatchKeep.title = "Keep in \(title(of: b))"
        }

        if noteView.string != model.shot.note { noteView.string = model.shot.note }
        rebuildMarks()
        canvas.needsDisplay = true
        canvas.updateAccessibility()
        tipLabel.stringValue = model.isCropping ? " Drag the frame or its corners · ↩ applies · ⎋ cancels "
            : model.shot.marks.isEmpty ? " Drag to mark an area · click to mark a spot "
            : " Drag to add a mark · drag a mark to move it · drag a corner to resize "
        rebuildFooter()
    }

    private func rebuildMarks() {
        let marks = model.shot.marks
        marksHeader.stringValue = marks.isEmpty ? "MARKS" : "MARKS · \(marks.count)"
        emptyMarks.isHidden = !marks.isEmpty
        if markNotes.count != marks.count {
            marksStack.clear()
            markNotes = marks.indices.map { i in
                let v = SnapNoteView(placeholder: "What about this area?")
                v.text.setAccessibilityLabel("Note for mark \(i + 1)")
                v.onFocus = { [weak self] in self?.focusedNote(i) }
                v.onChange = { [weak self] t in
                    guard let self, self.model.shot.marks.indices.contains(i) else { return }
                    self.model.shot.marks[i].note = t
                    self.canvas.updateAccessibility()
                }
                v.heightAnchor.constraint(equalToConstant: 44).isActive = true
                let badge = SnapBadge(i + 1)
                let del = ActionButton("", symbol: "xmark", style: .link) { [weak self] in self?.deleteMark(i) }
                del.setAccessibilityLabel("Delete mark \(i + 1)")
                del.toolTip = "Delete mark (⌫)"
                let row = NSStackView(h: [badge, v, del], spacing: 6, align: .top)
                row.identifier = NSUserInterfaceItemIdentifier("mark-\(i)")
                marksStack.addFull(row)
                return v
            }
        }
        for (i, v) in markNotes.enumerated() {
            if v.string != marks[i].note { v.string = marks[i].note }
            let row = v.superview as? NSStackView
            (row?.arrangedSubviews.first as? SnapBadge)?.selected = model.selected == i
            row?.wantsLayer = true
            row?.layer?.cornerRadius = 8
            row?.layer?.backgroundColor = model.selected == i ? Palette.sel.cgColor : nil
        }
    }

    private func rebuildFooter() {
        footer.clear()
        if model.confirming {
            let n = model.shot.marks.count
            let t = NSTextField.text("Discard this shot" + (n > 0 ? " and its \(n) mark\(n == 1 ? "" : "s")?" : "?"), size: 12)
            let really = ActionButton("Discard", style: .danger) { [weak self] in self?.close(discarded: true) }
            let keep = ActionButton("Keep") { [weak self] in self?.model.confirming = false; self?.reload() }
            footer.setViews([t, Spacer(), really, keep], in: .leading)
            makeFirstResponder(really)
            return
        }
        if let c = model.crop {
            sizeLabel.stringValue = "Crop · \(Int(c.w.rounded())) × \(Int(c.h.rounded())) px"
            let full = ActionButton("Full shot") { [weak self] in
                guard let self else { return }
                self.model.crop = self.model.shot.full
                self.reload()
            }
            let cancel = ActionButton("Cancel ⎋") { [weak self] in self?.model.crop = nil; self?.reload() }
            let apply = ActionButton("Apply ↩", style: .primary) { [weak self] in self?.applyCrop() }
            footer.setViews([sizeLabel, Spacer(), full, cancel, apply], in: .leading)
            return
        }
        sizeLabel.stringValue = "\(Int(model.shot.crop.w.rounded())) × \(Int(model.shot.crop.h.rounded())) px"
        let crop = ActionButton("Crop", symbol: "crop") { [weak self] in self?.startCrop() }
        crop.toolTip = "Crop (C)"
        let undo = ActionButton("", symbol: "arrow.uturn.backward") { [weak self] in self?.undo() }
        undo.setAccessibilityLabel("Undo"); undo.toolTip = "Undo (⌘Z)"; undo.isEnabled = model.canUndo
        let redo = ActionButton("", symbol: "arrow.uturn.forward") { [weak self] in self?.redo() }
        redo.setAccessibilityLabel("Redo"); redo.toolTip = "Redo (⇧⌘Z)"; redo.isEnabled = model.canRedo
        let v = ActionButton(voice.isRecording ? "Listening…" : "Voice", symbol: voice.isRecording ? "waveform" : "mic") { [weak self] in self?.toggleVoice() }
        v.toolTip = "Voice note into the focused note (V)"
        v.isHidden = !PROJECTS_CFG.capture.snap.voice
        if voice.isRecording { v.contentTintColor = Palette.bad }
        voiceButton = v
        var views: [NSView] = [crop, undo, redo, v, sizeLabel, Spacer()]
        if model.existing {
            views += [ActionButton("Remove from basket") { [weak self] in self?.removeShot() },
                      ActionButton("Save ⌘↩", style: .primary) { [weak self] in self?.add(again: false) }]
        } else {
            views += [ActionButton("Add and snap again ⇧⌘↩") { [weak self] in self?.add(again: true) },
                      ActionButton("Add to basket ⌘↩", style: .primary) { [weak self] in self?.add(again: false) }]
        }
        footer.setViews(views, in: .leading)
    }

    func toast(_ s: String) {
        toastLabel.stringValue = s
        toastBox.isHidden = false
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { [weak self] _ in self?.toastBox.isHidden = true }
    }

    // MARK: Canvas callbacks

    var canvasModel: SnapEditorModel {
        get { model }
        set { model = newValue }
    }

    func canvasChanged(full: Bool) {
        if full { reload() } else { canvas.needsDisplay = true; rebuildMarks(); if model.isCropping { rebuildFooter() } }
    }

    func markAdded(_ i: Int) {
        reload()
        if markNotes.indices.contains(i) { makeFirstResponder(markNotes[i].text) }
    }

    func editNote(of i: Int) { if markNotes.indices.contains(i) { makeFirstResponder(markNotes[i].text) } }

    private func focusedNote(_ i: Int?) {
        model.lastNote = i
        if model.selected != i { model.selected = i; canvas.needsDisplay = true; rebuildMarks() }
    }

    // MARK: Commands

    func undo() { model.undo(); reload() }
    func redo() { model.redo(); reload() }

    func startCrop() {
        model.startCrop()
        reload()
        makeFirstResponder(canvas)
    }

    func applyCrop() {
        let n = model.applyCrop()
        reload()
        makeFirstResponder(canvas)
        if n > 0 { toast("Removed \(n) mark\(n == 1 ? "" : "s") outside the crop · ⌘Z brings \(n == 1 ? "it" : "them") back") }
    }

    func deleteMark(_ i: Int) {
        model.deleteMark(i)
        reload()
        makeFirstResponder(canvas)
    }

    func toggleVoice() {
        guard PROJECTS_CFG.capture.snap.voice else { return }
        if voice.isRecording { voice.stop(); return }
        let target = model.lastNote
        voice.start(level: { [weak self] l in self?.voiceButton?.title = "Listening " + SnapVoice.bars(l) },
                    done: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text) where !text.isEmpty:
                self.insert(text, into: target)
                self.toast("Transcribed on this Mac · no audio is kept")
            case .success: break
            case .failure(let e): self.toast(e.localizedDescription)
            }
            self.rebuildFooter()
        })
        rebuildFooter()
    }

    private func insert(_ text: String, into i: Int?) {
        func join(_ a: String) -> String { a.isEmpty ? text : a.trimmingCharacters(in: .whitespaces) + " " + text }
        if let i, model.shot.marks.indices.contains(i) { model.shot.marks[i].note = join(model.shot.marks[i].note) } else { model.shot.note = join(model.shot.note) }
        reload()
    }

    func add(again: Bool) {
        if model.isCropping { applyCrop() }
        switch model.addBlock {
        case .mismatch?:
            makeFirstResponder(mismatchNew)
            toast("Pick a basket first")
        case .empty? where !model.existing:
            makeFirstResponder(noteView.text)
            toast("Type a note or mark an area first")
        default:
            if model.shot.project.isEmpty {
                makeFirstResponder(projectField)
                showList()
                toast("Pick a project first")
                return
            }
            let s = model.finish()
            orderOut(nil)
            if model.existing { actions.save(s) } else { actions.add(s, again) }
            close(discarded: false)
        }
    }

    private func removeShot() {
        actions.remove(model.shot)
        close(discarded: false)
    }

    func discard() {
        if model.existing { return close(discarded: false) }
        if model.shot.isBlank || model.confirming { return close(discarded: true) }
        model.confirming = true
        reload()
    }

    private func close(discarded: Bool) {
        voice.stop()
        orderOut(nil)
        actions.closed()
        close()
    }

    func escape() {
        let inField = firstResponder is NSTextView
        switch model.escape(inField: inField) {
        case .leaveField: makeFirstResponder(canvas)
        case .discard: close(discarded: true)
        case .askDiscard, .cancelConfirm, .cancelMismatch, .cancelCrop:
            reload()
            if !model.confirming { makeFirstResponder(canvas) }
        case .clearSelection: reload()
        }
    }

    override func cancelOperation(_ sender: Any?) { escape() }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if e.keyCode == 36 && mods.contains(.command) {
            if model.isCropping { applyCrop() } else { add(again: mods.contains(.shift)) }
            return true
        }
        if !(firstResponder is NSTextView), e.charactersIgnoringModifiers?.lowercased() == "z" {
            if mods == .command { undo(); return true }
            if mods == [.command, .shift] { redo(); return true }
        }
        if mods == .command && e.charactersIgnoringModifiers == "p" && !model.existing {
            makeFirstResponder(projectField)
            projectField.currentEditor()?.selectAll(nil)
            showList()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    // MARK: Project field and list

    private func showList() {
        let q = firstResponder === projectField.currentEditor() && projectField.stringValue != title(of: model.shot.project) ? projectField.stringValue : ""
        listShown = SnapProjectChoice.filter(projects, q)
        list.show(listShown, query: q, basket: model.basketProject, last: PROJECTS_CFG.capture.snap.lastProject)
        list.isHidden = false
    }

    private func hideList() { list.isHidden = true }

    private func pick(_ key: String) {
        hideList()
        if model.pick(key) {
            reload()
            makeFirstResponder(noteView.text)
        } else {
            reload()
            makeFirstResponder(mismatchNew)
        }
    }

    private func resolveMismatch(newBasket: Bool) {
        model.resolveMismatch(newBasket: newBasket)
        reload()
        makeFirstResponder(noteView.text)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { showList() }
    func controlTextDidChange(_ obj: Notification) { showList() }

    func controlTextDidEndEditing(_ obj: Notification) {
        hideList()
        projectField.stringValue = model.shot.project.isEmpty ? "" : title(of: model.shot.project)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): list.move(1); return true
        case #selector(NSResponder.moveUp(_:)): list.move(-1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if !list.isHidden, let c = list.current { pick(c.key); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            hideList()
            makeFirstResponder(noteView.text)
            return true
        default: return false
        }
    }
}

// MARK: Small views

/// The list under the project field. The panel keeps the keyboard focus in the field.
final class SnapProjectList: Box {
    var onPick: ((SnapProjectChoice) -> Void)?
    private let stack = NSStackView(v: [], spacing: 1)
    private var items: [SnapProjectChoice] = []
    private var index = 0

    init() {
        super.init(fill: Palette.raise, border: Palette.line, radius: 8)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Projects")
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 10
    }
    required init?(coder: NSCoder) { fatalError() }

    var current: SnapProjectChoice? { items.indices.contains(index) ? items[index] : nil }

    func show(_ items: [SnapProjectChoice], query: String, basket: String?, last: String?) {
        self.items = Array(items.prefix(8))
        index = 0
        stack.clear()
        if self.items.isEmpty {
            stack.addFull(NSTextField.text("No project matches \"\(query)\"", size: 12, color: Palette.dim))
            return
        }
        for (i, c) in self.items.enumerated() {
            let tag = c.key == basket ? "basket" : c.key == last ? "last" : c.key
            let row = SnapListRow(c, tag: tag) { [weak self] in self?.onPick?(c) }
            row.selected = i == index
            stack.addFull(row)
        }
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        index = max(0, min(items.count - 1, index + d))
        for (i, v) in stack.arrangedSubviews.enumerated() { (v as? SnapListRow)?.selected = i == index }
    }
}

private final class SnapListRow: Box {
    private let onClick: () -> Void
    private let name: NSTextField
    private let tagLabel: NSTextField
    var selected = false {
        didSet {
            fill = selected ? Palette.acc : nil
            name.textColor = selected ? .white : Palette.fg
            tagLabel.textColor = selected ? .white : Palette.dim
            setAccessibilitySelected(selected)
        }
    }

    init(_ c: SnapProjectChoice, tag t: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        name = .text(c.title, size: 12.5)
        tagLabel = .text(t, size: 11, color: Palette.dim, mono: true)
        super.init(fill: nil, border: nil, radius: 6)
        let icon = NSImageView(image: PROJECT_ICONS.image(for: c.key, size: 16))
        let s = NSStackView(h: [icon, name, Spacer(), tagLabel], spacing: 8)
        s.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(c.title), \(t)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// A text view with a border and a placeholder, for the shot note and the mark notes.
final class SnapNoteView: Box, NSTextViewDelegate {
    let text: SnapTextView
    var onFocus: (() -> Void)?
    var onChange: ((String) -> Void)?

    init(placeholder: String) {
        text = SnapTextView()
        super.init(fill: Palette.bg, border: Palette.line, radius: 7)
        text.placeholder = placeholder
        text.font = .systemFont(ofSize: 12.5)
        text.textColor = Palette.fg
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.textContainerInset = NSSize(width: 4, height: 5)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        text.onFocus = { [weak self] on in
            self?.border = on ? Palette.acc : Palette.line
            if on { self?.onFocus?() }
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    var string: String {
        get { text.string }
        set { text.string = newValue; text.needsDisplay = true }
    }

    func textDidChange(_ notification: Notification) { onChange?(text.string) }
}

class SnapTextView: NSTextView {
    var placeholder = ""
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }

    // Tab leaves the field, so the keyboard can reach the next control.
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 12.5), .foregroundColor: Palette.dim]
        (placeholder as NSString).draw(in: bounds.insetBy(dx: textContainerInset.width + 5, dy: textContainerInset.height), withAttributes: attrs)
    }
}

/// The number of a mark in a disc. The number is text, so color is not the only signal.
final class SnapBadge: NSView {
    let n: Int
    var selected = false { didSet { needsDisplay = true } }

    init(_ n: Int) {
        self.n = n
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Mark \(n)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let r = NSRect(x: 0, y: bounds.height - 22, width: 20, height: 20)
        (selected ? Palette.acc : NSColor(cgColor: SnapRenderer.vermillion)!).setFill()
        NSBezierPath(ovalIn: r).fill()
        let s = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        let z = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: r.midX - z.width / 2, y: r.midY - z.height / 2), withAttributes: attrs)
    }
}

/// A 1 px line in the line color.
final class SnapLine: Box {
    init(vertical: Bool) {
        super.init(fill: Palette.line, border: nil, radius: 0)
        (vertical ? widthAnchor : heightAnchor).constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The checker background behind the image.
final class SnapChecker: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let a = NSColor(srgbRed: 0xC9 / 255.0, green: 0xD3 / 255.0, blue: 0xDF / 255.0, alpha: 1)
        let b = NSColor(srgbRed: 0xAE / 255.0, green: 0xBC / 255.0, blue: 0xCD / 255.0, alpha: 1)
        a.setFill()
        bounds.fill()
        b.setFill()
        let z: CGFloat = 7
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = Int(y / z) % 2 == 0 ? 0 : z
            while x < bounds.width { NSRect(x: x, y: y, width: z, height: z).fill(); x += 2 * z }
            y += z
        }
    }
}

final class SnapFlipped: NSView {
    override var isFlipped: Bool { true }
}

import Cocoa
import OverSireCore

// The intake (triage) queue of one project: a list of pending items, and one item with its description.
// Accept or Decline, then the window shows the next item. Back or Esc goes to the list.
final class IntakeWindow: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private static var shared: IntakeWindow?

    static func show(projectKey: String, workItemId: String? = nil) {
        guard let store = (NSApp.delegate as? GHActionsBar)?.projectStore else { return }
        let w = shared ?? IntakeWindow(store: store)
        shared = w
        w.open(projectKey: projectKey, workItemId: workItemId)
        NSApp.activate(ignoringOtherApps: true)
        w.window?.makeKeyAndOrderFront(nil)
    }

    private let store: ProjectStore
    private let markdown: MarkdownView
    private var projectKey = ""
    private var selected: String?          // work item id of the open item
    private var details: [String: IntakeDetail] = [:]
    private var bodies: [String: String] = [:]   // Markdown with image links
    private var mode = MarkdownView.Mode.rendered
    private var busy: String?
    private var error: String?
    private var listOffset: CGFloat = 0
    private var scroll: NSScrollView?
    private var observer: Any?
    private var scrollObserver: Any?
    private var keyMonitor: Any?
    private let filterField = NSSearchField()

    init(store: ProjectStore) {
        self.store = store
        markdown = MarkdownView(width: 640)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 420)
        win.contentView = Flipped(frame: win.contentLayoutRect)
        win.center()
        win.setFrameAutosaveName("OverSireIntakeWindow")
        super.init(window: win)
        win.delegate = self
        markdown.onHeight = { [weak self] _ in self?.rebuild() }
        filterField.placeholderString = "Filter by title or key"
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: 11.5)
        filterField.sendsSearchStringImmediately = true
        filterField.delegate = self
        filterField.toolTip = "Show only items with this text in the title or the key (⌘F)"
        observer = NotificationCenter.default.addObserver(forName: ProjectStore.changed, object: store, queue: .main) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.rebuild()
            self.loadKeys()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var snap: ProjectSnapshot? { store.snapshots[projectKey] }
    private var all: [IntakeItem] { (snap?.intake ?? []).sorted { $0.createdAt > $1.createdAt } }
    // The list after the filter. Prev, next and the count use it too.
    private var items: [IntakeItem] {
        let q = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) || (key(of: $0)?.lowercased().contains(q) ?? false) }
    }

    private func key(of item: IntakeItem) -> String? {
        guard let snap, let n = store.intakeKeys[item.workItemId] ?? details[item.workItemId]?.sequence else { return nil }
        return "\(snap.summary.identifier)-\(n)"
    }

    private func loadKeys() {
        store.loadIntakeKeys(projectKey: projectKey) { [weak self] in self?.rebuild() }
    }

    func controlTextDidChange(_ obj: Notification) { rebuild(top: true) }
    private var current: IntakeItem? { selected.flatMap { id in items.first { $0.workItemId == id } } }

    func open(projectKey: String, workItemId: String?) {
        if projectKey != self.projectKey { listOffset = 0 }
        self.projectKey = projectKey
        error = nil
        select(workItemId)
        loadKeys()
    }

    private func select(_ id: String?) {
        if selected == nil, id != nil { listOffset = scroll?.contentView.bounds.origin.y ?? 0 }
        selected = id
        error = nil
        rebuild(top: id != nil)
        if id == nil, let sv = scroll { scrollTo(listOffset, in: sv) }
        guard let item = current else { return }
        if details[item.workItemId] == nil { load(item) }
    }

    private func load(_ item: IntakeItem) {
        let key = projectKey
        store.intakeDetail(projectKey: key, item: item) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let d):
                self.details[item.workItemId] = d
                self.store.resolveImages(d.body, projectKey: key) { body in
                    self.bodies[item.workItemId] = body
                    if self.selected == item.workItemId { self.rebuild() }
                }
            case .failure(let e):
                self.error = e.message
                self.rebuild()
            }
        }
    }

    private func key(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "f" {
            if selected != nil { select(nil) }
            window?.makeFirstResponder(filterField)
            return nil
        }
        guard !(window?.firstResponder is NSTextView) else { return e }
        switch e.keyCode {
        case 53:
            if selected != nil { select(nil) } else { window?.close() }
            return nil
        case 125 where selected != nil: step(1); return nil
        case 126 where selected != nil: step(-1); return nil
        default: return e
        }
    }

    private func step(_ by: Int) {
        let list = items
        guard let i = list.firstIndex(where: { $0.workItemId == selected }) else { return }
        let j = i + by
        if list.indices.contains(j) { select(list[j].workItemId) }
    }

    func windowDidEndLiveResize(_ notification: Notification) { rebuild() }

    // MARK: Build

    private func rebuild(top: Bool = false) {
        guard let win = window, let content = win.contentView else { return }
        let offset = top ? 0 : (scroll?.contentView.bounds.origin.y ?? 0)
        // The filter field stays, so it keeps the focus while the user types.
        content.subviews.filter { $0 !== filterField }.forEach { $0.removeFromSuperview() }
        filterField.isHidden = true
        let w = content.bounds.width
        let pad: CGFloat = 20
        guard let snap else {
            let l = NSTextField(labelWithString: "This project is not loaded.")
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: pad, y: 20, width: w - pad * 2, height: 20)
            content.addSubview(l)
            return
        }
        win.title = "\(snap.summary.title) · Intake"
        var y: CGFloat = 12
        let list = items

        // Top bar: back and position, or the project name.
        var x = pad
        if let item = current {
            let back = button("‹ Intake (\(list.count))", #selector(backToList), in: content)
            back.frame.origin = NSPoint(x: x - 4, y: y)
            back.toolTip = "Back to the list (Esc)"
            x = back.frame.maxX + 8
            let i = list.firstIndex(of: item) ?? 0
            let up = iconButton("chevron.up", "Previous item (↑)", #selector(prev), in: content)
            up.frame.origin = NSPoint(x: x, y: y)
            up.isEnabled = i > 0
            let down = iconButton("chevron.down", "Next item (↓)", #selector(next), in: content)
            down.frame.origin = NSPoint(x: up.frame.maxX + 4, y: y)
            down.isEnabled = i < list.count - 1
            let pos = NSTextField(labelWithString: "\(i + 1) of \(list.count)")
            pos.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular); pos.textColor = .secondaryLabelColor
            pos.sizeToFit()
            pos.frame.origin = NSPoint(x: down.frame.maxX + 8, y: y + 3)
            content.addSubview(pos)

            let decline = action(busy == "decline" ? "Declining…" : "Decline", symbol: "xmark.circle.fill", tint: C_FAILURE,
                                 #selector(declineItem), in: content)
            decline.frame.origin = NSPoint(x: w - pad - decline.frame.width, y: y - 1)
            let accept = action(busy == "accept" ? "Accepting…" : "Accept", symbol: "checkmark.circle.fill", tint: C_SUCCESS,
                                #selector(acceptItem), in: content)
            decline.frame.origin.x -= 36
            let more = NSPopUpButton(frame: NSRect(x: w - pad - 30, y: y - 1, width: 30, height: 24), pullsDown: true)
            more.bezelStyle = .rounded
            (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            more.menu = moreMenu(item)
            more.toolTip = "More actions"
            more.isEnabled = busy == nil
            content.addSubview(more)
            accept.frame.origin = NSPoint(x: decline.frame.minX - accept.frame.width - 8, y: y - 1)
            accept.isEnabled = busy == nil; decline.isEnabled = busy == nil
            accept.toolTip = "Accept: the item moves to the project's work items"
            decline.toolTip = "Decline: Plane closes the item"
        } else {
            let crumb = NSTextField(labelWithString: "\(snap.summary.ref.workspace) › \(snap.summary.title) › Intake")
            crumb.font = .systemFont(ofSize: 11.5); crumb.textColor = .secondaryLabelColor
            content.addSubview(crumb)
            let open = button("Open in Plane", #selector(openInPlane), in: content)
            open.frame.origin = NSPoint(x: w - pad - open.frame.width, y: y)
            filterField.isHidden = false
            filterField.frame = NSRect(x: open.frame.minX - 8 - 220, y: y, width: 220, height: 22)
            if filterField.superview !== content { content.addSubview(filterField) }
            crumb.frame = NSRect(x: pad, y: y + 3, width: filterField.frame.minX - pad - 8, height: 16)
        }
        y += 34
        if let error {
            let e = NSTextField(labelWithString: error)
            e.font = .systemFont(ofSize: 11); e.textColor = C_FAILURE
            e.lineBreakMode = .byTruncatingTail; e.toolTip = error
            e.frame = NSRect(x: pad, y: y - 6, width: w - pad * 2, height: 16)
            content.addSubview(e)
            y += 14
        }
        let sep = NSBox(frame: NSRect(x: 0, y: y, width: w, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)
        y += 1

        let sv = NSScrollView(frame: NSRect(x: 0, y: y, width: w, height: content.bounds.height - y))
        sv.hasVerticalScroller = true; sv.autohidesScrollers = true; sv.drawsBackground = false
        sv.autoresizingMask = [.width, .height]
        let dw = sv.contentSize.width
        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: dw, height: 10))
        let h: CGFloat
        if let item = current { h = detail(item, snap: snap, w: dw, pad: pad, in: doc) }
        else { h = listView(list, w: dw, pad: pad, in: doc) }
        doc.frame.size.height = max(h, sv.contentSize.height)
        sv.documentView = doc
        content.addSubview(sv)
        scroll = sv
        sv.contentView.postsBoundsChangedNotifications = true
        if let old = scrollObserver { NotificationCenter.default.removeObserver(old) }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: sv.contentView, queue: .main) { [weak doc] _ in
            doc?.subviews.forEach { ($0 as? IntakeRow)?.syncHover() }
        }
        scrollTo(offset, in: sv)
    }

    private func scrollTo(_ y: CGFloat, in sv: NSScrollView) {
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentSize.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func listView(_ list: [IntakeItem], w: CGFloat, pad: CGFloat, in doc: NSView) -> CGFloat {
        var y: CGFloat = 12
        let total = all.count
        let text = list.count == total ? (total == 0 ? "No pending intake items" : "\(total) pending")
            : "\(list.count) of \(total) pending match the filter"
        let head = NSTextField(labelWithString: text)
        head.font = .systemFont(ofSize: 13, weight: .semibold)
        head.textColor = list.isEmpty ? .tertiaryLabelColor : .labelColor
        head.frame = NSRect(x: pad, y: y, width: w - pad * 2, height: 18)
        doc.addSubview(head)
        y += 28
        for item in list {
            let row = IntakeRow(item, key: key(of: item), w: w)
            row.onTap = { [weak self] in self?.select(item.workItemId) }
            row.frame.origin = NSPoint(x: 0, y: y)
            doc.addSubview(row)
            y += row.frame.height
        }
        return y + 12
    }

    private func detail(_ item: IntakeItem, snap: ProjectSnapshot, w: CGFloat, pad: CGFloat, in doc: NSView) -> CGFloat {
        let cw = w - pad * 2
        var y: CGFloat = 16
        let d = details[item.workItemId]
        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let th = textHeight(item.name, font: font, width: cw) + 2
        let title = NSTextField(wrappingLabelWithString: item.name)
        title.font = font
        title.isSelectable = true
        title.frame = NSRect(x: pad, y: y, width: cw, height: th)
        doc.addSubview(title)
        y += th + 10

        var x = pad
        func chip(_ c: NSView) {
            if x + c.frame.width > pad + cw { x = pad; y += 26 }
            c.frame.origin = NSPoint(x: x, y: y)
            doc.addSubview(c)
            x += c.frame.width + 6
        }
        if let k = key(of: item) { chip(Chip(k, menu: false)) }
        chip(Chip("Pending", dot: .systemOrange, menu: false, tint: .systemOrange))
        if let p = item.priority {
            let color = StatusOption.priorities.first { $0.name == p }.map { projectColor($0.color) }
            chip(Chip(p, dot: color, menu: false, tint: color ?? .secondaryLabelColor))
        }
        for l in d?.labels ?? [] { chip(Chip(l, menu: false)) }
        if let a = item.author { chip(Chip("From \(a)", menu: false)) }
        chip(Chip(relativeTime(item.createdAt), menu: false))
        if let s = item.source { chip(Chip(s == "IN_APP" ? "In-app" : s.capitalized, menu: false)) }
        y += 34

        let section = NSTextField(labelWithString: "DESCRIPTION")
        section.font = .systemFont(ofSize: 10, weight: .bold); section.textColor = .secondaryLabelColor
        section.frame = NSRect(x: pad, y: y, width: 200, height: 14)
        doc.addSubview(section)
        let seg = NSSegmentedControl(labels: ["Rendered", "Code"], trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
        seg.controlSize = .small
        seg.selectedSegment = mode.rawValue
        seg.sizeToFit()
        seg.frame.origin = NSPoint(x: pad + cw - seg.frame.width, y: y - 4)
        doc.addSubview(seg)
        let open = button("Open in Plane", #selector(openInPlane), in: doc)
        open.frame.origin = NSPoint(x: seg.frame.minX - open.frame.width - 8, y: y - 3)
        y += 24

        guard let d else {
            let l = NSTextField(labelWithString: error == nil ? "Loading…" : "")
            l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: pad, y: y, width: cw, height: 18)
            doc.addSubview(l)
            return y + 30
        }
        let text = (bodies[item.workItemId] ?? d.body).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let l = NSTextField(labelWithString: "No description")
            l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: pad, y: y, width: cw, height: 18)
            doc.addSubview(l)
            return y + 30
        }
        // Code mode shows the Markdown as Plane keeps it, with asset ids.
        markdown.show(mode == .code ? d.body : text, mode: mode)
        let h = markdown.contentHeight > 0 ? markdown.contentHeight
            : textHeight(text, font: .systemFont(ofSize: 12.5), width: cw) + 8
        markdown.frame = NSRect(x: pad, y: y, width: cw, height: h)
        doc.addSubview(markdown)
        return y + h + 20
    }

    private func button(_ title: String, _ sel: Selector, in view: NSView) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11.5)
        b.sizeToFit()
        b.frame.size = NSSize(width: b.frame.width + 8, height: 22)
        view.addSubview(b)
        return b
    }

    private func iconButton(_ symbol: String, _ tip: String, _ sel: Selector, in view: NSView) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
        b.bezelStyle = .inline
        b.frame.size = NSSize(width: 28, height: 22)
        b.toolTip = tip
        view.addSubview(b)
        return b
    }

    private func action(_ title: String, symbol: String, tint: NSColor, _ sel: Selector, in view: NSView) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: sel)
        b.bezelStyle = .rounded
        b.imagePosition = .imageLeading
        b.contentTintColor = tint
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.sizeToFit()
        b.frame.size.width += 6
        view.addSubview(b)
        return b
    }

    // MARK: Actions

    @objc private func backToList() { select(nil) }
    @objc private func prev() { step(-1) }
    @objc private func next() { step(1) }
    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = MarkdownView.Mode(rawValue: sender.selectedSegment) ?? .rendered
        rebuild()
    }
    @objc private func openInPlane() {
        if let url = URL(string: intakeURL(selected)) { NSWorkspace.shared.open(url) }
    }

    private func intakeURL(_ workItemId: String?) -> String {
        let u = (snap?.summary.url ?? "").replacingOccurrences(of: "/issues/", with: "/intake/")
        return workItemId.map { u + "?currentTab=open&inboxIssueId=\($0)" } ?? u
    }
    @objc private func acceptItem() { triage(.accept) }
    @objc private func declineItem() {
        confirm("Decline", "Plane closes the item. You can find it later in the Closed tab of the intake in Plane.") { [weak self] in
            self?.triage(.decline)
        }
    }

    private func moreMenu(_ item: IntakeItem) -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "", action: nil, keyEquivalent: "")   // the title of a pull-down button
        m.items[0].image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        snooze.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu()
        for (title, days) in [("Until tomorrow", 1), ("For 3 days", 3), ("For 1 week", 7), ("For 2 weeks", 14), ("For 1 month", 30)] {
            let i = NSMenuItem(title: title, action: #selector(snoozeItem(_:)), keyEquivalent: "")
            i.target = self; i.tag = days
            sub.addItem(i)
        }
        snooze.submenu = sub
        m.addItem(snooze)
        let entries: [(String, String, Selector)] = [("Mark as duplicate…", "plus.square.on.square", #selector(duplicateItem)),
                                                     ("Copy work item link", "doc.on.doc", #selector(copyLink))]
        for (title, symbol, sel) in entries {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            m.addItem(i)
        }
        m.addItem(.separator())
        let del = NSMenuItem(title: "Delete", action: #selector(deleteItem), keyEquivalent: "")
        del.target = self
        del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        del.attributedTitle = NSAttributedString(string: "Delete", attributes: [.foregroundColor: C_FAILURE, .font: NSFont.menuFont(ofSize: 0)])
        m.addItem(del)
        return m
    }

    // Snoozed items leave the pending list. Plane shows them again at the date.
    @objc private func snoozeItem(_ sender: NSMenuItem) {
        var d = Calendar.current.date(byAdding: .day, value: sender.tag, to: Date()) ?? Date()
        d = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
        triage(.snooze(until: d))
    }

    @objc private func duplicateItem() {
        guard let item = current, let snap, let win = window else { return }
        let a = NSAlert()
        a.messageText = "Mark “\(item.name)” as a duplicate"
        a.informativeText = "Select or type the key of the work item that this item duplicates."
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        box.completes = true
        box.numberOfVisibleItems = 12
        box.placeholderString = "\(snap.summary.identifier)-12"
        box.addItems(withObjectValues: snap.items.sorted { $0.key.count == $1.key.count ? $0.key > $1.key : $0.key.count > $1.key.count }
            .map { "\($0.key)  \($0.title)" })
        a.accessoryView = box
        a.addButton(withTitle: "Mark as duplicate")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = box
        a.beginSheetModal(for: win) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            let k = box.stringValue.split(separator: " ").first.map { String($0).uppercased() } ?? ""
            guard let target = snap.items.first(where: { $0.key.uppercased() == k }) else {
                self.error = k.isEmpty ? "Type the key of a work item" : "No work item \(k) in \(snap.summary.title)"
                self.rebuild()
                return
            }
            self.triage(.duplicate(of: target.id))
        }
    }

    // The browse link needs the key. Without it, the link opens the item in the intake.
    @objc private func copyLink() {
        guard let item = current, let snap else { return }
        let base = snap.summary.url.components(separatedBy: "/projects/")[0]
        let u = key(of: item).map { "\(base)/browse/\($0)/" } ?? intakeURL(item.workItemId)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u, forType: .string)
    }

    @objc private func deleteItem() {
        confirm("Delete", "Plane deletes the item and its work item. You cannot undo this.") { [weak self] in self?.triage(.delete) }
    }

    private func confirm(_ verb: String, _ info: String, then: @escaping () -> Void) {
        guard let item = current, let win = window else { return }
        let a = NSAlert()
        a.messageText = "\(verb) “\(item.name)”?"
        a.informativeText = info
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "Cancel")
        if verb == "Delete" { a.buttons[0].hasDestructiveAction = true }
        a.beginSheetModal(for: win) { r in if r == .alertFirstButtonReturn { then() } }
    }

    // After the change, the window shows the next item, or the list when no item is left.
    private func triage(_ action: IntakeAction) {
        guard let item = current, busy == nil else { return }
        let list = items
        let i = list.firstIndex(of: item) ?? 0
        let after = list.indices.contains(i + 1) ? list[i + 1] : (i > 0 ? list[i - 1] : nil)
        switch action {
        case .accept: busy = "accept"
        case .decline: busy = "decline"
        default: busy = "other"
        }
        rebuild()
        store.triage(projectKey: projectKey, item: item, action: action) { [weak self] ok in
            guard let self else { return }
            self.busy = nil
            if ok {
                self.select(after?.workItemId)
            } else {
                self.error = self.store.lastError ?? "Plane did not change the item"
                self.rebuild()
            }
        }
    }
}

// One pending intake item in the list.
private final class IntakeRow: Flipped {
    var onTap: (() -> Void)?
    private var hovered = false

    init(_ item: IntakeItem, key: String?, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 58))
        wantsLayer = true
        let title = NSTextField(labelWithString: item.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 20, y: 9, width: w - 40, height: 18)
        title.toolTip = item.name
        addSubview(title)
        var x: CGFloat = 20
        if let key {
            let b = Badge(key)
            b.frame.origin = NSPoint(x: x, y: 31)
            addSubview(b)
            x += b.frame.width + 6
        }
        if let p = item.priority {
            let color = StatusOption.priorities.first { $0.name == p }.map { projectColor($0.color) }
            let b = Badge(p, tint: color)
            b.frame.origin = NSPoint(x: x, y: 31)
            addSubview(b)
            x += b.frame.width + 8
        }
        let meta = [item.author.map { "From \($0)" }, relativeTime(item.createdAt),
                    item.source.map { $0 == "IN_APP" ? "In-app" : $0.capitalized }].compactMap { $0 }.joined(separator: " · ")
        let m = NSTextField(labelWithString: meta)
        m.font = .systemFont(ofSize: 11); m.textColor = .secondaryLabelColor
        m.frame = NSRect(x: x, y: 33, width: w - x - 20, height: 15)
        addSubview(m)
        let line = NSBox(frame: NSRect(x: 20, y: 57, width: w - 40, height: 1))
        line.boxType = .separator
        addSubview(line)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    func syncHover() {
        guard let w = window else { return }
        let inside = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        if inside != hovered { hover(inside) }
    }
    private func hover(_ on: Bool) {
        hovered = on
        layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

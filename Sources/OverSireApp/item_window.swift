import Cocoa
import OverSireCore

// Draft text of an item in edit mode. The window keeps it, so a rebuild does not lose it.
struct ItemEdit {
    var title: String
    var body: String
    var saving = false
    var busy: String?          // "tidy" or "title" while AI runs
}

// A rounded button with a value, for example "● In Progress ▾". A click opens a menu.
final class Chip: NSButton {
    init(_ text: String, dot: NSColor? = nil, menu: Bool = true, tint: NSColor = .secondaryLabelColor) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = tint.withAlphaComponent(0.13).cgColor
        let s = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        if let dot { s.append(NSAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: dot])) }
        s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        if menu { s.append(NSAttributedString(string: "  ▾", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])) }
        attributedTitle = s
        frame.size = NSSize(width: ceil(s.size().width) + 20, height: 22)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// One window shows one work item: facts as chips, then Overview, Sub-items and Activity tabs.
// A sub-item opens in the same window. Back goes to the item before it.
final class ItemWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    enum Tab: Int { case overview, subItems, activity }

    private static var shared: ItemWindow?
    private static let descriptionCap: CGFloat = 320

    static var isOpen: Bool { shared?.window?.isVisible == true }

    static func show(_ itemId: String) {
        guard let store = (NSApp.delegate as? GHActionsBar)?.projectStore else { return }
        let w = shared ?? ItemWindow(store: store)
        shared = w
        w.open(itemId, push: false)
        NSApp.activate(ignoringOtherApps: true)
        w.window?.makeKeyAndOrderFront(nil)
    }

    private let store: ProjectStore
    private let markdown: MarkdownView
    private var history: [String] = []
    private var tab = Tab.overview
    private var mode = MarkdownView.Mode.rendered
    private var fullDescription = false
    private var edit: ItemEdit?
    private var saving: String?          // the chip that waits for Plane
    private var error: String?
    private var entries: [ActivityEntry]?
    private var options: ItemOptions?
    private var scroll: NSScrollView?
    private var commentField: NSTextField?
    private var titleEdit: NSTextField?
    private var bodyEdit: NSTextView?
    private var pending = false          // a store change came while the user typed
    private var images: (source: String, text: String)?   // the description with signed image links
    private var keyMonitor: Any?
    private var observer: Any?
    private var scrollObserver: Any?
    private var agentObserver: Any?
    private var agentTail: (key: String, lines: [String], at: Date)?
    private var agents: AgentIndex? { (NSApp.delegate as? GHActionsBar)?.agentIndex.ready }

    init(store: ProjectStore) {
        self.store = store
        markdown = MarkdownView(width: 600)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 420)
        win.contentView = Flipped(frame: win.contentLayoutRect)
        win.center()
        win.setFrameAutosaveName("OverSireItemWindow")
        super.init(window: win)
        win.delegate = self
        markdown.onHeight = { [weak self] _ in self?.rebuild() }
        observer = NotificationCenter.default.addObserver(forName: ProjectStore.changed, object: store, queue: .main) { [weak self] _ in
            self?.storeChanged()
        }
        if let a = (NSApp.delegate as? GHActionsBar)?.agentIndex {
            agentObserver = NotificationCenter.default.addObserver(forName: AgentIndex.changed, object: a, queue: .main) { [weak self] _ in
                self?.storeChanged()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var itemId: String? { history.last }

    func open(_ id: String, push: Bool) {
        history = push ? history + [id] : [id]
        reset()
    }

    private func back() {
        guard history.count > 1 else { window?.close(); return }
        history.removeLast()
        reset()
    }

    private func reset() {
        edit = nil
        error = nil
        entries = nil
        fullDescription = false
        if tab == .subItems, let id = itemId, store.item(id).map({ $0.snap.progress(of: id).total == 0 }) ?? true { tab = .overview }
        rebuild(top: true)
        loadTimeline()
        options = nil
        if let id = itemId, let key = store.item(id)?.key {
            store.options(projectKey: key) { [weak self] o in if self?.itemId == id { self?.options = o } }
        }
    }

    private func loadTimeline() {
        guard let id = itemId else { return }
        store.timeline(itemId: id) { [weak self] list in
            guard let self, self.itemId == id else { return }
            self.entries = list
            self.rebuild()
        }
    }

    // A store change rebuilds the window. While the user types, it waits for the end of the edit.
    private func storeChanged() {
        guard window?.isVisible == true else { return }
        if edit != nil || window?.firstResponder is NSTextView { pending = true; return }
        if let id = itemId, let found = store.item(id), entries != nil {
            // A newer item has a newer timeline. The store caches it by the activity time.
            store.timeline(itemId: id) { [weak self] list in
                guard let self, self.itemId == found.item.id else { return }
                self.entries = list
            }
        }
        rebuild()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if pending, edit == nil { pending = false; DispatchQueue.main.async { self.rebuild() } }
    }

    private func key(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if edit != nil {
            if e.keyCode == 53 { cancelEdit(); return nil }
            if e.keyCode == 36 && mods.contains(.command) { saveEdit(); return nil }
            return e
        }
        if e.keyCode == 53, !(window?.firstResponder is NSTextView) { back(); return nil }
        return e
    }

    func windowDidEndLiveResize(_ notification: Notification) { rebuild() }
    func windowDidResize(_ notification: Notification) { if window?.inLiveResize == false { rebuild() } }

    // MARK: Build

    private func rebuild(top: Bool = false) {
        guard let win = window, let content = win.contentView else { return }
        guard let id = itemId, let found = store.item(id) else {
            content.subviews.forEach { $0.removeFromSuperview() }
            let l = NSTextField(labelWithString: "This item is not loaded. It may be archived or in a project that OverSire does not track.")
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 20, y: 20, width: content.bounds.width - 40, height: 40)
            content.addSubview(l)
            return
        }
        let (snap, item) = (found.snap, found.item)
        let offset = top ? 0 : (scroll?.contentView.bounds.origin.y ?? 0)
        let draftComment = commentField?.stringValue ?? ""
        content.subviews.forEach { $0.removeFromSuperview() }
        win.title = "\(item.key) · \(item.title)"
        let w = content.bounds.width
        let pad: CGFloat = 20
        var y: CGFloat = 12

        // Back, breadcrumb, links.
        var x = pad
        if history.count > 1, let prev = store.item(history[history.count - 2])?.item {
            let b = button("‹ " + prev.key, #selector(goBack), in: content)
            b.frame.origin = NSPoint(x: x - 4, y: y)
            b.toolTip = "Back to \(prev.title) (Esc)"
            x = b.frame.maxX + 8
        }
        let crumb = NSTextField(labelWithString: "\(snap.summary.ref.workspace) › \(snap.summary.title) › \(item.key)")
        crumb.font = .systemFont(ofSize: 11.5); crumb.textColor = .secondaryLabelColor
        crumb.lineBreakMode = .byTruncatingTail
        crumb.frame = NSRect(x: x, y: y + 3, width: w - x - 230, height: 16)
        content.addSubview(crumb)
        let open = button("Open in Plane", #selector(openInPlane), in: content)
        open.frame.origin = NSPoint(x: w - pad - open.frame.width, y: y)
        let copy = button("Copy ▾", #selector(copyMenu(_:)), in: content)
        copy.frame.origin = NSPoint(x: open.frame.minX - copy.frame.width - 6, y: y)
        y += 32

        let font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        let th = textHeight(item.title, font: font, width: w - pad * 2) + 2
        let title = NSTextField(wrappingLabelWithString: item.title)
        title.font = font
        title.isSelectable = true
        title.frame = NSRect(x: pad, y: y, width: w - pad * 2, height: th)
        content.addSubview(title)
        y += th + 10

        y = chips(snap: snap, item: item, y: y, w: w, pad: pad, in: content)

        // Tabs.
        let progress = snap.progress(of: item.id)
        let comments = (entries ?? []).filter { if case .comments = $0.change { return true }; return false }.count
        let bar = TabBar(selected: tab.rawValue, w: w, pad: pad, tabs: [
            .init(title: "Overview", symbol: "doc.text"),
            .init(title: "Sub-items", symbol: "list.bullet.indent", ring: progress.total > 0 ? progress : nil),
            .init(title: "Activity", symbol: "bubble.left.and.bubble.right", count: comments > 0 ? comments : nil),
        ])
        bar.onSelect = { [weak self] i in
            self?.tab = Tab(rawValue: i) ?? .overview
            self?.rebuild(top: true)
        }
        bar.frame.origin = NSPoint(x: 0, y: y)
        content.addSubview(bar)
        y += bar.frame.height
        let sep = NSBox(frame: NSRect(x: 0, y: y, width: w, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)
        y += 1

        let sv = NSScrollView(frame: NSRect(x: 0, y: y, width: w, height: content.bounds.height - y))
        sv.hasVerticalScroller = true; sv.autohidesScrollers = true; sv.drawsBackground = false
        sv.autoresizingMask = [.width, .height]
        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: sv.contentSize.width, height: 10))
        let dw = sv.contentSize.width
        let h: CGFloat
        switch tab {
        case .overview: h = overview(snap: snap, item: item, w: dw, pad: pad, in: doc)
        case .subItems: h = subItems(snap: snap, item: item, w: dw, pad: pad, in: doc)
        case .activity: h = activity(item: item, w: dw, pad: pad, draft: draftComment, in: doc)
        }
        doc.frame.size.height = max(h, sv.contentSize.height)
        sv.documentView = doc
        content.addSubview(sv)
        scroll = sv
        sv.contentView.postsBoundsChangedNotifications = true
        if let old = scrollObserver { NotificationCenter.default.removeObserver(old) }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: sv.contentView, queue: .main) { [weak doc] _ in
            doc?.subviews.forEach { ($0 as? ProjectItemRow)?.syncHover() }
        }
        sv.contentView.scroll(to: NSPoint(x: 0, y: min(offset, max(0, doc.frame.height - sv.contentSize.height))))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // Status, priority, labels and assignees open a menu. Dates are facts only.
    private func chips(snap: ProjectSnapshot, item: Item, y: CGFloat, w: CGFloat, pad: CGFloat, in view: NSView) -> CGFloat {
        var x = pad, y = y
        func place(_ c: NSButton) {
            if x + c.frame.width > w - pad { x = pad; y += 28 }
            c.frame.origin = NSPoint(x: x, y: y)
            view.addSubview(c)
            x += c.frame.width + 8
        }
        func chip(_ field: String, _ text: String, dot: NSColor? = nil, tip: String) {
            let c = Chip(saving == field ? "Saving…" : text, dot: dot, tint: dot ?? .secondaryLabelColor)
            c.identifier = NSUserInterfaceItemIdentifier(field)
            c.target = self; c.action = #selector(chipMenu(_:))
            c.isEnabled = saving == nil
            c.toolTip = tip
            place(c)
        }
        let opt = snap.option(item.statusOptionId)
        chip("state", opt?.name ?? "No status", dot: projectColor(opt?.color ?? "GRAY"), tip: "Change the status")
        let pri = item.fields["Priority"]
        chip("priority", pri ?? "No priority",
             dot: pri.flatMap { p in StatusOption.priorities.first { $0.name == p } }.map { projectColor($0.color) },
             tip: "Change the priority")
        chip("labels", item.labels.isEmpty ? "No labels" : item.labels.joined(separator: ", "), tip: "Add or remove labels")
        chip("assignees", item.assignees.isEmpty ? "No assignee" : item.assignees.joined(separator: ", "),
             tip: "Add or remove assignees")
        for k in ["Start", "Due"] {
            if let v = item.fields[k] { place(Chip("\(k) \(v)", menu: false)) }
        }
        let mine = snap.me.map { m in item.assignees.contains { $0.caseInsensitiveCompare(m) == .orderedSame } } ?? false
        if !(opt?.category == .progress && mine) {
            let s = Chip("▶ Start", menu: false, tint: C_SUCCESS)
            s.target = self; s.action = #selector(start)
            s.isEnabled = saving == nil
            s.toolTip = "Set In progress and assign me"
            place(s)
        }
        if let agents {
            if let a = agents.agent(item.key) {
                let tint: NSColor = a.phase == .waiting ? .systemOrange : a.phase == .done ? .systemGreen
                    : a.phase == .failed ? C_FAILURE : AgentPill.orca
                let c = Chip("◉ " + a.label(), menu: false, tint: tint)
                c.target = self; c.action = #selector(agentChip(_:))
                c.toolTip = a.phase == .failed ? (a.message ?? "") : "Open the terminal in Orca"
                place(c)
            } else {
                let c = Chip("▶ Start in Orca", menu: false, tint: AgentPill.orca)
                c.target = self; c.action = #selector(startOrca(_:))
                c.toolTip = "Open a Claude session for \(item.key) in Orca and send the prompt"
                place(c)
            }
        }
        if let error {
            y += 28
            let e = NSTextField(labelWithString: error)
            e.font = .systemFont(ofSize: 11); e.textColor = C_FAILURE
            e.lineBreakMode = .byTruncatingTail; e.toolTip = error
            e.frame = NSRect(x: pad, y: y + 2, width: w - pad * 2, height: 16)
            view.addSubview(e)
        }
        return y + 34
    }

    private func overview(snap: ProjectSnapshot, item: Item, w: CGFloat, pad: CGFloat, in doc: NSView) -> CGFloat {
        let cw = w - pad * 2
        var y: CGFloat = 14
        if let edit {
            let tf = NSTextField(frame: NSRect(x: pad, y: y, width: cw, height: 26))
            tf.stringValue = edit.title
            tf.font = .systemFont(ofSize: 14, weight: .semibold)
            tf.placeholderString = "Title"
            tf.delegate = self
            tf.isEnabled = !edit.saving
            doc.addSubview(tf); titleEdit = tf
            y += 34
            let bodyH = max(260, (scroll?.contentSize.height ?? 500) - 110)
            let sv = NSScrollView(frame: NSRect(x: pad, y: y, width: cw, height: bodyH))
            sv.hasVerticalScroller = true; sv.autohidesScrollers = true; sv.borderType = .bezelBorder
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: sv.contentSize.width, height: bodyH))
            tv.string = edit.body
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.isRichText = false; tv.allowsUndo = true
            tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
            tv.textContainerInset = NSSize(width: 6, height: 8)
            tv.isVerticallyResizable = true; tv.autoresizingMask = [.width]
            tv.textContainer?.widthTracksTextView = true
            tv.isEditable = !edit.saving
            tv.delegate = self
            sv.documentView = tv
            doc.addSubview(sv); bodyEdit = tv
            y += bodyH + 8
            var x = pad
            if let ai = AIClient.current {
                if ai.cfg.tidy {
                    let t = button(edit.busy == "tidy" ? "✦ Tidying…" : "✦ Tidy", #selector(aiTidy), in: doc)
                    t.frame.origin = NSPoint(x: x, y: y)
                    t.isEnabled = edit.busy == nil && !edit.saving
                    x = t.frame.maxX + 6
                }
                if ai.cfg.titleAndFields {
                    let t = button(edit.busy == "title" ? "✦ Writing…" : "✦ Suggest title", #selector(aiTitle), in: doc)
                    t.frame.origin = NSPoint(x: x, y: y)
                    t.isEnabled = edit.busy == nil && !edit.saving
                }
            }
            let save = button(edit.saving ? "Saving…" : "Save  ⌘↩", #selector(saveEdit), in: doc)
            save.frame.origin = NSPoint(x: pad + cw - save.frame.width, y: y)
            save.isEnabled = !edit.saving
            let cancel = button("Cancel", #selector(cancelEdit), in: doc)
            cancel.frame.origin = NSPoint(x: save.frame.minX - cancel.frame.width - 6, y: y)
            DispatchQueue.main.async { [weak self] in
                if self?.window?.firstResponder === self?.window { self?.window?.makeFirstResponder(tf) }
            }
            return y + 40
        }

        y = agentCard(item: item, y: y, w: w, pad: pad, in: doc)
        section("DESCRIPTION", x: pad, y: y, in: doc)
        let text = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seg = NSSegmentedControl(labels: ["Rendered", "Code"], trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
        seg.controlSize = .small
        seg.selectedSegment = mode.rawValue
        seg.sizeToFit()
        seg.frame.origin = NSPoint(x: pad + cw - seg.frame.width, y: y - 4)
        seg.isEnabled = !text.isEmpty
        seg.toolTip = "Show the description as rendered Markdown or as Markdown source"
        doc.addSubview(seg)
        let pencil = button("Edit", #selector(beginEdit), in: doc)
        pencil.frame.origin = NSPoint(x: seg.frame.minX - pencil.frame.width - 8, y: y - 3)
        pencil.toolTip = "Edit the title and description"
        y += 24
        if text.isEmpty {
            let l = NSTextField(labelWithString: "No description. Click Edit to add one.")
            l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: pad, y: y, width: cw, height: 18)
            doc.addSubview(l)
            y += 30
        } else {
            var shown = text
            if mode == .rendered, let images, images.source == text { shown = images.text }
            else if mode == .rendered, text.contains("]("), let key = store.item(item.id)?.key {
                store.resolveImages(text, projectKey: key) { [weak self] out in
                    guard let self, out != text else { return }
                    self.images = (text, out)
                    if self.edit == nil { self.rebuild() }
                }
            }
            markdown.show(shown, mode: mode)
            let full = markdown.contentHeight > 0 ? markdown.contentHeight
                : textHeight(text, font: .systemFont(ofSize: 12.5), width: cw) + 8
            let cap = max(ItemWindow.descriptionCap, (window?.contentView?.bounds.height ?? 0) * 0.45)
            let capped = !fullDescription && full > cap + 60
            let h = capped ? cap : full
            markdown.frame = NSRect(x: pad, y: y, width: cw, height: h)
            doc.addSubview(markdown)
            y += h
            if capped {
                let fade = Fade(frame: NSRect(x: pad, y: y - 50, width: cw, height: 50))
                doc.addSubview(fade)
            }
            if capped || fullDescription {
                let more = button(capped ? "Show more ▾" : "Show less ▴", #selector(toggleDescription), in: doc)
                more.frame.origin = NSPoint(x: pad + (cw - more.frame.width) / 2, y: y + 6)
                y += 34
            }
            y += 14
        }

        section("DETAILS", x: pad, y: y, in: doc)
        y += 20
        func line(_ name: String, _ value: String) {
            let n = NSTextField(labelWithString: name)
            n.font = .systemFont(ofSize: 11.5); n.textColor = .secondaryLabelColor
            n.frame = NSRect(x: pad, y: y, width: 100, height: 16)
            doc.addSubview(n)
            let v = NSTextField(labelWithString: value)
            v.font = .systemFont(ofSize: 12); v.lineBreakMode = .byTruncatingTail
            v.isSelectable = true
            v.frame = NSRect(x: pad + 104, y: y, width: cw - 104, height: 16)
            v.toolTip = value
            doc.addSubview(v)
            y += 20
        }
        line("Key", item.key)
        if let parent = item.parentId.flatMap({ p in snap.items.first { $0.id == p } }) {
            let n = NSTextField(labelWithString: "Parent")
            n.font = .systemFont(ofSize: 11.5); n.textColor = .secondaryLabelColor
            n.frame = NSRect(x: pad, y: y, width: 100, height: 16)
            doc.addSubview(n)
            let b = button("\(parent.key) · \(parent.title)", #selector(openParent), in: doc)
            b.frame = NSRect(x: pad + 100, y: y - 3, width: min(b.frame.width, cw - 100), height: 22)
            y += 22
        }
        if let a = item.author { line("Created by", a) }
        line("Updated", relativeTime(item.updatedAt) + (item.updatedBy.map { " by \($0)" } ?? ""))
        y += 12
        let agent = button("Copy for agent", #selector(copyAgent), in: doc)
        agent.frame.origin = NSPoint(x: pad - 4, y: y)
        agent.toolTip = "Title, description and comments as Markdown"
        let read = button("Mark as read", #selector(markRead), in: doc)
        read.frame.origin = NSPoint(x: agent.frame.maxX + 6, y: y)
        return y + 40
    }

    private func subItems(snap: ProjectSnapshot, item: Item, w: CGFloat, pad: CGFloat, in doc: NSView) -> CGFloat {
        var y: CGFloat = 10
        let kids = snap.children(of: item.id)
        let progress = snap.progress(of: item.id)
        if progress.total == 0 {
            let l = NSTextField(labelWithString: "No sub-items")
            l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: pad, y: y + 6, width: w - pad * 2, height: 18)
            doc.addSubview(l)
            return y + 40
        }
        let ring = ProgressRing(done: progress.done, total: progress.total)
        ring.frame.origin = NSPoint(x: pad, y: y + 2)
        doc.addSubview(ring)
        let sum = NSTextField(labelWithString: "\(progress.done) of \(progress.total) done · \(progress.total - progress.done) open")
        sum.font = .systemFont(ofSize: 12, weight: .medium)
        sum.frame = NSRect(x: pad + 20, y: y, width: w - pad * 2 - 20, height: 18)
        doc.addSubview(sum)
        y += 28
        for kid in kids {
            let p = snap.progress(of: kid.id)
            let agent = agents?.agent(kid.key)
            let row = ProjectItemRow(item: kid, snap: snap, unread: store.isUnread(itemId: kid.id), last: nil, w: w,
                                     expanded: false, progress: p.total > 0 ? p : nil, agent: agent,
                                     canStart: agents != nil && agent == nil && snap.option(kid.statusOptionId)?.category ?? .todo == .todo)
            row.onToggle = { [weak self] in self?.open(kid.id, push: true) }
            if let agents {
                row.onStart = { [weak agents] anchor in agents?.start(kid, snap: snap, anchor: anchor) }
                row.onPill = { [weak agents] anchor in agents?.pillClicked(kid, snap: snap, anchor: anchor) }
            }
            row.onAgent = { [weak self] in self?.store.copyForAgent(kid.id) }
            row.frame.origin = NSPoint(x: 0, y: y)
            doc.addSubview(row)
            y += row.frame.height
        }
        if progress.total > kids.count {
            let n = progress.total - kids.count
            let note = SubItemNote("\(n) more sub-item\(n == 1 ? "" : "s") in Plane", url: item.url, w: w)
            note.frame.origin = NSPoint(x: 0, y: y + 4)
            doc.addSubview(note)
            y += 30
        }
        return y + 10
    }

    // Comments and changes, newest first. The comment box is on top.
    private func activity(item: Item, w: CGFloat, pad: CGFloat, draft: String, in doc: NSView) -> CGFloat {
        let cw = w - pad * 2
        var y: CGFloat = 14
        let cf = NSTextField(frame: NSRect(x: pad, y: y, width: cw - 90, height: 24))
        cf.placeholderString = "Leave a comment… (Markdown)"
        cf.font = .systemFont(ofSize: 12)
        cf.stringValue = draft
        cf.delegate = self
        doc.addSubview(cf); commentField = cf
        let send = button("Comment", #selector(sendComment), in: doc)
        send.frame = NSRect(x: pad + cw - 82, y: y + 1, width: 82, height: 22)
        y += 38
        guard let entries else {
            let l = NSTextField(labelWithString: "Loading activity…")
            l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: pad, y: y, width: cw, height: 18)
            doc.addSubview(l)
            return y + 30
        }
        if entries.isEmpty {
            let l = NSTextField(labelWithString: "No activity")
            l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: pad, y: y, width: cw, height: 18)
            doc.addSubview(l)
            return y + 30
        }
        for e in entries.sorted(by: { $0.at > $1.at }) {
            if case .comments(_, let c) = e.change {
                let card = Flipped(frame: .zero)
                card.wantsLayer = true
                card.layer?.cornerRadius = 8
                card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
                let head = NSTextField(labelWithString: (c.author ?? "Someone") + " · " + relativeTime(c.createdAt))
                head.font = .systemFont(ofSize: 11.5, weight: .semibold); head.textColor = .secondaryLabelColor
                head.frame = NSRect(x: 12, y: 8, width: cw - 24, height: 16)
                card.addSubview(head)
                let body = NSTextField(labelWithAttributedString: ItemWindow.inline((c.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                                                                    font: .systemFont(ofSize: 12.5)))
                body.isSelectable = true
                body.allowsEditingTextAttributes = true
                body.maximumNumberOfLines = 0
                body.lineBreakMode = .byWordWrapping
                let bh = max(16, ceil(body.attributedStringValue.boundingRect(
                    with: NSSize(width: cw - 24, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4)
                body.frame = NSRect(x: 12, y: 28, width: cw - 24, height: bh)
                card.addSubview(body)
                card.frame = NSRect(x: pad, y: y, width: cw, height: bh + 38)
                doc.addSubview(card)
                y += card.frame.height + 10
            } else {
                var line = e
                line.unread = false
                let row = ActivityLine(line, w: cw, hoverCard: false)
                row.frame.origin = NSPoint(x: pad - 8, y: y)
                doc.addSubview(row)
                y += row.frame.height + 2
            }
        }
        return y + 14
    }

    // Comments: inline Markdown (bold, code, links) and bullets.
    static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop { $0 == " " }
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return String(line) }
            return String(line.prefix(line.count - t.count)) + "• " + t.dropFirst(2)
        }.joined(separator: "\n")
        guard let a = try? NSMutableAttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        let all = NSRange(location: 0, length: a.length)
        a.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        a.addAttribute(.font, value: font, range: all)
        a.enumerateAttribute(.inlinePresentationIntent, in: all) { v, r, _ in
            guard let raw = v as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                a.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: r)
            } else if intent.contains(.stronglyEmphasized) {
                a.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), range: r)
            } else if intent.contains(.emphasized) {
                a.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: r)
            }
        }
        return a
    }

    private func section(_ title: String, x: CGFloat, y: CGFloat, in view: NSView) {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 10, weight: .bold); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: x, y: y, width: 200, height: 14)
        view.addSubview(l)
    }

    private func button(_ title: String, _ action: Selector, in view: NSView) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11.5)
        b.sizeToFit()
        b.frame.size = NSSize(width: b.frame.width + 8, height: 22)
        view.addSubview(b)
        return b
    }

    // MARK: Chip menus

    @objc private func chipMenu(_ sender: NSButton) {
        guard let field = sender.identifier?.rawValue, let id = itemId, let found = store.item(id) else { return }
        let (snap, item) = (found.snap, found.item)
        let menu = NSMenu()
        func add(_ title: String, value: String, on: Bool, color: String? = nil) {
            let mi = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = [field, value]
            mi.state = on ? .on : .off
            if let color { mi.image = dot(projectColor(color)) }
            menu.addItem(mi)
        }
        switch field {
        case "state":
            for o in snap.statusOptions { add(o.name, value: o.id, on: o.id == item.statusOptionId, color: o.color) }
        case "priority":
            for p in StatusOption.priorities {
                add(p.name, value: p.id, on: (item.fields["Priority"] ?? "None") == p.name, color: p.color)
            }
        default:
            guard let options else {
                let mi = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
                store.options(projectKey: found.key) { [weak self] o in self?.options = o }
                break
            }
            let list = field == "labels" ? options.labels : options.members
            let current = field == "labels" ? item.labels : item.assignees
            if list.isEmpty { menu.addItem(withTitle: field == "labels" ? "No labels in this project" : "No members", action: nil, keyEquivalent: "") }
            for o in list {
                add(o.name, value: o.id, on: current.contains { $0.caseInsensitiveCompare(o.name) == .orderedSame },
                    color: field == "labels" ? o.color : nil)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, let id = itemId,
              let found = store.item(id) else { return }
        let (field, value) = (pair[0], pair[1])
        let patch: ItemPatch
        switch field {
        case "labels", "assignees":
            // The item keeps names. The menu options map them to ids.
            let list = (field == "labels" ? options?.labels : options?.members) ?? []
            let names = field == "labels" ? found.item.labels : found.item.assignees
            var ids = list.filter { o in names.contains { $0.caseInsensitiveCompare(o.name) == .orderedSame } }.map(\.id)
            if let i = ids.firstIndex(of: value) { ids.remove(at: i) } else { ids.append(value) }
            patch = field == "labels" ? ItemPatch(labels: ids) : ItemPatch(assignees: ids)
        case "state": patch = ItemPatch(status: value)
        case "priority": patch = ItemPatch(priority: value)
        default: return
        }
        saving = field
        error = nil
        rebuild()
        store.update(itemId: id, patch, failure: "Could not change the \(field == "state" ? "status" : field)") { [weak self] ok in
            guard let self else { return }
            self.saving = nil
            self.error = ok ? nil : self.store.lastError
            self.rebuild()
        }
    }

    @objc private func start() {
        guard let id = itemId else { return }
        saving = "state"
        rebuild()
        store.start(itemId: id) { [weak self] ok in
            guard let self else { return }
            self.saving = nil
            self.error = ok ? nil : (self.store.lastError ?? "Could not start the item")
            self.rebuild()
        }
    }

    // The live agent of the item: state, prompt, buttons and the last lines of its terminal.
    private func agentCard(item: Item, y: CGFloat, w: CGFloat, pad: CGFloat, in doc: NSView) -> CGFloat {
        guard let agents, let a = agents.agent(item.key), a.phase != .failed else { return y }
        let cw = w - pad * 2
        let box = NSView(frame: NSRect(x: pad, y: y, width: cw, height: 52))
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.backgroundColor = AgentPill.orca.withAlphaComponent(0.1).cgColor
        doc.addSubview(box)
        let open = button("Open terminal", #selector(revealAgent), in: doc)
        open.frame.origin = NSPoint(x: pad + cw - open.frame.width - 8, y: y + 13)
        let send = button("Send…", #selector(sendAgent), in: doc)
        send.frame.origin = NSPoint(x: open.frame.minX - send.frame.width - 6, y: y + 13)
        let words: String
        switch a.phase {
        case .working: words = "Session working · " + AgentSession.minutes(Date().timeIntervalSince(a.since))
        case .waiting: words = "Session needs input"
        case .done: words = "Session done"
        default: words = "Session starting…"
        }
        let t = NSTextField(labelWithString: "◉ " + words)
        t.font = .systemFont(ofSize: 12.5, weight: .semibold)
        t.frame = NSRect(x: pad + 11, y: y + 8, width: send.frame.minX - pad - 20, height: 17)
        doc.addSubview(t)
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        var sub = [a.agent.rawValue, a.repo.isEmpty ? "Orca" : a.repo, PROJECTS_CFG.orca.environment ?? "this Mac"].joined(separator: " · ")
        if let p = a.prompt, !p.isEmpty { sub += " \"\(p.count > 70 ? p.prefix(70) + "…" : Substring(p))\"" }
        sub += " · since " + df.string(from: a.since)
        let st = NSTextField(labelWithString: sub)
        st.font = .systemFont(ofSize: 11); st.textColor = .secondaryLabelColor
        st.lineBreakMode = .byTruncatingTail; st.toolTip = a.prompt
        st.frame = NSRect(x: pad + 11, y: y + 27, width: send.frame.minX - pad - 20, height: 15)
        doc.addSubview(st)
        var out = y + 60
        let key = item.key.uppercased()
        if agentTail?.key != key || -(agentTail?.at.timeIntervalSinceNow ?? 99) > 10 {
            agentTail = (key, agentTail?.key == key ? agentTail?.lines ?? [] : [], Date())
            agents.tail(item.key) { [weak self] lines in
                guard let self, self.agentTail?.key == key, lines != self.agentTail?.lines else { return }
                self.agentTail = (key, lines, Date())
                self.storeChanged()
            }
        }
        if let lines = agentTail?.lines, agentTail?.key == key, !lines.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let h = CGFloat(lines.count) * 15 + 16
            let term = NSView(frame: NSRect(x: pad, y: out, width: cw, height: h))
            term.wantsLayer = true
            term.layer?.cornerRadius = 8
            term.layer?.backgroundColor = NSColor(red: 0.08, green: 0.1, blue: 0.12, alpha: 1).cgColor
            doc.addSubview(term)
            let l = NSTextField(labelWithString: lines.joined(separator: "\n"))
            l.font = font
            l.textColor = NSColor(red: 0.81, green: 0.85, blue: 0.88, alpha: 1)
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = lines.count
            l.frame = NSRect(x: pad + 12, y: out + 8, width: cw - 24, height: h - 16)
            doc.addSubview(l)
            out += h + 8
        }
        return out + 8
    }

    @objc private func startOrca(_ sender: NSButton) {
        guard let id = itemId, let found = store.item(id) else { return }
        agents?.start(found.item, snap: found.snap, anchor: sender)
    }

    @objc private func agentChip(_ sender: NSButton) {
        guard let id = itemId, let found = store.item(id) else { return }
        agents?.pillClicked(found.item, snap: found.snap, anchor: sender)
    }

    @objc private func revealAgent() {
        if let id = itemId, let key = store.item(id)?.item.key { agents?.reveal(key) }
    }

    @objc private func sendAgent() {
        guard let id = itemId, let key = store.item(id)?.item.key, let win = window else { return }
        let alert = NSAlert()
        alert.messageText = "Send to the session of \(key)"
        alert.informativeText = "OverSire types the text into the Orca terminal and presses Return."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.placeholderString = "also add a test"
        alert.accessoryView = tf
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tf
        alert.beginSheetModal(for: win) { [weak self] r in
            let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r == .alertFirstButtonReturn, !text.isEmpty else { return }
            self?.agents?.send(key, text: text) { e in
                guard let self else { return }
                self.error = e?.message
                self.rebuild()
            }
        }
    }

    // MARK: Actions

    @objc private func goBack() { back() }
    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = MarkdownView.Mode(rawValue: sender.selectedSegment) ?? .rendered
        rebuild()
    }
    @objc private func toggleDescription() {
        fullDescription.toggle()
        rebuild(top: !fullDescription)
    }
    @objc private func openParent() {
        guard let id = itemId, let p = store.item(id)?.item.parentId else { return }
        open(p, push: true)
    }
    @objc private func openInPlane() {
        if let id = itemId, let u = store.item(id).flatMap({ URL(string: $0.item.url) }) { NSWorkspace.shared.open(u) }
    }
    @objc private func copyMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy link", action: #selector(copyLink), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy for agent", action: #selector(copyAgent), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    @objc private func copyLink() {
        guard let id = itemId, let url = store.item(id)?.item.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func copyAgent() { if let id = itemId { store.copyForAgent(id) } }
    @objc private func markRead() { if let id = itemId { store.markRead(itemId: id) } }

    @objc private func sendComment() {
        guard let id = itemId else { return }
        let body = commentField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return }
        commentField?.isEnabled = false
        store.comment(itemId: id, body: body) { [weak self] ok in
            guard let self else { return }
            self.error = ok ? nil : (self.store.lastError ?? "Could not post the comment")
            if ok { self.commentField?.stringValue = "" }
            self.commentField?.isEnabled = true
            self.loadTimeline()
            self.rebuild()
        }
    }

    // ↩ in the comment field posts it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === commentField, sel == #selector(NSResponder.insertNewline(_:)) { sendComment(); return true }
        return false
    }

    // MARK: Edit

    @objc private func beginEdit() {
        guard let id = itemId, let item = store.item(id)?.item else { return }
        edit = ItemEdit(title: item.title, body: item.body ?? "")
        tab = .overview
        rebuild(top: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === titleEdit { edit?.title = titleEdit?.stringValue ?? "" }
    }
    func textDidChange(_ notification: Notification) { edit?.body = bodyEdit?.string ?? "" }

    @objc private func cancelEdit() {
        edit = nil
        pending = false
        rebuild()
    }

    @objc private func saveEdit() {
        guard let id = itemId, var e = edit, !e.saving else { return }
        let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error = "Add a title"; rebuild(); return }
        e.saving = true
        edit = e
        rebuild()
        store.edit(itemId: id, title: title, body: e.body) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.error = nil
                self.edit = nil
            } else {
                self.error = self.store.lastError ?? "Could not save the item"
                self.edit?.saving = false
            }
            self.rebuild()
        }
    }

    @objc private func aiTidy() { editWithAI("tidy") }
    @objc private func aiTitle() { editWithAI("title") }

    private func editWithAI(_ what: String) {
        guard let ai = AIClient.current, let e = edit, e.busy == nil, !e.body.isEmpty else { return }
        edit?.busy = what
        rebuild()
        let finish: (String?) -> Void = { [weak self] err in
            self?.edit?.busy = nil
            self?.error = err
            self?.rebuild()
        }
        if what == "tidy" {
            ai.tidy(body: e.body) { [weak self] r in
                switch r {
                case .success(let text): self?.edit?.body = text; finish(nil)
                case .failure(let err): finish(err.message)
                }
            }
        } else {
            ai.draft(body: e.body, ctx: DraftContext()) { [weak self] r in
                switch r {
                case .success(let s): self?.edit?.title = s.title; finish(nil)
                case .failure(let err): finish(err.message)
                }
            }
        }
    }
}

// The bottom of a cut description fades into the window background.
private final class Fade: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor.windowBackgroundColor
        NSGradient(starting: bg.withAlphaComponent(0), ending: bg)?.draw(in: bounds, angle: -90)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Tabs with an icon and an underline. Sub-items show a progress ring, Activity a count.
private final class TabBar: Flipped {
    struct Spec {
        var title: String
        var symbol: String
        var ring: (done: Int, total: Int)? = nil
        var count: Int? = nil
    }
    var onSelect: ((Int) -> Void)?

    init(selected: Int, w: CGFloat, pad: CGFloat, tabs: [Spec]) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 34))
        var x = pad - 6
        for (i, t) in tabs.enumerated() {
            let on = i == selected
            let color: NSColor = on ? .labelColor : .secondaryLabelColor
            let tab = Flipped(frame: .zero)
            var tx: CGFloat = 8
            if let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil) {
                let iv = NSImageView(image: img)
                iv.symbolConfiguration = .init(pointSize: 12, weight: on ? .semibold : .regular)
                iv.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
                iv.frame = NSRect(x: tx, y: 8, width: 16, height: 16)
                tab.addSubview(iv)
                tx += 21
            }
            let l = NSTextField(labelWithString: t.title)
            l.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
            l.textColor = color
            l.sizeToFit()
            l.frame.origin = NSPoint(x: tx, y: 8)
            tab.addSubview(l)
            tx = l.frame.maxX + 6
            if let r = t.ring {
                let ring = ProgressRing(done: r.done, total: r.total, size: 15)
                ring.frame.origin = NSPoint(x: tx, y: 9)
                tab.addSubview(ring)
                let n = NSTextField(labelWithString: "\(r.done)/\(r.total)")
                n.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
                n.textColor = .secondaryLabelColor
                n.sizeToFit()
                n.frame.origin = NSPoint(x: tx + 19, y: 9)
                tab.addSubview(n)
                tx = n.frame.maxX + 4
            }
            if let c = t.count {
                let n = NSTextField(labelWithString: "\(c)")
                n.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
                n.textColor = on ? .white : .secondaryLabelColor
                n.alignment = .center
                n.sizeToFit()
                let pill = NSView(frame: NSRect(x: tx, y: 8, width: max(18, n.frame.width + 10), height: 17))
                pill.wantsLayer = true
                pill.layer?.cornerRadius = 8.5
                pill.layer?.backgroundColor = (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)).cgColor
                n.frame = NSRect(x: 0, y: 1, width: pill.frame.width, height: 15)
                pill.addSubview(n)
                tab.addSubview(pill)
                tx = pill.frame.maxX + 4
            }
            tab.frame = NSRect(x: x, y: 0, width: tx + 6, height: 34)
            if on {
                let line = NSView(frame: NSRect(x: 6, y: 32, width: tab.frame.width - 12, height: 2))
                line.wantsLayer = true
                line.layer?.cornerRadius = 1
                line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                tab.addSubview(line)
            }
            let tap = TapArea(frame: tab.bounds)
            tap.onTap = { [weak self] in self?.onSelect?(i) }
            tab.addSubview(tap)
            addSubview(tab)
            x += tab.frame.width + 6
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

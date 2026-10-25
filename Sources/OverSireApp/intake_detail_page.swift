import Cocoa
import OverSireCore

extension ProjectStore {
    /// The detail page of an intake item, or the Intake list of the project. `id`: the intake id or the work item id.
    func intakeRoute(_ project: String, id: String? = nil) -> Route {
        guard let s = snapshot(project) else { return .intake(nil) }
        return id.map { .intakeItem(s.summary.identifier, $0) } ?? .intake(s.summary.identifier)
    }
}

// One pending intake item in the main window: triage, Enhance, Refine, the description with Edit, and the files.
// After a triage the page shows the next item. When Refine accepts the item, the page opens the item page.
final class IntakeDetailPage: Page {
    override var pageWidth: CGFloat { 960 }

    private let markdown = MarkdownView(width: 600)
    private var markdownHeight: NSLayoutConstraint?
    private var details: [String: IntakeDetail] = [:]   // work item id
    private var bodies: [String: String] = [:]          // with signed image links
    private var loading: Set<String> = []
    private var mode = MarkdownView.Mode.rendered
    private var editor: MarkdownEditor?
    private var busy: String?
    private var note: (Tone, String)?
    private var refining = false
    private var lastKey: String?
    private var keyMonitor: Any?

    private var projectId: String { if case .intakeItem(let p, _) = route { return p }; return "" }
    private var intakeId: String { if case .intakeItem(_, let id) = route { return id }; return "" }
    private var snap: ProjectSnapshot? { data.projectStore.snapshot(projectId) }
    private var list: [IntakeItem] { (snap?.intake ?? []).sorted { $0.createdAt > $1.createdAt } }
    private var current: IntakeItem? { list.first { $0.id == intakeId || $0.workItemId == intakeId } }

    override var watches: DataDomains { [.projects, .intake, .agents, .questions, .config] }
    override var shownProjects: Set<String>? { snap.map { [$0.summary.ref.storeKey] } }

    override var isEditing: Bool { super.isEditing || editor != nil }
    override var hasDraft: Bool {
        guard let editor, let item = current else { return false }
        return editor.string != (details[item.workItemId]?.body ?? "")
    }
    override func dropDraft() { editor = nil }

    private func key(of item: IntakeItem) -> String? {
        guard let snap, let n = data.projectStore.intakeKeys[item.workItemId] ?? details[item.workItemId]?.sequence else { return nil }
        return "\(snap.summary.identifier)-\(n)"
    }

    override func viewDidLoad() {
        markdown.translatesAutoresizingMaskIntoConstraints = true
        markdown.onHeight = { [weak self] h in self?.markdownHeight?.constant = max(24, h) }
        super.viewDidLoad()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
    }

    override func show(_ r: Route) {
        if case .intakeItem(_, let id) = r, id != intakeId {
            editor = nil
            note = nil
            mode = .rendered
        }
        super.show(r)
    }

    // ↑ ↓ step, Esc goes to the list. Text fields keep their keys.
    private func key(_ e: NSEvent) -> NSEvent? {
        guard isShown, e.window === view.window, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !(view.window?.firstResponder is NSText) else { return e }
        switch e.keyCode {
        case 125: step(1); return nil
        case 126: step(-1); return nil
        case 53: go(.intake(projectId)); return nil
        default: return e
        }
    }

    private func step(_ by: Int) {
        guard editor == nil, let i = list.firstIndex(where: { $0.id == current?.id }), list.indices.contains(i + by) else { return }
        go(.intakeItem(projectId, list[i + by].id))
    }

    override func reload(reason: String) {
        if let snap, let item = current {
            data.projectStore.loadIntakeKeys(projectKey: snap.summary.ref.storeKey) { [weak self] in self?.reload() }
            if details[item.workItemId] == nil { load(item, pk: snap.summary.ref.storeKey) }
        }
        pageBusy = snap == nil && data.projectsLoading
        super.reload(reason: reason)
    }

    private func load(_ item: IntakeItem, pk: String) {
        guard loading.insert(item.workItemId).inserted else { return }
        data.projectStore.intakeDetail(projectKey: pk, item: item) { [weak self] r in
            guard let self else { return }
            self.loading.remove(item.workItemId)
            switch r {
            case .success(let d):
                self.details[item.workItemId] = d
                if UIShots.shooting, UIShots.intakeEdit, self.editor == nil { self.beginEdit(item) }
                self.data.projectStore.resolveImages(d.body, projectKey: pk) { body in
                    self.bodies[item.workItemId] = body
                    self.reload()
                }
            case .failure(let e):
                self.note = (.bad, "OverSire cannot read the description: \(e.message)")
            }
            self.reload()
        }
    }

    override func sections() -> [PageSection]? {
        let p = projectId
        guard let snap else {
            let loading = data.projectsLoading
            return [PageSection("missing", rows: [
                PageRow("header", p) { PageHeader("Intake item", caption: p) },
                PageRow("body", p, loading) { loading ? LoadingNote("Loading \(p)") : EmptyNote("OverSire does not track the project \(p).", symbol: "questionmark.square.dashed") },
            ])]
        }
        guard let item = current else { return gone(snap) }
        let pk = snap.summary.ref.storeKey
        let key = key(of: item)
        if let key { lastKey = key }
        var rows = [barRow(snap: snap, item: item, key: key), headRow(snap: snap, item: item, key: key)]
        if let note { rows.append(PageRow("note", "\(note.0.word)", note.1) { Banner(note.0, title: note.1) }) }
        if let r = enhanceRow(pk: pk, item: item) { rows.append(r) }
        if let key, let r = refineRow(key, snap: snap) { rows.append(r) }
        rows.append(descriptionRow(pk: pk, item: item))
        if let r = attachmentRow(snap: snap, item: item, key: key) { rows.append(r) }
        return [PageSection("intake", rows: rows)]
    }

    // The item left the intake. After Refine accepts it, the same key is a work item: its page opens.
    private func gone(_ snap: ProjectSnapshot) -> [PageSection] {
        if busy == nil, let k = lastKey, data.projectStore.item(key: k) != nil {
            DispatchQueue.main.async { [weak self] in self?.go(.item(k, .overview)) }
        }
        let p = projectId, n = list.count
        return [PageSection("gone", rows: [
            PageRow("header", p, n) { [weak self] in
                PageHeader("Intake item", caption: snap.summary.title,
                           actions: [ActionButton("‹ Intake (\(n))") { self?.go(.intake(p)) }])
            },
            PageRow("body", p) { EmptyNote("This item does not wait for triage any more.", symbol: "tray") },
        ])]
    }

    // MARK: Top bar and head

    private func barRow(snap: ProjectSnapshot, item: IntakeItem, key: String?) -> PageRow {
        let ids = list.map(\.id), i = ids.firstIndex(of: item.id) ?? 0
        let agent = data.enhanceAgent
        let canEnhance = agent.available && agent.state(.intake(item)) == nil
        let session = key.flatMap { RefineStarter(data.agentIndex).session($0) } != nil
        let canRefine = key != nil && data.has(.sessionInput)
        let editing = editor != nil
        return PageRow("bar", ids, i, busy, canEnhance, session, canRefine, refining, editing) { [unowned self] in
            let p = self.projectId
            let back = ActionButton("‹ Intake (\(ids.count))") { [weak self] in self?.go(.intake(p)) }
            back.toolTip = "Back to the list (Esc)"
            let up = ActionButton("", symbol: "chevron.up") { [weak self] in self?.step(-1) }
            up.toolTip = "Previous item (↑)"
            up.setAccessibilityLabel("Previous item")
            up.isEnabled = i > 0 && !editing
            let down = ActionButton("", symbol: "chevron.down") { [weak self] in self?.step(1) }
            down.toolTip = "Next item (↓)"
            down.setAccessibilityLabel("Next item")
            down.isEnabled = i < ids.count - 1 && !editing
            var views: [NSView] = [back, up, down, NSTextField.text("\(i + 1) of \(ids.count)", size: 12, color: Palette.dim), Spacer()]
            if self.busy != nil { views.append(Spinner()) }
            if canEnhance {
                let b = ActionButton("Enhance", symbol: "sparkles") { [weak self] in self?.data.enhanceAgent.start(projectKey: snap.summary.ref.storeKey, target: .intake(item)) }
                b.toolTip = "A read-only agent reads the code and writes a better description"
                b.contentTintColor = Palette.intake
                views.append(b)
            }
            if canRefine, let key { views.append(self.refineButton(item: item, key: key, session: session, snap: snap)) }
            let idle = self.busy == nil
            let accept = ActionButton(self.busy == "accept" ? "Accepting…" : "Accept", symbol: "checkmark", style: .primary) { [weak self] in self?.triage(.accept) }
            accept.toolTip = "Accept: the item moves to the project's work items"
            let queue = ActionButton("Accept and queue") { [weak self] in self?.acceptAndQueue(item) }
            queue.toolTip = "Accept, then add the start label. Checked Enhance changes go with it."
            let decline = ActionButton(self.busy == "decline" ? "Declining…" : "Decline", symbol: "xmark") { [weak self] in self?.decline() }
            decline.toolTip = "Decline: Plane closes the item"
            let more = ActionButton("", symbol: "ellipsis")
            more.toolTip = "More actions"
            more.setAccessibilityLabel("More actions")
            more.onClick = { [weak self, weak more] in
                guard let self, let more else { return }
                self.moreMenu(item, snap: snap).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 2), in: more)
            }
            [accept, queue, decline, more].forEach { $0.isEnabled = idle && !editing }
            views += [accept, queue, decline, more]
            return NSStackView(h: views, spacing: 6)
        }
    }

    private func refineButton(item: IntakeItem, key: String, session: Bool, snap: ProjectSnapshot) -> NSView {
        if session {
            return ActionButton("Open session", symbol: "terminal") { [weak self] in
                guard let self else { return }
                self.data.actions.click("session.reveal", ["key": .string(key)], in: self.view.window)
            }
        }
        let b = ActionButton(refining ? "Starting…" : "Refine", symbol: "bubble.left.and.bubble.right") { [weak self] in
            guard let self else { return }
            self.refine(.intake(item, key: key, body: self.details[item.workItemId]?.body), snap: snap)
        }
        b.toolTip = "Talk with an agent about this item. On your approval it accepts \(key) and adds sub-items."
        b.isEnabled = !refining
        return b
    }

    private func refine(_ t: RefineTarget, snap: ProjectSnapshot) {
        refining = true
        note = nil
        reload()
        RefineStarter(data.agentIndex).start(t, in: snap.summary) { [weak self] err in
            guard let self else { return }
            self.refining = false
            if let err { self.note = (.bad, "Refine did not start: \(err)") }
            self.reload()
        }
    }

    private func headRow(snap: ProjectSnapshot, item: IntakeItem, key: String?) -> PageRow {
        let labels = details[item.workItemId]?.labels ?? []
        return PageRow("head", item, key, labels) { [unowned self] in
            var chips: [NSView] = []
            if let key {
                let copy = Chiplet(key, symbol: "doc.on.doc", color: Palette.dim, mono: true)
                copy.toolTip = "Copy \(key)"
                copy.setAccessibilityLabel("Copy \(key)")
                copy.onClick = { [weak copy] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    copy?.flash("Copied")
                }
                chips.append(copy)
            }
            chips += [Pill(Tone(symbol: "clock", color: Palette.warn, word: "Pending"), text: "Pending"), self.priorityChip(snap: snap, item: item)]
            chips += labels.prefix(4).map { Chiplet($0, symbol: "tag") as NSView }
            if let a = item.author { chips.append(Chiplet("From \(a)", symbol: "person")) }
            chips.append(Chiplet(relativeTime(item.createdAt), symbol: "clock"))
            if let s = item.source { chips.append(Chiplet(s == "IN_APP" ? "In-app" : s.capitalized)) }
            let v = NSStackView(v: [], spacing: 8)
            v.addFull(NSTextField.text(item.name, size: 22, weight: .semibold, lines: 3))
            v.addFull(NSStackView(h: [Wrap(chips), Spacer()], spacing: 6))
            return v
        }
    }

    private func priorityChip(snap: ProjectSnapshot, item: IntakeItem) -> NSView {
        let cur = item.priority ?? "None"
        let chip = MenuChip("Priority: \(cur.capitalized)", symbol: "flag") { [weak self] in
            StatusOption.priorities.map { p in
                let a = MenuAction(p.name) { self?.update(item, ItemPatch(priority: p.id), what: "priority") }
                a.item.state = p.name.caseInsensitiveCompare(cur) == .orderedSame ? .on : .off
                return a
            }
        }
        chip.setAccessibilityLabel("Priority: \(cur.capitalized). Change the priority")
        return chip
    }

    // MARK: Enhance, Refine and files

    private func enhanceRow(pk: String, item: IntakeItem) -> PageRow? {
        guard let state = data.enhanceAgent.state(.intake(item)) else { return nil }
        return PageRow("enhance", String(describing: state)) { [unowned self] in
            EnhancePanel(state, projectKey: pk, target: .intake(item), agent: self.data.enhanceAgent, questions: self.data.questions) { [weak self] err in
                self?.note = err.map { (.bad, $0) }
                self?.reload()
            }
        }
    }

    private func refineRow(_ key: String, snap: ProjectSnapshot) -> PageRow? {
        let agents = data.agentIndex
        let starter = RefineStarter(agents)
        guard let a = starter.session(key) else { return nil }
        let last = agents.watch(key)?.recap ?? a.message
        let folder = starter.root(snap.summary) ?? a.repo
        return PageRow("refine", a, last, agents.place, folder) { [unowned self] in
            let card = RefineCard(key: key, session: a, place: agents.place, folder: folder, last: last) { [weak self] in
                guard let self else { return }
                self.data.actions.click("session.reveal", ["key": .string(key)], in: self.view.window)
            }
            card.onWork = { [weak self] in self?.go(.work(.items)) }
            return card
        }
    }

    private func attachmentRow(snap: ProjectSnapshot, item: IntakeItem, key: String?) -> PageRow? {
        let book = data.attachments
        guard let url = URL(string: snap.summary.url) else { return nil }
        let ref = ItemRef(project: snap.summary.ref, id: item.workItemId, key: key ?? item.name, url: url)
        guard let files = book.files(of: ref, changedAt: item.createdAt), !files.isEmpty else { return nil }
        return PageRow("attachments", hash: PageRow.hash(AttachmentStrip.sig(files, of: ref, book: book))) { AttachmentStrip(files, of: ref, book: book) }
    }

    // MARK: Description

    private func descriptionRow(pk: String, item: IntakeItem) -> PageRow {
        let d = details[item.workItemId]
        let body = d?.body, shown = bodies[item.workItemId]
        let editing = editor != nil, saving = busy == "body", mode = mode
        return PageRow("description", body, shown, editing, saving, mode.rawValue) { [unowned self] in
            self.descriptionCard(item, body: body, shown: shown ?? body, editing: editing, saving: saving, mode: mode)
        }
    }

    private func descriptionCard(_ item: IntakeItem, body: String?, shown: String?, editing: Bool, saving: Bool, mode: MarkdownView.Mode) -> NSView {
        var trailing: [NSView] = []
        if let url = URL(string: intakeURL(item)) {
            trailing.append(ActionButton("Open in Plane", symbol: "arrow.up.right.square", style: .ghost) { NSWorkspace.shared.open(url) })
        }
        if !editing {
            let seg = NSSegmentedControl(labels: ["Rendered", "Code"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
            seg.controlSize = .small
            seg.selectedSegment = mode.rawValue
            seg.setAccessibilityLabel("Description view")
            let edit = ActionButton("Edit", symbol: "pencil", style: .primary) { [weak self] in self?.beginEdit(item) }
            edit.isEnabled = body != nil && busy == nil
            trailing += [seg, edit]
        }
        let c = Card(title: "Description", trailing: trailing)
        if let editor {
            editor.removeFromSuperview()
            c.add(editor)
            let save = ActionButton(saving ? "Saving…" : "Save", style: .primary) { [weak self] in self?.save(item) }
            save.isEnabled = !saving
            let cancel = ActionButton("Cancel", style: .ghost) { [weak self] in self?.cancelEdit() }
            c.add(NSStackView(h: [save, cancel, NSTextField.text("⌘S saves to Plane. Esc cancels. The body stays Markdown.", size: 12, color: Palette.dim), Spacer()],
                              spacing: 8))
            return c
        }
        guard let body else {
            c.add(LoadingNote("Loading the description", height: 60, compact: true))
            return c
        }
        let text = (shown ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            c.add(NSTextField.text("No description.", size: 12.5, color: Palette.dim))
            return c
        }
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        markdown.removeFromSuperview()
        holder.addSubview(markdown)
        markdown.autoresizingMask = [.width, .height]
        markdown.frame = holder.bounds
        let h = holder.heightAnchor.constraint(equalToConstant: max(24, markdown.contentHeight))
        h.isActive = true
        markdownHeight = h
        c.add(holder)
        // Code mode shows the Markdown as Plane keeps it, with asset ids.
        markdown.show(mode == .code ? body : text, mode: mode)
        return c
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        mode = MarkdownView.Mode(rawValue: sender.selectedSegment) ?? .rendered
        reload()
    }

    private func beginEdit(_ item: IntakeItem) {
        let e = MarkdownEditor(details[item.workItemId]?.body ?? "")
        e.onSave = { [weak self] in self?.save(item) }
        e.onCancel = { [weak self] in self?.cancelEdit() }
        editor = e
        note = nil
        reload()
        DispatchQueue.main.async { [weak self, weak e] in if let e { self?.view.window?.makeFirstResponder(e.text) } }
    }

    private func cancelEdit() {
        editor = nil
        reload()
    }

    private func save(_ item: IntakeItem) {
        guard let text = editor?.string, busy == nil else { return }
        guard text != details[item.workItemId]?.body else { cancelEdit(); return }
        update(item, ItemPatch(bodyMarkdown: text), what: "body") { [weak self] in
            self?.editor = nil
            self?.details[item.workItemId] = nil
            self?.bodies[item.workItemId] = nil
        }
    }

    // Body and priority writes keep the item in the intake.
    func update(_ item: IntakeItem, _ patch: ItemPatch, what: String, then: (() -> Void)? = nil) {
        guard let snap, busy == nil,
              let (id, args) = IntakeAction.update(IntakeEdit(patch: patch)).action(project: snap.summary.ref.storeKey, id: item.id) else { return }
        busy = what
        note = nil
        reload()
        data.actions.run(id, args) { [weak self] r in
            guard let self else { return }
            self.busy = nil
            if case .ok = r { then?() } else { self.note = (.bad, r.summary) }
            self.reload()
        }
    }

    private func intakeURL(_ item: IntakeItem) -> String {
        (snap?.summary.url ?? "").replacingOccurrences(of: "/issues/", with: "/intake/") + "?currentTab=open&inboxIssueId=\(item.workItemId)"
    }

    // MARK: Triage

    private func decline() {
        confirm("Decline", "Plane closes the item. You can find it later in the Closed tab of the intake in Plane.") { [weak self] in self?.triage(.decline) }
    }

    private func moreMenu(_ item: IntakeItem, snap: ProjectSnapshot) -> NSMenu {
        let m = NSMenu()
        let snooze = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        snooze.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu()
        for (title, days) in [("Until tomorrow", 1), ("For 3 days", 3), ("For 1 week", 7), ("For 2 weeks", 14), ("For 1 month", 30)] {
            sub.addItem(MenuAction(title) { [weak self] in
                var d = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
                d = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
                self?.triage(.snooze(until: d))
            }.item)
        }
        snooze.submenu = sub
        m.addItem(snooze)
        let entries: [(String, String, () -> Void)] = [
            ("Mark as duplicate…", "plus.square.on.square", { [weak self] in self?.duplicate(item, snap: snap) }),
            ("Copy work item link", "doc.on.doc", { [weak self] in self?.copyLink(item, snap: snap) }),
            ("Open in Plane", "arrow.up.right.square", { [weak self] in
                if let u = self.flatMap({ URL(string: $0.intakeURL(item)) }) { NSWorkspace.shared.open(u) }
            }),
        ]
        for (title, symbol, run) in entries {
            let i = MenuAction(title, run).item
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            m.addItem(i)
        }
        m.addItem(.separator())
        let del = MenuAction("Delete") { [weak self] in
            self?.confirm("Delete", "Plane deletes the item and its work item. You cannot undo this.") { self?.triage(.delete) }
        }.item
        del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        del.attributedTitle = NSAttributedString(string: "Delete", attributes: [.foregroundColor: Palette.bad, .font: NSFont.menuFont(ofSize: 0)])
        m.addItem(del)
        return m
    }

    private func duplicate(_ item: IntakeItem, snap: ProjectSnapshot) {
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        box.completes = true
        box.numberOfVisibleItems = 12
        box.placeholderString = "\(snap.summary.identifier)-12"
        box.addItems(withObjectValues: snap.items.sorted { $0.key.count == $1.key.count ? $0.key > $1.key : $0.key.count > $1.key.count }
            .map { "\($0.key)  \($0.title)" })
        AlertConfirm.show(.init(title: "Mark “\(item.name)” as a duplicate", info: "Select or type the key of the work item that this item duplicates.",
                                buttons: ["Mark as duplicate", "Cancel"], accessory: box, focus: box), in: view.window) { [weak self] r in
            guard let self, r.button == 0 else { return }
            let k = box.stringValue.split(separator: " ").first.map { String($0).uppercased() } ?? ""
            guard let target = snap.items.first(where: { $0.key.uppercased() == k }) else {
                self.note = (.bad, k.isEmpty ? "Type the key of a work item" : "No work item \(k) in \(snap.summary.title)")
                self.reload()
                return
            }
            self.triage(.duplicate(of: target.id))
        }
    }

    // The browse link needs the key. Without it, the link opens the item in the intake.
    private func copyLink(_ item: IntakeItem, snap: ProjectSnapshot) {
        let base = snap.summary.url.components(separatedBy: "/projects/")[0]
        let u = key(of: item).map { "\(base)/browse/\($0)/" } ?? intakeURL(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u, forType: .string)
    }

    private func confirm(_ verb: String, _ info: String, then: @escaping () -> Void) {
        guard let item = current else { return }
        AlertConfirm.show(.init(title: "\(verb) “\(item.name)”?", info: info, buttons: [verb, "Cancel"], destructive: verb == "Delete"), in: view.window) {
            if $0.button == 0 { then() }
        }
    }

    // The item after this one, or the one before it, for the page after a triage.
    private var neighbour: IntakeItem? {
        let l = list
        guard let i = l.firstIndex(where: { $0.id == current?.id }) else { return nil }
        return l.indices.contains(i + 1) ? l[i + 1] : (i > 0 ? l[i - 1] : nil)
    }

    private func triage(_ action: IntakeAction) {
        guard let item = current, busy == nil, let snap,
              let (id, args) = action.action(project: snap.summary.ref.storeKey, id: item.id) else { return }
        let after = neighbour
        switch action {
        case .accept: busy = "accept"
        case .decline: busy = "decline"
        default: busy = "other"
        }
        note = nil
        reload()
        data.actions.run(id, args) { [weak self] r in
            guard let self else { return }
            self.busy = nil
            guard case .ok = r else { self.note = (.bad, r.summary); self.reload(); return }
            self.next(after)
        }
    }

    private func acceptAndQueue(_ item: IntakeItem) {
        guard let snap, busy == nil else { return }
        let after = neighbour
        busy = "accept"
        reload()
        data.enhanceAgent.apply(projectKey: snap.summary.ref.storeKey, item: item, accept: true, queue: true) { [weak self] err in
            guard let self else { return }
            self.busy = nil
            if let err { self.note = (.bad, err); self.reload(); return }
            self.next(after)
        }
    }

    private func next(_ after: IntakeItem?) {
        lastKey = nil
        go(after.map { .intakeItem(projectId, $0.id) } ?? .intake(projectId))
    }
}

// The Refine session of an intake item: the machine, the state, the last turn and Open terminal.
final class RefineCard: Card {
    var onWork: (() -> Void)?

    init(key: String, session a: AgentSession, place: String, folder: String, last: String?, open: @escaping () -> Void) {
        let tone = a.phase == .waiting ? Tone(symbol: "circle.fill", color: Palette.intake, word: "Waits for you") : Tone(a.phase)
        let path = folder.hasPrefix("/") ? (folder as NSString).abbreviatingWithTildeInPath : folder
        let more = ActionButton("", symbol: "ellipsis")
        more.toolTip = "More actions"
        more.setAccessibilityLabel("More actions")
        var trailing: [NSView] = [Chiplet("Runs on: \(place)")]
        if !path.isEmpty { trailing.append(Chiplet(path, mono: true)) }
        trailing += [Pill(tone, text: a.phase == .waiting ? tone.word : a.label()), ActionButton("Open terminal", symbol: "terminal", style: .primary, open), more]
        super.init(title: "Refine session", trailing: trailing)
        more.onClick = { [weak self, weak more] in
            guard let self, let more else { return }
            let m = NSMenu()
            m.autoenablesItems = false
            let work = MenuAction("Show on the Work page") { [weak self] in self?.onWork?() }
            let copy = MenuAction("Copy the folder path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder, forType: .string)
            }
            copy.item.isEnabled = !folder.isEmpty
            [work, copy].forEach { m.addItem($0.item) }
            self.menuActions = [work, copy]
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 2), in: more)
        }
        if let last = last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            let t = NSMutableAttributedString(string: "Last turn: ", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Palette.fg])
            t.append(NSAttributedString(string: "“\(last.prefix(400))”", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Palette.fg]))
            let f = NSTextField.text("", size: 12.5, lines: 4)
            f.attributedStringValue = t
            add(f)
        }
        add(NSTextField.text("The agent asks questions and gives a plan or a preview. When you approve, it accepts \(key) (same ID), "
                             + "writes the refined description and adds sub-items. The page then becomes the item page.", size: 12, color: Palette.dim, lines: 3))
    }
    private var menuActions: [MenuAction] = []
    required init?(coder: NSCoder) { fatalError() }
}

// A Markdown text area. ⌘S saves, Esc cancels.
final class MarkdownEditor: Box {
    final class Text: NSTextView {
        var onSave: (() -> Void)?
        var onCancel: (() -> Void)?

        override func performKeyEquivalent(with e: NSEvent) -> Bool {
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "s" { onSave?(); return true }
            return super.performKeyEquivalent(with: e)
        }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    let text = Text()
    var onSave: (() -> Void)? { get { text.onSave } set { text.onSave = newValue } }
    var onCancel: (() -> Void)? { get { text.onCancel } set { text.onCancel = newValue } }
    var string: String { text.string }

    init(_ body: String, height: CGFloat = 320) {
        super.init(fill: Palette.raise, border: Palette.line, radius: 8)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = Palette.fg
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = body
        text.setAccessibilityLabel("Description, Markdown")
        scroll.documentView = text
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

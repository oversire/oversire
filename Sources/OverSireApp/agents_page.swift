import AppKit
import OverSireCore
import OverSireSync

// The agents: runner sessions of the cloud, then the sessions that need you and all worktrees. Views › Activity shows the Orca events.
final class AgentsPage: Page {
    private var allWorktrees = false
    override var fillsHeight: Bool { true }
    private var expanded: Set<String> = UIShots.sessions ? ["uishots-card-3"] : []     // card ids with the status open
    private let table = ColumnLayout(id: "worktrees-4", columns: [
        TableColumn(id: "worktree", title: "Worktree", width: 290, min: 140),
        TableColumn(id: "state", title: "State", width: 150, min: 60),
        TableColumn(id: "status", title: "Status", width: 360, min: 120, flexible: true),
        TableColumn(id: "terms", title: "Terms", width: 44, min: 36, optional: true),
        TableColumn(id: "ci", title: "CI", width: 30, min: 24, optional: true),
    ])

    override func build(_ col: NSStackView) {
        let idx = data.agentIndex
        let cfg = PROJECTS_CFG.orca
        var caption = cfg.environment.map { "Orca environment \($0)" } ?? "Orca on this Mac"
        caption += " · read every 15 s"
        if data.statusJob.on { caption += " · status after \(Int(AGENTS.quietMinutes)) min idle" }
        if let e = idx.lastError { caption += " · last read failed: \(e)" }
        let actions = [
            NeedsYouCard.refreshButton(data),
            ActionButton("Open Orca", symbol: "terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Orca.app")) },
            ActionButton("Refresh", symbol: "arrow.clockwise") { idx.poll() },
        ]
        let cards = idx.cards.sorted(by: { $0.lastActivity > $1.lastActivity })
        let active = cards.filter { Self.isActive($0, linked: cardKey($0) != nil) }
        var trailing: [NSView] = []
        if idx.ready != nil {
            trailing = [Segmented(["With item \(active.count)", "All \(cards.count)"], selected: allWorktrees ? 1 : 0, label: "Worktrees") { [weak self] i in
                self?.allWorktrees = i == 1
                self?.reload()
            }]
        }
        WorkPage.header(self, tab: .worktrees, caption: caption, actions: actions, trailing: trailing, in: col)
        let hub = data.questions
        for e in hub.open where e.question.session.workspace.account.provider == RunnerQuestions.provider { col.addFull(hub.card(e)) }
        if let sessions = cloudAIRecords?.sessions, !sessions.isEmpty { runnerSessions(col, sessions) }
        guard idx.ready != nil else {
            col.addFull(Banner(.idle, title: "Orca is off or not installed.", body: "Turn on Orca to see sessions and worktrees here.",
                               actions: [ActionButton("Runtime settings") { [weak self] in self?.go(.settings(.agents)) }]))
            return
        }

        let shown = allWorktrees ? cards : active
        let lines = Dictionary(uniqueKeysWithValues: shown.compactMap { c in
            cardKey(c).flatMap { data.cleaner.line(card: c, key: $0, data: data) }.map { (c.id, $0) }
        })
        let safe = shown.filter { lines[$0.id].map { $0.safe && $0.removable } == true }
        let unsafe = shown.filter { lines[$0.id].map { !($0.safe && $0.removable) } == true }
        let rest = shown.filter { lines[$0.id] == nil }
        if !safe.isEmpty {
            let n = safe.count
            col.addFull(Banner(.ok, title: "\(n) worktree\(n == 1 ? " is" : "s are") finished and safe to remove.",
                               body: "The items are finished, the branches are merged or have no own commits, and no agent is live.",
                               actions: [ActionButton("Remove \(n) worktree\(n == 1 ? "" : "s")…", symbol: "trash") { [weak self] in self?.removeAll(safe) }]))
        }
        commands.intercept = { [weak self] c in
            guard case .removeWorktree(let id) = c else { return false }
            if let self, let card = shown.first(where: { $0.id == id }), let l = lines[id], let key = self.cardKey(card) {
                self.remove(l, key: key, card: card, ask: true)
            }
            return true
        }

        let list = StickyListCard.table(table)
        let grouped = !safe.isEmpty || !unsafe.isEmpty
        for (title, group) in [("Finished", safe), ("Done, but not safe to remove", unsafe), ("In progress", rest)] where !group.isEmpty {
            if grouped { list.addGroup(title, count: group.count) }
            for c in group { list.add(cardRow(c, cleanup: lines[c.id])) }
        }
        if cards.isEmpty {
            list.add(EmptyNote(idx.lastError == nil ? "Orca has no worktrees." : "OverSire could not read Orca.", symbol: "circle.dashed"))
        } else if !allWorktrees, active.count < cards.count {
            let n = cards.count - active.count
            list.add(Row([ActionButton("\(n) \(n == 1 ? "worktree has" : "worktrees have") no item · Show all", style: .link) { [weak self] in
                self?.allWorktrees = true
                self?.reload()
            }, Spacer()], height: 32, label: "Show all worktrees"))
        }
        col.addFull(list)
    }

    private func runnerSessions(_ col: NSStackView, _ sessions: [RunnerSession]) {
        col.addFull(SectionTitle("Runner sessions", count: sessions.count))
        let list = ListCard()
        for s in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(30) { list.add(runnerRow(s)) }
        col.addFull(list)
    }

    private func runnerTitle(_ s: RunnerSession) -> String {
        s.item?.key ?? URL(fileURLWithPath: s.repo).lastPathComponent
    }

    private func runnerRow(_ s: RunnerSession) -> NSView {
        let tone = Tone(s.state)
        let key = s.item?.key
        let name: NSView = key.map { k in Chiplet(k, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(k, .overview)) } }
            ?? NSTextField.text(runnerTitle(s), size: 12.5, mono: true)
        let asks = key.flatMap { data.questions.line(key: $0) }
        let note = s.error ?? asks ?? s.summary ?? ""
        let text = NSTextField.text(note, size: 12.5, color: s.error != nil ? Palette.bad : asks != nil ? Palette.acc : Palette.fg, lines: 1)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let label = "\(runnerTitle(s)), \(s.agent), \(tone.word)" + (note.isEmpty ? "" : ": \(note)") + ", \(relativeTime(s.updatedAt))"
        return Row([Pill(tone), fixed(name, 124), fixed(Chiplet(s.agent, symbol: "terminal", mono: true), 100), text, Spacer(),
                    NSTextField.text(relativeTime(s.updatedAt), size: 11.5, color: Palette.dim)], height: 36, label: label)
    }

    private func fixed(_ v: NSView, _ w: CGFloat) -> NSView {
        let box = NSStackView(h: [v, Spacer()], spacing: 0)
        box.widthAnchor.constraint(equalToConstant: w).isActive = true
        return box
    }

    /// A worktree with an item. A working agent without an item key does not count.
    static func isActive(_ c: Workspace, linked: Bool) -> Bool { linked }

    static func cardKey(_ c: Workspace, data: AppData) -> String? {
        data.agentIndex.agents.first { $0.value.card == c.id }?.key
            ?? data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }?.key
            ?? WorkstreamIndex.key(in: c.name, known: Set(data.projectStore.tracked.map { $0.identifier.uppercased() }), whole: true)
    }

    private func cardKey(_ c: Workspace) -> String? { Self.cardKey(c, data: data) }

    // MARK: Remove

    /// A safe line runs at once. Any other line asks first and forces the removal.
    private func remove(_ l: CleanupLine, key: String, card c: Workspace, ask: Bool) {
        guard l.removable else { return }
        let run = { [weak self] in
            guard let self else { return }
            self.data.cleaner.run([l], key: key, data: self.data) { [weak self] errors in self?.failed(errors) }
            self.reload()
        }
        guard ask || !l.safe else { run(); return }
        let a = NSAlert()
        a.messageText = "Remove \(c.name)?"
        a.informativeText = l.safe ? "OverSire runs orca worktree rm. The Plane item does not change."
            : "\(l.detail) OverSire forces the removal. Changes that are not in the base branch are lost."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if !l.safe { a.alertStyle = .critical }
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { run() } }
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }

    /// Runs the safe lines of each finished item that has a safe worktree.
    private func removeAll(_ cards: [Workspace]) {
        let keys = Array(Set(cards.compactMap { cardKey($0) })).sorted()
        let a = NSAlert()
        a.messageText = "Remove \(cards.count) worktree\(cards.count == 1 ? "" : "s")?"
        a.informativeText = """
            • OverSire runs orca worktree rm for each worktree.
            • A local branch is deleted only when it is merged.
            • A remote branch is deleted only when its PR is merged.
            • The Plane items do not change.
            """
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            for k in keys {
                let lines = self.data.cleaner.lines(k, data: self.data).filter { $0.safe && $0.removable && $0.kind != .group }
                self.data.cleaner.run(lines, key: k, data: self.data) { [weak self] errors in self?.failed(errors) }
            }
            self.reload()
        }
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }

    private func failed(_ errors: [String]) {
        guard !errors.isEmpty else { reload(); return }
        let a = NSAlert()
        a.messageText = "OverSire could not remove all of it."
        a.informativeText = errors.joined(separator: "\n")
        if let w = view.window { a.beginSheetModal(for: w) } else { a.runModal() }
        reload()
    }

    private func cardRow(_ c: Workspace, cleanup: CleanupLine? = nil) -> NSView {
        let key = cardKey(c)
        let co = data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }
        let job = data.statusJob
        let agent: NSView
        var live = false
        if let key, let a = data.agentIndex.agent(key), a.card == c.id, let s = job.item(key) {
            agent = StatusPill(s)
            live = true
        } else if let g = c.agents.min(by: { $0.rank < $1.rank }) {
            agent = Pill(tone(g.phase))
        } else {
            agent = Chiplet("Shell only", symbol: "terminal")
        }
        let status = live ? key.flatMap { job.status($0) } : nil
        let reading = live && key.map { job.reading.contains($0.uppercased()) } == true
        let ci: NSView = key.flatMap { data.workstreams.stream($0)?.ci }.map { Glyph($0) as NSView } ?? NSTextField.text("—", color: Palette.dim)

        let title = key.flatMap { data.projectStore.item(key: $0)?.2.title }
        let name = title.map { NSTextField.text($0, size: 12.5) } ?? NSTextField.text(c.name, size: 12.5, mono: true)
        name.lineBreakMode = title == nil ? .byTruncatingMiddle : .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        name.toolTip = c.name
        var top: [NSView] = [name]
        if let key { top.insert(Chiplet(key, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(key, .overview)) }, at: 0) }
        let place = NSTextField.text([c.repo, co?.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                     size: 11.5, color: Palette.dim, mono: true)
        place.lineBreakMode = .byTruncatingMiddle
        place.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let worktree = NSStackView(v: [NSStackView(h: top, spacing: 6), place], spacing: 3)
        worktree.alignment = .leading
        worktree.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: worktree.widthAnchor).isActive = true }

        var head = "—", meta = "", headColor = Palette.dim
        let asks = key.flatMap { data.questions.line(key: $0) }
        if let asks {
            head = asks
            headColor = asks.hasPrefix("✦") ? Palette.acc : Palette.ok
            meta = asks.hasPrefix("✦") ? "Open the item to answer" : "The session goes on"
        } else if reading {
            head = "Reading the last turn…"
            meta = "Status requested"
        } else if let s = status {
            let old = job.outOfDate(s)
            // The State pill shows the word. A status that does not hold keeps the word here.
            head = s.reply.headline.isEmpty || old != nil ? s.word + (s.reply.headline.isEmpty ? "" : ": " + s.reply.headline) : s.reply.headline
            headColor = old != nil ? Palette.dim : s.state == .unfinished || s.state == .stuck ? Palette.warn : Palette.fg
            meta = ([relativeAgo(s.at), s.cause] + (old.map { [$0] } ?? [])).joined(separator: " · ")
        } else if let key, data.projectStore.isDone(key: key) {
            head = "Item is done."
            meta = "No AI status for a closed item"
        } else if live, let key {
            head = "No status yet."
            meta = job.on ? "Next status after \(Int(AGENTS.quietMinutes)) min idle, or press refresh" : data.agentIndex.screenText(key)
        }
        if let l = cleanup, asks == nil {
            let ok = l.safe && l.removable
            head = ok ? "Finished. Safe to remove." : l.kind == .session ? "Done. An agent is live." : "Done. Not safe to remove."
            meta = l.detail
            headColor = ok ? Palette.ok : Palette.warn
        }
        let statusCell = TwoLine(head, meta, titleSize: 12.5, weight: .regular, titleColor: headColor)
        statusCell.toolTip = head
        let cells: [String: NSView] = [
            "worktree": worktree, "state": agent, "status": statusCell,
            "terms": NSTextField.text("\(c.liveTerminals)", size: 12, color: Palette.mut), "ci": ci,
        ]
        // Each row keeps the refresh slot, so that the columns align.
        let canRead = live && key.map { !data.projectStore.isDone(key: $0) } == true
        let r = ActionButton("", symbol: "arrow.clockwise", style: .link) { if let key { job.refresh(keys: [key]) } }
        r.setAccessibilityLabel("Refresh the status of \(key ?? c.name)")
        r.toolTip = "Read the history and the screen of the session now"
        r.isEnabled = canRead && !reading
        if !canRead { r.alphaValue = 0; r.setAccessibilityElement(false) }
        var trailing: [NSView] = [r]
        // Each row keeps the Remove slot too, so that the columns align.
        let slot = NSStackView(h: [Spacer()], spacing: 0)
        slot.widthAnchor.constraint(equalToConstant: 112).isActive = true
        if let l = cleanup, l.removable, let key {
            let running = data.cleaner.running.contains(key.uppercased())
            let b = ActionButton(running ? "Removing…" : l.safe ? "Remove" : "Remove…", symbol: running ? nil : "trash") { [weak self] in
                self?.remove(l, key: key, card: c, ask: false)
            }
            b.isEnabled = !running
            b.setAccessibilityLabel("Remove the worktree \(c.name)")
            b.toolTip = l.safe ? "orca worktree rm" : l.detail
            slot.addArrangedSubview(b)
        }
        trailing.append(slot)
        let open = ActionButton("Open", style: .plain) { [weak self] in
            if let key { self?.go(.item(key, .session)) } else { self?.data.agentIndex.reveal(card: c.id) }
        }
        open.setAccessibilityLabel(key.map { "Open the session of \($0)" } ?? "Open \(c.name) in Orca")
        trailing.append(open)
        let detail = status.flatMap { $0.reply.done.isEmpty && $0.reply.next.isEmpty ? nil : $0 }
        let isOpen = detail != nil && expanded.contains(c.id)
        let label = "\(c.name), \(c.repo), \(c.liveTerminals) terminals" + (key.map { ", item \($0)" } ?? ", no item")
            + (status.map { ". \($0.word): \($0.reply.headline)" } ?? "")
        let row = TableRow(table, cells: cells, trailing: trailing, height: 54, label: label) { [weak self] in
            guard let self else { return }
            if asks != nil, let key {
                self.go(.item(key, .session))
            } else if detail != nil {
                if self.expanded.remove(c.id) == nil { self.expanded.insert(c.id) }
                self.reload()
            } else if let key { self.go(.item(key, .overview)) } else { self.data.agentIndex.reveal(card: c.id) }
        }
        if let box = row.cells.boxes["worktree"] { worktree.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        if detail != nil { row.setAccessibilityExpanded(isOpen) }
        let hasAgent = key.flatMap { data.agentIndex.agent($0) } != nil
        commands.attach(row) { RowMenu.session(card: c, key: key, checkout: co, hasAgent: hasAgent, caps: $0, removable: cleanup?.removable == true) }
        guard isOpen, let s = detail else { return row }
        return expandedRow(row, s)
    }

    // Done and "Now and next" under the row.
    private func expandedRow(_ row: NSView, _ s: SessionStatus) -> NSView {
        func list(_ title: String, _ items: [String]) -> NSView {
            let v = NSStackView(v: [NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim)], spacing: 4)
            if items.isEmpty { v.addFull(NSTextField.text("—", size: 12.5, color: Palette.dim)) }
            for e in items { v.addFull(NSTextField.text("· " + e, size: 12.5, color: Palette.mut, lines: 3)) }
            return v
        }
        let two = NSStackView(h: [list("Done", s.reply.done), list("Now and next", s.reply.next)], spacing: 20, align: .top)
        two.distribution = .fillEqually
        let pad = Padded(two, vertical: 6, side: 0)
        pad.edgeInsets = NSEdgeInsets(top: 4, left: min(table.columns.first?.width ?? 290, 300) + 30, bottom: 14, right: 16)
        let v = NSStackView(v: [row, pad], spacing: 0)
        v.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        return v
    }

    private func tone(_ s: AgentSession.Phase) -> Tone {
        Tone(s == .waiting ? SessionState.needsInput : s == .working ? .working : .done)
    }

    /// ⌘R: read each session again and write its status.
    func checkAgain() {
        data.statusJob.refresh(keys: data.statusJob.refreshable)
    }
}

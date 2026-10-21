import AppKit
import OverSireCore

// The agents: runner sessions of the cloud, then the sessions that need you and all worktrees. Views › Activity shows the Orca events.
final class AgentsPage: Page {
    /// The prompt ids with an answer on the way.
    private var answering: Set<String> = []
    private var note: (Tone, String)?
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
        if let note { col.addFull(Banner(note.0, title: note.1)) }
        if let sessions = cloudAIRecords?.sessions, !sessions.isEmpty { runnerSessions(col, sessions) }
        guard idx.ready != nil else {
            col.addFull(Banner(.idle, title: "Orca is off or not installed.", body: "Turn on Orca to see sessions and worktrees here.",
                               actions: [ActionButton("Runtime settings") { [weak self] in self?.go(.settings(.agents)) }]))
            return
        }

        let list = StickyListCard.table(table)
        for c in allWorktrees ? cards : active { list.add(cardRow(c)) }
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
        let asking = sessions.filter { $0.permission != nil }.sorted { $0.updatedAt < $1.updatedAt }
        for s in asking { col.addFull(permissionCard(s)) }
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
        let note = s.error ?? s.summary ?? ""
        let text = NSTextField.text(note, size: 12.5, color: s.error == nil ? Palette.fg : Palette.bad, lines: 1)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let label = "\(runnerTitle(s)), \(s.agent), \(tone.word)" + (note.isEmpty ? "" : ": \(note)") + ", \(relativeTime(s.updatedAt))"
        return Row([Pill(tone), fixed(name, 124), fixed(Chiplet(s.agent, symbol: "terminal", mono: true), 100), text, Spacer(),
                    NSTextField.text(relativeTime(s.updatedAt), size: 11.5, color: Palette.dim)], height: 36, label: label)
    }

    private func permissionCard(_ s: RunnerSession) -> NSView {
        guard let p = s.permission else { return NSView() }
        let c = Card(border: Palette.warn.withAlphaComponent(0.55))
        let title = s.item.flatMap { data.projectStore.item(key: $0.key)?.2.title }.map { " · \($0)" } ?? ""
        let head = NSTextField.text("\(runnerTitle(s))\(title)", size: 13, weight: .semibold)
        head.lineBreakMode = .byTruncatingTail
        c.add(NSStackView(h: [Pill(Tone(s.state)), head, Chiplet(s.agent, symbol: "terminal", mono: true),
                              NSTextField.text(timeLeft(p.expiresAt), size: 12, color: Palette.dim), Spacer()], spacing: 8))
        if let summary = s.summary { c.add(NSTextField.text(summary, size: 12.5, color: Palette.mut, lines: 3)) }
        c.add(TermView(lines: ["\(p.tool): \(p.text)"], height: 44))
        let allow = ActionButton("Allow", style: .primary) { [weak self] in self?.answer(s, p, allow: true) }
        let deny = ActionButton("Deny") { [weak self] in self?.answer(s, p, allow: false) }
        if answering.contains(p.id) { allow.busy("Sending…"); deny.isEnabled = false }
        allow.setAccessibilityLabel("Allow \(p.tool) for \(runnerTitle(s))")
        deny.setAccessibilityLabel("Deny \(p.tool) for \(runnerTitle(s))")
        c.add(NSStackView(h: [allow, deny, NSTextField.text("No answer before the time limit is a deny.", size: 12, color: Palette.dim), Spacer()],
                          spacing: 6))
        return c
    }

    private func timeLeft(_ at: Date) -> String {
        let m = Int((at.timeIntervalSinceNow / 60).rounded(.up))
        return m <= 0 ? "time limit reached" : "\(m) min left"
    }

    private func answer(_ s: RunnerSession, _ p: PermissionPrompt, allow: Bool) {
        guard !answering.contains(p.id) else { return }
        answering.insert(p.id)
        reload()
        let api = RelayAPI(base: RELAY.workerURL, token: SecretStore().get(SecretStore.deviceToken))
        let session = s.id, title = runnerTitle(s)
        Task { @MainActor in
            let result = await Task.detached { api.answer(session: session, permission: p.id, allow: allow) }.value
            self.answering.remove(p.id)
            switch result {
            case .success: self.note = nil
            case .failure(.http(409)): self.note = (.info, "The prompt of \(title) has an answer already.")
            case .failure(.http(410)): self.note = (.bad, "The prompt of \(title) expired. The runner denied it.")
            case .failure(let e): self.note = (.bad, "Could not answer \(title): \(e)")
            }
            self.reload()
        }
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

    private func cardRow(_ c: Workspace) -> NSView {
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
        if reading {
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
            if detail != nil {
                if self.expanded.remove(c.id) == nil { self.expanded.insert(c.id) }
                self.reload()
            } else if let key { self.go(.item(key, .overview)) } else { self.data.agentIndex.reveal(card: c.id) }
        }
        if let box = row.cells.boxes["worktree"] { worktree.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        if detail != nil { row.setAccessibilityExpanded(isOpen) }
        let hasAgent = key.flatMap { data.agentIndex.agent($0) } != nil
        commands.attach(row) { RowMenu.session(card: c, key: key, checkout: co, hasAgent: hasAgent, caps: $0) }
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

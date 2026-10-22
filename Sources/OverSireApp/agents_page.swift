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

    override var watches: DataDomains { [.agents, .projects, .runs, .questions, .summaries, .config] }

    override func sections() -> [PageSection]? {
        let idx = data.agentIndex
        let cfg = PROJECTS_CFG.orca
        var caption = cfg.environment.map { "Orca environment \($0)" } ?? "Orca on this Mac"
        caption += " · read every 15 s"
        if data.statusJob.on { caption += " · status after \(Int(AGENTS.quietMinutes)) min idle" }
        if let e = idx.lastError { caption += " · last read failed: \(e)" }
        let data = data
        let cards = idx.cards.sorted(by: { $0.lastActivity > $1.lastActivity })
        let active = cards.filter { Self.isActive($0, linked: cardKey($0) != nil) }
        let ready = idx.ready != nil, all = allWorktrees
        let top = WorkPage.header(self, tab: .worktrees, caption: caption, extra: [ready, all, active.count, cards.count] as [AnyHashable], actions: {
            [NeedsYouCard.refreshButton(data),
             ActionButton("Open Orca", symbol: "terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Orca.app")) },
             ActionButton("Refresh", symbol: "arrow.clockwise") { idx.poll() }]
        }, trailing: { [weak self] in
            guard ready else { return [] }
            return [Segmented(["With item \(active.count)", "All \(cards.count)"], selected: all ? 1 : 0, label: "Worktrees") { i in
                self?.allWorktrees = i == 1
                self?.reload()
            }]
        })
        var out = [PageSection("top", rows: top)]
        let hub = data.questions
        let asks = hub.open.filter { $0.question.session.workspace.account.provider == RunnerQuestions.provider }
        if !asks.isEmpty {
            out.append(PageSection("asks", rows: asks.map { e in PageRow("q." + e.id.rawValue, String(describing: e)) { hub.card(e) } }))
        }
        if let sessions = cloudAIRecords?.sessions, !sessions.isEmpty {
            let list = sessions.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(30)
            let rows = list.map { s in
                PageRow(s.id, s.state.rawValue, s.item?.key, s.agent, s.repo, s.error, s.summary, s.updatedAt,
                        s.item.flatMap { data.questions.line(key: $0.key) }) { [weak self] in self?.runnerRow(s) ?? NSView() }
            }
            out.append(PageSection("runners", header: PageRow("title", sessions.count) { SectionTitle("Runner sessions", count: sessions.count) },
                                   rows: [PageRow.list("list", rows: rows) { ListCard() }]))
        }
        guard ready else {
            out.append(PageSection("off", rows: [PageRow("banner", 0) { [weak self] in
                Banner(.idle, title: "Orca is off or not installed.", body: "Turn on Orca to see sessions and worktrees here.",
                       actions: [ActionButton("Runtime settings") { self?.go(.settings(.agents)) }])
            }]))
            return out
        }

        let shown = all ? cards : active
        let lines = Dictionary(uniqueKeysWithValues: shown.compactMap { c in
            cardKey(c).flatMap { data.cleaner.line(card: c, key: $0, data: data) }.map { (c.id, $0) }
        })
        let safe = shown.filter { lines[$0.id].map { $0.safe && $0.removable } == true }
        let unsafe = shown.filter { lines[$0.id].map { !($0.safe && $0.removable) } == true }
        let rest = shown.filter { lines[$0.id] == nil }
        if !safe.isEmpty {
            let n = safe.count
            out.append(PageSection("safe", rows: [PageRow("banner", safe.map(\.id)) { [weak self] in
                Banner(.ok, title: "\(n) worktree\(n == 1 ? " is" : "s are") finished and safe to remove.",
                       body: "The items are finished, the branches are merged or have no own commits, and no agent is live.",
                       actions: [ActionButton("Remove \(n) worktree\(n == 1 ? "" : "s")…", symbol: "trash") { self?.removeAll(safe) }])
            }]))
        }
        commands.intercept = { [weak self] c in
            guard case .removeWorktree(let id) = c else { return false }
            if let self, let card = shown.first(where: { $0.id == id }), let l = lines[id], let key = self.cardKey(card) {
                self.remove(l, key: key, card: card, ask: true)
            }
            return true
        }

        var rows: [PageRow] = []
        let grouped = !safe.isEmpty || !unsafe.isEmpty
        for (title, group) in [("Finished", safe), ("Done, but not safe to remove", unsafe), ("In progress", rest)] where !group.isEmpty {
            if grouped { rows.append(StickyListCard.group(title, title, count: group.count)) }
            rows += group.map { cardRow($0, cleanup: lines[$0.id]) }
        }
        if cards.isEmpty {
            let failed = idx.lastError != nil
            rows.append(PageRow("empty", failed) { EmptyNote(failed ? "OverSire could not read Orca." : "Orca has no worktrees.", symbol: "circle.dashed") })
        } else if !all, active.count < cards.count {
            let n = cards.count - active.count
            rows.append(PageRow("more", n) { [weak self] in
                Row([ActionButton("\(n) \(n == 1 ? "worktree has" : "worktrees have") no item · Show all", style: .link) {
                    self?.allWorktrees = true
                    self?.reload()
                }, Spacer()], height: 32, label: "Show all worktrees")
            })
        }
        let table = table
        out.append(PageSection("worktrees", rows: [PageRow.list("table", rows: rows) { StickyListCard.table(table) }]))
        return out
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
                    RelativeTimeLabel(s.updatedAt)], height: 36, label: label)
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
        AlertConfirm.ask("Remove \(c.name)?",
                         info: l.safe ? "OverSire runs orca worktree rm. The Plane item does not change."
                             : "\(l.detail) OverSire forces the removal. Changes that are not in the base branch are lost.",
                         button: "Remove", critical: !l.safe, in: view.window, run)
    }

    /// Runs the safe lines of each finished item that has a safe worktree.
    private func removeAll(_ cards: [Workspace]) {
        let keys = Array(Set(cards.compactMap { cardKey($0) })).sorted()
        let info = """
            • OverSire runs orca worktree rm for each worktree.
            • A local branch is deleted only when it is merged.
            • A remote branch is deleted only when its PR is merged.
            • The Plane items do not change.
            """
        AlertConfirm.ask("Remove \(cards.count) worktree\(cards.count == 1 ? "" : "s")?", info: info, button: "Remove", in: view.window) { [weak self] in
            guard let self else { return }
            for k in keys {
                let lines = self.data.cleaner.lines(k, data: self.data).filter { $0.safe && $0.removable && $0.kind != .group }
                self.data.cleaner.run(lines, key: k, data: self.data) { [weak self] errors in self?.failed(errors) }
            }
            self.reload()
        }
    }

    private func failed(_ errors: [String]) {
        guard !errors.isEmpty else { reload(); return }
        AlertConfirm.tell("OverSire could not remove all of it.", info: errors.joined(separator: "\n"), in: view.window)
        reload()
    }

    // The row of a worktree. Its hash holds the inputs of `cardView`.
    private func cardRow(_ c: Workspace, cleanup: CleanupLine? = nil) -> PageRow {
        let key = cardKey(c)
        let job = data.statusJob
        let co = data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }
        let st = key.flatMap { job.status($0) }
        let parts: [AnyHashable?] = [c, key, co?.branch, key.flatMap { data.agentIndex.agent($0) }, key.flatMap { job.item($0)?.label },
                                     key.flatMap { job.item($0)?.tone.word }, st?.reply, st?.at, st.flatMap { job.outOfDate($0) },
                                     key.map { job.reading.contains($0.uppercased()) }, key.flatMap { data.workstreams.stream($0)?.ci?.word },
                                     key.flatMap { data.projectStore.item(key: $0)?.2.title }, key.flatMap { data.questions.line(key: $0) },
                                     key.map { data.projectStore.isDone(key: $0) }, job.on, expanded.contains(c.id),
                                     cleanup.map { [$0.kind, $0.safe, $0.removable, $0.detail] as [AnyHashable] }, key.map { data.cleaner.running.contains($0.uppercased()) }]
        return PageRow(c.id, hash: PageRow.hash(parts.map { $0 ?? AnyHashable(0) })) { [weak self] in self?.cardView(c, cleanup: cleanup) ?? NSView() }
    }

    private func cardView(_ c: Workspace, cleanup: CleanupLine?) -> NSView {
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
        var metaAt: Date?, metaTail = ""
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
            metaAt = s.at
            metaTail = ([s.cause] + (old.map { [$0] } ?? [])).joined(separator: " · ")
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
            metaAt = nil
            headColor = ok ? Palette.ok : Palette.warn
        }
        let sub: NSView = metaAt.map { at in RelativeTimeLabel({ at }, text: relativeAgo) { [$0, metaTail].joined(separator: " · ") } }
            ?? NSTextField.text(meta, size: 11.5, color: Palette.dim)
        let statusCell = TwoLine(head, subView: meta.isEmpty ? nil : sub, titleSize: 12.5, weight: .regular, titleColor: headColor)
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

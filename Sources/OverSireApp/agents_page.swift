import AppKit
import OverSireCore

// The agents: runner sessions of the cloud, then the Orca agents that need input, all worktrees and the activity.
final class AgentsPage: Page {
    /// The prompt ids with an answer on the way.
    private var answering: Set<String> = []
    private var tails: [String: [String]] = [:]
    private var tailAt: [String: Date] = [:]
    private var replies: [String: NSTextField] = [:]
    private var sending: Set<String> = []
    private var note: (Tone, String)?
    private let table = ColumnLayout(id: "worktrees", columns: [
        TableColumn(id: "worktree", title: "Worktree", width: 200, min: 100),
        TableColumn(id: "repo", title: "Repo", width: 130, min: 60, optional: true),
        TableColumn(id: "branch", title: "Branch", width: 170, min: 60, optional: true),
        TableColumn(id: "session", title: "Session", width: 130, min: 60),
        TableColumn(id: "terms", title: "Terms", width: 44, min: 36, optional: true),
        TableColumn(id: "item", title: "Item", width: 124, min: 60),
        TableColumn(id: "ci", title: "CI", width: 30, min: 24, optional: true),
    ])

    override var isEditing: Bool { super.isEditing || replies.values.contains { !$0.stringValue.isEmpty } }

    override func build(_ col: NSStackView) {
        let idx = data.agentIndex
        let cfg = PROJECTS_CFG.orca
        var caption = cfg.environment.map { "Orca environment \($0)" } ?? "Orca on this Mac"
        caption += " · read every 15 s"
        if let e = idx.lastError { caption += " · last read failed: \(e)" }
        col.addFull(PageHeader("Sessions and worktrees", caption: caption, actions: [
            ActionButton("Open Orca", symbol: "terminal") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Orca.app")) },
            ActionButton("Refresh", symbol: "arrow.clockwise") { idx.poll() },
        ]))
        if let note { col.addFull(Banner(note.0, title: note.1)) }
        if let sessions = cloudAIRecords?.sessions, !sessions.isEmpty { runnerSessions(col, sessions) }
        guard idx.ready != nil else {
            col.addFull(Banner(.idle, title: "Orca is off or not installed.", body: "Turn on Orca to see sessions and worktrees here.",
                               actions: [ActionButton("Runtime settings") { [weak self] in self?.go(.settings(.agents)) }]))
            return
        }

        let waiting = idx.agents.filter { $0.value.phase == .waiting }.sorted { $0.value.since < $1.value.since }
        for (key, a) in waiting { col.addFull(waitingCard(key, a)) }

        col.addFull(SectionTitle("Worktrees", count: idx.cards.count))
        let list = ListCard()
        list.add(TableHeader(table))
        for c in idx.cards.sorted(by: { $0.lastActivity > $1.lastActivity }) { list.add(cardRow(c)) }
        if idx.cards.isEmpty { list.add(EmptyNote(idx.lastError == nil ? "Orca has no worktrees." : "OverSire could not read Orca.", symbol: "circle.dashed")) }
        col.addFull(list)

        col.addFull(SectionTitle("Orca activity"))
        let feed = ListCard()
        for e in idx.feed.events.prefix(30) { feed.add(eventRow(e)) }
        if feed.isEmpty { feed.add(EmptyNote("No session changed state since OverSire started.", symbol: "clock")) }
        col.addFull(feed)
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

    private func cardKey(_ c: Workspace) -> String? {
        data.agentIndex.agents.first { $0.value.card == c.id }?.key
            ?? data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }?.key
            ?? WorkstreamIndex.key(in: c.name, known: Set(data.projectStore.tracked.map { $0.identifier.uppercased() }), whole: true)
    }

    private func cardRow(_ c: Workspace) -> NSView {
        let key = cardKey(c)
        let co = data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }
        let agent: NSView
        if let key, let a = data.agentIndex.agent(key), a.card == c.id {
            agent = Pill(Tone(a.phase), text: a.label())
        } else if let g = c.agents.min(by: { $0.rank < $1.rank }) {
            agent = Pill(tone(g.phase))
        } else {
            agent = Chiplet("Shell only", symbol: "terminal")
        }
        let item: NSView = key.map { k in Chiplet(k, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(k, .overview)) } }
            ?? NSTextField.text("unlinked", size: 12, color: Palette.dim)
        let ci: NSView = key.flatMap { data.workstreams.stream($0)?.ci }.map { Glyph($0) as NSView } ?? NSTextField.text("—", color: Palette.dim)
        let name = NSTextField.text(c.name, size: 12.5, mono: true)
        name.lineBreakMode = .byTruncatingMiddle
        let branch = NSTextField.text(co?.branch ?? "—", size: 12, color: Palette.mut, mono: true)
        branch.lineBreakMode = .byTruncatingMiddle
        let cells: [String: NSView] = [
            "worktree": name, "repo": NSTextField.text(c.repo, size: 12, color: Palette.mut), "branch": branch,
            "session": agent, "terms": NSTextField.text("\(c.liveTerminals)", size: 12, color: Palette.mut), "item": item, "ci": ci,
        ]
        let open = ActionButton(key == nil ? "Open in Orca" : "Session", style: .plain) { [weak self] in
            if let key { self?.go(.item(key, .session)) } else { self?.data.agentIndex.reveal(card: c.id) }
        }
        let label = "\(c.name), \(c.repo), \(c.liveTerminals) terminals" + (key.map { ", item \($0)" } ?? ", unlinked")
        let row = TableRow(table, cells: cells, trailing: [open], height: 40, label: label) { [weak self] in
            if let key { self?.go(.item(key, .overview)) } else { self?.data.agentIndex.reveal(card: c.id) }
        }
        let hasAgent = key.flatMap { data.agentIndex.agent($0) } != nil
        commands.attach(row) { RowMenu.session(card: c, key: key, checkout: co, hasAgent: hasAgent, caps: $0) }
        return row
    }

    private func tone(_ s: AgentSession.Phase) -> Tone { s == .waiting ? .waiting : s == .working ? .working : .done }

    private func waitingCard(_ key: String, _ a: AgentSession) -> NSView {
        let title = data.projectStore.item(key: key)?.2.title ?? ""
        let c = Card(border: Palette.warn.withAlphaComponent(0.55))
        let link = ActionButton("\(key) · \(title)", style: .link) { [weak self] in self?.go(.item(key, .session)) }
        link.truncates()
        c.add(NSStackView(h: [Pill(Tone(a.phase), text: a.label()), link, Chiplet(a.repo.isEmpty ? a.agent.rawValue : a.repo, symbol: "folder", mono: true),
                              NSTextField.text("since \(relativeTime(a.since))", size: 12, color: Palette.dim), Spacer()], spacing: 8))
        loadTail(key)
        let lines = tails[key].map { Array($0.suffix(10)) } ?? [a.message ?? "Reading the terminal…"]
        c.add(TermView(lines: lines, height: 130))
        c.add(replyRow(key))
        return c
    }

    private func loadTail(_ key: String) {
        guard -(tailAt[key] ?? .distantPast).timeIntervalSinceNow > 5 else { return }
        tailAt[key] = Date()
        data.agentIndex.tail(key) { [weak self] lines in
            guard let self, !lines.isEmpty, lines != self.tails[key] else { return }
            self.tails[key] = lines
            if !self.isEditing { self.reload() }
        }
    }

    private func replyRow(_ key: String) -> NSView {
        let f = NSTextField()
        f.placeholderString = "Send to the session…"
        f.setAccessibilityLabel("Reply to the session of \(key)")
        f.stringValue = replies[key]?.stringValue ?? ""
        f.identifier = NSUserInterfaceItemIdentifier(key)
        f.target = self
        f.action = #selector(sendReply(_:))
        replies[key] = f
        let b = ActionButton("Send", style: .primary) { [weak self, weak f] in if let f { self?.sendReply(f) } }
        if sending.contains(key) { b.busy("Sending…") }
        return NSStackView(h: [f, b], spacing: 6)
    }

    @objc private func sendReply(_ f: NSTextField) {
        guard let key = f.identifier?.rawValue else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending.contains(key) else { return }
        sending.insert(key)
        reload()
        data.agentIndex.send(key, text: text) { [weak self] err in
            guard let self else { return }
            self.sending.remove(key)
            if let err { self.note = (.bad, "Could not send to \(key): \(err.message)") } else {
                self.replies[key]?.stringValue = ""
                self.note = nil
                self.tailAt[key] = nil
            }
            self.reload()
        }
    }

    private func eventRow(_ e: OrcaEvent) -> NSView {
        let tone = Tone(e.phase)
        let key = Chiplet(e.key, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(e.key, .session)) }
        let text = NSTextField.text(e.text, size: 12.5, lines: 1)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return Row([Glyph(tone, size: 12), fixed(key, 124), fixed(NSTextField.text(e.repo, size: 12, color: Palette.dim, mono: true), 130),
                    text, Spacer(), NSTextField.text(relativeTime(e.at), size: 11.5, color: Palette.dim)],
                   height: 34, label: "\(e.key): \(e.text), \(relativeTime(e.at))") { [weak self] in self?.go(.item(e.key, .session)) }
    }
}

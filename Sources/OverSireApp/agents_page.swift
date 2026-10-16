import AppKit

// The Orca agents and worktrees: agents that need input first, then all worktrees, then the activity.
final class AgentsPage: Page {
    private var tails: [String: [String]] = [:]
    private var tailAt: [String: Date] = [:]
    private var replies: [String: NSTextField] = [:]
    private var note: (Tone, String)?

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
        guard idx.ready != nil else {
            col.addFull(Banner(.idle, title: "Orca is off or not installed.", body: "Turn on Orca to see sessions and worktrees here.",
                               actions: [ActionButton("Orca settings") { [weak self] in self?.go(.settings(.orca)) }]))
            return
        }
        if let note { col.addFull(Banner(note.0, title: note.1)) }

        let waiting = idx.agents.filter { $0.value.phase == .waiting }.sorted { $0.value.since < $1.value.since }
        for (key, a) in waiting { col.addFull(waitingCard(key, a)) }

        col.addFull(SectionTitle("Worktrees", count: idx.cards.count))
        let list = ListCard()
        list.add(Row([head("Worktree", 200), head("Repo", 130), head("Branch", 170), head("Session", 130),
                      head("Terms", 44), head("Item", 124), head("CI", 30), Spacer()], height: 28))
        for c in idx.cards.sorted(by: { $0.lastActivity > $1.lastActivity }) { list.add(cardRow(c)) }
        if idx.cards.isEmpty { list.add(EmptyNote(idx.lastError == nil ? "Orca has no worktrees." : "OverSire could not read Orca.", symbol: "circle.dashed")) }
        col.addFull(list)

        col.addFull(SectionTitle("Orca activity"))
        let feed = ListCard()
        for e in idx.feed.events.prefix(30) { feed.add(eventRow(e)) }
        if feed.isEmpty { feed.add(EmptyNote("No session changed state since OverSire started.", symbol: "clock")) }
        col.addFull(feed)
    }

    private func head(_ s: String, _ w: CGFloat) -> NSView {
        let t = NSTextField.text(s, size: 11.5, weight: .semibold, color: Palette.dim)
        t.widthAnchor.constraint(equalToConstant: w).isActive = true
        return t
    }

    private func fixed(_ v: NSView, _ w: CGFloat) -> NSView {
        let box = NSStackView(h: [v, Spacer()], spacing: 0)
        box.widthAnchor.constraint(equalToConstant: w).isActive = true
        return box
    }

    private func cardKey(_ c: OrcaCard) -> String? {
        data.agentIndex.agents.first { $0.value.card == c.id }?.key
            ?? data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }?.key
            ?? WorkstreamIndex.key(in: c.name, known: Set(data.projectStore.tracked.map { $0.identifier.uppercased() }), whole: true)
    }

    private func cardRow(_ c: OrcaCard) -> NSView {
        let key = cardKey(c)
        let co = data.workstreams.checkouts.first { $0.cardId == c.id || $0.path == c.path }
        let agent: NSView
        if let key, let a = data.agentIndex.agent(key), a.card == c.id {
            agent = Pill(Tone(a.phase), text: a.label())
        } else if let g = c.agents.min(by: { rank($0.state) < rank($1.state) }) {
            agent = Pill(tone(g.state))
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
        let views: [NSView] = [
            fixed(name, 200), fixed(NSTextField.text(c.repo, size: 12, color: Palette.mut), 130), fixed(branch, 170),
            fixed(agent, 130), fixed(NSTextField.text("\(c.liveTerminals)", size: 12, color: Palette.mut), 44),
            fixed(item, 124), fixed(ci, 30), Spacer(),
            ActionButton(key == nil ? "Open in Orca" : "Session", style: .plain) { [weak self] in
                if let key { self?.go(.item(key, .session)) } else { self?.data.agentIndex.reveal(card: c.id) }
            },
        ]
        let label = "\(c.name), \(c.repo), \(c.liveTerminals) terminals" + (key.map { ", item \($0)" } ?? ", unlinked")
        return Row(views, height: 40, label: label) { [weak self] in
            if let key { self?.go(.item(key, .overview)) } else { self?.data.agentIndex.reveal(card: c.id) }
        }
    }

    private func rank(_ s: OrcaAgent.State) -> Int { s == .waiting ? 0 : s == .working ? 1 : 2 }
    private func tone(_ s: OrcaAgent.State) -> Tone { s == .waiting ? .waiting : s == .working ? .working : .done }

    private func waitingCard(_ key: String, _ a: ItemAgent) -> NSView {
        let title = data.projectStore.item(key: key)?.2.title ?? ""
        let c = Card(border: Palette.warn.withAlphaComponent(0.55))
        let link = ActionButton("\(key) · \(title)", style: .link) { [weak self] in self?.go(.item(key, .session)) }
        c.add(NSStackView(h: [Pill(Tone(a.phase), text: a.label()), link, Chiplet(a.repo.isEmpty ? a.type : a.repo, symbol: "folder", mono: true),
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
        return NSStackView(h: [f, ActionButton("Send", style: .primary) { [weak self, weak f] in if let f { self?.sendReply(f) } }], spacing: 6)
    }

    @objc private func sendReply(_ f: NSTextField) {
        guard let key = f.identifier?.rawValue else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        data.agentIndex.send(key, text: text) { [weak self] err in
            guard let self else { return }
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

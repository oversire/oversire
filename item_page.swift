import Cocoa

// A chip that opens a menu of choices, for status, priority and the like.
final class MenuChip: Chiplet {
    private var actions: [MenuAction] = []

    init(_ text: String, symbol: String? = nil, color: NSColor = Palette.fg, choices: @escaping () -> [MenuAction]) {
        super.init(text, symbol: symbol, color: color)
        onClick = { [weak self] in
            guard let self else { return }
            self.actions = choices()
            let m = NSMenu()
            self.actions.forEach { m.addItem($0.item) }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.height + 3), in: self)
        }
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// The page of one work item: its workstream, session, sub-items and activity, with the properties at the side.
final class ItemPage: Page, NSTextFieldDelegate {
    private enum Source: String, CaseIterable { case all = "All", plane = "Plane", github = "GitHub", orca = "Orca", oversire = "OverSire" }

    private let markdown = MarkdownView(width: 600)
    private var markdownHeight: NSLayoutConstraint?
    private var timeline: [ActivityEntry]?
    private var tail: [String] = []
    private var tailAt = Date.distantPast
    private var saving: String?
    private var note: (Tone, String)?
    private var activitySource = Source.all
    private var replyField: NSTextField?
    private var commentField: NSTextField?
    private var askField: NSTextField?
    private var asking = false

    private var key: String { if case .item(let k, _) = route { return k }; return "" }
    private var tab: Route.ItemTab { if case .item(_, let t) = route { return t }; return .overview }

    override func viewDidLoad() {
        markdown.translatesAutoresizingMaskIntoConstraints = true
        markdown.onHeight = { [weak self] h in self?.markdownHeight?.constant = max(24, h) }
        super.viewDidLoad()
    }

    override func show(_ r: Route) {
        if case .item(let k, let t) = r, k != key || t != tab { if k != key { timeline = nil; tail = [] }; tailAt = .distantPast }
        super.show(r)
    }

    override var isEditing: Bool {
        super.isEditing || !(replyField?.stringValue.isEmpty ?? true) || !(commentField?.stringValue.isEmpty ?? true) || !(askField?.stringValue.isEmpty ?? true)
    }

    override func build(_ col: NSStackView) {
        let store = data.projectStore
        guard let (pk, snap, item) = store.item(key: key) else {
            col.addFull(PageHeader(key, caption: "Work item"))
            col.addFull(EmptyNote(store.snapshots.isEmpty ? "Loading projects…" : "OverSire has no item \(key). It may be in a project that OverSire does not track, or it was deleted.",
                                  symbol: "questionmark.square.dashed"))
            return
        }
        let stream = data.workstreams.stream(key)
        loadData(item: item, stream: stream)

        let main = NSStackView(v: [], spacing: 14)
        main.addFull(head(snap: snap, item: item, stream: stream))
        if let note { main.addFull(Banner(note.0, title: note.1)) }
        let prog = snap.progress(of: item.id)
        let tabs = Route.ItemTab.allCases
        let strip = TabStrip(["Overview", "Session", prog.total > 0 ? "Sub-items \(prog.done)/\(prog.total)" : "Sub-items", "Activity"],
                             selected: tabs.firstIndex(of: tab) ?? 0)
        strip.onSelect = { [weak self] i in guard let self else { return }; self.go(.item(self.key, tabs[i])) }
        main.addArrangedSubview(strip)
        switch tab {
        case .overview: overview(main, pk: pk, snap: snap, item: item, stream: stream)
        case .session: session(main, stream: stream)
        case .subitems: subItems(main, snap: snap, item: item, progress: prog)
        case .activity: activity(main, item: item, stream: stream)
        }
        let side = NSStackView(v: [], spacing: 0)
        side.addFull(properties(snap: snap, item: item, stream: stream))
        for s in [main, side] {
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            s.addArrangedSubview(fill)
        }
        let two = NSStackView(h: [main, side], spacing: 18, align: .top)
        col.addFull(two)
        side.widthAnchor.constraint(equalToConstant: 270).isActive = true
    }

    private func loadData(item: ProjectItem, stream: Workstream?) {
        if timeline == nil {
            data.projectStore.timeline(itemId: item.id) { [weak self] e in
                guard let self, self.key == item.key else { return }
                self.timeline = e
                if self.tab == .activity { self.reload() }
            }
        }
        if stream?.agent != nil, -tailAt.timeIntervalSinceNow > 5 {
            tailAt = Date()
            data.agentIndex.tail(key, lines: tab == .session ? 60 : 14) { [weak self] lines in
                guard let self, lines != self.tail else { return }
                self.tail = lines
                if !self.isEditing { self.reload() }
            }
        }
    }

    // MARK: Head and properties

    private func head(snap: ProjectSnapshot, item: ProjectItem, stream: Workstream?) -> NSView {
        let project = Chiplet(snap.summary.title, symbol: "folder", color: Palette.acc) { [weak self] in self?.go(.project(snap.summary.identifier)) }
        let keyLine = NSStackView(h: [NSTextField.text(item.key, size: 12, color: Palette.dim, mono: true), project, Spacer()], spacing: 8)
        var chips: [NSView] = [statusChip(snap: snap, item: item), priorityChip(item)]
        chips += item.labels.prefix(4).map { Chiplet($0, symbol: "tag") as NSView }
        if let a = stream?.agent {
            chips.append(Pill(Tone(a.phase), text: a.label()))
        } else {
            let b = ActionButton("Start in Orca", symbol: "play.fill", style: .primary)
            b.onClick = { [weak self, weak b] in
                guard let self, let b else { return }
                self.data.agentIndex.start(item, snap: snap, anchor: b)
            }
            chips.append(b)
        }
        if let saving { chips.append(NSTextField.text("Saving \(saving)…", size: 12, color: Palette.dim)) }
        return NSStackView(v: [keyLine, NSTextField.text(item.title, size: 22, weight: .semibold, lines: 3),
                               NSStackView(h: chips + [Spacer()], spacing: 6)], spacing: 7)
    }

    private func statusChip(snap: ProjectSnapshot, item: ProjectItem) -> NSView {
        let opt = snap.option(item.statusOptionId)
        return MenuChip(opt?.name ?? "No status", symbol: "circle.dotted") { [weak self] in
            snap.statusOptions.map { o in
                let a = MenuAction(o.name) { self?.save("status", ["state": o.id]) }
                a.item.state = o.id == item.statusOptionId ? .on : .off
                return a
            }
        }
    }

    private func priorityChip(_ item: ProjectItem) -> NSView {
        let cur = item.fields["Priority"] ?? "None"
        return MenuChip(cur == "None" ? "No priority" : cur, symbol: "flag") { [weak self] in
            PlaneClient.priorities.map { p in
                let a = MenuAction(p.name) { self?.save("priority", ["priority": p.id]) }
                a.item.state = p.name == cur ? .on : .off
                return a
            }
        }
    }

    private func save(_ what: String, _ fields: [String: Any]) {
        guard let (_, _, item) = data.projectStore.item(key: key) else { return }
        saving = what
        note = nil
        reload()
        data.projectStore.update(itemId: item.id, fields: fields, failure: "Could not change the \(what)") { [weak self] ok in
            guard let self else { return }
            self.saving = nil
            if !ok { self.note = (.bad, self.data.projectStore.lastError ?? "Plane did not take the change.") }
            self.reload()
        }
    }

    private func properties(snap: ProjectSnapshot, item: ProjectItem, stream: Workstream?) -> NSView {
        let c = Card(padding: 14, spacing: 9)
        func line(_ name: String, _ value: NSView) {
            let n = NSTextField.text(name, size: 12, color: Palette.dim)
            n.widthAnchor.constraint(equalToConstant: 76).isActive = true
            value.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            c.add(NSStackView(h: [n, value, Spacer()], spacing: 6, align: value is Chiplet ? .centerY : .firstBaseline))
        }
        func text(_ s: String, mono: Bool = false) -> NSView { NSTextField.text(s, size: 12.5, lines: 2, mono: mono) }
        line("Status", text(snap.statusName(item.statusOptionId) ?? "None"))
        line("Priority", text(item.fields["Priority"] ?? "None"))
        line("Assignees", text(item.assignees.isEmpty ? "—" : item.assignees.joined(separator: ", ")))
        line("Labels", text(item.labels.isEmpty ? "—" : item.labels.joined(separator: ", ")))
        line("Project", Chiplet(snap.summary.title, color: Palette.acc) { [weak self] in self?.go(.project(snap.summary.identifier)) })
        let co = stream?.checkouts.first { !$0.branch.isEmpty } ?? stream?.checkouts.first
        line("Checkout", text(co.map { ($0.path as NSString).lastPathComponent } ?? "—", mono: true))
        line("Branch", text(co?.branch.isEmpty == false ? co!.branch : "—", mono: true))
        line("PR", text(stream?.prs.first.map { "#\($0.pr.number) \($0.pr.isDraft ? "draft" : $0.pr.state.lowercased())" } ?? "—"))
        line("Updated", text(relativeTime(item.activityAt)))
        let inQueue = data.queue.contains(key)
        let buttons: [NSView] = [
            ActionButton(inQueue ? "In the queue" : "Add to queue", symbol: "text.line.first.and.arrowtriangle.forward") { [weak self] in
                guard let self else { return }
                if inQueue { self.go(.queue) } else { self.data.queue.add(item, snap: snap) }
            },
            ActionButton("Copy for agent", symbol: "doc.on.doc") { [weak self] in self?.data.projectStore.copyForAgent(item.id) },
            ActionButton("Copy oversire link", symbol: "link") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Route.item(self.key, .overview).url.absoluteString, forType: .string)
            },
            ActionButton("Open in Plane", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(URL(string: item.url)!) },
        ]
        for b in buttons { c.add(b) }
        return c
    }

    // MARK: Overview

    private func overview(_ main: NSStackView, pk: String, snap: ProjectSnapshot, item: ProjectItem, stream: Workstream?) {
        if let s = stream, s.agent != nil || !s.runs.isEmpty || !s.checkouts.isEmpty {
            main.addFull(workstream(s, snap: snap, item: item))
        } else {
            let start = ActionButton("Start in Orca", symbol: "play.fill", style: .primary)
            start.onClick = { [weak self, weak start] in
                guard let self, let start else { return }
                self.data.agentIndex.start(item, snap: snap, anchor: start)
            }
            main.addFull(Banner(.idle, title: "No session works on this item.",
                                body: "Start it in Orca now, or add it to the queue of \(snap.summary.title).",
                                actions: [start, ActionButton("Add to queue") { [weak self] in self?.data.queue.add(item, snap: snap) }]))
        }
        let d = Card(title: "Description")
        let body = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            d.add(NSTextField.text("No description.", size: 12.5, color: Palette.dim))
        } else {
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            markdown.removeFromSuperview()
            holder.addSubview(markdown)
            markdown.autoresizingMask = [.width, .height]
            markdown.frame = holder.bounds
            let h = holder.heightAnchor.constraint(equalToConstant: max(24, markdown.contentHeight))
            h.isActive = true
            markdownHeight = h
            d.add(holder)
            data.projectStore.resolveImages(body, projectKey: pk) { [weak self] out in self?.markdown.show(out, mode: .rendered) }
        }
        main.addFull(d)
    }

    private func workstream(_ s: Workstream, snap: ProjectSnapshot, item: ProjectItem) -> NSView {
        var trailing: [NSView] = []
        if let a = s.agent {
            trailing.append(ActionButton("Open in Orca", symbol: "terminal") { [weak self] in self?.data.agentIndex.reveal(self?.key ?? "") })
            if a.phase == .failed { trailing.append(ActionButton("Dismiss") { [weak self] in self?.data.agentIndex.clearFailure(self?.key ?? "") }) }
        }
        let c = Card(title: "Workstream", trailing: trailing, spacing: 12)
        var chips: [NSView] = []
        for co in s.checkouts.prefix(3) {
            chips.append(Chiplet((co.path as NSString).lastPathComponent, symbol: "folder", mono: true))
            if !co.branch.isEmpty { chips.append(Chiplet(co.branch, symbol: "arrow.triangle.branch", mono: true)) }
        }
        if let a = s.agent { chips.append(Chiplet("\(a.type)\(a.repo.isEmpty ? "" : " · " + a.repo)", symbol: "cpu")) }
        if !chips.isEmpty { c.add(NSStackView(h: chips + [Spacer()], spacing: 6)) }

        let left = NSStackView(v: [], spacing: 8)
        if let a = s.agent {
            left.addFull(NSStackView(h: [NSTextField.text("Session", size: 12.5, weight: .semibold), Pill(Tone(a.phase), text: a.label()), Spacer()], spacing: 6))
            let lines = tail.isEmpty ? [a.message ?? "Reading the terminal…"] : Array(tail.suffix(14))
            left.addFull(TermView(lines: lines, height: 150))
            if a.phase != .done && a.phase != .failed { left.addFull(replyRow()) }
        }
        let right = NSStackView(v: [], spacing: 8)
        right.addFull(NSStackView(h: [NSTextField.text("CI on this work", size: 12.5, weight: .semibold),
                                      NSTextField.text("matched by branch, commit or title", size: 11.5, color: Palette.dim), Spacer()], spacing: 6))
        let runs = ListCard()
        for r in s.runs.prefix(5) { runs.add(RunLine(repo: r.repo, run: r.run, data: data) { [weak self] in self?.go($0) }) }
        if runs.isEmpty { runs.add(EmptyNote("No runs yet.", symbol: "circle.dashed")) }
        right.addFull(runs)
        if s.agent != nil, s.ci?.word == Tone.bad.word, s.agent?.phase != .done {
            right.addFull(NSStackView(h: [Glyph("eye", color: Palette.dim, size: 12),
                                          NSTextField.text("The session works on this branch. It usually sees the failure and fixes it.", size: 11.5, color: Palette.dim, lines: 2)], spacing: 5))
        }
        for p in s.prs.prefix(2) {
            right.addFull(NSStackView(h: [NSTextField.text("Pull request", size: 12.5, weight: .semibold),
                                          Chiplet("#\(p.pr.number) \(p.pr.isDraft ? "draft" : p.pr.state.lowercased())", symbol: "arrow.triangle.pull") {
                                              NSWorkspace.shared.open(URL(string: p.pr.url)!) }, Spacer()], spacing: 6))
        }
        let wb = AGENTS.writeBack
        right.addFull(NSTextField.text("On Plane", size: 12.5, weight: .semibold))
        var onPlane: [NSView] = []
        if !wb.enabled {
            onPlane.append(Chiplet("Write-back is off"))
        } else {
            if wb.links { onPlane.append(Chiplet("links", symbol: "link")) }
            if wb.labels { onPlane.append(Chiplet("session:* label", symbol: "tag")) }
            if wb.block { onPlane.append(Chiplet("OverSire block", symbol: "text.append")) }
        }
        onPlane.append(Chiplet("Edit…", color: Palette.acc) { [weak self] in self?.go(.settings(.writeback)) })
        onPlane.append(Spacer())
        right.addFull(NSStackView(h: onPlane, spacing: 6))

        if s.agent == nil {
            c.add(right)
        } else {
            let two = NSStackView(h: [left, right], spacing: 14, align: .top)
            two.distribution = .fillEqually
            c.add(two)
        }
        return c
    }

    private func replyRow() -> NSView {
        let f = NSTextField()
        f.placeholderString = "Send to the session…"
        f.setAccessibilityLabel("Reply to the session")
        f.delegate = self
        f.stringValue = replyField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendReply)
        replyField = f
        return NSStackView(h: [f, ActionButton("Send", style: .primary) { [weak self] in self?.sendReply() }], spacing: 6)
    }

    @objc private func sendReply() {
        guard let f = replyField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        data.agentIndex.send(key, text: text) { [weak self] err in
            guard let self else { return }
            if let err { self.note = (.bad, "Could not send: \(err.message)") } else { self.replyField?.stringValue = ""; self.note = nil; self.tailAt = .distantPast }
            self.reload()
        }
    }

    // MARK: Session

    private func session(_ main: NSStackView, stream: Workstream?) {
        if let a = stream?.agent {
            let c = Card(title: "Terminal", trailing: [ActionButton("Open in Orca", symbol: "terminal") { [weak self] in self?.data.agentIndex.reveal(self?.key ?? "") }])
            c.add(NSStackView(h: [Pill(Tone(a.phase), text: a.label()), Chiplet(a.type, symbol: "cpu"),
                                  NSTextField.text("since \(relativeTime(a.since))", size: 12, color: Palette.dim), Spacer()], spacing: 6))
            c.add(TermView(lines: tail.isEmpty ? ["Reading the terminal…"] : tail, height: 300))
            if a.phase != .done && a.phase != .failed { c.add(replyRow()) }
            main.addFull(c)
        } else {
            main.addFull(Banner(.idle, title: "No Orca session yet.", body: "Start the item in Orca to see its session here."))
        }
        main.addFull(summaryCard(hasAgent: stream?.agent != nil))
        if stream?.agent != nil { main.addFull(askCard()) }
    }

    private func summaryCard(hasAgent: Bool) -> NSView {
        let notes = data.sessions
        let k = key
        let busy = notes.busy.contains(k.uppercased())
        let summary = notes.summary(k)
        let sum = ActionButton(busy ? "Summarizing…" : summary == nil ? "Summarize" : "Summarize again", symbol: "sparkles") { [weak self] in
            notes.summarize(k) { s in
                guard let self, s == nil else { return }
                self.note = (.warning, "No summary. AI is off, or OverSire found no transcript.")
                self.reload()
            }
        }
        sum.isEnabled = !busy && hasAgent && AI_CFG.enabled && AI_CFG.sessionSummary
        let copy = ActionButton("Copy hand-off", symbol: "doc.on.doc") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(notes.handoff(k), forType: .string)
            self?.note = (.ok, "The hand-off note is on the clipboard.")
            self?.reload()
        }
        let c = Card(title: "Summary", trailing: [copy, sum])
        guard let s = summary else {
            let why = !AI_CFG.enabled ? "Turn on AI in Settings › AI to summarize sessions."
                : !AI_CFG.sessionSummary ? "Session summaries are off in Settings › AI."
                : "No summary yet. OverSire writes one when the session ends" + (AGENTS.writeBack.sessionComment ? ", and posts it as one Plane comment." : ".")
            c.add(EmptyNote(why, symbol: "sparkles"))
            return c
        }
        for (title, list) in [("Done", s.done), ("Files", s.files), ("Decisions", s.decisions), ("Open questions", s.questions)] where !list.isEmpty {
            c.add(NSTextField.text(title, size: 12.5, weight: .semibold))
            for l in list {
                c.add(NSStackView(h: [NSTextField.text("•", color: Palette.dim),
                                      NSTextField.text(l, size: 12.5, color: Palette.mut, lines: 3, mono: title == "Files")], spacing: 6, align: .top))
            }
        }
        c.add(NSTextField.text("Updated \(relativeTime(s.at))", size: 11.5, color: Palette.dim))
        return c
    }

    private func askCard() -> NSView {
        let c = Card(title: "Ask about this session")
        for qa in data.sessions.answers[key.uppercased()] ?? [] {
            c.add(NSTextField.text(qa.q, size: 12.5, weight: .semibold))
            c.add(NSTextField.text(qa.a, size: 12.5, color: Palette.mut, lines: 12))
        }
        let f = NSTextField()
        f.placeholderString = AI_CFG.enabled ? "Why did the session change the config?" : "Turn on AI in Settings › AI to ask."
        f.isEnabled = AI_CFG.enabled
        f.setAccessibilityLabel("Question about the session")
        f.stringValue = askField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendAsk)
        askField = f
        let b = ActionButton(asking ? "Asking…" : "Ask", style: .primary) { [weak self] in self?.sendAsk() }
        b.isEnabled = AI_CFG.enabled && !asking
        c.add(NSStackView(h: [f, b], spacing: 6))
        return c
    }

    @objc private func sendAsk() {
        guard let f = askField, !asking else { return }
        let q = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        asking = true
        reload()
        data.sessions.ask(key, question: q) { [weak self] a in
            guard let self else { return }
            self.asking = false
            if a == nil { self.note = (.bad, "AI did not answer. Check Settings › AI.") } else { self.askField?.stringValue = "" }
            self.reload()
        }
    }

    // MARK: Sub-items

    private func subItems(_ main: NSStackView, snap: ProjectSnapshot, item: ProjectItem, progress: (done: Int, total: Int)) {
        let kids = snap.children(of: item.id)
        let list = ListCard()
        if progress.total > 0 {
            list.add(Row([ProgressRing(done: progress.done, total: progress.total).sized(16),
                          NSTextField.text("\(progress.done) of \(progress.total) done", size: 13, weight: .semibold), Spacer()], height: 36))
        }
        for k in kids { list.add(ItemLine(k, snap: snap, stream: data.workstreams.stream(k.key)) { [weak self] in self?.go($0) }) }
        if progress.total > kids.count {
            list.add(Row([NSTextField.text("\(progress.total - kids.count) more sub-items in Plane", size: 12, color: Palette.acc)], height: 32) {
                NSWorkspace.shared.open(URL(string: item.url)!) })
        }
        if list.isEmpty { list.add(EmptyNote("No sub-items.", symbol: "list.bullet.indent")) }
        main.addFull(list)
    }

    // MARK: Activity

    private struct Event { let source: Source; let text: String; let at: Date; var body: String? = nil; var route: Route? = nil }

    private func events(item: ProjectItem, stream: Workstream?) -> [Event] {
        var out: [Event] = []
        for e in timeline ?? [] {
            if case .comments(_, let c) = e.change {
                out.append(Event(source: .plane, text: "\(c.author ?? "Someone") commented", at: c.createdAt, body: c.body))
            } else {
                out.append(Event(source: .plane, text: (e.actor.map { "\($0): " } ?? "") + e.text, at: e.at))
            }
        }
        for r in stream?.runs.prefix(20) ?? [] {
            let t = Tone(r.run)
            out.append(Event(source: .github, text: "\(r.run.workflowName ?? r.run.name) #\(r.run.number) \(t.word.lowercased()) on \(r.run.headBranch)",
                             at: lastActivity(r.run), route: .run(repo: r.repo, id: r.run.id)))
        }
        for p in stream?.prs ?? [] {
            out.append(Event(source: .github, text: "PR #\(p.pr.number) \(p.pr.title)", at: parseISO(p.pr.updatedAt) ?? .distantPast))
        }
        if let a = stream?.agent {
            out.append(Event(source: .orca, text: "Session: \(a.label())" + (a.message.map { " · \($0)" } ?? ""), at: a.since))
        }
        for j in data.aiChecks.checks where j.key == key {
            out.append(Event(source: .oversire, text: "AI check: \(j.verdict.word) · \(j.state)", at: j.at, body: j.evidence.joined(separator: "\n")))
        }
        return out.sorted { $0.at > $1.at }
    }

    private func activity(_ main: NSStackView, item: ProjectItem, stream: Workstream?) {
        let all = events(item: item, stream: stream)
        main.addFull(NSStackView(h: Source.allCases.map { s in
            ToggleChip(s.rawValue, on: activitySource == s) { [weak self] in self?.activitySource = s; self?.reload() } as NSView
        } + [Spacer()], spacing: 6))

        let f = NSTextField()
        f.placeholderString = "Write a comment (Markdown). Return sends."
        f.setAccessibilityLabel("Comment")
        f.stringValue = commentField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendComment)
        commentField = f
        main.addFull(NSStackView(h: [f, ActionButton("Comment") { [weak self] in self?.sendComment() }], spacing: 6))

        let list = ListCard()
        if timeline == nil { list.add(EmptyNote("Loading the activity…", symbol: "hourglass")) }
        for e in all where activitySource == .all || e.source == activitySource {
            var col: [NSView] = [NSTextField.text(e.text, size: 12.5, lines: 2)]
            if let b = e.body?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
                let t = NSTextField(labelWithAttributedString: ItemWindow.inline(b, font: .systemFont(ofSize: 12.5)))
                t.maximumNumberOfLines = 12
                t.lineBreakMode = .byWordWrapping
                t.isSelectable = true
                t.translatesAutoresizingMaskIntoConstraints = false
                t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                t.preferredMaxLayoutWidth = 0
                col.append(t)
            }
            let text = NSStackView(v: col, spacing: 4)
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            let src = Chiplet(e.source.rawValue)
            let srcBox = NSView()
            srcBox.translatesAutoresizingMaskIntoConstraints = false
            srcBox.addSubview(src)
            NSLayoutConstraint.activate([
                srcBox.widthAnchor.constraint(equalToConstant: 64), srcBox.heightAnchor.constraint(equalTo: src.heightAnchor),
                src.leadingAnchor.constraint(equalTo: srcBox.leadingAnchor), src.topAnchor.constraint(equalTo: srcBox.topAnchor),
            ])
            let route = e.route
            let row = Row([srcBox, text, NSTextField.text(relativeTime(e.at), size: 11.5, color: Palette.dim)], height: 34,
                          label: "\(e.source.rawValue): \(e.text)", onClick: route.map { r in { [weak self] in self?.go(r) } })
            row.stack.alignment = .top
            list.add(row)
        }
        if list.isEmpty { list.add(EmptyNote("No activity.")) }
        main.addFull(list)
    }

    @objc private func sendComment() {
        guard let f = commentField, let (_, _, item) = data.projectStore.item(key: key) else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        data.projectStore.comment(itemId: item.id, body: text) { [weak self] ok in
            guard let self else { return }
            if ok { self.commentField?.stringValue = ""; self.timeline = nil; self.note = nil } else { self.note = (.bad, self.data.projectStore.lastError ?? "Plane did not take the comment.") }
            self.reload()
        }
    }
}

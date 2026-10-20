import AppKit
import OverSireCore
import OverSireAI

extension Tone {
    init(_ s: SessionState) {
        switch s {
        case .closed: self = Tone(symbol: "xmark.circle", color: Palette.dim, word: s.label)
        case .needsInput: self = Tone(symbol: "exclamationmark.bubble.fill", color: Palette.warn, word: s.label)
        case .blocked: self = Tone(symbol: "hand.raised.fill", color: Palette.bad, word: s.label)
        case .background: self = Tone(symbol: "terminal.fill", color: Palette.run, word: s.label)
        case .done: self = Tone(symbol: "checkmark.seal.fill", color: Palette.ok, word: s.label)
        case .working: self = Tone(symbol: "bolt.circle.fill", color: Palette.run, word: s.label)
        case .longCommand: self = Tone(symbol: "hourglass", color: Palette.acc, word: s.label)
        case .quiet: self = Tone(symbol: "moon.zzz.fill", color: Palette.intake, word: s.label)
        }
    }

    init(_ s: StatusReply.State) {
        switch s {
        case .working: self = .working
        case .done: self = .done
        case .unfinished: self = Tone(symbol: "circle.lefthalf.filled", color: Palette.warn, word: "Not finished")
        case .blocked: self = Tone(SessionState.blocked)
        case .stuck: self = .warning
        }
    }
}

extension AgentIndex {
    /// The pill text of a session: "Quiet 12m", "Background 27m", "Session done".
    func pillText(_ key: String) -> String? {
        guard let st = state(key), let a = agent(key) else { return nil }
        let w = watch(key)
        let same = w.map { now().timeIntervalSince($0.changedAt) } ?? 0
        switch st {
        case .working: return "Working " + AgentSession.minutes(now().timeIntervalSince(a.since))
        case .quiet: return "Quiet " + AgentSession.minutes(same)
        case .longCommand: return "Long command " + AgentSession.minutes(same)
        case .background: return "Background " + AgentSession.minutes(now().timeIntervalSince(a.since))
        default: return st.label
        }
    }

    /// What the screen did, in words: "12 min ago", "1 shell runs", "screen same 41 min · counter moves".
    func screenText(_ key: String) -> String {
        guard let st = state(key), let a = agent(key) else { return "—" }
        let w = watch(key)
        let same = w.map { now().timeIntervalSince($0.changedAt) } ?? 0
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        switch st {
        case .closed: return "no live terminal"
        case .background: let n = w?.shells ?? 1; return "\(n) shell\(n == 1 ? "" : "s") \(n == 1 ? "runs" : "run")"
        case .done, .blocked: return "done at \(clock.string(from: a.since))"
        case .longCommand: return "screen same \(Int(same / 60)) min · counter moves"
        default: return w.map { relativeAgo($0.changedAt) } ?? "not read yet"
        }
    }
}

// The "Needs you" card of the Sessions page and the Inbox: statuses to act on, Needs input and Blocked on you.
// The page keeps the card, so the open rows stay open after a rebuild.
final class NeedsYouCard: NSObject {
    weak var page: Page?
    var expanded: Set<String> = []
    // The Sessions page shows the screen and a reply field under a Needs input row.
    var inputDetail: ((String, AgentSession) -> NSView)?
    private var notes: [String: (Tone, String)] = [:]   // end id → the result of the last send
    private var sending: Set<String> = []
    private var all = false

    init(page: Page) {
        self.page = page
        if let id = UIShots.expandBlocked { expanded.insert(id) }
    }

    private var data: AppData? { page?.data }

    func waiting(_ d: AppData) -> [(String, AgentSession)] {
        d.agentIndex.agents.filter { d.agentIndex.state($0.key) == .needsInput }.sorted { $0.value.since < $1.value.since }.map { ($0.key, $0.value) }
    }

    func count(_ d: AppData) -> Int { d.statusJob.pending.count + waiting(d).count + d.statusJob.blocking.count }

    /// The "Status for all" button. It shows "Reading N…" while a read runs.
    static func refreshButton(_ d: AppData, title: String = "Status for all", keys: [String]? = nil) -> ActionButton {
        let job = d.statusJob
        let b = ActionButton(title, symbol: "arrow.clockwise") { job.refresh(keys: keys ?? job.refreshable) }
        b.toolTip = "Read the history and the screen of each session now, and write its status (⌘R)"
        if !job.reading.isEmpty { b.busy("Reading \(job.reading.count)…") }
        return b
    }

    func card() -> NSView? {
        guard let d = data else { return nil }
        let job = d.statusJob
        let checks = job.pending
        let asks = waiting(d)
        let blocked = job.blocking
        let n = checks.count + asks.count + blocked.count
        guard n > 0 else { return nil }
        var trailing: [NSView] = []
        let freeing = checks.filter(StatusJob.frees)
        if freeing.count >= 2 {
            trailing.append(ActionButton("Approve all \(freeing.count) \"free the slot\"") { job.approve(all: freeing.map(\.id)) })
        }
        trailing.append(NeedsYouCard.refreshButton(d, title: "Refresh"))
        if !(page is InboxPage) { trailing.append(ActionButton("Open in Inbox", style: .link) { [weak self] in self?.page?.go(.inbox(.agents)) }) }
        let c = Card(title: "Needs you · \(n)", trailing: trailing, padding: 10, spacing: 2,
                     fill: Palette.panel, border: Palette.intake.withAlphaComponent(0.55))
        var rows: [NSView] = checks.map(checkLine) + asks.map { inputLine($0.0, $0.1) } + blocked.map(blockedLine)
        let limit = 6
        if !all && rows.count > limit { rows = Array(rows.prefix(limit)) }
        rows.forEach(c.add)
        if n > limit {
            let more = all ? "Show less" : "\(n - limit) more · Show all"
            c.add(NSStackView(h: [ActionButton(more, style: .link) { [weak self] in self?.all.toggle(); self?.page?.reload() }, Spacer()], spacing: 0))
        }
        return c
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        page?.reload()
    }

    private func titleField(_ key: String) -> NSTextField {
        let title = NSTextField.text(data?.projectStore.item(key: key)?.item.title ?? "", size: 12.5, color: Palette.mut)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        return title
    }

    private func keyField(_ key: String) -> NSTextField {
        let f = NSTextField.text(key, size: 12, weight: .semibold, mono: true)
        f.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return f
    }

    private func moreButton(_ key: String, _ items: @escaping () -> [MenuAction]) -> ActionButton {
        let more = ActionButton("", symbol: "ellipsis")
        more.setAccessibilityLabel("More actions for \(key)")
        more.onClick = { [weak more] in
            guard let more else { return }
            let m = NSMenu()
            let list = items()
            list.forEach { m.addItem($0.item) }
            _ = withExtendedLifetime(list) { m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 3), in: more) }
        }
        return more
    }

    private func checkedText(_ key: String) -> NSView {
        guard let d = data else { return NSView() }
        if d.statusJob.reading.contains(key.uppercased()) { return NSStackView(h: [Spinner(), NSTextField.text("Reading…", size: 11.5, color: Palette.dim)], spacing: 4) }
        let t = d.statusJob.status(key).map { "read " + relativeAgo($0.at) } ?? ""
        return NSTextField.text(t, size: 11.5, color: Palette.dim)
    }

    private func wrap(_ row: NSView, _ detail: NSView) -> NSView {
        let v = NSStackView(v: [row, Padded(detail, vertical: 4, side: 28)], spacing: 0)
        v.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        return v
    }

    // MARK: Status

    func checkLine(_ st: SessionStatus) -> NSView {
        guard let d = data else { return NSView() }
        let job = d.statusJob
        let open = expanded.contains(st.id)
        let tone = Tone(st.state)
        let word = NSTextField.text(st.word, size: 12.5, weight: .medium, color: tone.color)
        word.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let frees = StatusJob.frees(st)
        let pill: Chiplet
        var buttons: [NSView]
        switch st.state {
        case .stuck:
            pill = Chiplet("Nudge", symbol: "text.bubble")
            buttons = [ActionButton("Send nudge", style: .primary) { job.approve(st.id) }, ActionButton("Hold") { job.hold(st.id) }]
        case .unfinished:
            pill = Chiplet("Not finished", symbol: "circle.lefthalf.filled")
            buttons = [ActionButton("Ask the agent", style: .primary) { job.ask(st.id) }, ActionButton("Mark as blocked on you") { job.markBlocked(st.id) }]
        default:
            pill = Chiplet(frees ? "Free slot" : "Seen", symbol: "square.dashed")
            buttons = [ActionButton("Approve", style: .primary) { job.approve(st.id) }, ActionButton("Hold") { job.hold(st.id) }]
        }
        let menu: () -> [MenuAction] = { [weak self] in
            [MenuAction("Refresh") { job.refresh(keys: [st.key]) },
             MenuAction("Open session") { self?.page?.go(.item(st.key, .session)) },
             MenuAction("Free the slot") { job.release(st.id) }]
        }
        let row = Row([Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), keyField(st.key), word, titleField(st.key), checkedText(st.key), pill]
                      + buttons + [moreButton(st.key, menu)],
                      height: 34, inset: 6, label: "\(st.key): \(st.word). \(st.reply.headline)") { [weak self] in self?.toggle(st.id) }
        row.menuItems = { menu().map(\.item) }
        guard open else { return row }
        var facts = [st.read + " " + relativeAgo(st.at)]
        if let s = st.since { facts.append("screen same for \(Int(st.at.timeIntervalSince(s) / 60)) min") }
        if st.byAI { facts.append("by AI") }
        let detail = NSStackView(v: [NSStackView(h: [NSTextField.text(facts.joined(separator: " · "), size: 11.5, color: Palette.dim), Spacer(),
                                                     ActionButton("Refresh", symbol: "arrow.clockwise", style: .link) { job.refresh(keys: [st.key]) }],
                                                 spacing: 6)], spacing: 3)
        detail.arrangedSubviews.first?.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        if !st.reply.headline.isEmpty { detail.addFull(NSTextField.text(st.reply.headline, size: 12.5, color: Palette.fg, lines: 3)) }
        for (label, list) in [("Done", st.reply.done), ("Next", st.reply.next)] where !list.isEmpty {
            detail.addFull(NSTextField.text(label, size: 11, weight: .semibold, color: Palette.dim))
            for e in list {
                detail.addFull(NSStackView(h: [NSTextField.text("•", color: Palette.dim), NSTextField.text(e, size: 12, color: Palette.mut, lines: 3)],
                                           spacing: 6, align: .top))
            }
        }
        if st.state == .stuck, !st.reply.nudge.isEmpty { detail.addFull(TermView(lines: [st.reply.nudge], height: 44)) }
        return wrap(row, detail)
    }

    // MARK: Needs input

    private func inputLine(_ key: String, _ a: AgentSession) -> NSView {
        let id = "input|" + key
        let open = expanded.contains(id)
        let tone = Tone(SessionState.needsInput)
        let ask = (a.message ?? "").replacingOccurrences(of: "\n", with: " ")
        let text = NSTextField.text(ask.isEmpty ? "The agent waits for input" : "Asks: \"\(ask.prefix(140))\"", size: 12.5, color: Palette.mut)
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let reply = ActionButton("Reply") { [weak self] in
            if self?.inputDetail == nil { self?.page?.go(.item(key, .session)) } else { self?.toggle(id) }
        }
        let menu: () -> [MenuAction] = { [weak self] in
            [MenuAction("Open session") { self?.page?.go(.item(key, .session)) },
             MenuAction("Show in Orca") { self?.data?.agentIndex.reveal(key) }]
        }
        let row = Row([Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), keyField(key),
                       NSTextField.text(tone.word, size: 12.5, weight: .medium, color: tone.color), text, Spacer(), reply,
                       ActionButton("Open") { [weak self] in self?.page?.go(.item(key, .session)) }, moreButton(key, menu)],
                      height: 34, inset: 6, label: "\(key): Needs input. \(ask.prefix(140))") { [weak self] in
            if self?.inputDetail != nil { self?.toggle(id) } else { self?.page?.go(.item(key, .session)) }
        }
        row.menuItems = { menu().map(\.item) }
        guard open, let detail = inputDetail?(key, a) else { return row }
        return wrap(row, detail)
    }

    // MARK: Blocked on you

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "manual-check": return "Manual check"
        case "secret": return "Secret"
        case "approval": return "Approval"
        case "login": return "Login"
        case "deploy": return "Deploy"
        default: return "Step"
        }
    }

    static func kindSymbol(_ kind: String) -> String {
        switch kind {
        case "manual-check": return "checklist"
        case "secret": return "key.fill"
        case "approval": return "hand.thumbsup.fill"
        case "login": return "person.badge.key.fill"
        case "deploy": return "shippingbox.fill"
        default: return "list.bullet"
        }
    }

    /// One chip for each kind, with its count: "Manual check · 7".
    static func kindChips(_ steps: [StatusReply.Step]) -> [NSView] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in steps {
            if counts[s.kind] == nil { order.append(s.kind) }
            counts[s.kind, default: 0] += 1
        }
        return order.prefix(2).map { k in
            let n = counts[k] ?? 0
            return Chiplet(n > 1 ? "\(kindLabel(k)) · \(n)" : kindLabel(k), symbol: kindSymbol(k))
        }
    }

    func blockedLine(_ e: SessionStatus) -> NSView {
        guard let d = data else { return NSView() }
        let job = d.statusJob
        let open = expanded.contains(e.id)
        let tone = Tone(SessionState.blocked)
        let steps = e.reply.needsYou
        var cells: [NSView] = [Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), keyField(e.key),
                               NSTextField.text(tone.word, size: 12.5, weight: .medium, color: tone.color), titleField(e.key)]
        cells += NeedsYouCard.kindChips(steps)
        if let b = e.reply.blockedBy.first { cells.append(Chiplet("Blocked by \(b)", symbol: "link")) }
        let since = d.agentIndex.agent(e.key)?.since ?? e.at
        cells.append(NSTextField.text(AgentSession.minutes(Date().timeIntervalSince(since)).replacingOccurrences(of: "m", with: " min"), size: 11.5,
                                      color: Palette.dim))
        let menu: () -> [MenuAction] = { [weak self] in
            [MenuAction("Refresh") { job.refresh(keys: [e.key]) },
             MenuAction("Open session") { self?.page?.go(.item(e.key, .session)) },
             MenuAction("Snooze 1 day") { job.snooze(e.id) }]
        }
        cells.append(moreButton(e.key, menu))
        let row = Row(cells, height: 34, inset: 6,
                      label: "\(e.key): Blocked on you. \(steps.count) steps, \(e.passed) pass.") { [weak self] in self?.toggle(e.id) }
        row.menuItems = { menu().map(\.item) }
        guard open else { return row }
        return wrap(row, needsYou(e))
    }

    /// The "Needs you" checklist of a blocked status, with Tell the agent, Report a failure and Snooze.
    func needsYou(_ e: SessionStatus, session: Bool = true) -> NSView {
        let detail = NSStackView(v: [], spacing: 4)
        guard let d = data else { return detail }
        let job = d.statusJob
        if !e.reply.headline.isEmpty { detail.addFull(NSTextField.text(e.reply.headline, size: 12, color: Palette.mut, lines: 2)) }
        for (i, s) in e.reply.needsYou.enumerated() {
            let box = NSButton(checkboxWithTitle: s.text, target: self, action: #selector(ticked(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(e.id)
            box.tag = i
            box.state = e.ticks.indices.contains(i) && e.ticks[i] ? .on : .off
            box.font = .systemFont(ofSize: 12.5)
            box.setAccessibilityLabel("\(NeedsYouCard.kindLabel(s.kind)): \(s.text)")
            detail.addFull(box)
        }
        let tell = ActionButton("Tell the agent: \(e.passed) of \(e.reply.needsYou.count) pass", style: .primary) { [weak self] in self?.tell(e) }
        if sending.contains(e.id) { tell.busy("Sending…") }
        var actions: [NSView] = [tell, ActionButton("Report a failure…") { [weak self] in self?.report(e) }]
        if session { actions.append(ActionButton("Open session") { [weak self] in self?.page?.go(.item(e.key, .session)) }) }
        if let found = d.projectStore.item(key: e.key), let blockedOpt = found.snap.statusOptions.first(where: { $0.category == .blocked }),
           found.item.statusOptionId != blockedOpt.id {
            actions.append(ActionButton("Set Plane to Blocked") { [weak self] in
                d.projectStore.setStatus(itemId: found.item.id, optionId: blockedOpt.id) { ok in
                    self?.notes[e.id] = ok ? (.ok, "Plane status set to Blocked.") : (.bad, "Could not set the Plane status.")
                    self?.page?.reload()
                }
            })
        }
        actions.append(ActionButton("Snooze 1 day") { job.snooze(e.id) })
        actions.append(Spacer())
        detail.addFull(NSStackView(h: actions, spacing: 6))
        if let (t, n) = notes[e.id] { detail.addFull(NSTextField.text(n, size: 11.5, color: t.color)) }
        else if let told = e.told { detail.addFull(NSTextField.text("Sent \(relativeAgo(told)). The ticks stay on this Mac.", size: 11.5, color: Palette.dim)) }
        else { detail.addFull(NSTextField.text("The ticks stay on this Mac. The button sends the list to the session.", size: 11.5, color: Palette.dim)) }
        return detail
    }

    @objc private func ticked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        data?.statusJob.toggle(id, step: sender.tag)
    }

    private func tell(_ e: SessionStatus, extra: String = "") {
        guard let job = data?.statusJob, !sending.contains(e.id) else { return }
        sending.insert(e.id)
        page?.reload()
        job.tell(e.id, extra: extra) { [weak self] err in
            self?.sending.remove(e.id)
            self?.notes[e.id] = err.map { (.bad, "Could not send to \(e.key): \($0.message)") } ?? (.ok, "Sent to the session of \(e.key).")
            self?.page?.reload()
        }
    }

    private func report(_ e: SessionStatus) {
        let a = NSAlert()
        a.messageText = "Report a failure to \(e.key)"
        a.informativeText = "Tell the agent what failed. OverSire sends it with the checklist."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        f.placeholderString = "The capture on the second display is black."
        a.accessoryView = f
        a.addButton(withTitle: "Send")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        tell(e, extra: "Failure: " + text)
    }
}

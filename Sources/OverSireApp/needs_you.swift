import AppKit
import OverSireCore

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

    init(_ v: Judgement.Verdict) { self = v == .done ? .done : v == .stuck ? .warning : .working }
}

extension AgentIndex {
    /// The state pill of a session: the SessionState after a screen read, else the runtime phase.
    func pill(_ key: String) -> Pill? {
        if let st = state(key) {
            let p = Pill(Tone(st), text: pillText(key) ?? st.label)
            p.toolTip = st.facts
            return p
        }
        return agent(key).map { Pill(Tone($0.phase), text: $0.label()) }
    }

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

// The "Needs you" card of the Sessions page and the Inbox: AI checks, Needs input and Blocked on you.
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

    func count(_ d: AppData) -> Int { d.aiChecks.pending.count + waiting(d).count + d.aiChecks.blocking.count }

    /// The "Check again" button. It shows "Checking N…" while a check runs.
    static func recheckButton(_ d: AppData, keys: [String]? = nil) -> ActionButton {
        let judge = d.aiChecks
        let b = ActionButton("Check again", symbol: "arrow.clockwise") { judge.recheck(keys: keys ?? judge.recheckable) }
        b.toolTip = "Read the screens now and check each session again (⌘R)"
        if !judge.checking.isEmpty { b.busy("Checking \(judge.checking.count)…") }
        return b
    }

    func card() -> NSView? {
        guard let d = data else { return nil }
        let judge = d.aiChecks
        let checks = judge.pending
        let asks = waiting(d)
        let blocked = judge.blocking
        let n = checks.count + asks.count + blocked.count
        guard n > 0 else { return nil }
        var trailing: [NSView] = []
        let freeing = AgentJudge.freeing(checks)
        if freeing.count >= 2 {
            trailing.append(ActionButton("Approve all \(freeing.count) \"free the slot\"") { judge.approve(all: freeing.map(\.id)) })
        }
        trailing.append(NeedsYouCard.recheckButton(d))
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
        if d.aiChecks.checking.contains(key.uppercased()) { return NSStackView(h: [Spinner(), NSTextField.text("Checking…", size: 11.5, color: Palette.dim)], spacing: 4) }
        let t = d.aiChecks.checkedAt(key).map { "checked " + relativeAgo($0) } ?? ""
        return NSTextField.text(t, size: 11.5, color: Palette.dim)
    }

    private func wrap(_ row: NSView, _ detail: NSView) -> NSView {
        let v = NSStackView(v: [row, Padded(detail, vertical: 4, side: 28)], spacing: 0)
        v.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        return v
    }

    // MARK: AI checks

    func checkLine(_ j: Judgement) -> NSView {
        guard let d = data else { return NSView() }
        let judge = d.aiChecks
        let open = expanded.contains(j.id)
        let tone = Tone(j.verdict)
        let word = NSTextField.text(j.verdict.word, size: 12.5, weight: .medium, color: tone.color)
        word.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let frees = AgentJudge.freeing([j]).count == 1
        let pill = Chiplet(j.verdict == .done ? (frees ? "Free slot" : "Seen") : "Nudge", symbol: j.verdict == .done ? "square.dashed" : "text.bubble")
        let menu: () -> [MenuAction] = { [weak self] in
            [MenuAction("Check again") { judge.recheck(keys: [j.key]) },
             MenuAction("Open session") { self?.page?.go(.item(j.key, .session)) },
             MenuAction("Free the slot") { judge.release(j.id) }]
        }
        let row = Row([Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), keyField(j.key), word, titleField(j.key), checkedText(j.key), pill,
                       ActionButton("Approve", style: .primary) { judge.approve(j.id) }, ActionButton("Hold") { judge.hold(j.id) },
                       moreButton(j.key, menu)],
                      height: 34, inset: 6, label: "\(j.key): \(j.verdict.word). \(j.action)") { [weak self] in self?.toggle(j.id) }
        row.menuItems = { menu().map(\.item) }
        guard open else { return row }
        var facts = ["Checked \(relativeAgo(j.at))"]
        if let s = j.since { facts.append("output same for \(Int(j.at.timeIntervalSince(s) / 60)) min") }
        if let t = j.ticking { facts.append(t ? "spinner counter moves" : "spinner counter does not move") }
        if j.byAI { facts.append("by AI") }
        let detail = NSStackView(v: [NSStackView(h: [NSTextField.text(facts.joined(separator: " · "), size: 11.5, color: Palette.dim), Spacer(),
                                                     ActionButton("Check again", symbol: "arrow.clockwise", style: .link) { judge.recheck(keys: [j.key]) }],
                                                 spacing: 6)]
                                 + j.evidence.map { e in
                                     NSStackView(h: [NSTextField.text("•", color: Palette.dim), NSTextField.text(e, size: 12, color: Palette.mut, lines: 3)],
                                                 spacing: 6, align: .top)
                                 }, spacing: 3)
        detail.arrangedSubviews.first?.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        detail.addFull(NSTextField.text(j.action, size: 12, color: Palette.dim, lines: 2))
        if let n = j.nudge { detail.addFull(TermView(lines: [n], height: 44)) }
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
    static func kindChips(_ e: SessionEnd) -> [NSView] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for s in e.steps {
            if counts[s.kind] == nil { order.append(s.kind) }
            counts[s.kind, default: 0] += 1
        }
        return order.prefix(2).map { k in
            let n = counts[k] ?? 0
            return Chiplet(n > 1 ? "\(kindLabel(k)) · \(n)" : kindLabel(k), symbol: kindSymbol(k))
        }
    }

    func blockedLine(_ e: SessionEnd) -> NSView {
        guard let d = data else { return NSView() }
        let judge = d.aiChecks
        let open = expanded.contains(e.id)
        let tone = Tone(SessionState.blocked)
        var cells: [NSView] = [Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), keyField(e.key),
                               NSTextField.text(tone.word, size: 12.5, weight: .medium, color: tone.color), titleField(e.key)]
        cells += NeedsYouCard.kindChips(e)
        if let b = e.blockedBy.first { cells.append(Chiplet("Blocked by \(b)", symbol: "link")) }
        if let f = e.followUpAt {
            let df = DateFormatter()
            df.dateFormat = "MMM d HH:mm"
            cells.append(Chiplet("Follow-up \(df.string(from: f))", symbol: "calendar"))
        }
        let since = d.agentIndex.agent(e.key)?.since ?? e.at
        cells.append(NSTextField.text(AgentSession.minutes(Date().timeIntervalSince(since)).replacingOccurrences(of: "m", with: " min"), size: 11.5,
                                      color: Palette.dim))
        let menu: () -> [MenuAction] = { [weak self] in
            [MenuAction("Check again") { judge.recheck(keys: [e.key]) },
             MenuAction("Open session") { self?.page?.go(.item(e.key, .session)) },
             MenuAction("Snooze 1 day") { judge.snooze(end: e.id) }]
        }
        cells.append(moreButton(e.key, menu))
        let row = Row(cells, height: 34, inset: 6,
                      label: "\(e.key): Blocked on you. \(e.steps.count) steps, \(e.passed) pass.") { [weak self] in self?.toggle(e.id) }
        row.menuItems = { menu().map(\.item) }
        guard open else { return row }

        let detail = NSStackView(v: [], spacing: 4)
        if let a = d.agentIndex.agent(e.key), let first = a.message?.components(separatedBy: "\n").first, !first.isEmpty {
            detail.addFull(NSTextField.text(SessionEnd.plain(first), size: 12, color: Palette.mut, lines: 2))
        }
        for (i, s) in e.steps.enumerated() {
            let box = NSButton(checkboxWithTitle: s.text, target: self, action: #selector(ticked(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(e.id)
            box.tag = i
            box.state = s.ticked == true ? .on : .off
            box.font = .systemFont(ofSize: 12.5)
            box.setAccessibilityLabel("\(NeedsYouCard.kindLabel(s.kind)): \(s.text)")
            detail.addFull(box)
        }
        let tell = ActionButton("Tell the agent: \(e.passed) of \(e.steps.count) pass", style: .primary) { [weak self] in self?.tell(e) }
        if sending.contains(e.id) { tell.busy("Sending…") }
        var actions: [NSView] = [tell, ActionButton("Report a failure…") { [weak self] in self?.report(e) },
                                 ActionButton("Open session") { [weak self] in self?.page?.go(.item(e.key, .session)) }]
        if let found = d.projectStore.item(key: e.key), let blockedOpt = found.snap.statusOptions.first(where: { $0.category == .blocked }),
           found.item.statusOptionId != blockedOpt.id {
            actions.append(ActionButton("Set Plane to Blocked") { [weak self] in
                d.projectStore.setStatus(itemId: found.item.id, optionId: blockedOpt.id) { ok in
                    self?.notes[e.id] = ok ? (.ok, "Plane status set to Blocked.") : (.bad, "Could not set the Plane status.")
                    self?.page?.reload()
                }
            })
        }
        actions.append(ActionButton("Snooze 1 day") { judge.snooze(end: e.id) })
        actions.append(Spacer())
        detail.addFull(NSStackView(h: actions, spacing: 6))
        if let (t, n) = notes[e.id] { detail.addFull(NSTextField.text(n, size: 11.5, color: t.color)) }
        else if let told = e.told { detail.addFull(NSTextField.text("Sent \(relativeAgo(told)). The ticks stay on this Mac.", size: 11.5, color: Palette.dim)) }
        else { detail.addFull(NSTextField.text("The ticks stay on this Mac. The button sends the list to the session.", size: 11.5, color: Palette.dim)) }
        return wrap(row, detail)
    }

    @objc private func ticked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        data?.aiChecks.toggle(end: id, step: sender.tag)
    }

    private func tell(_ e: SessionEnd, extra: String = "") {
        guard let judge = data?.aiChecks, !sending.contains(e.id) else { return }
        sending.insert(e.id)
        page?.reload()
        judge.tell(end: e.id, extra: extra) { [weak self] err in
            self?.sending.remove(e.id)
            self?.notes[e.id] = err.map { (.bad, "Could not send to \(e.key): \($0.message)") } ?? (.ok, "Sent to the session of \(e.key).")
            self?.page?.reload()
        }
    }

    private func report(_ e: SessionEnd) {
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

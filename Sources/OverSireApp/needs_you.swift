import AppKit
import OverSireCore
import OverSireAssistant
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
            let all = ActionButton("Approve all \(freeing.count) \"free the slot\"")
            all.onClick = { [weak all] in
                freeing.forEach { d.actions.click("status.approve", ["id": .string($0.id)], in: all?.window) }
            }
            trailing.append(all)
        }
        trailing.append(NeedsYouCard.refreshButton(d, title: "Refresh"))
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
            buttons = [ActionButton("Send nudge", style: .primary, action: "status.approve", ["id": .string(st.id)]),
                       ActionButton("Hold", action: "status.hold", ["id": .string(st.id)])]
        case .unfinished:
            pill = Chiplet("Not finished", symbol: "circle.lefthalf.filled")
            buttons = [ActionButton("Ask the agent", style: .primary, action: "status.ask", ["id": .string(st.id)]), ActionButton("Mark as blocked on you", action: "status.markBlocked", ["id": .string(st.id)])]
        default:
            pill = Chiplet(frees ? "Free slot" : "Seen", symbol: "square.dashed")
            buttons = [ActionButton("Approve", style: .primary, action: "status.approve", ["id": .string(st.id)]),
                       ActionButton("Hold", action: "status.hold", ["id": .string(st.id)])]
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
             MenuAction("Show in Orca") { self?.data?.actions.click("session.reveal", ["key": .string(key)], in: NSApp.keyWindow) }]
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
             MenuAction("Snooze 1 day") { self?.data?.actions.click("status.snooze", ["id": .string(e.id)], in: NSApp.keyWindow) }]
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
                d.actions.run("item.setStatus", ["key": .string(found.item.key), "status": .string(blockedOpt.id)]) { r in
                    if case .ok = r { self?.notes[e.id] = (.ok, "Plane status set to Blocked.") } else { self?.notes[e.id] = (.bad, "Could not set the Plane status: \(r.summary)") }
                    self?.page?.reload()
                }
            })
        }
        actions.append(ActionButton("Snooze 1 day", action: "status.snooze", ["id": .string(e.id)]))
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
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        f.placeholderString = "The capture on the second display is black."
        let r = AlertConfirm.run(.init(title: "Report a failure to \(e.key)", info: "Tell the agent what failed. OverSire sends it with the checklist.",
                                       buttons: ["Send", "Cancel"], accessory: f, focus: f))
        guard r.button == 0 else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        tell(e, extra: "Failure: " + text)
    }
}

// One row of Needs you: one item, or one run or PR with no item. Home, its badge and the menu bar list them.
struct NeedsYou: Equatable {
    enum Kind: Int { case question, permission, needsInput, blocked, usageLimit, stuck, notFinished, openSubItems, done, runFailed, review, mention }

    // The chips over the list.
    enum Filter: Int, CaseIterable {
        case all, blocked, stuck, notFinished
        var title: String { ["All", "Blocked", "Stuck", "Not finished"][rawValue] }
        func has(_ k: Kind) -> Bool {
            switch self {
            case .all: return true
            case .blocked: return k == .question || k == .permission || k == .needsInput || k == .blocked
            case .stuck: return k == .stuck || k == .usageLimit
            case .notFinished: return k == .notFinished || k == .openSubItems
            }
        }
    }

    // The action that shows on hover.
    enum Act: Equatable {
        case answer, answerInOrca(QuestionID), reply(String), checklist(String), nudge(String), ask(String), approve(String), rerun(repo: String, run: Run), open(String),
             closeSubItems(String)
        var title: String {
            switch self {
            case .answer: return "Answer"
            case .answerInOrca: return "Open in Orca ↗"
            case .reply: return "Reply"
            case .checklist: return "Checklist"
            case .nudge: return "Send nudge"
            case .ask: return "Ask the agent"
            case .approve: return "Approve"
            case .rerun: return "Re-run failed"
            case .open: return "Open PR"
            case .closeSubItems: return "Close sub-items…"
            }
        }
    }

    let kind: Kind
    let key: String
    let reason: String
    let at: Date
    let route: Route
    var act: Act?
    var watched = false   // a session works on the failed run

    /// The id holds the time, so a new event of the same item shows again after a snooze.
    var id: String { "\(kind)|\(key)|\(Int(at.timeIntervalSince1970))" }

    /// Changes when the row must update.
    var rowHash: Int { PageRow.hash([id, reason, String(describing: route), act.map { String(describing: $0) }, watched]) }

    var tone: Tone {
        switch kind {
        case .question: return .question
        case .permission: return Tone(symbol: "lock.shield.fill", color: Palette.warn, word: "Permission")
        case .needsInput: return Tone(SessionState.needsInput)
        case .blocked: return Tone(SessionState.blocked)
        case .usageLimit: return Tone(symbol: "hourglass.circle.fill", color: Palette.warn, word: "Usage limit")
        case .stuck: return Tone(StatusReply.State.stuck)
        case .notFinished: return Tone(StatusReply.State.unfinished)
        case .openSubItems: return Tone(symbol: "exclamationmark.triangle.fill", color: Palette.bad, word: "Done with open sub-items")
        case .done: return Tone(StatusReply.State.done)
        case .runFailed: return .bad
        case .review: return Tone(symbol: "eye.circle.fill", color: Palette.acc, word: "Review")
        case .mention: return Tone(symbol: "at.circle.fill", color: Palette.acc, word: "Mention")
        }
    }

    /// Kind first. A failure that a session watches comes after one that no session watches. Then the newest first.
    static func ranked(_ list: [NeedsYou]) -> [NeedsYou] {
        list.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.watched != b.watched { return !a.watched }
            return a.at > b.at
        }
    }

    /// Ranked, with one row for each key: the row of the most urgent kind.
    static func merged(_ list: [NeedsYou]) -> [NeedsYou] {
        var seen = Set<String>()
        return ranked(list).filter { seen.insert($0.key).inserted }
    }

    /// The rows of the AI statuses that wait for a decision.
    static func checks(_ pending: [SessionStatus]) -> [NeedsYou] {
        pending.compactMap { s in
            let headline = s.reply.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            switch s.state {
            case .stuck:
                return NeedsYou(kind: .stuck, key: s.key, reason: headline.isEmpty ? "Looks stuck" : headline, at: s.at,
                                route: .item(s.key, .overview), act: .nudge(s.id))
            case .unfinished:
                return NeedsYou(kind: .notFinished, key: s.key, reason: headline.isEmpty ? "Not finished" : headline, at: s.at,
                                route: .item(s.key, .overview), act: .ask(s.id))
            case .done:
                return NeedsYou(kind: .done, key: s.key, reason: StatusJob.frees(s) ? "Looks done · approve to free the slot" : "Looks done",
                                at: s.at, route: .item(s.key, .overview), act: .approve(s.id))
            default: return nil
            }
        }
    }

    /// Done items with open sub-items that changed in the last week. OverSire counts them as not finished.
    static func openSubItems(_ snaps: [ProjectSnapshot], now: Date = Date()) -> [NeedsYou] {
        snaps.flatMap { snap in
            snap.items.filter { snap.isDoneWithOpenSubItems($0) && now.timeIntervalSince($0.activityAt) < 7 * 86400 }.map { i in
                let n = snap.openSubItems(of: i.id)
                return NeedsYou(kind: .openSubItems, key: i.key, reason: "Done with \(n) open sub-item\(n == 1 ? "" : "s") · " + i.title,
                                at: i.activityAt, route: .item(i.key, .overview), act: .closeSubItems(i.key))
            }
        }
    }

    /// The steps of a Blocked on you status in a few words: the step, "2 manual checks", "3 steps for you".
    static func steps(_ s: [StatusReply.Step]) -> String {
        guard let first = s.first else { return "Blocked on you" }
        if s.count == 1 { return first.text }
        if Set(s.map(\.kind)).count == 1 { return "\(s.count) \(NeedsYouCard.kindLabel(first.kind).lowercased())s" }
        return "\(s.count) steps for you"
    }

    /// A failed run counts when it is on a default branch or on a branch of one of the user's PRs.
    static func counts(_ r: Run, repo: String, prs: [(String, [ChangeRequest])]) -> Bool {
        DEFAULT_BRANCHES.contains(r.headBranch)
            || (prs.first { $0.0 == repo }?.1.contains { $0.mine && $0.headRefName == r.headBranch } ?? false)
    }

    /// The rows of the open questions and permissions. A form question gets its answer in Orca.
    static func questions(_ hub: QuestionHub) -> [NeedsYou] {
        hub.open.map { e in
            let q = e.question
            let key = hub.key(q)
            let first = q.items.first
            var text = (first?.text ?? "Asks a question").replacingOccurrences(of: "\n", with: " ")
            if q.via == .permission { text = "Allow " + [first?.header, text].compactMap { $0 }.joined(separator: ": ") }
            let route: Route = hub.origin(q).isIntake ? .intake(key?.split(separator: "-").first.map(String.init))
                : key.map { .item($0, .session) } ?? .work(.worktrees)
            return NeedsYou(kind: q.via == .permission ? .permission : .question, key: key ?? "Session", reason: "\(text) · \(hub.place(q).text)",
                            at: q.askedAt, route: route, act: q.answerable ? .answer : .answerInOrca(e.id))
        }
    }

    static func collect(_ data: AppData, snoozes: Snoozes = SNOOZES, now: Date = Date()) -> [NeedsYou] {
        var out = questions(data.questions)
        let agents = data.agentIndex
        for (key, a) in agents.agents where agents.state(key) == .needsInput {
            let ask = (a.message ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            out.append(NeedsYou(kind: .needsInput, key: key, reason: ask.isEmpty ? "Waits for your input" : "Asks: " + ask, at: a.since,
                                route: .item(key, .session), act: .reply(key)))
        }
        for e in data.statusJob.blocking {
            out.append(NeedsYou(kind: .blocked, key: e.key, reason: steps(e.reply.needsYou), at: e.at, route: .item(e.key, .overview),
                                act: .checklist(e.key)))
        }
        for l in agents.limits {
            out.append(NeedsYou(kind: .usageLimit, key: l.key, reason: "Usage limit · resumes \(l.reset)",
                                at: agents.watch(l.key)?.changedAt ?? now, route: .item(l.key, .session)))
        }
        out += checks(data.statusJob.pending)
        out += openSubItems(Array(data.projectStore.snapshots.values), now: now)
        let ws = data.workstreams
        for (repo, r) in failingRuns(data.grouped) where counts(r, repo: repo, prs: data.prGrouped) {
            let link = ws.link(runId: r.id)
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            out.append(NeedsYou(kind: .runFailed, key: link?.key ?? "\(name) #\(r.number)",
                                reason: "\(r.workflowName ?? r.name) #\(r.number) failed · \(r.headBranch)", at: lastActivity(r),
                                route: .run(repo: repo, id: r.id), act: .rerun(repo: repo, run: r),
                                watched: link.flatMap { ws.stream($0.key)?.agent }.map { $0.phase != .done } ?? false))
        }
        for (repo, prs) in data.prGrouped {
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            for p in prs where !p.mine && !p.isDraft {
                out.append(NeedsYou(kind: .review, key: "\(name) #\(p.number)", reason: "Review: " + p.title,
                                    at: parseISO(p.createdAt) ?? now, route: .prs, act: .open(p.url)))
            }
        }
        let store = data.projectStore
        for e in store.activity(limit: 300, project: nil) where e.change == .mention && now.timeIntervalSince(e.at) < 3 * 86400 {
            guard let snap = store.snapshots[e.projectKey], let item = snap.items.first(where: { $0.id == e.itemId }) else { continue }
            out.append(NeedsYou(kind: .mention, key: item.key, reason: "Mentions you: " + item.title, at: e.at, route: .item(item.key, .overview)))
        }
        return merged(out.filter { !snoozes.has($0.id, now: now) })
    }
}

// The Needs you rows that the user put off, with the end time.
final class Snoozes {
    private var until: [String: Date] = [:]
    private let path: String

    init(path: String) {
        self.path = path
        if let d = FileManager.default.contents(atPath: path), let m = try? JSONDecoder().decode([String: Date].self, from: d) { until = m }
    }

    func has(_ id: String, now: Date = Date()) -> Bool { until[id].map { $0 > now } ?? false }

    func snooze(_ id: String, for t: TimeInterval = 86400, now: Date = Date()) {
        until = until.filter { $0.value > now }
        until[id] = now.addingTimeInterval(t)
        if let d = try? JSONEncoder().encode(until) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        ChangeBus.shared.post(DataChange(.questions, origin: .user))
    }
}

let SNOOZES = Snoozes(path: (CONFIG_DIR as NSString).appendingPathComponent("needs-you-snoozes.json"))

// One line of Needs you: icon, key, reason and age. The action and Snooze show on hover. A click opens the summary.
final class NeedsYouRow: Row {
    init(_ n: NeedsYou, data: AppData, commands: RowCommander? = nil, go: @escaping (Route) -> Void) {
        let tone = n.tone
        let key = NSTextField.text(n.key, size: 11.5, color: Palette.mut, mono: true)
        key.lineBreakMode = .byTruncatingTail
        let reason = NSTextField.text(n.reason, size: 12.5)
        reason.lineBreakMode = .byTruncatingTail
        reason.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        reason.setContentHuggingPriority(.init(1), for: .horizontal)
        let age = relativeTime(n.at)
        super.init([Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), key.fixedWidth(112), reason, Spacer(),
                    RelativeTimeLabel(n.at)],
                   height: 36, label: "\(tone.word): \(n.key), \(n.reason), \(age)") { go(n.route) }
        var actions: [NSView] = []
        if let a = n.act {
            actions.append(ActionButton(a.title, style: .primary) {
                switch a {
                case .answer: go(n.route)
                case .answerInOrca(let id): if let e = data.questions.entries.first(where: { $0.id == id }) { data.questions.reveal(e.question) }
                case .reply(let k): go(.item(k, .session))
                case .checklist(let k): go(.item(k, .overview))
                case .nudge(let id), .approve(let id): data.actions.click("status.approve", ["id": .string(id)], in: NSApp.keyWindow)
                case .ask(let id): data.actions.click("status.ask", ["id": .string(id)], in: NSApp.keyWindow)
                case .rerun(let repo, let r): data.rerun(repo: repo, runs: [r], failedOnly: true)
                case .open(let url): if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                case .closeSubItems(let k): NeedsYouRow.finish(k, data: data, window: NSApp.keyWindow)
                }
            })
        }
        let snooze = ActionButton("Snooze") { SNOOZES.snooze(n.id) }
        snooze.toolTip = "Hide this row for one day"
        actions.append(snooze)
        actions.forEach { ($0 as? NSButton)?.controlSize = .small }
        hoverViews = actions
        if case .run(let repo, let id) = n.route, let commands,
           let r = data.grouped.first(where: { $0.0 == repo })?.1.first(where: { $0.id == id }) {
            let linked = data.workstreams.link(runId: id)?.key
            commands.attach(self) { RowMenu.run(repo: repo, run: r, linkedKey: linked, ignored: IGNORED.contains(r), caps: $0) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // The two choices of the item page banner. Close sets all open sub-items to the first completed state.
    static func finish(_ key: String, data: AppData, window: NSWindow?) {
        let store = data.projectStore
        guard let f = store.item(key: key), f.snap.isDoneWithOpenSubItems(f.item) else { return }
        let open = f.snap.openDescendants(of: f.item.id)
        AlertConfirm.show(.init(title: "\(key) is Done, but \(open.count) sub-item\(open.count == 1 ? " is" : "s are") open.",
                                info: "OverSire counts this item as not finished. Close the sub-items, or move the parent back to In progress.",
                                buttons: ["Close \(open.count) sub-item\(open.count == 1 ? "" : "s")", "Reopen parent", "Cancel"]), in: window) { r in
            switch r.button {
            case 0: data.actions.click("item.closeSubItems", ["key": .string(key), "keys": .array(open.map(JSONValue.string))], in: window, asked: true)
            case 1: data.actions.click("item.reopen", ["key": .string(key)], in: window)
            default: break
            }
        }
    }
}

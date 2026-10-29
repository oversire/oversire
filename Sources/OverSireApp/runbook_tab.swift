import Cocoa
import OverSireCore

/// The mark of one step in the step list: a symbol, a color and a text, so the state never relies on color.
struct StepMark: Equatable {
    let symbol: String
    let color: NSColor
    let text: String

    /// "Pass · 27m", "2 rounds", "Working · 31m", "Waits", "On gaps".
    static func of(_ step: RunbookStep, in r: RunbookRun, now: Date = Date()) -> StepMark {
        let rounds = r.rounds(of: step.id)
        guard let last = rounds.last, last.state != .waits || rounds.count > 1 else {
            return r.runbook.review(fixedBy: step.id) != nil ? StepMark(symbol: "circle.dotted", color: Palette.dim, text: "On gaps")
                                                              : StepMark(symbol: "circle", color: Palette.dim, text: "Waits")
        }
        let time = last.started.map { AgentSession.minutes((last.ended ?? now).timeIntervalSince($0)) }
        let span = rounds.count > 1 ? "\(rounds.count) rounds" : time
        func mark(_ symbol: String, _ color: NSColor, _ word: String, _ extra: String?) -> StepMark {
            StepMark(symbol: symbol, color: color, text: extra.map { "\(word) · \($0)" } ?? word)
        }
        switch last.state {
        case .waits: return mark("circle", Palette.dim, "Waits", span)
        case .starting: return mark("circle.fill", Palette.run, "Starting", nil)
        case .working: return mark("circle.fill", Palette.run, "Working", time)
        case .asks: return mark("questionmark.circle.fill", Palette.warn, "Asks", time)
        case .pass: return mark("checkmark.circle.fill", Palette.ok, "Pass", span)
        case .gaps: return mark("exclamationmark.triangle.fill", Palette.warn, "Gaps", span)
        case .done: return mark("checkmark.circle.fill", Palette.ok, "Done", span)
        case .skipped: return mark("minus.circle", Palette.dim, "Skipped", nil)
        case .blocked: return mark("exclamationmark.octagon.fill", Palette.bad, "Blocked", time)
        case .ended: return mark("exclamationmark.octagon.fill", Palette.bad, "Ended", time)
        case .failed: return mark("xmark.circle.fill", Palette.bad, "Failed", nil)
        }
    }

    /// The gate line before a step that pauses before.
    static func gate(_ step: RunbookStep, in r: RunbookRun) -> String {
        if r.state == .gate && r.current == step.id { return "Waits for your approval" }
        return r.rounds(of: step.id).contains { $0.started != nil } ? "You approved \(step.name)" : "Pause before \(step.name)"
    }
}

/// The Runbook tab of an item page: the run head, the step list and the detail of one step (OVERSIRE-349).
/// Use it on the main thread.
final class RunbookTab {
    var reload: () -> Void = {}
    var window: () -> NSWindow? = { nil }
    var go: (Route) -> Void = { _ in }
    var runtime: () -> (any RunbookRunning)? = { ENV.runtime as? any RunbookRunning }
    var starter = RunbookStarter()

    // The picks and the histories are the same in each window. The history of a round does not change.
    private static var picked: [RunbookRunID: String] = [:]
    private static var pickedRound: [String: Int] = [:]          // "run.step" → round
    private static var histories: [String: SessionDigest] = [:]  // session key → digest
    private var reading: Set<String> = []
    private var unread: [String: String] = [:]            // session key → why
    private var busy: String?
    private var focusPicked = false

    /// The step that the detail shows: the pick, else the current step, else the last step that started.
    func selected(_ r: RunbookRun) -> RunbookStep? {
        let id = Self.picked[r.id] ?? r.current ?? r.steps.last(where: { $0.started != nil })?.step
        return id.flatMap(r.runbook.step) ?? r.runbook.steps.first
    }

    func select(_ step: String, in r: RunbookRun, focus: Bool = false) {
        Self.picked[r.id] = step
        focusPicked = focus
        reload()
    }

    /// The round that the detail shows: the pick, else the last round.
    func round(of step: String, in r: RunbookRun) -> StepRun? {
        let rounds = r.rounds(of: step)
        return Self.pickedRound["\(r.id).\(step)"].flatMap { n in rounds.first { $0.round == n } } ?? rounds.last
    }

    /// For `--uishots`: the step that the tab of the run shows, and the history of a round.
    static func seed(_ r: RunbookRun, pick step: String?, round: Int? = nil, histories: [StepRun: SessionDigest] = [:]) {
        picked[r.id] = step
        if let step { pickedRound["\(r.id).\(step)"] = round }
        for (s, d) in histories { Self.histories[sessionKey(r, s)] = d }
    }

    static func sessionKey(_ r: RunbookRun, _ s: StepRun) -> String { "runbook:\(r.id).\(s.step).\(s.round)" }

    // MARK: Rows

    /// `live` is the terminal row of the session tab. It shows under the detail of a live current step.
    func rows(_ r: RunbookRun, item: Item, snap: ProjectSnapshot, canReveal: Bool, live: PageRow?) -> [PageRow] {
        var rows = [PageRow("rb-head", r.id, r.state, r.current, r.runbook.name, r.machine, busy) { [unowned self] in self.head(r) }]
        if let reason = r.reason, r.state == .paused || r.state == .failed {
            rows.append(PageRow("rb-reason", r.id, r.state, reason, r.current) { [unowned self] in self.reasonBanner(r, reason: reason) })
        }
        let step = selected(r)
        let shown = step.flatMap { round(of: $0.id, in: r) }
        let key = shown.map { Self.sessionKey(r, $0) } ?? ""
        let kids = snap.children(of: item.id).map { "\($0.key)|\($0.statusOptionId ?? "")" }
        let hasLive = live != nil
        rows.append(PageRow("rb-split", r, step?.id, shown?.round, Self.histories[key], reading.contains(key), unread[key], canReveal, kids, busy, hasLive) { [unowned self] in
            self.split(r, step: step, shown: shown, item: item, snap: snap, canReveal: canReveal, hasLive: hasLive)
        })
        if let live, let step, r.current == step.id, shown?.state.isLive == true { rows.append(live) }
        return rows
    }

    private func head(_ r: RunbookRun) -> NSView {
        let place = "\(Self.runtimeName(r.runtime)) on \(r.machine.rawValue)"
        var views: [NSView] = [Glyph("list.number", color: Palette.acc, size: 14),
                               NSTextField.text("Runbook \(r.runbook.name)", size: 14, weight: .semibold),
                               NSTextField.text(place, size: 12, color: Palette.mut), Spacer()]
        if let n = r.position, r.state.isOpen { views.append(Chiplet("Step \(n) of \(r.runbook.steps.count)", color: Palette.fg)) }
        views.append(Pill(Self.tone(r.state)))
        if let busy {
            views.append(InlineSpinner(busy))
        } else {
            switch r.state {
            case .gate: views.append(ActionButton("Approve", symbol: "checkmark", style: .primary) { [weak self] in self?.act("Approving…") { try await $0.act(.approve, on: r.id) } })
            case .running: views.append(ActionButton("Pause", symbol: "pause.fill") { [weak self] in self?.act("Pausing…") { try await $0.act(.pause, on: r.id) } })
            case .paused: views.append(ActionButton("Resume", symbol: "play.fill", style: .primary) { [weak self] in self?.act("Resuming…") { try await $0.act(.resume, on: r.id) } })
            case .done, .failed, .stopped: break
            }
            if r.state.isOpen { views.append(ActionButton("Stop", style: .ghost) { [weak self] in self?.confirmStop(r) }) }
        }
        let c = Card(padding: 12)
        c.add(NSStackView(h: views, spacing: 8))
        c.setAccessibilityElement(true)
        c.setAccessibilityRole(.group)
        c.setAccessibilityLabel("Runbook \(r.runbook.name), \(Self.tone(r.state).word)" + (r.position.map { ", step \($0) of \(r.runbook.steps.count)" } ?? ""))
        return c
    }

    private func reasonBanner(_ r: RunbookRun, reason: String) -> NSView {
        var actions: [NSView] = []
        if r.state == .paused, let cur = r.current, busy == nil {
            actions.append(ActionButton("Retry step") { [weak self] in self?.act("Retrying…") { try await $0.act(.retry, step: cur, on: r.id) } })
            actions.append(ActionButton("Skip step") { [weak self] in self?.act("Skipping…") { try await $0.act(.skip, step: cur, on: r.id) } })
        }
        return Banner(r.state == .failed ? .bad : .warning, title: reason, actions: actions)
    }

    private func split(_ r: RunbookRun, step: RunbookStep?, shown: StepRun?, item: Item, snap: ProjectSnapshot, canReveal: Bool, hasLive: Bool) -> NSView {
        let list = stepList(r, selected: step?.id)
        list.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let detail: NSView = step.map { self.detail(r, step: $0, shown: shown, item: item, snap: snap, canReveal: canReveal, hasLive: hasLive) }
            ?? EmptyNote("The runbook has no steps.", symbol: "list.number")
        detail.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(h: [list, detail], spacing: 12, align: .top)
        row.distribution = .fill
        return row
    }

    // MARK: Step list

    private func stepList(_ r: RunbookRun, selected: String?) -> NSView {
        let card = ListCard()
        let steps = r.runbook.steps
        for (i, s) in steps.enumerated() {
            if s.pauses {
                let text = StepMark.gate(s, in: r)
                let waits = r.state == .gate && r.current == s.id
                let g = Row([Glyph("diamond.fill", color: waits ? Palette.acc : Palette.dim, size: 10),
                             NSTextField.text(text, size: 12, weight: waits ? .semibold : .regular, color: waits ? Palette.fg : Palette.mut), Spacer()],
                            height: 30, label: text)
                card.add(g)
            }
            let m = StepMark.of(s, in: r)
            let name = NSTextField.text(s.name, size: 13, weight: s.id == r.current ? .semibold : .medium)
            let agent = NSTextField.text(s.agent, size: 11, color: Palette.dim, mono: true)
            let row = StepRow([Glyph(m.symbol, color: m.color, size: 12), NSStackView(v: [name, agent], spacing: 1), Spacer(),
                               NSTextField.text(m.text, size: 12, color: m.color == Palette.dim ? Palette.mut : m.color)],
                              height: 44, label: "Step \(i + 1), \(s.name), \(m.text)") { [weak self] in self?.select(s.id, in: r) }
            row.move = { [weak self] d in
                let j = i + d
                guard steps.indices.contains(j) else { return }
                self?.select(steps[j].id, in: r, focus: true)
            }
            row.selected = s.id == selected
            if row.selected, focusPicked {
                focusPicked = false
                DispatchQueue.main.async { [weak row] in row?.window?.makeFirstResponder(row) }
            }
            card.add(row)
        }
        return card
    }

    // MARK: Detail

    private func detail(_ r: RunbookRun, step: RunbookStep, shown: StepRun?, item: Item, snap: ProjectSnapshot, canReveal: Bool, hasLive: Bool) -> NSView {
        let c = Card(spacing: 10)
        guard let shown, shown.started != nil || shown.state.isFinished else { return notStarted(r, step: step, item: item, in: c) }
        let agent = r.agents[step.agent]?.profile ?? step.agent
        var caption = [agent]
        if let ws = shown.session?.workspace.id {
            let n = r.steps.filter { $0.started != nil }.firstIndex(of: shown).map { "terminal \($0 + 1) in " } ?? ""
            caption.append("\(n)\(Self.runtimeName(r.runtime)) workspace \(ws)")
        }
        if let a = shown.started { caption.append(Self.span(a, shown.ended)) }
        var trailing: [NSView] = []
        if canReveal, r.runtime == "orca", let s = shown.session {
            trailing.append(ActionButton("Open in Orca", symbol: "terminal") { [weak self] in self?.reveal(s) })
        }
        if r.state.isOpen, shown.state.isFinished, busy == nil {
            trailing.append(ActionButton("Run again", symbol: "arrow.clockwise") { [weak self] in
                self?.act("Starting \(step.name)…") { try await $0.act(.retry, step: step.id, on: r.id) }
            })
        }
        c.add(NSStackView(h: [NSStackView(v: [NSTextField.text(step.name, size: 15, weight: .semibold),
                                              NSTextField.text(caption.joined(separator: " · "), size: 11.5, color: Palette.dim, lines: 2, mono: true)], spacing: 2),
                              Spacer()] + trailing, spacing: 8, align: .top))
        let rounds = r.rounds(of: step.id)
        if rounds.count > 1 {
            let chips: [NSView] = rounds.map { x in
                let m = StepMark.of(step, in: Self.only(r, x))
                return ToggleChip("Round \(x.round) · \(m.text.components(separatedBy: " · ")[0])", on: x.round == shown.round) { [weak self] in
                    Self.pickedRound["\(r.id).\(step.id)"] = x.round
                    self?.reload()
                }
            }
            c.add(NSStackView(h: chips + [Spacer()], spacing: 6))
        }
        if shown.state.isFinished {
            let m = StepMark.of(step, in: Self.only(r, shown))
            let word = m.text.components(separatedBy: " · ")[0]
            let w = NSTextField.text(word, size: 13, weight: .semibold, color: m.color)
            w.setContentCompressionResistancePriority(.required, for: .horizontal)
            c.add(NSStackView(h: [Glyph(m.symbol, color: m.color, size: 13, label: word), w,
                                  NSTextField.text(shown.note.map { "“\($0)”" } ?? "No note.", size: 13, color: Palette.mut, lines: 3)], spacing: 6, align: .firstBaseline))
        }
        if shown.state.isLive, r.current == step.id {
            live(r, step: step, item: item, snap: snap, hasLive: hasLive, in: c)
        } else if shown.session != nil {
            history(r, shown, in: c)
        }
        return c
    }

    private func notStarted(_ r: RunbookRun, step: RunbookStep, item: Item, in c: Card) -> NSView {
        c.add(NSStackView(h: [NSTextField.text(step.name, size: 15, weight: .semibold), Spacer(), Chiplet("Not started")]))
        guard r.state.isOpen else {
            c.add(NSTextField.text("The run ended before this step.", size: 12.5, color: Palette.mut))
            return c
        }
        c.add(NSTextField.text("You can change its agent or prompt for this run until it starts.", size: 12.5, color: Palette.mut, lines: 2))
        let names = Array(PROJECTS_CFG.runtime.runbookAgents.union(r.agents.keys)).sorted()
        let pop = PopUp(names, selected: names.firstIndex(of: step.agent) ?? 0, label: "Agent of \(step.name)") { [weak self] i in
            self?.patch(r, step: step, item: item, StepPatch(agent: names[i]))
        }
        let edit = ActionButton("Change prompt…", symbol: "pencil") { [weak self] in self?.editPrompt(r, step: step, item: item) }
        c.add(NSStackView(h: [NSTextField.text("Agent", size: 12.5, color: Palette.mut), pop, edit, Spacer()], spacing: 8))
        c.add(TermView(lines: step.prompt.components(separatedBy: "\n"), height: 90))
        return c
    }

    private func live(_ r: RunbookRun, step: RunbookStep, item: Item, snap: ProjectSnapshot, hasLive: Bool, in c: Card) {
        let kids = snap.children(of: item.id)
        if !kids.isEmpty {
            let chips: [NSView] = kids.prefix(12).map { k in
                Chiplet(k.key, icon: StatusGlyph.item(k, snap: snap).sized(12), color: Palette.fg, mono: true) { [weak self] in self?.go(.item(k.key, .overview)) }
            }
            c.add(Wrap(chips))
        }
        let done = ActionButton("Mark done", symbol: "chevron.down")
        done.imagePosition = .imageTrailing
        done.toolTip = "Give the step a verdict when the agent did not run oversire step done"
        done.onClick = { [weak self, weak done] in
            guard let self, let done else { return }
            self.doneMenu(r, step: step).popUp(positioning: nil, at: NSPoint(x: 0, y: done.bounds.height + 2), in: done)
        }
        done.isEnabled = busy == nil
        let text = (hasLive ? "The terminal of the step is below. " : "") + "The agent ends the step with oversire step done."
        c.add(NSStackView(h: [NSTextField.text(text, size: 12, color: Palette.mut, lines: 2),
                              Spacer(), done], spacing: 8))
    }

    /// The verdicts that the step takes, and Skip.
    private func doneMenu(_ r: RunbookRun, step: RunbookStep) -> NSMenu {
        let m = NSMenu()
        let verdicts: [StepDone.Verdict] = step.review != nil ? [.pass, .gaps, .blocked] : [.done, .blocked]
        for v in verdicts {
            m.addItem(MenuAction(Self.verdictTitle(v)) { [weak self] in self?.markDone(r, step: step, v) }.item)
        }
        m.addItem(.separator())
        m.addItem(MenuAction("Skip step") { [weak self] in self?.act("Skipping…") { try await $0.act(.skip, step: step.id, on: r.id) } }.item)
        return m
    }

    static func verdictTitle(_ v: StepDone.Verdict) -> String {
        switch v {
        case .pass: return "Pass"
        case .gaps: return "Gaps…"
        case .done: return "Done"
        case .skipped: return "Skipped"
        case .blocked: return "Blocked…"
        }
    }

    private func markDone(_ r: RunbookRun, step: RunbookStep, _ v: StepDone.Verdict) {
        guard v == .gaps || v == .blocked else {
            act("Saving…") { try await $0.act(.done(StepDone(verdict: v)), step: step.id, on: r.id) }
            return
        }
        AlertConfirm.input("\(Self.verdictTitle(v).dropLast()) for \(step.name)", info: "Write one line for the notes of the next steps.",
                           placeholder: v == .gaps ? "What is missing" : "What blocks the step", button: "Save", in: window()) { [weak self] note in
            self?.act("Saving…") { try await $0.act(.done(StepDone(verdict: v, note: note)), step: step.id, on: r.id) }
        }
    }

    // MARK: History

    private func history(_ r: RunbookRun, _ s: StepRun, in c: Card) {
        let k = Self.sessionKey(r, s)
        if let d = Self.histories[k] {
            turns(d, in: c, id: k)
        } else if let why = unread[k] {
            c.add(NSTextField.text(why, size: 12, color: Palette.dim, lines: 2))
        } else {
            c.add(InlineSpinner("Reading the session…"))
            read(r, s)
        }
    }

    private func turns(_ d: SessionDigest, in c: Card, id: String) {
        if !d.earlier.isEmpty {
            let more = Disclosure("Show earlier turns (\(d.earlier.count))", id: "rb-earlier-\(id)")
            for (i, t) in d.earlier.enumerated() {
                more.add(Padded(NSStackView(v: [Self.turn(i == 0 ? "Runbook" : "You", t.prompt, lines: 4),
                                                Self.turn("Agent", t.closing, lines: 4)], spacing: 6), vertical: 8, side: 4))
            }
            c.add(more)
        }
        for (i, t) in d.last.enumerated() {
            c.add(Self.turn(d.earlier.isEmpty && i == 0 ? "Runbook" : "You", t.prompt, lines: 6))
            let tools = t.tools > 0 ? " · \(t.tools) tool call\(t.tools == 1 ? "" : "s")" : ""
            c.add(Self.turn("Agent" + tools, t.text, lines: 20))
        }
        if d.isEmpty { c.add(NSTextField.text("The session has no turns.", size: 12, color: Palette.dim)) }
    }

    private static func turn(_ who: String, _ text: String, lines: Int) -> NSView {
        let s = NSStackView(v: [NSTextField.text(who, size: 11, weight: .semibold, color: Palette.dim),
                                NSTextField.text(text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12.5, lines: lines)], spacing: 2)
        s.setAccessibilityElement(true)
        s.setAccessibilityRole(.group)
        s.setAccessibilityLabel(who)
        return s
    }

    private func read(_ r: RunbookRun, _ s: StepRun) {
        let k = Self.sessionKey(r, s)
        guard !reading.contains(k) else { return }
        guard let rt = ENV.runtime as? any SessionHistoryReading, rt.capabilities.contains(.sessionHistory),
              let ref = s.session, let pane = s.daemonSession else {
            unread[k] = "OverSire cannot read the history of this session."
            return
        }
        reading.insert(k)
        let cli = r.agents[r.runbook.step(s.step)?.agent ?? ""]?.cli ?? "claude"
        let a = AgentSession(phase: .done, since: s.started ?? r.started, card: ref.workspace.id, paneKey: pane, agent: AgentName(rawValue: cli), repo: r.repo)
        let ws = Workspace(id: ref.workspace.id, repo: r.repo, path: r.repo, name: r.item.key, comment: nil, liveTerminals: 0, lastActivity: s.ended ?? r.updated, agents: [])
        Task {
            let res = await Result(awaiting: { try await rt.history(of: a, in: ws, budget: HistoryBudget(earlier: 40, full: 2, maxChars: 12000)) })
            await MainActor.run {
                self.reading.remove(k)
                switch res {
                case .success(let d): Self.histories[k] = d
                case .failure(.notFound): self.unread[k] = "The terminal of this step is closed. Its history is gone."
                case .failure(let e): self.unread[k] = "OverSire could not read the session: \(e.message)"
                }
                self.reload()
            }
        }
    }

    // MARK: Actions

    private func act(_ what: String, _ f: @escaping (any RunbookRunning) async throws -> RunbookRun) {
        guard let rt = runtime(), rt.capabilities.contains(.runbooks) else {
            AlertConfirm.tell("The runbook did not change", info: SessionStartError.noRunbooks.errorDescription ?? "", in: window())
            return
        }
        busy = what
        reload()
        Task {
            let res = await Result(awaiting: { try await f(rt) })
            await MainActor.run {
                self.busy = nil
                switch res {
                case .success(let run): RUNBOOKS.apply(run)
                case .failure(let e): AlertConfirm.tell("The runbook did not change", info: e.message, in: self.window())
                }
                self.reload()
            }
        }
    }

    private func confirmStop(_ r: RunbookRun) {
        AlertConfirm.ask("Stop the runbook of \(r.item.key)?", info: "The session of the current step stops. The worktree and the steps so far stay.",
                         button: "Stop", critical: true, in: window()) { [weak self] in
            self?.act("Stopping…") { try await $0.act(.stop, on: r.id) }
        }
    }

    private func patch(_ r: RunbookRun, step: RunbookStep, item: Item, _ p: StepPatch) {
        var p = p
        if let a = p.agent {
            guard a != step.agent else { return }
            if r.agents[a] == nil {
                do { p.launch = try starter.spec(a, key: item.key, title: item.title) } catch {
                    AlertConfirm.tell("The step did not change", info: error.localizedDescription, in: window())
                    return
                }
            }
        }
        act("Saving…") { try await $0.act(.patch(p), step: step.id, on: r.id) }
    }

    private func editPrompt(_ r: RunbookRun, step: RunbookStep, item: Item) {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 180)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.string = step.prompt
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        let info = "This changes the prompt only for this run. Placeholders: " + Runbook.placeholders.map { "{\($0)}" }.joined(separator: " ")
        AlertConfirm.show(.init(title: "Prompt of \(step.name)", info: info, buttons: ["Save", "Cancel"], accessory: scroll, focus: tv), in: window()) { [weak self] a in
            let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard a.button == 0, !text.isEmpty, text != step.prompt else { return }
            self?.patch(r, step: step, item: item, StepPatch(prompt: text))
        }
    }

    private func reveal(_ s: SessionRef) {
        guard let rt = ENV.runtime as? any Revealing else { return }
        Task {
            if case .failure(let e) = await Result(awaiting: { try await rt.reveal(s) }) {
                await MainActor.run { AlertConfirm.tell("Orca did not show the terminal", info: e.message, in: self.window()) }
            }
        }
    }

    // MARK: Text

    static func runtimeName(_ id: String) -> String { id == "orca" ? "Orca" : id == "oversire" ? "OverSire runner" : id }

    static func tone(_ s: RunbookRun.State) -> Tone {
        switch s {
        case .running: return Tone(symbol: "circle.dashed", color: Palette.run, word: "Running")
        case .gate: return Tone(symbol: "diamond.fill", color: Palette.acc, word: "Waits for your approval")
        case .paused: return Tone(symbol: "pause.circle.fill", color: Palette.warn, word: "Paused")
        case .done: return .done
        case .failed: return .bad
        case .stopped: return Tone(symbol: "stop.circle", color: Palette.dim, word: "Stopped")
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func span(_ a: Date, _ b: Date?) -> String { clock.string(from: a) + "–" + (b.map(clock.string) ?? "now") }

    /// The run with only this round of its step, for the mark of one round.
    private static func only(_ r: RunbookRun, _ s: StepRun) -> RunbookRun {
        var c = r
        c.steps = r.steps.filter { $0.step != s.step } + [s]
        return c
    }
}

/// A step row: ↑ and ↓ move the pick.
private final class StepRow: Row {
    var move: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move?(1)
        case 126: move?(-1)
        default: super.keyDown(with: event)
        }
    }
}

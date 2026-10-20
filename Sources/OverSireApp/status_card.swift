import Cocoa
import OverSireCore
import OverSireAI

// The Status card of a work item: the AI status of its session, the actions for the state, and the code chips.
// It takes the place of the Workstream card and the terminal preview.
struct StatusCard {
    let key: String
    let stream: Workstream?
    let data: AppData
    let needsYou: NeedsYouCard
    let go: (Route) -> Void

    func build() -> NSView {
        let job = data.statusJob
        let agents = data.agentIndex
        let k = key.uppercased()
        let s = job.status(k)
        let reading = job.reading.contains(k)
        let agent = stream?.agent ?? agents.agent(k)

        var trailing: [NSView] = []
        if let s {
            let p = Pill(Tone(s.state), text: s.word)
            p.toolTip = s.byAI ? "Written by the AI engine" : "From the closing message, without AI"
            trailing.append(p)
            trailing.append(NSTextField.text(reading ? "Reading…" : relativeAgo(s.at), size: 12, color: Palette.dim))
        } else if let agent {
            trailing.append(agents.pill(k) ?? Pill(Tone(agent.phase), text: agent.label()))
        }
        let closed = data.projectStore.isDone(key: k)
        if agent != nil {
            if !closed {
                let r = ActionButton("Refresh", symbol: "arrow.clockwise", style: .link) { job.refresh(keys: [k]) }
            r.toolTip = "Read the history and the screen of the session now"
                if reading { r.busy("Reading…") }
                trailing.append(r)
            }
            trailing.append(ActionButton("Open in Orca", symbol: "terminal") { agents.reveal(k) })
            if agent?.phase == .failed { trailing.append(ActionButton("Dismiss") { agents.clearFailure(k) }) }
        }
        let c = Card(title: "Status", trailing: trailing, spacing: 10)

        if closed && s == nil {
            c.add(NSStackView(h: [Glyph("checkmark.circle", color: Palette.dim, size: 13),
                                  NSTextField.text("The item is done. OverSire reads no AI status for a closed item.", size: 12.5, color: Palette.dim, lines: 2),
                                  Spacer()], spacing: 6))
        } else if agent == nil && s == nil {
            c.add(NSStackView(h: [Glyph("moon.zzz", color: Palette.dim, size: 13),
                                  NSTextField.text("No session yet. Start it in Orca or add it to the queue.", size: 12.5, color: Palette.dim, lines: 2),
                                  Spacer()], spacing: 6))
        } else if let s {
            body(c, s, reading: reading)
        } else if reading {
            c.add(InlineSpinner("Reading the history of the session…"))
        } else {
            noStatus(c)
        }
        if let why = s?.partial { c.add(Self.partialNote("From the screen only. " + why, key: k, go: go)) }
        c.add(chips())
        if let s { c.add(NSTextField.text(s.read + (s.byAI ? " · by AI" : "") + " · " + s.cause, size: 11.5, color: Palette.dim, lines: 2)) }
        return c
    }

    // An amber note where the data is partial, with a link to the log lines of the item.
    static func partialNote(_ text: String, key: String, go: @escaping (Route) -> Void) -> NSView {
        let box = Box(fill: Palette.warn.withAlphaComponent(0.1), border: nil, radius: 6)
        let row = NSStackView(h: [NSTextField.text("▲", size: 12, color: Palette.warn),
                                  NSTextField.text(text, size: 12, color: Palette.fg, lines: 2),
                                  ActionButton("View log", style: .link) {
                                      LogListView.model = LogListModel(filter: .all, text: key)
                                      go(.settings(.logs, anchor: SettingsAnchor.log.rawValue))
                                  }, Spacer()], spacing: 6, align: .top)
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("Warning: " + text)
        box.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        return box
    }

    private func body(_ c: Card, _ s: SessionStatus, reading: Bool) {
        let job = data.statusJob
        let old = reading || job.outOfDate(s) != nil
        if reading {
            c.add(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Reading the last turn…", size: 12, color: Palette.dim), Spacer()], spacing: 6))
        } else if let why = job.outOfDate(s) {
            c.add(NSStackView(h: [Glyph("clock.arrow.circlepath", color: Palette.warn, size: 12),
                                  NSTextField.text(why, size: 12, color: Palette.warn), Spacer()], spacing: 6))
        }
        if !s.reply.headline.isEmpty, s.state != .blocked {
            c.add(NSTextField.text(s.reply.headline, size: 13, color: old ? Palette.dim : Palette.fg, lines: 3))
        }
        if s.state == .blocked, !old {
            c.add(NSTextField.text("NEEDS YOU · \(s.reply.needsYou.count)", size: 11, weight: .semibold, color: Palette.dim))
            c.add(needsYou.needsYou(s, session: false))
        }
        if !s.reply.done.isEmpty || !s.reply.next.isEmpty { c.add(columns(s, dim: old)) }
        if s.state == .stuck, !s.reply.nudge.isEmpty, !old { c.add(TermView(lines: [s.reply.nudge], height: 44)) }
        if !old, let row = actions(s) { c.add(row) }
    }

    // Done and Next side by side.
    private func columns(_ s: SessionStatus, dim: Bool) -> NSView {
        func list(_ title: String, _ items: [String]) -> NSView {
            let v = NSStackView(v: [NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim)], spacing: 4)
            if items.isEmpty { v.addFull(NSTextField.text("—", size: 12.5, color: Palette.dim)) }
            for e in items {
                v.addFull(NSStackView(h: [NSTextField.text("•", color: Palette.dim),
                                          NSTextField.text(e, size: 12.5, color: dim ? Palette.dim : Palette.mut, lines: 3)], spacing: 6, align: .top))
            }
            return v
        }
        let two = NSStackView(h: [list("Done", s.reply.done), list("Next", s.reply.next)], spacing: 18, align: .top)
        two.distribution = .fillEqually
        return two
    }

    private func actions(_ s: SessionStatus) -> NSView? {
        let job = data.statusJob
        var b: [NSView]
        switch s.state {
        case .stuck:
            b = [ActionButton("Send nudge", style: .primary) { job.approve(s.id) }, ActionButton("Free the slot") { job.release(s.id) },
                 ActionButton("Hold") { job.hold(s.id) }]
        case .unfinished:
            b = [ActionButton("Mark as blocked on you", style: .primary) { job.markBlocked(s.id) }, ActionButton("Ask the agent") { job.ask(s.id) }]
        case .done:
            b = [ActionButton(StatusJob.frees(s) ? "Free the slot" : "Approve", style: .primary) { job.approve(s.id) },
                 ActionButton("Hold") { job.hold(s.id) }]
        case .working:
            b = [NSTextField.text("Nothing for you. The session works.", size: 12, color: Palette.dim)]
        case .blocked:
            return nil
        }
        if s.handled != .open, s.state != .working {
            b = [NSTextField.text(s.handled == .approved ? "Approved." : "On hold.", size: 12, color: Palette.dim)]
        }
        return NSStackView(h: b + [Spacer()], spacing: 6)
    }

    // A session without a status: the recap from the screen, or a hint to set up AI.
    private func noStatus(_ c: Card) {
        let recap = data.agentIndex.watch(key.uppercased())?.recap ?? stream?.agent?.message
        if let recap, !recap.isEmpty {
            c.add(NSTextField.text(BlockedText.plain(recap), size: 12.5, color: Palette.mut, lines: 4))
        }
        if data.statusJob.on {
            c.add(NSTextField.text("No status yet. OverSire reads the session at the turn end, or click Refresh.", size: 12, color: Palette.dim, lines: 2))
        } else {
            c.add(NSStackView(h: [NSTextField.text("No AI engine. This is the recap from the screen.", size: 12, color: Palette.dim),
                                  ActionButton("Set up AI…", style: .link) { go(.settings(.ai)) }, Spacer()], spacing: 6))
        }
    }

    // Agent and repo, branch, PR, CI and the Plane write-back.
    private func chips() -> NSView {
        var chips: [NSView] = []
        if let a = stream?.agent ?? data.agentIndex.agent(key.uppercased()) { chips.append(Chiplet("\(a.agent.rawValue)\(a.repo.isEmpty ? "" : " · " + a.repo)", symbol: "cpu")) }
        let branch = stream?.branches.first
        chips.append(Chiplet(branch ?? "No branch", symbol: "arrow.triangle.branch", mono: branch != nil))
        if let p = stream?.prs.first {
            chips.append(Chiplet("#\(p.pr.number) \(p.pr.isDraft ? "draft" : p.pr.state.lowercased())", symbol: "arrow.triangle.pull") {
                NSWorkspace.shared.open(URL(string: p.pr.url)!) })
        } else {
            chips.append(Chiplet("No PR", symbol: "arrow.triangle.pull"))
        }
        if let ci = stream?.ci, let r = stream?.runs.first {
            chips.append(Chiplet("CI: \(ci.word.lowercased())", symbol: ci.symbol, color: ci.color) { go(.run(repo: r.repo, id: r.run.id)) })
        } else {
            chips.append(Chiplet("CI: no runs", symbol: "circle.dashed"))
        }
        let wb = AGENTS.writeBack
        var plane: [String] = []
        if wb.links { plane.append("links") }
        if wb.labels { plane.append("label") }
        if wb.block { plane.append("block") }
        let text = !wb.enabled || plane.isEmpty ? "On Plane: off" : "On Plane: " + plane.joined(separator: ", ")
        chips.append(Chiplet(text, symbol: "square.and.arrow.up") { go(.settings(.projects, tab: .linking, anchor: "writeback")) })
        return Wrap(chips)
    }
}

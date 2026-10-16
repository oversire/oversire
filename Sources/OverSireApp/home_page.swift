import Cocoa

// One thing that waits for the user. Home and the menu bar list them, most urgent first.
struct NeedsYou: Equatable {
    enum Kind: Int { case agentWaiting, aiCheck, runFailed, review, intake }
    let kind: Kind
    let title: String
    let body: String
    let at: Date
    let route: Route
    var tone: Tone {
        switch kind {
        case .agentWaiting: return .waiting
        case .aiCheck: return .info
        case .runFailed: return .bad
        case .review: return Tone(symbol: "eye.circle.fill", color: Palette.acc, word: "Review")
        case .intake: return .intake
        }
    }

    // Kind first. A linked failure comes after an unlinked one, because an agent watches it. Then newest first.
    static func ranked(_ list: [NeedsYou]) -> [NeedsYou] {
        list.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            let (wa, wb) = (a.body.contains("the session watches it"), b.body.contains("the session watches it"))
            if wa != wb { return !wa }
            return a.at > b.at
        }
    }

    static func ==(a: NeedsYou, b: NeedsYou) -> Bool { a.kind == b.kind && a.title == b.title && a.route == b.route }

    static func collect(_ data: AppData) -> [NeedsYou] {
        var out: [NeedsYou] = []
        let ws = data.workstreams
        for (key, a) in data.agentIndex.agents where a.phase == .waiting {
            out.append(NeedsYou(kind: .agentWaiting, title: "\(key) asks a question",
                                body: a.message ?? "The session waits for your answer.", at: a.since, route: .item(key, .overview)))
        }
        for c in data.aiChecks.pending {
            out.append(NeedsYou(kind: .aiCheck, title: "AI: the \(c.key) session \(c.verdict.word.lowercased())",
                                body: c.verdict == .done ? "Approve to start the next item in the queue." : "Approve a nudge, or stop it.",
                                at: c.at, route: .queue))
        }
        for (repo, runs) in data.grouped {
            for r in latestPerWorkflow(runs) where r.isFailure && !IGNORED.contains(r) {
                let link = ws.link(runId: r.id)
                let watched = link.flatMap { ws.stream($0.key)?.agent }.map { $0.phase != .done } ?? false
                let name = repo.split(separator: "/").last.map(String.init) ?? repo
                let body = link.map { "\($0.key) · " + (watched ? "the session watches it" : "no session works on it") }
                    ?? "\(name) · \(r.headBranch) · unlinked"
                out.append(NeedsYou(kind: .runFailed, title: "\(r.workflowName ?? r.name) #\(r.number) failed", body: body,
                                    at: lastActivity(r), route: .run(repo: repo, id: r.id)))
            }
        }
        for (repo, prs) in data.prGrouped {
            for p in prs where !p.mine {
                let name = repo.split(separator: "/").last.map(String.init) ?? repo
                out.append(NeedsYou(kind: .review, title: "Review requested: \(name) #\(p.number)", body: p.title,
                                    at: parseISO(p.updatedAt) ?? Date.distantPast, route: .prs))
            }
        }
        let pending = data.projectStore.snapshots.values.flatMap { s in (s.intake ?? []).map { (s.summary.identifier, $0) } }
        if let newest = pending.max(by: { $0.1.createdAt < $1.1.createdAt }) {
            out.append(NeedsYou(kind: .intake, title: "\(pending.count) intake item\(pending.count == 1 ? "" : "s") wait",
                                body: "Newest: \(newest.0) · \(newest.1.name)", at: newest.1.createdAt, route: .inbox(.intake)))
        }
        return ranked(out)
    }
}

// A row for one item of Needs you.
final class NeedsYouRow: Row {
    init(_ n: NeedsYou, go: @escaping (Route) -> Void) {
        let when = NSTextField.text(relativeTime(n.at), size: 11.5, color: Palette.dim)
        super.init([Glyph(n.tone), TwoLine(n.title, n.body), when], height: 46,
                   label: "\(n.tone.word): \(n.title). \(n.body)") { go(n.route) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A workstream on Home: item, checkout, agent, CI and PR in one card.
final class WorkstreamCard: Row {
    init(_ s: Workstream, go: @escaping (Route) -> Void) {
        let title = NSTextField.text(s.item?.title ?? "Not in a tracked project", size: 13.5, weight: .semibold)
        var chips: [NSView] = []
        if let a = s.agent { chips.append(Pill(Tone(a.phase), text: a.label())) }
        if let co = s.checkouts.first(where: { !$0.branch.isEmpty }) ?? s.checkouts.first {
            chips.append(Chiplet((co.path as NSString).lastPathComponent, symbol: "folder", mono: true))
            if !co.branch.isEmpty { chips.append(Chiplet(co.branch, symbol: "arrow.triangle.branch", mono: true)) }
        }
        if let r = s.latestRuns.first {
            let t = s.ci ?? Tone(r.run)
            chips.append(Chiplet("\(r.run.workflowName ?? r.run.name) #\(r.run.number) · \(t.word)", symbol: t.symbol, color: t.color))
        } else {
            chips.append(Chiplet("No CI yet"))
        }
        if let p = s.prs.first { chips.append(Chiplet("PR #\(p.pr.number) \(p.pr.isDraft ? "draft" : p.pr.state.lowercased())", symbol: "arrow.triangle.pull")) }
        let chipRow = NSStackView(h: chips, spacing: 6)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let head = NSStackView(h: [Chiplet(s.key, color: Palette.fg, mono: true), title, Spacer()], spacing: 8)
        var col: [NSView] = [head, chipRow]
        if let a = s.agent, let msg = a.message?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
            let line = NSTextField.text((a.phase == .waiting ? "? " : "") + msg.replacingOccurrences(of: "\n", with: " "),
                                        size: 11.5, color: a.phase == .waiting ? Palette.warn : Palette.termFg, mono: true)
            let term = Box(fill: Palette.term, border: nil, radius: 6)
            term.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: term.leadingAnchor, constant: 10),
                line.trailingAnchor.constraint(lessThanOrEqualTo: term.trailingAnchor, constant: -10),
                line.topAnchor.constraint(equalTo: term.topAnchor, constant: 6),
                line.bottomAnchor.constraint(equalTo: term.bottomAnchor, constant: -6),
            ])
            col.append(term)
        }
        let v = NSStackView(v: col, spacing: 8)
        super.init([v], height: 70, inset: 14, label: "\(s.key) \(s.item?.title ?? ""), " + chips.compactMap { $0.accessibilityLabel() }.joined(separator: ", ")) {
            go(.item(s.key, .overview))
        }
        fill = Palette.panel; border = Palette.line; radius = 10
        if let term = col.last as? Box, col.count == 3 { term.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Waiting first, then failing CI, working, starting, the rest.
    static func rank(_ s: Workstream) -> Int {
        if s.agent?.phase == .waiting { return 0 }
        if s.ci?.word == Tone.bad.word { return 1 }
        switch s.agent?.phase {
        case .working: return 2
        case .starting: return 3
        default: return 4
        }
    }
}

final class HomePage: Page {
    override func build(_ col: NSStackView) {
        let runs = data.grouped.flatMap { g in g.1.map { (repo: g.0, run: $0) } }
        let running = runs.filter { $0.run.status != "completed" }
        let failing = data.grouped.flatMap { latestPerWorkflow($0.1) }.filter { $0.isFailure && !IGNORED.contains($0) }
        let agents = Array(data.agentIndex.agents.values)
        let streams = data.workstreams.streams.values
            .filter { s in (s.agent.map { $0.phase != .done && $0.phase != .failed } ?? false) || s.runs.contains { $0.run.status != "completed" } }
            .sorted { (WorkstreamCard.rank($0), $0.key) < (WorkstreamCard.rank($1), $1.key) }
        let intake = data.projectStore.snapshots.values.compactMap { s in s.intake.map { (s.summary.identifier, $0.count) } }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let needs = NeedsYou.collect(data)

        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        col.addFull(PageHeader("Home", caption: "\(df.string(from: Date())) · \(streams.count) workstream\(streams.count == 1 ? "" : "s") · \(running.count) run\(running.count == 1 ? "" : "s") in progress"))

        let linked = running.filter { data.workstreams.link(runId: $0.run.id) != nil }.count
        let tiles: [NSView] = [
            Tile("\(running.count)", "Running now · \(linked) linked", tone: .running) { [weak self] in self?.go(.runs(.running)) },
            Tile("\(failing.count)", failing.isEmpty ? "Failing runs · all green" : "Failing runs", tone: failing.isEmpty ? .ok : .bad) { [weak self] in self?.go(.runs(.failed)) },
            Tile("\(agents.count)", "Orca sessions · \(agents.filter { $0.phase == .waiting }.count) need input", tone: .working) { [weak self] in self?.go(.agents) },
            Tile("\(data.queue.count)", "Queue · \(data.aiChecks.pending.count) AI checks", tone: .queued) { [weak self] in self?.go(.queue) },
            Tile("\(intake.reduce(0) { $0 + $1.1 })", intake.isEmpty ? "Intake to triage" : intake.prefix(2).map { "\($0.0) \($0.1)" }.joined(separator: " · "),
                 tone: .intake) { [weak self] in self?.go(.inbox(.intake)) },
        ]
        col.addFull(Grid(tiles, columns: 5))
        if AI_CFG.digest, let d = data.ciAssist.digest, d.day == CIAssist.day(), !d.facts.isEmpty {
            let c = Card(title: "Morning digest", trailing: [ActionButton("Dismiss") { [weak self] in self?.data.ciAssist.dismissDigest() }])
            if let s = d.summary { c.add(NSTextField.text(s, size: 13, lines: 0)) }
            for f in d.facts { c.add(NSTextField.text("• " + f, size: 12.5, color: d.summary == nil ? Palette.fg : Palette.mut, lines: 0)) }
            col.addFull(c)
        }

        let main = NSStackView(v: [], spacing: 10)
        main.addFull(SectionTitle("Workstreams", count: streams.count))
        if streams.isEmpty {
            let c = Card()
            c.add(EmptyNote("No session works now. Start an item from its page or from the queue.", symbol: "moon.zzz"))
            main.addFull(c)
        }
        for s in streams.prefix(10) { main.addFull(WorkstreamCard(s) { [weak self] in self?.go($0) }) }
        let next = data.queue.upNext(store: data.projectStore)
        if !next.isEmpty {
            let chips: [NSView] = next.prefix(4).map { e in
                Chiplet("\(e.key) \(e.title)", symbol: "arrow.right.circle", color: Palette.fg) { [weak self] in self?.go(.item(e.key, .overview)) }
            }
            let c = Card(title: "Up next", trailing: [ActionButton("Open queue") { [weak self] in self?.go(.queue) }])
            c.add(NSStackView(h: chips, spacing: 6))
            main.addFull(c)
        }

        let aside = NSStackView(v: [], spacing: 10)
        aside.addFull(SectionTitle("Needs you", count: needs.count))
        let ny = ListCard()
        for n in needs.prefix(8) { ny.add(NeedsYouRow(n) { [weak self] in self?.go($0) }) }
        if needs.count > 8 {
            ny.add(Row([NSTextField.text("\(needs.count - 8) more in the inbox", size: 12, color: Palette.acc)], height: 34) { [weak self] in self?.go(.inbox(.all)) })
        }
        if ny.isEmpty { ny.add(EmptyNote("Nothing waits for you.")) }
        aside.addFull(ny)
        aside.addFull(SectionTitle("Running now", count: running.count))
        let rn = ListCard()
        for r in running.prefix(8) { rn.add(RunLine(repo: r.repo, run: r.run, data: data) { [weak self] in self?.go($0) }) }
        if rn.isEmpty { rn.add(EmptyNote("Nothing runs now.", symbol: "pause.circle")) }
        aside.addFull(rn)

        let two = NSStackView(h: [main, aside], spacing: 16, align: .top)
        col.addFull(two)
        aside.widthAnchor.constraint(equalTo: two.widthAnchor, multiplier: 0.4).isActive = true
    }
}

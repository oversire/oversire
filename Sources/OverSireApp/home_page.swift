import Cocoa
import OverSireCore

// One thing that waits for the user. Home and the menu bar list them, most urgent first.
struct NeedsYou: Equatable {
    enum Kind: Int { case agentWaiting, aiCheck, runFailed, review, intake }
    let kind: Kind
    let title: String
    let body: String
    let at: Date
    let route: Route
    var keys: [String] = []   // the items of a grouped line
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

    /// One line for each check, or one line for each verdict when two or more checks have it.
    static func checks(_ pending: [Judgement]) -> [NeedsYou] {
        [Judgement.Verdict.done, .stuck].flatMap { v -> [NeedsYou] in
            let list = pending.filter { $0.verdict == v }
            let at = list.map(\.at).max() ?? .distantPast
            if list.count > 1 {
                return [NeedsYou(kind: .aiCheck, title: "AI: \(list.count) sessions \(v == .done ? "look done" : "look stuck")",
                                 body: list.map(\.key).joined(separator: " · "), at: at, route: .agents, keys: list.map(\.key))]
            }
            return list.map { c in
                NeedsYou(kind: .aiCheck, title: "AI: the \(c.key) session \(c.verdict.word.lowercased())",
                         body: c.verdict == .done ? "Approve to start the next item in the queue." : "Approve a nudge, or stop it.",
                         at: c.at, route: .agents)
            }
        }
    }

    static func collect(_ data: AppData) -> [NeedsYou] {
        var out: [NeedsYou] = []
        let ws = data.workstreams
        for (key, a) in data.agentIndex.agents where a.phase == .waiting {
            out.append(NeedsYou(kind: .agentWaiting, title: "\(key) asks a question",
                                body: a.message ?? "The session waits for your answer.", at: a.since, route: .item(key, .overview)))
        }
        out += checks(data.aiChecks.pending)
        for e in data.aiChecks.blocking {
            out.append(NeedsYou(kind: .agentWaiting, title: "\(e.key) is blocked on you",
                                body: "\(e.steps.count) step\(e.steps.count == 1 ? "" : "s") for you · \(e.passed) pass", at: e.at, route: .agents))
        }
        for (repo, r) in failingRuns(data.grouped) {
            let link = ws.link(runId: r.id)
            let watched = link.flatMap { ws.stream($0.key)?.agent }.map { $0.phase != .done } ?? false
            let name = repo.split(separator: "/").last.map(String.init) ?? repo
            let body = link.map { "\($0.key) · " + (watched ? "the session watches it" : "no session works on it") }
                ?? "\(name) · \(r.headBranch) · unlinked"
            out.append(NeedsYou(kind: .runFailed, title: "\(r.workflowName ?? r.name) #\(r.number) failed", body: body,
                                at: lastActivity(r), route: .run(repo: repo, id: r.id)))
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
    init(_ n: NeedsYou, commands: RowCommander? = nil, go: @escaping (Route) -> Void) {
        let when = NSTextField.text(relativeTime(n.at), size: 11.5, color: Palette.dim)
        let review: [NSView] = n.keys.isEmpty ? [] : [ActionButton("Review") { go(n.route) }]
        super.init([Glyph(n.tone), TwoLine(n.title, n.body)] + review + [when], height: 46,
                   label: "\(n.tone.word): \(n.title). \(n.body)") { go(n.route) }
        if case .run(let repo, let id) = n.route, let commands,
           let r = commands.data.grouped.first(where: { $0.0 == repo })?.1.first(where: { $0.id == id }) {
            let linked = commands.data.workstreams.link(runId: id)?.key
            commands.attach(self) { RowMenu.run(repo: repo, run: r, linkedKey: linked, ignored: IGNORED.contains(r), caps: $0) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A running run on Home. The name gets the full width; the times go on their own line.
final class HomeRunRow: Row {
    init(repo: String, run r: Run, data: AppData, commands: RowCommander? = nil, go: @escaping (Route) -> Void) {
        let tone = Tone(r)
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let title = NSTextField.text("\(r.workflowName ?? r.name) #\(r.number)", size: 13, weight: .medium)
        let link = data.workstreams.link(runId: r.id)?.key
        let sub = NSTextField.text([name, link ?? r.headBranch].joined(separator: " · "), size: 11.5, color: Palette.dim)
        for t in [title, sub] { t.setContentCompressionResistancePriority(.init(1), for: .horizontal) }
        let total = r.estimatedTotal(history: data.grouped.first { $0.0 == repo }?.1 ?? [])
        let v = NSStackView(v: [title, sub, RunClock(r, total: total, inline: true)], spacing: 3)
        v.setHuggingPriority(.init(1), for: .horizontal)
        super.init([Glyph(tone), v], height: 46,
                   label: "\(tone.word): \(r.workflowName ?? r.name) number \(r.number), \(name)") { go(.run(repo: repo, id: r.id)) }
        stack.alignment = .top
        itemActions(url: r.url, key: r.id, tracker: "GitHub")
        commands?.attach(self) { RowMenu.run(repo: repo, run: r, linkedKey: link, ignored: IGNORED.contains(r), caps: $0) }
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
        let chipRow = NSStackView(h: chips + [Spacer()], spacing: 6)
        // In a narrow card the last chips drop out first. The state pill stays.
        for (i, c) in chips.enumerated() where i > 0 { chipRow.setVisibilityPriority(.init(rawValue: 900 - Float(i) * 10), for: c) }
        chipRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        chips.first?.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        restFill = Palette.panel; restBorder = Palette.line; radius = 10
        if let term = col.last as? Box, col.count == 3 { term.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        if let item = s.item { itemActions(url: item.url, key: s.key) }
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
        pageBusy = data.loadingFirst
        let runs = data.grouped.flatMap { g in g.1.map { (repo: g.0, run: $0) } }
        let running = runs.filter { $0.run.status != "completed" }
        let failing = failingRuns(data.grouped).map(\.run)
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

        let checks = data.aiChecks.pending.count
        let attention = NeedsYouCard(page: self).count(data)
        let linked = running.filter { data.workstreams.link(runId: $0.run.id) != nil }.count
        var tiles: [NSView] = [
            Tile("\(running.count)", "Running now · \(linked) linked", tone: .running) { [weak self] in self?.go(.runs(.running)) },
            Tile("\(failing.count)", failing.isEmpty ? "Failing runs · all green" : "Failing runs", tone: failing.isEmpty ? .ok : .bad) { [weak self] in self?.go(.runs(.failed)) },
            Tile("\(agents.count)", "Sessions · \(attention) need\(attention == 1 ? "s" : "") you", tone: .working, ring: attention > 0 ? Palette.intake : nil) { [weak self] in
                self?.go(.agents)
            },
            Tile("\(data.queue.count)", "Queue · \(checks) AI check\(checks == 1 ? "" : "s")", tone: .queued) { [weak self] in self?.go(.queue) },
        ]
        if data.has(.intake) {
            tiles.append(Tile("\(intake.reduce(0) { $0 + $1.1 })", intake.isEmpty ? "Intake to triage" : intake.prefix(2).map { "\($0.0) \($0.1)" }.joined(separator: " · "),
                              tone: .intake) { [weak self] in self?.go(.inbox(.intake)) })
        }
        col.addFull(Grid(tiles, columns: tiles.count))
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
            let c = Card(title: "Up next", trailing: [ActionButton("Open queue") { [weak self] in self?.go(.queue) }])
            for (i, e) in next.prefix(3).enumerated() {
                let num = NSTextField.text("\(i + 1)", size: 12, color: Palette.dim, mono: true)
                let key = NSTextField.text(e.key, size: 12, mono: true)
                for f in [num, key] { f.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal) }
                let title = NSTextField.text(e.title, size: 12.5)
                title.setContentHuggingPriority(.init(1), for: .horizontal)
                c.add(Row([num, key, title],
                          height: 28, inset: 4, label: "\(i + 1). \(e.key) \(e.title)") { [weak self] in self?.go(.item(e.key, .overview)) })
            }
            main.addFull(c)
        }

        let aside = NSStackView(v: [], spacing: 10)
        aside.addFull(SectionTitle("Needs you", count: needs.count))
        let ny = ListCard()
        for n in needs.prefix(8) { ny.add(NeedsYouRow(n, commands: commands) { [weak self] in self?.go($0) }) }
        if needs.count > 8 {
            ny.add(Row([NSTextField.text("\(needs.count - 8) more in the inbox", size: 12, color: Palette.acc)], height: 34) { [weak self] in self?.go(.inbox(.all)) })
        }
        if ny.isEmpty { ny.add(data.loadingFirst ? LoadingNote("Loading") : EmptyNote("Nothing waits for you.")) }
        aside.addFull(ny)
        aside.addFull(SectionTitle("Running now", count: running.count))
        let rn = ListCard()
        for r in running.prefix(8) { rn.add(HomeRunRow(repo: r.repo, run: r.run, data: data, commands: commands) { [weak self] in self?.go($0) }) }
        if rn.isEmpty { rn.add(data.firstLoad ? LoadingNote("Loading runs") : EmptyNote("Nothing runs now.", symbol: "pause.circle")) }
        aside.addFull(rn)

        // A filler at the end keeps each card at its own height when the other column is taller.
        for s in [main, aside] {
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            s.addArrangedSubview(fill)
        }
        let two = NSStackView(h: [main, aside], spacing: 16, align: .top)
        col.addFull(two)
        aside.widthAnchor.constraint(equalTo: two.widthAnchor, multiplier: 0.4).isActive = true
    }
}

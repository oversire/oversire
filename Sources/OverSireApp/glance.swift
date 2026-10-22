import Cocoa
import OverSireCore

// The small menu bar popover: Now, Runs and Work. A row opens the window at its page.
final class GlanceVC: NSViewController {
    enum Tab: Int, CaseIterable {
        case now, runs, work
        var title: String { ["Now", "Runs", "Work"][rawValue] }
    }

    static let size = NSSize(width: 420, height: 560)
    static let watches: DataDomains = [.runs, .prs, .agents, .questions, .queue, .projects, .intake, .summaries, .planner, .config]
    static var tab = Tab.now

    private let data: AppData
    private let open: (Route) -> Void
    private let body = NSStackView(v: [], spacing: 10)
    private let head = NSStackView(h: [], spacing: 8)
    private let foot = NSStackView(h: [], spacing: 8)
    private var observation: ChangeBus.Observation?
    private var needsCount = 0
    private lazy var commands = RowCommander(data: data, go: open)

    init(data: AppData, open: @escaping (Route) -> Void) {
        self.data = data
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = Box(fill: Palette.bg, border: nil, radius: 0)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.frame = NSRect(origin: .zero, size: GlanceVC.size)
        let scroll = PageScroll(maxWidth: 10_000)
        scroll.column.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
        scroll.column.addFull(body)
        head.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 0, right: 12)
        foot.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let line1 = Box(fill: Palette.line, border: nil, radius: 0), line2 = Box(fill: Palette.line, border: nil, radius: 0)
        for v in [head, line1, scroll, line2, foot] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor),
            head.heightAnchor.constraint(equalToConstant: 40),
            line1.topAnchor.constraint(equalTo: head.bottomAnchor),
            line1.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: line1.bottomAnchor),
            line2.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            line2.heightAnchor.constraint(equalToConstant: 1),
            foot.topAnchor.constraint(equalTo: line2.bottomAnchor),
            foot.heightAnchor.constraint(equalToConstant: 40),
            foot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ] + [head, line1, scroll, line2, foot].flatMap {
            [$0.leadingAnchor.constraint(equalTo: root.leadingAnchor), $0.trailingAnchor.constraint(equalTo: root.trailingAnchor)]
        })
        view = root
        preferredContentSize = GlanceVC.size
        rebuild()
        observation = data.bus.observe { [weak self] c in
            guard c.touches(GlanceVC.watches, repos: nil, projects: nil, items: nil) else { return }
            self?.rebuild()
        }
    }

    func rebuild() {
        let needs = NeedsYou.collect(data)
        header(needs.count)
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch GlanceVC.tab {
        case .now: now(needs)
        case .runs: runs()
        case .work: work()
        }

        foot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let when = data.firstLoad ? "Loading…" : "Updated \(relativeTime(data.lastUpdate))"
        foot.addArrangedSubview(NSTextField.text(when, size: 11.5, color: Palette.dim))
        foot.addArrangedSubview(Spacer())
        foot.addArrangedSubview(ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.data.refresh(force: true, completion: nil) })
        foot.addArrangedSubview(ActionButton("", symbol: "gearshape") { [weak self] in self?.open(.settings(.general, anchor: "menubar")) }.labeled("Settings"))
    }

    private func header(_ needs: Int) {
        needsCount = needs
        head.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let strip = TabStrip(Tab.allCases.map(\.title), selected: GlanceVC.tab.rawValue, counts: [needs == 0 ? nil : needs, nil, nil])
        strip.onSelect = { [weak self] i in self?.select(Tab(rawValue: i) ?? .now) }
        head.addArrangedSubview(strip)
        head.addArrangedSubview(Spacer())
        head.addArrangedSubview(ActionButton("Ask", symbol: "sparkles") { (NSApp.delegate as? GHActionsBar)?.askAssistant() }.labeled("Ask the assistant"))
        head.addArrangedSubview(ActionButton("", symbol: "macwindow") { [weak self] in self?.open(.home) }.labeled("Open the window"))
    }

    // The strip and a spinner show at once. The tab builds on the next run loop turn, so the click does not wait for it.
    private func select(_ tab: Tab) {
        guard tab != GlanceVC.tab else { return }
        GlanceVC.tab = tab
        header(needsCount)
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        body.addFull(LoadingNote("Loading \(tab.title)", height: 200))
        view.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, GlanceVC.tab == tab else { return }
            self.rebuild()
        }
    }

    // MARK: Tabs

    private func now(_ needs: [NeedsYou]) {
        section("Needs you", count: needs.count, needs.prefix(5).map { n in NeedsYouRow(n, data: data, commands: commands) { [weak self] in self?.open($0) } },
                more: needs.count > 5 ? ("\(needs.count - 5) more on Home", .home) : nil, empty: "Nothing waits for you.")
        let running = data.grouped.flatMap { g in g.1.filter { $0.status != "completed" }.map { (g.0, $0) } }
            .sorted { ($0.1.createdAt) > ($1.1.createdAt) }
        section("Running", count: running.count, running.prefix(6).map { runRow($0.0, $0.1) }, empty: "No run is in progress.")
        let agents = data.agentIndex.agents.filter { $0.value.phase != .failed }.sorted { ($0.value.rank, $0.key) < ($1.value.rank, $1.key) }
        section("Sessions", count: agents.count, agents.prefix(6).map { agentRow($0.key, $0.value) },
                more: agents.count > 6 ? ("All worktrees", .work(.worktrees)) : nil, empty: "No session works now.")
    }

    private func runs() {
        let latest = data.grouped.flatMap { g in latestPerWorkflow(g.1, acrossBranches: true).map { (g.0, $0) } }
            .sorted { newerActivity($0.1, $1.1) }
        if latest.isEmpty, data.firstLoad { body.addFull(LoadingNote("Loading runs", height: 200)); return }
        section("Latest run of each workflow", count: latest.count, latest.prefix(14).map { runRow($0.0, $0.1) },
                more: ("All runs", .runs(.all)), empty: data.firstLoad ? "Loading runs…" : "No runs.")
    }

    private func work() {
        var mine: [WorkPage.Entry] = []
        for snap in data.projectStore.snapshots.values {
            for i in snap.rootItems where i.isMine(snap.me) && !snap.isFinished(i) {
                mine.append((i, snap, data.workstreams.stream(i.key)))
            }
        }
        let ordered = WorkPage.order(mine, status: data.statusJob.item)
        section("My items", count: ordered.count, ordered.prefix(5).map { e in
            let status = e.snap.option(e.item.statusOptionId)?.name ?? "No status"
            let st = data.statusJob.item(e.item.key)
            let sub = [e.item.key, status, st?.label].compactMap { $0 }.joined(separator: " · ")
            let tone = st?.tone ?? Tone(symbol: "circle", color: Palette.mut, word: status)
            let row = Row([Glyph(tone), TwoLine(e.item.title, sub)], height: 40,
                          label: "\(e.item.title), \(sub)") { [weak self] in self?.open(.item(e.item.key, .overview)) }
            row.toolTip = st.map(\.tip)
            return row
        }, more: ordered.count > 5 ? ("All my items", .work(.items)) : nil, empty: data.projectStore.snapshots.isEmpty ? "Loading projects…" : "No open items are yours.")

        let next = data.queue.lanes.compactMap { l in l.entries.first.map { (l, $0) } }
        section("Queue next", count: next.count, next.map { l, e in
            Row([Glyph("list.number", color: Palette.mut), TwoLine("\(e.key) \(e.title)", "\(l.identifier) · \(e.condition.label)" + (data.queue.state(l.project)?.error.map { " · \($0)" } ?? ""))],
                height: 40, label: "Next in \(l.identifier): \(e.key) \(e.title), \(e.condition.label)") { [weak self] in self?.open(.work(.items)) }
        }, empty: "The queue is empty.")
        // One line only when a plan change waits. No status light change, no notification.
        let plans = UIShots.cloud ?? data.relay.canRun ? data.suggestions.openPlans().reduce(0) { $0 + ($1.plan?.lines.count ?? 0) } : 0
        if plans > 0 {
            let text = "Plan: \(plans) suggestion\(plans == 1 ? "" : "s")"
            body.addFull(Row([Glyph("rectangle.split.3x1", color: Palette.intake), NSTextField.text(text, size: 12.5), Spacer(),
                              Glyph("chevron.right", color: Palette.dim, size: 11)], height: 32, label: text) { [weak self] in self?.open(.work(.items)) })
        }

        guard data.has(.intake) else { return }
        let intake = data.projectStore.snapshots.values.reduce(0) { $0 + ($1.intake?.count ?? 0) }
        let row = Row([Glyph(Tone.intake), TwoLine("Intake", intake == 0 ? "No item waits for triage." : "\(intake) item\(intake == 1 ? "" : "s") wait for triage."),
                       Spacer(), Glyph("chevron.right", color: Palette.dim, size: 11)],
                      height: 40, label: "Intake, \(intake) items wait") { [weak self] in self?.open(.intake(nil)) }
        section("Intake", count: nil, [row], empty: "")
    }

    // MARK: Rows

    private func runRow(_ repo: String, _ r: Run) -> NSView {
        let t = Tone(r)
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let link = data.workstreams.link(runId: r.id)
        let sub = [name, r.headBranch, link?.key, relativeTime(lastActivity(r))].compactMap { $0 }.joined(separator: " · ")
        let row = Row([Glyph(t), TwoLine("\(r.workflowName ?? r.name) #\(r.number)", sub)], height: 40,
                      label: "\(t.word): \(r.workflowName ?? r.name) #\(r.number), \(sub)") { [weak self] in self?.open(.run(repo: repo, id: r.id)) }
        if r.status != "completed" {
            let history = data.grouped.first { $0.0 == repo }?.1 ?? []
            row.stack.addArrangedSubview(Spacer())
            row.stack.addArrangedSubview(RunClock(r, total: r.estimatedTotal(history: history)))
        }
        if let key = link?.key, data.agentIndex.agent(key)?.card != nil { row.stack.addArrangedSubview(orcaButton(key)) }
        commands.attach(row) { RowMenu.run(repo: repo, run: r, linkedKey: link?.key, ignored: IGNORED.contains(r), caps: $0) }
        return row
    }

    private func agentRow(_ key: String, _ a: AgentSession) -> NSView {
        let title = data.workstreams.stream(key)?.item?.title ?? a.repo
        let msg = a.message?.replacingOccurrences(of: "\n", with: " ")
        let st = data.statusJob.item(key)
        let tone = st?.tone ?? Tone(a.phase)
        let sub = [key, st?.label ?? a.label(), a.phase == .waiting ? msg : nil].compactMap { $0 }.joined(separator: " · ")
        let row = Row([Glyph(tone), TwoLine(title, sub)], height: 40,
                      label: "\(tone.word): \(title), \(sub)") { [weak self] in self?.open(.item(key, .overview)) }
        row.toolTip = st.map(\.tip)
        if a.card != nil { row.stack.addArrangedSubview(orcaButton(key)) }
        return row
    }

    private func orcaButton(_ key: String) -> NSView {
        ActionButton("", symbol: "terminal", action: "session.reveal", ["key": .string(key)]).labeled("Open \(key) in Orca")
    }

    private func section(_ title: String, count: Int?, _ rows: [NSView], more: (String, Route)? = nil, empty: String) {
        body.addFull(SectionTitle(title, count: count))
        let card = ListCard()
        rows.forEach(card.add)
        if card.isEmpty, !empty.isEmpty { card.add(EmptyNote(empty)) }
        if let (text, route) = more {
            card.add(Row([NSTextField.text(text, size: 12, color: Palette.acc)], height: 30) { [weak self] in self?.open(route) })
        }
        if !card.isEmpty { body.addFull(card) }
    }
}

private extension NSView {
    func labeled(_ s: String) -> Self { setAccessibilityLabel(s); toolTip = s; return self }
}

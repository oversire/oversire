import Cocoa

// The small menu bar popover: Now, Runs and Work. A row opens the window at its page.
final class GlanceVC: NSViewController {
    enum Tab: Int, CaseIterable {
        case now, runs, work
        var title: String { ["Now", "Runs", "Work"][rawValue] }
    }

    static let size = NSSize(width: 420, height: 560)
    static var tab = Tab.now

    private let data: AppData
    private let open: (Route) -> Void
    private let body = NSStackView(v: [], spacing: 10)
    private let head = NSStackView(h: [], spacing: 8)
    private let foot = NSStackView(h: [], spacing: 8)
    private var observer: Any?
    private var fingerprint: DataFingerprint?

    init(data: AppData, open: @escaping (Route) -> Void) {
        self.data = data
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

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
        observer = NotificationCenter.default.addObserver(forName: AppWindow.changed, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let fp = DataFingerprint(self.data)
            if n.userInfo?[AppWindow.pollKey] != nil, fp == self.fingerprint { return }
            self.fingerprint = fp
            self.rebuild()
        }
    }

    func rebuild() {
        let needs = NeedsYou.collect(data)
        head.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let strip = TabStrip(Tab.allCases.map(\.title), selected: GlanceVC.tab.rawValue, counts: [needs.isEmpty ? nil : needs.count, nil, nil])
        strip.onSelect = { [weak self] i in GlanceVC.tab = Tab(rawValue: i) ?? .now; self?.rebuild() }
        head.addArrangedSubview(strip)
        head.addArrangedSubview(Spacer())
        head.addArrangedSubview(ActionButton("", symbol: "macwindow") { [weak self] in self?.open(.home) }.labeled("Open the window"))

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
        foot.addArrangedSubview(ActionButton("", symbol: "gearshape") { [weak self] in self?.open(.settings(.menubar)) }.labeled("Settings"))
    }

    // MARK: Tabs

    private func now(_ needs: [NeedsYou]) {
        section("Needs you", count: needs.count, needs.prefix(5).map { n in NeedsYouRow(n) { [weak self] in self?.open($0) } },
                more: needs.count > 5 ? ("\(needs.count - 5) more in the inbox", .inbox(.all)) : nil, empty: "Nothing waits for you.")
        let running = data.grouped.flatMap { g in g.1.filter { $0.status != "completed" }.map { (g.0, $0) } }
            .sorted { ($0.1.createdAt) > ($1.1.createdAt) }
        section("Running", count: running.count, running.prefix(6).map { runRow($0.0, $0.1) }, empty: "No run is in progress.")
        let agents = data.agentIndex.agents.filter { $0.value.phase != .failed }.sorted { ($0.value.rank, $0.key) < ($1.value.rank, $1.key) }
        section("Sessions", count: agents.count, agents.prefix(6).map { agentRow($0.key, $0.value) },
                more: agents.count > 6 ? ("All sessions", .agents) : nil, empty: "No session works now.")
    }

    private func runs() {
        let latest = data.grouped.flatMap { g in latestPerWorkflow(g.1, acrossBranches: true).map { (g.0, $0) } }
            .sorted { newerActivity($0.1, $1.1) }
        section("Latest run of each workflow", count: latest.count, latest.prefix(14).map { runRow($0.0, $0.1) },
                more: ("All runs", .runs(.all)), empty: data.firstLoad ? "Loading runs…" : "No runs.")
    }

    private func work() {
        var mine: [MyItemsPage.Entry] = []
        for snap in data.projectStore.snapshots.values {
            for i in snap.rootItems where i.isMine(snap.me) && snap.option(i.statusOptionId)?.category != .done {
                mine.append((i, snap, data.workstreams.stream(i.key)))
            }
        }
        let ordered = MyItemsPage.order(mine)
        section("My items", count: ordered.count, ordered.prefix(5).map { e in
            let status = e.snap.option(e.item.statusOptionId)?.name ?? "No status"
            let sub = [e.item.key, status, e.stream?.agent?.label()].compactMap { $0 }.joined(separator: " · ")
            let tone = e.stream?.agent.map { Tone($0.phase) } ?? Tone(symbol: "circle", color: Palette.mut, word: status)
            return Row([Glyph(tone), TwoLine(e.item.title, sub)], height: 40,
                       label: "\(e.item.title), \(sub)") { [weak self] in self?.open(.item(e.item.key, .overview)) }
        }, more: ordered.count > 5 ? ("All my items", .mine) : nil, empty: data.projectStore.snapshots.isEmpty ? "Loading projects…" : "No open items are yours.")

        let next = data.queue.lanes.compactMap { l in l.entries.first.map { (l, $0) } }
        section("Queue next", count: next.count, next.map { l, e in
            Row([Glyph("list.number", color: Palette.mut), TwoLine("\(e.key) \(e.title)", "\(l.identifier) · \(e.condition.label)" + (l.error.map { " · \($0)" } ?? ""))],
                height: 40, label: "Next in \(l.identifier): \(e.key) \(e.title), \(e.condition.label)") { [weak self] in self?.open(.queue) }
        }, empty: "The queue is empty.")

        let intake = data.projectStore.snapshots.values.reduce(0) { $0 + ($1.intake?.count ?? 0) }
        let row = Row([Glyph(Tone.intake), TwoLine("Intake", intake == 0 ? "No item waits for triage." : "\(intake) item\(intake == 1 ? "" : "s") wait for triage."),
                       Spacer(), Glyph("chevron.right", color: Palette.dim, size: 11)],
                      height: 40, label: "Intake, \(intake) items wait") { [weak self] in self?.open(.inbox(.intake)) }
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
        if let key = link?.key, data.agentIndex.agent(key)?.card != nil { row.stack.addArrangedSubview(orcaButton(key)) }
        return row
    }

    private func agentRow(_ key: String, _ a: ItemAgent) -> NSView {
        let title = data.workstreams.stream(key)?.item?.title ?? a.repo
        let msg = a.message?.replacingOccurrences(of: "\n", with: " ")
        let sub = [key, a.label(), a.phase == .waiting ? msg : nil].compactMap { $0 }.joined(separator: " · ")
        let row = Row([Glyph(Tone(a.phase)), TwoLine(title, sub)], height: 40,
                      label: "\(Tone(a.phase).word): \(title), \(sub)") { [weak self] in self?.open(.item(key, .overview)) }
        if a.card != nil { row.stack.addArrangedSubview(orcaButton(key)) }
        return row
    }

    private func orcaButton(_ key: String) -> NSView {
        ActionButton("", symbol: "terminal") { [weak self] in self?.data.agentIndex.reveal(key) }.labeled("Open \(key) in Orca")
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

import Cocoa
import OverSireCore
import OverSireAI

// A KPI tile on Home: a label, a value with a unit, a line of detail and an optional sparkline.
// A nil detail hides its line.
final class KPITile: Row {
    init(_ label: String, value: String, unit: String = "", detail: [String?], tone: NSColor? = nil, ring: NSColor? = nil,
         spark: [Double?] = [], onClick: (() -> Void)?) {
        let head = NSTextField.text(label.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim)
        let v = NSMutableAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
                                                                       .foregroundColor: tone ?? Palette.fg])
        if !unit.isEmpty {
            v.append(NSAttributedString(string: " " + unit, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.mut]))
        }
        let big = NSTextField(labelWithAttributedString: v)
        var col: [NSView] = [head, big]
        let line = detail.compactMap { $0 }.joined(separator: " · ")
        if !line.isEmpty { col.append(NSTextField.text(line, size: 11.5, color: Palette.mut, lines: 2)) }
        if spark.contains(where: { $0 != nil }) { col.append(Sparkline(spark)) }
        let stack = NSStackView(v: col, spacing: 3)
        col.forEach { $0.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        super.init([stack], height: 104, inset: 12, label: "\(label): \(value) \(unit). \(line)", onClick: onClick)
        stack.alignment = .leading
        self.stack.alignment = .top
        if ring != nil { borderWidth = 2 }
        restFill = Palette.panel; restBorder = ring ?? Palette.line; radius = 10
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A small line of rates from 0 to 1. A nil value makes a gap.
final class Sparkline: NSView {
    private let values: [Double?]

    init(_ values: [Double?]) {
        self.values = values
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height - 4
        let line = NSBezierPath(); line.lineWidth = 1.5; line.lineJoinStyle = .round
        var open = false
        for (i, v) in values.enumerated() {
            guard let v else { open = false; continue }
            let pt = NSPoint(x: CGFloat(i) * w / CGFloat(max(1, values.count - 1)), y: 2 + CGFloat(v) * h)
            if open { line.line(to: pt) } else { line.move(to: pt); open = true }
        }
        (values.compactMap { $0 }.min() ?? 1 < 0.8 ? Palette.bad : Palette.ok).setStroke()
        line.stroke()
    }
}

// Bars for each day of the week: items closed and PRs merged, side by side.
final class WeekChart: NSView {
    private let days: [Date]
    private let series: [(values: [Int], color: NSColor)]

    init(days: [Date], series: [(values: [Int], color: NSColor)], label: String) {
        self.days = days
        self.series = series
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 96).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bottom: CGFloat = 16, top: CGFloat = 4
        let h = bounds.height - bottom - top
        let slot = bounds.width / CGFloat(max(1, days.count))
        let peak = max(1, series.flatMap(\.values).max() ?? 1)
        let bar = min(10, (slot - 8) / CGFloat(max(1, series.count)))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Palette.dim]
        let f = DateFormatter(); f.dateFormat = "EEE"
        Palette.line.setStroke()
        let base = NSBezierPath(); base.move(to: NSPoint(x: 0, y: bottom)); base.line(to: NSPoint(x: bounds.width, y: bottom)); base.stroke()
        for (i, d) in days.enumerated() {
            let mid = slot * (CGFloat(i) + 0.5)
            let s = NSAttributedString(string: f.string(from: d), attributes: attrs)
            s.draw(at: NSPoint(x: mid - s.size().width / 2, y: 1))
            let x0 = mid - bar * CGFloat(series.count) / 2
            for (j, ser) in series.enumerated() where ser.values.indices.contains(i) && ser.values[i] > 0 {
                let bh = max(2, CGFloat(ser.values[i]) / CGFloat(peak) * h)
                ser.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x0 + CGFloat(j) * bar, y: bottom, width: bar - 1, height: bh), xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}

// Home: KPI tiles, then Needs you, Moving now and This week.
final class HomePage: Page {
    private var filter = NeedsYou.Filter.all
    private var all = false
    static let shown = 5

    override func build(_ col: NSStackView) {
        pageBusy = data.loadingFirst
        let now = Date()
        let cal = Calendar.current
        let needs = NeedsYou.collect(data)
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        let updated = data.firstLoad ? "loading" : "updated " + relativeTime(data.lastUpdate)
        col.addFull(PageHeader("Home", caption: "\(df.string(from: now)) · \(updated)", actions: [
            ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.data.refresh(force: true, completion: nil) },
        ]))
        col.addFull(CardGrid(tiles(needs, now: now, calendar: cal), minWidth: 150, gap: 10))
        if AI_CFG.digest, let d = data.ciAssist.digest, d.day == CIAssist.day(), !d.facts.isEmpty {
            let c = Card(title: "Morning digest", trailing: [ActionButton("Dismiss") { [weak self] in self?.data.ciAssist.dismissDigest() }])
            if let s = d.summary { c.add(NSTextField.text(s, size: 13, lines: 0)) }
            for f in d.facts { c.add(NSTextField.text("• " + f, size: 12.5, color: d.summary == nil ? Palette.fg : Palette.mut, lines: 0)) }
            col.addFull(c)
        }

        let main = NSStackView(v: [needsCard(needs)], spacing: 16)
        let aside = NSStackView(v: [movingCard(), weekCard(now: now, calendar: cal)], spacing: 16)
        // A filler at the end keeps each card at its own height when the other column is taller.
        for s in [main, aside] {
            s.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            s.addArrangedSubview(fill)
        }
        let two = NSStackView(h: [main, aside], spacing: 16, align: .top)
        col.addFull(two)
        aside.widthAnchor.constraint(equalTo: two.widthAnchor, multiplier: 0.38).isActive = true
    }

    // MARK: Tiles

    private func tiles(_ needs: [NeedsYou], now: Date, calendar cal: Calendar) -> [NSView] {
        func n(_ f: NeedsYou.Filter) -> Int { needs.filter { f.has($0.kind) }.count }
        let parts = [(n(.blocked), "blocked"), (n(.stuck), "stuck"), (n(.notFinished), "not finished")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        var out: [NSView] = [
            KPITile("Needs you", value: "\(needs.count)", detail: [needs.isEmpty ? "All clear" : parts.isEmpty ? nil : parts.joined(separator: " · ")],
                    ring: needs.isEmpty ? nil : Palette.bad.withAlphaComponent(0.5)) { [weak self] in
                self?.filter = .all; self?.all = true; self?.reload()
            },
        ]

        let agents = data.agentIndex
        let working = agents.agents.keys.filter { agents.state($0) == .working }.count
        let q = data.queue
        let used = q.lanes.reduce(0) { $0 + q.busy($1) }, slots = q.lanes.reduce(0) { $0 + AGENTS.slots($1.project) }
        let limits = agents.limits
        out.append(KPITile("Sessions", value: "\(working)", unit: "working", detail: [
            slots > 0 ? "\(used) of \(slots) slots" : "\(agents.agents.count) open",
            limits.isEmpty ? nil : "\(limits.count) at usage limit until \(limits[0].reset)",
        ]) { [weak self] in self?.go(.work(.worktrees)) })

        let failing = failingRuns(data.grouped).count
        let running = data.grouped.reduce(0) { $0 + $1.1.filter { $0.status != "completed" }.count }
        let pass = WorkStats.passRate(data.grouped.flatMap(\.1), now: now, calendar: cal)
        out.append(KPITile("Runs", value: "\(failing)", unit: "failing", detail: ["\(running) running", pass.rate.map { "\(pct($0)) passed, 7 days" }],
                           tone: failing > 0 ? Palette.bad : nil, spark: pass.daily) { [weak self] in self?.go(.runs(failing > 0 ? .failed : .all)) })

        let open = data.prGrouped.reduce(0) { $0 + $1.1.count }
        let rv = WorkStats.reviews(data.prGrouped.flatMap(\.1))
        out.append(KPITile("Pull requests", value: "\(open)", unit: "open", detail: [
            rv.count == 0 ? "No review waits" : "\(rv.count) wait for your review",
            rv.oldest.map { "oldest " + AgentSession.minutes(now.timeIntervalSince($0)) },
        ]) { [weak self] in self?.go(.prs) })

        let mine = WorkPage.mine(data)
        let todo = mine.filter { ($0.snap.option($0.item.statusOptionId)?.category ?? .todo) == .todo }.count
        let closed = WorkStats.closed(data.projectStore.activity(limit: 2000, project: nil), mine: isMine, now: now, calendar: cal).reduce(0, +)
        out.append(KPITile("My items", value: "\(mine.count - todo)", unit: "in progress",
                           detail: ["\(todo) not started", "\(closed) closed this week"]) { [weak self] in self?.go(.work(.items)) })

        if data.has(.intake) {
            let all = ActivityFeed.intake(data)
            let today = IntakeListPage.addedToday(all, now: now, calendar: cal)
            let top = IntakeListPage.counts(all).prefix(2).map { "\($0.project) \($0.count)" }.joined(separator: " · ")
            out.append(KPITile("Intake", value: "\(all.count)", detail: [top.isEmpty ? nil : top, today > 0 ? "+\(today) today" : nil],
                               tone: Palette.intake) { [weak self] in self?.go(.intake(nil)) })
        }
        return out
    }

    private func isMine(_ e: ActivityEntry) -> Bool {
        guard let snap = data.projectStore.snapshots[e.projectKey] else { return false }
        return snap.items.first { $0.id == e.itemId }?.isMine(snap.me) ?? false
    }

    // MARK: Needs you

    private func needsCard(_ needs: [NeedsYou]) -> NSView {
        let card = ListCard()
        let chips = NeedsYou.Filter.allCases.map { f -> NSView in
            let c = needs.filter { f.has($0.kind) }.count
            return ToggleChip("\(f.title) \(c)", on: filter == f) { [weak self] in self?.filter = f; self?.reload() }
        }
        let head = Row([NSTextField.text("Needs you", size: 13, weight: .semibold), Spacer()] + chips, height: 40)
        head.restFill = Palette.raise
        card.add(head)
        let list = needs.filter { filter.has($0.kind) }
        for n in all ? list : Array(list.prefix(HomePage.shown)) {
            card.add(NeedsYouRow(n, data: data, commands: commands) { [weak self] in self?.go($0) })
        }
        if list.count > HomePage.shown {
            let t = all ? "Show less" : "\(list.count - HomePage.shown) more · Open all"
            card.add(Row([ActionButton(t, style: .link) { [weak self] in self?.all.toggle(); self?.reload() }, Spacer()], height: 34))
        }
        if list.isEmpty {
            card.add(data.loadingFirst ? LoadingNote("Loading") : EmptyNote(filter == .all ? "Nothing waits for you." : "No row of this kind.",
                                                                              symbol: "checkmark.circle"))
        }
        return card
    }

    // MARK: Moving now

    private func movingCard() -> NSView {
        let card = ListCard()
        let head = Row([NSTextField.text("Moving now", size: 13, weight: .semibold), Spacer(),
                        NSTextField.text("sessions and runs", size: 12, color: Palette.dim)], height: 40)
        head.restFill = Palette.raise
        card.add(head)
        let agents = data.agentIndex
        let working = agents.agents.filter { agents.state($0.key) == .working }.sorted { $0.value.since < $1.value.since }
        var rows: [NSView] = working.map { k, a in
            let tone = Tone(SessionState.working)
            let title = data.projectStore.item(key: k)?.item.title ?? a.message ?? tone.word
            return line(tone, k, title, AgentSession.minutes(Date().timeIntervalSince(a.since))) { [weak self] in self?.go(.item(k, .session)) }
        }
        for (repo, runs) in data.grouped {
            for r in runs where r.status != "completed" {
                let name = repo.split(separator: "/").last.map(String.init) ?? repo
                let key = data.workstreams.link(runId: r.id)?.key ?? name
                let since = parseISO(r.startedAt ?? r.createdAt) ?? Date()
                rows.append(line(Tone(r), key, "\(r.workflowName ?? r.name) #\(r.number) · \(r.headBranch)",
                                 AgentSession.minutes(Date().timeIntervalSince(since))) { [weak self] in self?.go(.run(repo: repo, id: r.id)) })
            }
        }
        let max = 6
        rows.prefix(max).forEach(card.add)
        if rows.count > max {
            card.add(Row([ActionButton("\(rows.count - max) more · Open runs", style: .link) { [weak self] in self?.go(.runs(.running)) }, Spacer()],
                         height: 34))
        }
        if let next = data.queue.upNext(store: data.projectStore).first {
            let t = NSTextField.text("Next: \(next.key) when a slot frees", size: 12.5, color: Palette.dim)
            card.add(Row([Glyph("chevron.right.circle", color: Palette.dim, size: 12).fixedWidth(16), t, Spacer()], height: 36,
                         label: "Next: \(next.key) when a slot frees") { [weak self] in self?.go(.work(.items)) })
        }
        if card.isEmpty || card.list.arrangedSubviews.count == 1 {
            card.add(data.firstLoad ? LoadingNote("Loading") : EmptyNote("Nothing moves now.", symbol: "pause.circle"))
        }
        return card
    }

    private func line(_ tone: Tone, _ key: String, _ text: String, _ age: String, onClick: @escaping () -> Void) -> NSView {
        let k = NSTextField.text(key, size: 11.5, color: Palette.mut, mono: true)
        k.lineBreakMode = .byTruncatingTail
        let t = NSTextField.text(text.replacingOccurrences(of: "\n", with: " "), size: 12.5)
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        t.setContentHuggingPriority(.init(1), for: .horizontal)
        return Row([Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), k.fixedWidth(112), t, Spacer(),
                    NSTextField.text(age, size: 11.5, color: Palette.dim)],
                   height: 36, label: "\(tone.word): \(key), \(text), \(age)", onClick: onClick)
    }

    // MARK: This week

    private func weekCard(now: Date, calendar cal: Calendar) -> NSView {
        let stats = data.stats
        let days = WorkStats.week(now, calendar: cal)
        let closed = WorkStats.closed(data.projectStore.activity(limit: 2000, project: nil), mine: isMine, now: now, calendar: cal)
        let merged = stats.merged(repos: REPOS)
        let hours = stats.sessionHours.reduce(0, +)
        var series: [(values: [Int], color: NSColor)] = [(closed, Palette.acc)]
        if let merged { series.append((merged, Palette.ok)) }
        var words = ["\(closed.reduce(0, +)) items closed"]
        if let merged { words.append("\(merged.reduce(0, +)) PRs merged") }
        let c = Card(title: "This week", padding: 14, spacing: 8)
        c.add(WeekChart(days: days, series: series, label: "Each day this week: " + words.joined(separator: ", ")))
        func key(_ color: NSColor?, _ text: String, _ value: String) -> NSView {
            var v: [NSView] = []
            if let color {
                let dot = Box(fill: color, border: nil, radius: 2)
                NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
                v.append(dot)
            }
            v += [NSTextField.text(text, size: 11.5, color: Palette.mut), NSTextField.text(value, size: 11.5, weight: .semibold)]
            return NSStackView(h: v, spacing: 5)
        }
        var legend = [key(Palette.acc, "Items closed", "\(closed.reduce(0, +))")]
        if let merged { legend.append(key(Palette.ok, "PRs merged", "\(merged.reduce(0, +))")) }
        c.add(NSStackView(h: legend + [Spacer()], spacing: 14))
        c.add(NSStackView(h: [key(nil, "Session hours", hours < 10 ? String(format: "%.1fh", hours) : "\(Int(hours.rounded()))h"), Spacer()], spacing: 14))
        return c
    }
}

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

    override var watches: DataDomains { [.runs, .prs, .agents, .queue, .projects, .intake, .questions, .summaries, .stats, .config] }

    override func sections() -> [PageSection]? {
        pageBusy = data.loadingFirst
        let now = Date()
        let cal = Calendar.current
        let needs = NeedsYou.collect(data)
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        let day = df.string(from: now), loading = data.firstLoad, data = data
        var rows: [PageRow] = [
            PageRow("header", day, loading) {
                PageHeader("Home", updated: { data.lastUpdate }, caption: { "\(day) · " + (loading ? "loading" : "updated \($0)") }, actions: [
                    ActionButton("Refresh", symbol: "arrow.clockwise") { data.refresh(force: true, completion: nil) },
                ])
            },
        ]
        let tiles = tiles(needs, now: now, calendar: cal)
        rows.append(PageRow("tiles", hash: PageRow.hash(tiles.map(\.hash))) { CardGrid(tiles.map { $0.make() }, minWidth: 150, gap: 10) })
        if AI_CFG.digest, let d = data.ciAssist.digest, d.day == CIAssist.day(), !d.facts.isEmpty {
            rows.append(PageRow("digest", d.day, d.summary, d.facts) {
                let c = Card(title: "Morning digest", trailing: [ActionButton("Dismiss") { data.ciAssist.dismissDigest() }])
                if let s = d.summary { c.add(NSTextField.text(s, size: 13, lines: 0)) }
                for f in d.facts { c.add(NSTextField.text("• " + f, size: 12.5, color: d.summary == nil ? Palette.fg : Palette.mut, lines: 0)) }
                return c
            })
        }
        let needsRows = needsRows(needs), movingRows = movingRows()
        let week = weekRow(now: now, calendar: cal)
        var h = Hasher()
        for r in needsRows + movingRows + [week] { h.combine(r.id); h.combine(r.hash) }
        rows.append(PageRow("columns", hash: h.finalize(), update: { ($0 as? HomeColumns)?.apply(needsRows, movingRows, week) }) {
            let c = HomeColumns()
            c.apply(needsRows, movingRows, week)
            return c
        })
        return [PageSection("home", rows: rows)]
    }

    // MARK: Tiles

    /// A tile and the values that it shows.
    private struct TileSpec {
        let hash: Int
        let make: () -> NSView
        init(_ parts: AnyHashable..., make: @escaping () -> NSView) {
            hash = PageRow.hash(parts)
            self.make = make
        }
    }

    private func tiles(_ needs: [NeedsYou], now: Date, calendar cal: Calendar) -> [TileSpec] {
        func n(_ f: NeedsYou.Filter) -> Int { needs.filter { f.has($0.kind) }.count }
        let parts = [(n(.blocked), "blocked"), (n(.stuck), "stuck"), (n(.notFinished), "not finished")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let needDetail = needs.isEmpty ? "All clear" : parts.isEmpty ? nil : parts.joined(separator: " · ")
        let needCount = needs.count
        var out: [TileSpec] = [
            TileSpec(needCount, needDetail) { [weak self] in
                KPITile("Needs you", value: "\(needCount)", detail: [needDetail], ring: needCount == 0 ? nil : Palette.bad.withAlphaComponent(0.5)) {
                    self?.filter = .all; self?.all = true; self?.reload()
                }
            },
        ]

        let agents = data.agentIndex
        let working = agents.agents.keys.filter { agents.state($0) == .working }.count
        let q = data.queue
        let used = q.lanes.reduce(0) { $0 + q.busy($1) }, slots = q.lanes.reduce(0) { $0 + AGENTS.slots($1.project) }
        let limits = agents.limits
        let sessionDetail = [slots > 0 ? "\(used) of \(slots) slots" : "\(agents.agents.count) open",
                             limits.isEmpty ? nil : "\(limits.count) at usage limit until \(limits[0].reset)"]
        out.append(TileSpec(working, sessionDetail) { [weak self] in
            KPITile("Sessions", value: "\(working)", unit: "working", detail: sessionDetail) { self?.go(.work(.worktrees)) }
        })

        let failing = failingRuns(data.grouped).count
        let running = data.grouped.reduce(0) { $0 + $1.1.filter { $0.status != "completed" }.count }
        let pass = WorkStats.passRate(data.grouped.flatMap(\.1), now: now, calendar: cal)
        let runDetail = ["\(running) running", pass.rate.map { "\(pct($0)) passed, 7 days" }]
        out.append(TileSpec(failing, runDetail, pass.daily) { [weak self] in
            KPITile("Runs", value: "\(failing)", unit: "failing", detail: runDetail, tone: failing > 0 ? Palette.bad : nil, spark: pass.daily) {
                self?.go(.runs(failing > 0 ? .failed : .all))
            }
        })

        let open = data.prGrouped.reduce(0) { $0 + $1.1.count }
        let rv = WorkStats.reviews(data.prGrouped.flatMap(\.1))
        let prDetail = [rv.count == 0 ? "No review waits" : "\(rv.count) wait for your review",
                        rv.oldest.map { "oldest " + AgentSession.minutes(now.timeIntervalSince($0)) }]
        out.append(TileSpec(open, prDetail) { [weak self] in
            KPITile("Pull requests", value: "\(open)", unit: "open", detail: prDetail) { self?.go(.prs) }
        })

        let mine = WorkPage.mine(data)
        let todo = mine.filter { ($0.snap.option($0.item.statusOptionId)?.category ?? .todo) == .todo }.count
        let closed = WorkStats.closed(data.projectStore.activity(limit: 2000, project: nil), mine: isMine, now: now, calendar: cal).reduce(0, +)
        let progress = mine.count - todo
        out.append(TileSpec(progress, todo, closed) { [weak self] in
            KPITile("My items", value: "\(progress)", unit: "in progress", detail: ["\(todo) not started", "\(closed) closed this week"]) {
                self?.go(.work(.items))
            }
        })

        if data.has(.intake) {
            let all = ActivityFeed.intake(data)
            let today = IntakeListPage.addedToday(all, now: now, calendar: cal)
            let top = IntakeListPage.counts(all).prefix(2).map { "\($0.project) \($0.count)" }.joined(separator: " · ")
            let count = all.count
            out.append(TileSpec(count, top, today) { [weak self] in
                KPITile("Intake", value: "\(count)", detail: [top.isEmpty ? nil : top, today > 0 ? "+\(today) today" : nil], tone: Palette.intake) {
                    self?.go(.intake(nil))
                }
            })
        }
        return out
    }

    private func isMine(_ e: ActivityEntry) -> Bool {
        guard let snap = data.projectStore.snapshots[e.projectKey] else { return false }
        return snap.items.first { $0.id == e.itemId }?.isMine(snap.me) ?? false
    }

    // MARK: Needs you

    private func needsRows(_ needs: [NeedsYou]) -> [PageRow] {
        let counts = NeedsYou.Filter.allCases.map { f in needs.filter { f.has($0.kind) }.count }
        let filter = filter, data = data, commands = commands
        var rows = [PageRow("head", filter.rawValue, counts) { [weak self] in
            let chips = NeedsYou.Filter.allCases.map { f -> NSView in
                ToggleChip("\(f.title) \(counts[f.rawValue])", on: filter == f) { self?.filter = f; self?.reload() }
            }
            let head = Row([NSTextField.text("Needs you", size: 13, weight: .semibold), Spacer()] + chips, height: 40)
            head.restFill = Palette.raise
            return head
        }]
        let list = needs.filter { filter.has($0.kind) }
        for n in all ? list : Array(list.prefix(HomePage.shown)) {
            rows.append(PageRow(n.id, hash: n.rowHash) { [weak self] in NeedsYouRow(n, data: data, commands: commands) { self?.go($0) } })
        }
        if list.count > HomePage.shown {
            let t = all ? "Show less" : "\(list.count - HomePage.shown) more · Open all"
            rows.append(PageRow("more", t) { [weak self] in Row([ActionButton(t, style: .link) { self?.all.toggle(); self?.reload() }, Spacer()], height: 34) })
        }
        if list.isEmpty {
            let loading = data.loadingFirst
            rows.append(PageRow(loading ? "loading" : "empty", filter.rawValue) {
                loading ? LoadingNote("Loading") : EmptyNote(filter == .all ? "Nothing waits for you." : "No row of this kind.", symbol: "checkmark.circle")
            })
        }
        return rows
    }

    // MARK: Moving now

    private func movingRows() -> [PageRow] {
        var rows = [PageRow("head", 0) {
            let head = Row([NSTextField.text("Moving now", size: 13, weight: .semibold), Spacer(),
                            NSTextField.text("sessions and runs", size: 12, color: Palette.dim)], height: 40)
            head.restFill = Palette.raise
            return head
        }]
        let agents = data.agentIndex
        let working = agents.agents.filter { agents.state($0.key) == .working }.sorted { $0.value.since < $1.value.since }
        var lines: [PageRow] = working.map { k, a in
            let tone = Tone(SessionState.working)
            let title = data.projectStore.item(key: k)?.item.title ?? a.message ?? tone.word
            return PageRow("agent." + k, title, a.since) { [weak self] in
                HomePage.line(tone, k, title, since: a.since) { self?.go(.item(k, .session)) }
            }
        }
        for (repo, runs) in data.grouped {
            for r in runs where r.status != "completed" {
                let name = repo.split(separator: "/").last.map(String.init) ?? repo
                let key = data.workstreams.link(runId: r.id)?.key ?? name
                let since = parseISO(r.startedAt ?? r.createdAt) ?? Date()
                let tone = Tone(r), text = "\(r.workflowName ?? r.name) #\(r.number) · \(r.headBranch)"
                lines.append(PageRow("run." + repo + "#" + r.id, tone.word, key, text, since) { [weak self] in
                    HomePage.line(tone, key, text, since: since) { self?.go(.run(repo: repo, id: r.id)) }
                })
            }
        }
        let max = 6
        rows += lines.prefix(max)
        if lines.count > max {
            let left = lines.count - max
            rows.append(PageRow("more", left) { [weak self] in
                Row([ActionButton("\(left) more · Open runs", style: .link) { self?.go(.runs(.running)) }, Spacer()], height: 34)
            })
        }
        if let next = data.queue.upNext(store: data.projectStore).first {
            let key = next.key
            rows.append(PageRow("next", key) { [weak self] in
                let t = NSTextField.text("Next: \(key) when a slot frees", size: 12.5, color: Palette.dim)
                return Row([Glyph("chevron.right.circle", color: Palette.dim, size: 12).fixedWidth(16), t, Spacer()], height: 36,
                           label: "Next: \(key) when a slot frees") { self?.go(.work(.items)) }
            })
        }
        if rows.count == 1 {
            let loading = data.firstLoad
            rows.append(PageRow(loading ? "loading" : "empty", 0) { loading ? LoadingNote("Loading") : EmptyNote("Nothing moves now.", symbol: "pause.circle") })
        }
        return rows
    }

    private static func line(_ tone: Tone, _ key: String, _ text: String, since: Date, onClick: @escaping () -> Void) -> NSView {
        let k = NSTextField.text(key, size: 11.5, color: Palette.mut, mono: true)
        k.lineBreakMode = .byTruncatingTail
        let t = NSTextField.text(text.replacingOccurrences(of: "\n", with: " "), size: 12.5)
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        t.setContentHuggingPriority(.init(1), for: .horizontal)
        let age = AgentSession.minutes(Date().timeIntervalSince(since))
        return Row([Glyph(tone.symbol, color: tone.color, size: 12).fixedWidth(16), k.fixedWidth(112), t, Spacer(), RelativeTimeLabel.since(since)],
                   height: 36, label: "\(tone.word): \(key), \(text), \(age)", onClick: onClick)
    }

    // MARK: This week

    private func weekRow(now: Date, calendar cal: Calendar) -> PageRow {
        let closed = WorkStats.closed(data.projectStore.activity(limit: 2000, project: nil), mine: isMine, now: now, calendar: cal)
        let merged = data.stats.merged(repos: REPOS)
        let hours = data.stats.sessionHours.reduce(0, +)
        return PageRow("week", closed, merged, Int(hours * 10), cal.startOfDay(for: now)) { [weak self] in
            self?.weekCard(now: now, calendar: cal) ?? NSView()
        }
    }

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

/// The two columns of Home: Needs you at the left, Moving now and This week at the right. Each card keeps its rows.
final class HomeColumns: NSStackView {
    private let needs = ListCard()
    private let moving = ListCard()
    private let week = NSStackView(v: [], spacing: 0)
    private var weekHash: Int?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 16
        translatesAutoresizingMaskIntoConstraints = false
        let main = NSStackView(v: [needs], spacing: 16)
        let aside = NSStackView(v: [moving, week], spacing: 16)
        // A filler at the end keeps each card at its own height when the other column is taller.
        for s in [main, aside] {
            s.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            s.addArrangedSubview(fill)
        }
        addArrangedSubview(main)
        addArrangedSubview(aside)
        aside.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.38).isActive = true
    }
    required init(coder: NSCoder) { fatalError() }

    func apply(_ needsRows: [PageRow], _ movingRows: [PageRow], _ weekRow: PageRow) {
        needs.apply(needsRows)
        moving.apply(movingRows)
        guard weekRow.hash != weekHash else { return }
        weekHash = weekRow.hash
        week.clear()
        week.addFull(weekRow.make())
    }
}

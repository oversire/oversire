import Cocoa
import OverSireCore

// One run in a page list: state, workflow and number, repo and branch, item link, time.
final class RunLine: TableRow {
    static let layout = ColumnLayout(id: "runs", columns: [
        TableColumn(id: "state", title: "", width: 16, min: 16),
        TableColumn(id: "run", title: "Run", width: 300, min: 160, flexible: true),
        TableColumn(id: "progress", title: "Progress", width: 70, min: 50, optional: true),
        TableColumn(id: "item", title: "Item", width: 112, min: 60),
        TableColumn(id: "when", title: "When", width: 90, min: 50, optional: true),
    ])

    init(repo: String, run r: Run, data: AppData, commands: RowCommander? = nil, go: @escaping (Route) -> Void) {
        let tone = Tone(r)
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        var cells: [String: NSView] = [
            "state": Glyph(tone),
            "run": TwoLine("\(r.workflowName ?? r.name) #\(r.number)", "\(name) · \(r.headBranch) · \(r.displayTitle)"),
        ]
        let live = r.status != "completed"
        let total = live ? r.estimatedTotal(history: data.grouped.first { $0.0 == repo }?.1 ?? []) : nil
        if live { cells["progress"] = RunClock(r, total: total, parts: .bar) }
        if let link = data.workstreams.link(runId: r.id) {
            cells["item"] = Chiplet(link.key, color: Palette.fg, mono: true) { go(.item(link.key, .overview)) }
        } else {
            cells["item"] = Chiplet("unlinked")
        }
        let when = live ? "running" : relativeTime(lastActivity(r))
        cells["when"] = live ? RunClock(r, total: total, parts: .times) : NSTextField.text(when, size: 11.5, color: Palette.dim)
        super.init(RunLine.layout, cells: cells, height: 46,
                   label: "\(tone.word): \(r.workflowName ?? r.name) number \(r.number), \(name), branch \(r.headBranch), \(when)") {
            go(.run(repo: repo, id: r.id))
        }
        itemActions(url: r.url, key: r.id, tracker: "GitHub")
        let linked = data.workstreams.link(runId: r.id)?.key
        commands?.attach(self) { RowMenu.run(repo: repo, run: r, linkedKey: linked, ignored: IGNORED.contains(r), caps: $0) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// The live time of a running run: the time passed, the time left and a short bar.
// It ticks each second while it is in a visible window. Without an estimate the bar is indeterminate.
final class RunClock: NSStackView {
    struct Parts: OptionSet {
        let rawValue: Int
        static let times = Parts(rawValue: 1), bar = Parts(rawValue: 2), all: Parts = [.times, .bar]
    }
    private let run: Run
    private let total: TimeInterval?
    private let elapsed = NSTextField.text("", size: 12, weight: .medium)
    private let left = NSTextField.text("", size: 10.5, color: Palette.dim)
    private let bar: MiniBar?
    private let spinner: NSProgressIndicator?
    private var timer: Timer?

    // `inline` puts the times on one line, for a line of its own under the run name.
    init(_ r: Run, total: TimeInterval?, parts: Parts = .all, inline: Bool = false) {
        run = r
        self.total = total
        bar = parts.contains(.bar) && total != nil ? MiniBar() : nil
        spinner = parts.contains(.bar) && total == nil ? NSProgressIndicator() : nil
        super.init(frame: .zero)
        orientation = inline ? .horizontal : .vertical
        // In a table column the times align left, like the other cells. Alone at the end of a row they align right.
        alignment = inline ? .centerY : parts == .times ? .leading : .trailing
        spacing = inline ? 6 : 2
        translatesAutoresizingMaskIntoConstraints = false
        if parts.contains(.times) {
            elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            left.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            addArrangedSubview(elapsed)
            if total != nil { addArrangedSubview(left) }
        }
        if let bar { addArrangedSubview(bar) }
        if let spinner {
            spinner.style = .bar
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 64).isActive = true
            addArrangedSubview(spinner)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        tick()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { spinner?.stopAnimation(nil); return }
        spinner?.startAnimation(nil)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        if let w = window, !w.occlusionState.contains(.visible) { return }
        let e = runElapsed(run)
        elapsed.stringValue = fmtDuration(e)
        var spoken = "Running, \(fmtDuration(e))"
        if let total {
            let rest = total - e
            left.stringValue = rest > 0 ? "~\(fmtDuration(rest)) left" : "\(fmtDuration(-rest)) over"
            bar?.set(e / max(1, total), over: rest <= 0)
            spoken += ", " + (rest > 0 ? "about \(fmtDuration(rest)) left" : "\(fmtDuration(-rest)) over the estimate")
        } else {
            spoken += ", no estimate yet"
        }
        setAccessibilityLabel(spoken)
    }
}

// A thin progress bar. It turns amber when the run passes its estimate.
final class MiniBar: NSView {
    private var fraction: CGFloat = 0
    private var over = false

    init(width: CGFloat = 64) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 4).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ f: Double, over o: Bool) {
        let v = CGFloat(min(1, max(0, f)))
        guard v != fraction || o != over else { return }
        fraction = v
        over = o
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.line.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        (over ? Palette.warn : Palette.run).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

// All runs of the tracked repos, with filters. Linked runs show their item.
final class RunsPage: Page {
    private static let latestKey = "runsLatestOnly"
    private var latestOnly = UserDefaults.standard.object(forKey: RunsPage.latestKey) as? Bool ?? true
    private let more = MoreRows()
    override var buildsLater: Bool { true }

    private var filter: Route.RunFilter { if case .runs(let f) = route { return f }; return .all }

    static func matches(_ f: Route.RunFilter, run r: Run, linked: Bool) -> Bool {
        switch f {
        case .all: return true
        case .running: return r.status != "completed"
        case .failed: return r.isFailure && !IGNORED.contains(r)
        case .linked: return linked
        case .unlinked: return !linked
        }
    }

    override func build(_ col: NSStackView) {
        let ws = data.workstreams
        var all: [(repo: String, run: Run)] = []
        for (repo, runs) in data.grouped {
            for r in latestOnly ? latestPerWorkflow(runs, acrossBranches: true) : runs { all.append((repo, r)) }
        }
        all.sort { newerActivity($0.run, $1.run) }
        let filters = Route.RunFilter.allCases
        let counts = filters.map { f in all.filter { RunsPage.matches(f, run: $0.run, linked: ws.link(runId: $0.run.id) != nil) }.count }
        col.addFull(PageHeader("Runs", caption: "\(data.grouped.count) repos · updated \(relativeTime(data.lastUpdate)). A linked run shows its item.",
                               actions: [ToggleChip("Latest per workflow", on: latestOnly) { [weak self] in
                                   guard let self else { return }
                                   self.latestOnly.toggle()
                                   UserDefaults.standard.set(self.latestOnly, forKey: RunsPage.latestKey)
                                   self.reload()
                               },
                               ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.data.refresh(force: true, completion: nil) }]))
        let strip = TabStrip(filters.map { $0.rawValue.capitalized }, selected: filters.firstIndex(of: filter) ?? 0, counts: counts)
        strip.onSelect = { [weak self] i in self?.go(.runs(filters[i])) }
        col.addArrangedSubview(strip)
        if filter == .unlinked {
            col.addFull(NSTextField.text("A run links to an item by its branch, commit or title. See Settings › Projects and repos › Linking and write-back for the rules.", size: 12, color: Palette.dim, lines: 2))
        }
        let shown = all.filter { RunsPage.matches(filter, run: $0.run, linked: ws.link(runId: $0.run.id) != nil) }
        let list = ListCard()
        if !shown.isEmpty { list.add(TableHeader(RunLine.layout)) }
        list.add(shown, more: more) { [weak self, data, commands] r in RunLine(repo: r.repo, run: r.run, data: data, commands: commands) { self?.go($0) } }
        if list.isEmpty { list.add(data.firstLoad ? LoadingNote("Loading runs") : EmptyNote("No runs match.", symbol: "circle.dashed")) }
        col.addFull(list)
    }
}

// Where the run page gets a run and its jobs. `RepoClient` is the real one.
protocol RunSource: Sendable {
    func run(_ repo: String, id: String) async -> Run?
    func jobs(_ repo: String, runId: String) async -> [Job]?
}

extension RepoClient: RunSource {}

// The jobs of a run as the run page loads them. A nil fetch with no jobs yet is a failure, not a wait.
struct JobsLoad {
    private(set) var jobs: [Job]?
    private(set) var failed = false

    mutating func absorb(_ fetched: [Job]?) {
        if let fetched { jobs = fetched }
        failed = jobs == nil
    }

    mutating func retry() { failed = false }

    // What the jobs card shows in place of the job rows, or nil when it shows rows.
    func placeholder(retry: @escaping () -> Void) -> NSView? {
        if failed {
            return NSStackView(v: [EmptyNote("GitHub did not give the jobs.", symbol: "exclamationmark.triangle"),
                                   NSStackView(h: [ActionButton("Retry", symbol: "arrow.clockwise", retry), Spacer()], spacing: 0)], spacing: 0)
        }
        guard let jobs else { return LoadingNote("Loading jobs") }
        return jobs.isEmpty ? EmptyNote("No jobs.") : nil
    }
}

// One run: jobs, the log of a job, and the actions re-run and cancel.
final class RunPage: Page {
    private var run: Run?
    private var jobsLoad = JobsLoad()
    private var jobs: [Job]? { jobsLoad.jobs }
    private var jobId: String?
    private var log: [String]?
    private var logFor: String?
    private var follow = true
    private var errorsOnly = false
    private var busy: String?
    private static let rerunFailed = "Re-running the failed jobs…", rerunAll = "Re-running all jobs…", cancelling = "Cancelling…"
    private var note: (Tone, String)?
    private var timer: Timer?
    private let q = DispatchQueue(label: "com.oversire.app.run-page", qos: .userInitiated)
    static var source: any RunSource = REPO_CLIENT
    // The jobs of ended runs, by "repo#id". They do not change, so a second visit shows them at once.
    private static var endedJobs: [String: [Job]] = [:]
    private var jobsKey: String { "\(repo)#\(runId)" }

    private var repo: String { if case .run(let r, _) = route { return r }; return "" }
    private var runId: String { if case .run(_, let id) = route { return id }; return "" }

    override func viewDidAppear() {
        super.viewDidAppear()
        load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.follow, self.current?.status != "completed" || self.jobs == nil else { return }
            self.load()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }

    private var current: Run? { data.grouped.first { $0.0 == repo }?.1.first { $0.id == runId } ?? run }

    private func load() {
        let (repo, id, key) = (self.repo, self.runId, jobsKey)
        if jobs == nil, let j = Self.endedJobs[key] {
            jobsLoad.absorb(j)
            pickJob()
            loadLog()
        }
        if current?.status == "completed", Self.endedJobs[key] != nil { return }
        if jobs == nil { pageBusy = true }
        let source = Self.source
        Task { [weak self] in
            let r = await source.run(repo, id: id)
            let j = await source.jobs(repo, runId: id)
            DispatchQueue.main.async {
                guard let self, self.runId == id else { return }
                self.pageBusy = false
                if let r { self.run = r }
                self.jobsLoad.absorb(j)
                if let j, r?.status == "completed", j.allSatisfy({ $0.status == "completed" }) {
                    if Self.endedJobs.count >= 50, let k = Self.endedJobs.keys.first { Self.endedJobs[k] = nil }
                    Self.endedJobs[key] = j
                }
                self.pickJob()
                self.loadLog()
                self.reload()
            }
        }
    }

    // The failed job first, then the running one, then the first.
    private func pickJob() {
        guard jobId == nil || !(jobs ?? []).contains(where: { $0.id == jobId }) else { return }
        jobId = (jobs ?? []).first { JobChip.failed($0) }?.id ?? (jobs ?? []).first { $0.status == "in_progress" }?.id ?? jobs?.first?.id
    }

    private func loadLog() {
        guard let job = jobs?.first(where: { $0.id == jobId }), job.status == "completed" else { return }
        if logFor == job.id, log != nil { return }
        logFor = job.id
        log = nil
        JobLogs.shared.lines(repo: repo, jobId: job.id) { [weak self] l in
            guard let self, self.logFor == job.id else { return }
            self.log = l ?? []
            self.explainIfNeeded()
            self.reload()
        }
    }

    override func build(_ col: NSStackView) {
        guard let r = current else {
            col.addFull(PageHeader(route.title, caption: repo))
            let c = ListCard()
            c.add(LoadingNote("Loading the run"))
            col.addFull(c)
            return
        }
        let tone = Tone(r)
        let live = r.status != "completed"
        let link = data.workstreams.link(runId: r.id)
        let stream = link.flatMap { data.workstreams.stream($0.key) }

        var actions: [NSView] = []
        if r.isFailure {
            let failed = ActionButton("Re-run failed jobs", symbol: "arrow.clockwise", style: .primary) { [weak self] in self?.rerun(failed: true) }
            if busy == Self.rerunFailed { failed.busy("Re-running…") } else { failed.isEnabled = busy == nil }
            actions.append(failed)
        }
        let all = ActionButton("Re-run all") { [weak self] in self?.rerun(failed: false) }
        all.isEnabled = !live && busy == nil
        if busy == Self.rerunAll { all.busy("Re-running…") }
        let cancel = ActionButton("Cancel", style: .danger) { [weak self] in self?.cancelRun() }
        cancel.isEnabled = live && busy == nil
        if busy == Self.cancelling { cancel.busy("Cancelling…") }
        actions += [all, cancel, ActionButton("Open in GitHub", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(URL(string: r.url)!) }]
        let title = "\(r.workflowName ?? r.name) #\(r.number)" + ((r.attempt ?? 1) > 1 ? " · attempt \(r.attempt!)" : "")
        col.addFull(NSStackView(h: [Glyph(tone, size: 26), PageHeader(title, caption: r.displayTitle, actions: actions)], spacing: 12, align: .top))

        var chips: [NSView] = [Pill(tone),
                               Chiplet(repo, symbol: "shippingbox", mono: true),
                               Chiplet(r.headBranch, symbol: "arrow.triangle.branch", mono: true),
                               Chiplet(String(r.headSha.prefix(7)), mono: true),
                               Chiplet("\(r.event)\(r.actorLogin.map { " · \($0)" } ?? "")"),
                               Chiplet(live ? fmtDuration(runElapsed(r)) : runDuration(r), symbol: "timer")]
        if let link {
            chips.append(Chiplet("\(link.key) · \(link.reason.rawValue)", symbol: "link", color: Palette.fg) { [weak self] in self?.go(.item(link.key, .overview)) })
        } else {
            chips.append(Chiplet("unlinked", symbol: "link.badge.plus") { [weak self] in self?.go(.settings(.projects, tab: .linking)) })
        }
        let cia = data.ciAssist
        if cia.isFlaky(repo: repo, r) { chips.append(Chiplet("Flaky workflow", symbol: "arrow.triangle.2.circlepath", color: Palette.warn)) }
        if let busy { chips.append(NSTextField.text(busy, size: 12, color: Palette.dim)) }
        col.addFull(NSStackView(h: chips + [Spacer()], spacing: 6))
        if let note { col.addFull(Banner(note.0, title: note.1)) }

        if r.isFailure, let s = stream, let a = s.agent, a.phase == .working || a.phase == .waiting {
            col.addFull(Banner(.info, title: "The session of \(s.key) works on this branch.",
                               body: "It usually sees the failure and fixes it or re-runs it. OverSire does not act on this run unless you ask.",
                               actions: [ActionButton("Open session") { [weak self] in self?.go(.item(s.key, .session)) }]))
        }

        if cia.retried(r) {
            col.addFull(Banner(.info, title: "OverSire re-ran the failed jobs once, because this workflow failed and then passed on the same commit before."))
        }
        if r.isFailure && !watched(r) { col.addFull(causeCard(r)) }

        let jobsCard = ListCard()
        for j in jobs ?? [] {
            let t = Tone(j)
            let dur = JobSummary.duration(j.startedAt, j.completedAt) ?? (j.status == "in_progress" ? "running" : "—")
            let row = Row([Glyph(t, size: 13), NSTextField.text(j.name, size: 12.5, weight: .medium), Spacer(),
                           NSTextField.text(dur, size: 11.5, color: Palette.dim)], height: 34, label: "\(j.name), \(t.word), \(dur)") { [weak self] in
                self?.jobId = j.id
                self?.loadLog()
                self?.reload()
            }
            row.selected = j.id == jobId
            commands.attach(row) { [repo] in RowMenu.job(repo: repo, run: r, job: j, caps: $0) }
            jobsCard.add(row)
        }
        if let p = jobsLoad.placeholder(retry: { [weak self] in self?.retryJobs() }) { jobsCard.add(p) }

        let logCard = Card(title: "Log", trailing: [
            ToggleChip("Follow", on: follow) { [weak self] in self?.follow.toggle(); self?.reload() },
            ToggleChip("Errors only", on: errorsOnly) { [weak self] in self?.errorsOnly.toggle(); self?.reload() },
            ActionButton("Copy", symbol: "doc.on.doc") { [weak self] in
                guard let lines = self?.log else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            },
        ])
        let job = jobs?.first { $0.id == jobId }
        if let job, job.status != "completed" {
            logCard.add(NSTextField.text("GitHub gives the log when the job ends. The steps update every 5 seconds.", size: 12, color: Palette.dim, lines: 2))
            let steps = (job.steps ?? []).map { s -> String in
                let t = Tone(status: s.status ?? "queued", conclusion: s.conclusion)
                return "\(t.word.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.name)"
            }
            logCard.add(TermView(lines: steps.isEmpty ? ["Waiting for the runner…"] : steps, height: 300))
        } else if let log {
            let lines = errorsOnly ? log.filter(CILog.isError) : log
            let errs = Set(lines.indices.filter { CILog.isError(lines[$0]) })
            logCard.add(NSTextField.text("\(job?.name ?? "") · last \(log.count) lines", size: 11.5, color: Palette.dim, mono: true))
            logCard.add(TermView(lines: lines.isEmpty ? ["No error lines."] : lines, height: 420, errors: errs))
        } else {
            if let job { logCard.add(InlineSpinner("Loading the log of \(job.name)…")) } else { logCard.add(TermView(lines: [jobsLoad.failed ? "No jobs." : "Pick a job."], height: 120)) }
        }
        let two = NSStackView(h: [jobsCard, logCard], spacing: 14, align: .top)
        col.addFull(two)
        jobsCard.widthAnchor.constraint(equalToConstant: 260).isActive = true
        logCard.widthAnchor.constraint(equalTo: two.widthAnchor, constant: -274).isActive = true
    }

    private func watched(_ r: Run) -> Bool {
        let ws = data.workstreams
        return ws.link(runId: r.id).flatMap { ws.stream($0.key)?.agent }.map { $0.phase == .working || $0.phase == .waiting } ?? false
    }

    private func explainIfNeeded() {
        let cia = data.ciAssist
        guard let r = current, r.isFailure, !watched(r), cia.canExplain, cia.explanation(r) == nil,
              cia.errors[CIAssist.runKey(r)] == nil, let job = jobs?.first(where: { $0.id == jobId }), JobChip.failed(job), let log else { return }
        cia.explain(repo: repo, run: r, job: job, log: log)
    }

    private func causeCard(_ r: Run) -> NSView {
        let cia = data.ciAssist
        let k = CIAssist.runKey(r)
        let e = cia.explanation(r)
        var trailing: [NSView] = []
        if let e { trailing.append(Chiplet("AI · \(e.confidence) confidence", symbol: "sparkles")) }
        if cia.hasEngine {
            let again = ActionButton(e == nil ? "Explain" : "Explain again", symbol: "sparkles") { [weak self] in
                guard let self, let job = self.jobs?.first(where: { $0.id == self.jobId }), let log = self.log else { return }
                cia.explain(repo: self.repo, run: r, job: job, log: log, force: true)
            }
            again.isEnabled = log != nil
            if cia.busy.contains(k) { again.busy("Explaining…") }
            trailing.append(again)
        }
        let c = Card(title: "Likely cause", trailing: trailing)
        if let e {
            c.add(NSTextField.text(e.cause, size: 13, lines: 0))
            if !e.fix.isEmpty { c.add(NSTextField.text("Try: " + e.fix, size: 12.5, color: Palette.mut, lines: 0)) }
        } else if cia.busy.contains(k) {
            c.add(NSTextField.text("The AI reads the log of the failed job and the changed files…", size: 12.5, color: Palette.dim))
            c.add(LoadingNote("The AI writes the cause", compact: true))
        } else if let err = cia.errors[k] {
            c.add(NSTextField.text("Could not explain: \(err)", size: 12.5, color: Palette.bad, lines: 0))
        } else if !cia.hasEngine {
            c.add(NSStackView(h: [NSTextField.text("No session works on this run. Set up an AI engine to get a short cause from the log.", size: 12.5, color: Palette.dim),
                                  Spacer(), ActionButton("AI settings") { [weak self] in self?.go(.settings(.ai)) }], spacing: 8))
        } else if !cia.canExplain {
            c.add(NSTextField.text("Press Explain for a short cause from the log of the failed job.", size: 12.5, color: Palette.dim))
        } else {
            c.add(NSTextField.text("Pick the failed job. OverSire explains it when the log loads.", size: 12.5, color: Palette.dim))
        }
        return c
    }

    private func retryJobs() {
        jobsLoad.retry()
        reload()
        load()
    }

    private func rerun(failed: Bool) {
        guard let r = current else { return }
        busy = failed ? Self.rerunFailed : Self.rerunAll
        Self.endedJobs[jobsKey] = nil
        reload()
        data.rerun(repo: repo, runs: [r], failedOnly: failed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.busy = nil
            self?.jobsLoad = JobsLoad()
            self?.log = nil
            self?.logFor = nil
            self?.load()
        }
    }

    private func cancelRun() {
        let (repo, id) = (self.repo, self.runId)
        busy = Self.cancelling
        reload()
        Task { [weak self] in
            let err = await REPO_CLIENT.perform(.cancel, repo: repo, id: id)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                self.note = err.map { (.bad, "Could not cancel: \($0)") } ?? (.info, "GitHub cancels the run.")
                self.load()
            }
        }
    }
}

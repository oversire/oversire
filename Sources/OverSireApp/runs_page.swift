import Cocoa
import OverSireCore
import CIGitHubActions

// One run in a page list: state, workflow and number, repo and branch, item link, time.
final class RunLine: Row {
    init(repo: String, run r: Run, data: AppData, go: @escaping (Route) -> Void) {
        let tone = Tone(r)
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let main = TwoLine("\(r.workflowName ?? r.name) #\(r.number)", "\(name) · \(r.headBranch) · \(r.displayTitle)")
        var views: [NSView] = [Glyph(tone), main, Spacer()]
        let live = r.status != "completed"
        if live, let total = r.estimatedTotal(history: data.grouped.first { $0.0 == repo }?.1 ?? []) {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.controlSize = .small
            bar.minValue = 0; bar.maxValue = 1
            bar.doubleValue = min(0.98, runElapsed(r) / max(1, total))
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 70).isActive = true
            bar.setAccessibilityLabel("Progress")
            views.append(bar)
        }
        if let link = data.workstreams.link(runId: r.id) {
            views.append(Chiplet(link.key, color: Palette.fg, mono: true) { go(.item(link.key, .overview)) })
        } else {
            views.append(Chiplet("unlinked"))
        }
        let when: String
        if live, let total = r.estimatedTotal(history: data.grouped.first { $0.0 == repo }?.1 ?? []) {
            when = "~" + fmtDuration(max(5, total - runElapsed(r))) + " left"
        } else {
            when = relativeTime(lastActivity(r))
        }
        let t = NSTextField.text(when, size: 11.5, color: Palette.dim)
        t.alignment = .right
        t.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        views.append(t)
        super.init(views, height: 46, label: "\(tone.word): \(r.workflowName ?? r.name) number \(r.number), \(name), branch \(r.headBranch), \(when)") {
            go(.run(repo: repo, id: r.id))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// All runs of the tracked repos, with filters. Linked runs show their item.
final class RunsPage: Page {
    private static let latestKey = "runsLatestOnly"
    private var latestOnly = UserDefaults.standard.bool(forKey: RunsPage.latestKey)

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
            for r in latestOnly ? latestPerWorkflow(runs) : runs { all.append((repo, r)) }
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
            col.addFull(NSTextField.text("A run links to an item by its branch, commit or title. See Settings › Linking for the rules.", size: 12, color: Palette.dim, lines: 2))
        }
        let shown = all.filter { RunsPage.matches(filter, run: $0.run, linked: ws.link(runId: $0.run.id) != nil) }
        let list = ListCard()
        for r in shown.prefix(200) { list.add(RunLine(repo: r.repo, run: r.run, data: data) { [weak self] in self?.go($0) }) }
        if list.isEmpty { list.add(EmptyNote(data.firstLoad ? "Loading runs…" : "No runs match.", symbol: "circle.dashed")) }
        col.addFull(list)
    }
}

// One run: jobs, the log of a job, and the actions re-run and cancel.
final class RunPage: Page {
    private var run: Run?
    private var jobs: [Job]?
    private var jobId: String?
    private var log: [String]?
    private var logFor: String?
    private var follow = true
    private var errorsOnly = false
    private var busy: String?
    private var note: (Tone, String)?
    private var timer: Timer?
    private let q = DispatchQueue(label: "com.oversire.app.run-page", qos: .userInitiated)

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
        let (repo, id) = (self.repo, self.runId)
        q.async { [weak self] in
            let r = fetchRun(repo: repo, id: id)
            let j = fetchRunJobs(repo: repo, runId: id)
            DispatchQueue.main.async {
                guard let self, self.runId == id else { return }
                if let r { self.run = r }
                if let j { self.jobs = j }
                if self.jobId == nil || !(self.jobs ?? []).contains(where: { $0.id == self.jobId }) {
                    self.jobId = (self.jobs ?? []).first { JobChip.failed($0) }?.id ?? (self.jobs ?? []).first { $0.status == "in_progress" }?.id ?? self.jobs?.first?.id
                }
                self.loadLog()
                self.reload()
            }
        }
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
            col.addFull(EmptyNote("Loading the run…", symbol: "hourglass"))
            return
        }
        let tone = Tone(r)
        let live = r.status != "completed"
        let link = data.workstreams.link(runId: r.id)
        let stream = link.flatMap { data.workstreams.stream($0.key) }

        var actions: [NSView] = []
        if r.isFailure { actions.append(ActionButton("Re-run failed jobs", symbol: "arrow.clockwise", style: .primary) { [weak self] in self?.rerun(failed: true) }) }
        let all = ActionButton("Re-run all") { [weak self] in self?.rerun(failed: false) }
        all.isEnabled = !live && busy == nil
        let cancel = ActionButton("Cancel", style: .danger) { [weak self] in self?.cancelRun() }
        cancel.isEnabled = live && busy == nil
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
            chips.append(Chiplet("unlinked", symbol: "link.badge.plus") { [weak self] in self?.go(.settings(.linking)) })
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
            jobsCard.add(row)
        }
        if jobs == nil { jobsCard.add(EmptyNote("Loading jobs…", symbol: "hourglass")) } else if jobsCard.isEmpty { jobsCard.add(EmptyNote("No jobs.")) }

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
            let lines = errorsOnly ? log.filter(ActionsCI.isError) : log
            let errs = Set(lines.indices.filter { ActionsCI.isError(lines[$0]) })
            logCard.add(NSTextField.text("\(job?.name ?? "") · last \(log.count) lines", size: 11.5, color: Palette.dim, mono: true))
            logCard.add(TermView(lines: lines.isEmpty ? ["No error lines."] : lines, height: 420, errors: errs))
        } else {
            logCard.add(TermView(lines: [job == nil ? "Pick a job." : "Loading the log…"], height: 120))
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
        if cia.canExplain {
            let again = ActionButton(e == nil ? "Explain" : "Explain again", symbol: "sparkles") { [weak self] in
                guard let self, let job = self.jobs?.first(where: { $0.id == self.jobId }), let log = self.log else { return }
                cia.explain(repo: self.repo, run: r, job: job, log: log)
            }
            again.isEnabled = !cia.busy.contains(k) && log != nil
            trailing.append(again)
        }
        let c = Card(title: "Likely cause", trailing: trailing)
        if let e {
            c.add(NSTextField.text(e.cause, size: 13, lines: 0))
            if !e.fix.isEmpty { c.add(NSTextField.text("Try: " + e.fix, size: 12.5, color: Palette.mut, lines: 0)) }
        } else if cia.busy.contains(k) {
            c.add(NSTextField.text("The AI reads the log of the failed job and the changed files…", size: 12.5, color: Palette.dim))
        } else if let err = cia.errors[k] {
            c.add(NSTextField.text("Could not explain: \(err)", size: 12.5, color: Palette.bad, lines: 0))
        } else if !cia.canExplain {
            c.add(NSStackView(h: [NSTextField.text("No session works on this run. Turn on AI to get a short cause from the log.", size: 12.5, color: Palette.dim),
                                  Spacer(), ActionButton("AI settings") { [weak self] in self?.go(.settings(.ai)) }], spacing: 8))
        } else {
            c.add(NSTextField.text("Pick the failed job. OverSire explains it when the log loads.", size: 12.5, color: Palette.dim))
        }
        return c
    }

    private func rerun(failed: Bool) {
        guard let r = current else { return }
        busy = failed ? "Re-running the failed jobs…" : "Re-running all jobs…"
        reload()
        data.rerun(repo: repo, runs: [r], failedOnly: failed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.busy = nil
            self?.jobs = nil
            self?.log = nil
            self?.logFor = nil
            self?.load()
        }
    }

    private func cancelRun() {
        let (repo, id) = (self.repo, self.runId)
        busy = "Cancelling…"
        reload()
        q.async { [weak self] in
            let err = runAction(.cancel, repo: repo, id: id)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                self.note = err.map { (.bad, "Could not cancel: \($0)") } ?? (.info, "GitHub cancels the run.")
                self.load()
            }
        }
    }
}

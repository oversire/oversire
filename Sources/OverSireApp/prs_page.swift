import Cocoa
import OverSireCore
import OverSireAssistant

// Review requests and my open PRs, with the linked item and the CI of the branch.
final class PRsPage: Page {
    private var busy: [String: String] = [:]   // row id → verb
    private var errors: [String: String] = [:]
    override var buildsLater: Bool { true }
    override var fillsHeight: Bool { true }
    private let table = ColumnLayout(id: "prs", columns: [
        TableColumn(id: "kind", title: "", width: 58, min: 48),
        TableColumn(id: "title", title: "Pull request", width: 300, min: 160, flexible: true),
        TableColumn(id: "item", title: "Item", width: 112, min: 60),
        TableColumn(id: "ci", title: "CI", width: 104, min: 50, optional: true),
        TableColumn(id: "state", title: "State", width: 110, min: 50, optional: true),
        TableColumn(id: "actions", title: "", width: 170, min: 90),
    ])

    override var watches: DataDomains { [.prs, .runs, .agents, .projects, .config] }

    override func sections() -> [PageSection]? {
        let all = data.prGrouped.flatMap { g in g.1.map { (repo: g.0, pr: $0) } }
            .sorted { a, b in a.pr.mine != b.pr.mine ? !a.pr.mine : a.pr.updatedAt > b.pr.updatedAt }
        let data = data
        let header = PageRow("header", 0) {
            PageHeader("Pull requests", caption: "Review requests and my open PRs. A PR links to its item by branch, or by the key in the title or body.",
                       actions: [ActionButton("Refresh", symbol: "arrow.clockwise") { data.refresh(force: true, completion: nil) }])
        }
        commands.intercept = { [weak self] c in
            switch c {
            case .approve(let repo, let n):
                if let e = all.first(where: { $0.repo == repo && $0.pr.number == n }) { self?.act(repo, e.pr, .approve(nil), verb: "Approve") }
            case .merge(let repo, let n):
                if let e = all.first(where: { $0.repo == repo && $0.pr.number == n }) { self?.act(repo, e.pr, .merge(.squash), verb: "Squash and merge") }
            default: return false
            }
            return true
        }
        guard !all.isEmpty else {
            let loading = data.firstLoad
            let note = PageRow(loading ? "loading" : "empty", 0) {
                loading ? LoadingNote("Loading pull requests")
                    : EmptyNote("No review waits for you, and you have no open pull request. OverSire reads the repos of Settings › Projects and repos with the gh CLI.",
                                symbol: "arrow.triangle.pull")
            }
            return [PageSection("top", rows: [header]), PageSection("prs", rows: [PageRow.list("plain", rows: [note]) { ListCard() }])]
        }
        let reviews = all.filter { !$0.pr.mine }, mine = all.filter { $0.pr.mine }
        var rows: [PageRow] = []
        for (id, title, list) in [("reviews", "Review requests", reviews), ("mine", "My pull requests", mine)] where !list.isEmpty {
            rows.append(StickyListCard.group(id, title, count: list.count))
            rows += list.map { row($0.repo, $0.pr) }
        }
        let table = table
        return [PageSection("top", rows: [header]), PageSection("prs", rows: [PageRow.list("table", rows: rows) { StickyListCard.table(table) }])]
    }

    private func linkedKey(_ repo: String, _ p: ChangeRequest) -> String? {
        data.workstreams.streams.values.first { s in s.prs.contains { $0.repo == repo && $0.pr.number == p.number } }?.key
    }

    // The latest run of each workflow on the PR branch. The worst one gives the tone.
    private func checks(_ repo: String, _ p: ChangeRequest) -> Tone? {
        let runs = latestPerWorkflow((data.grouped.first { $0.0 == repo }?.1 ?? []).filter { $0.headBranch == p.headRefName })
        guard !runs.isEmpty else { return nil }
        if let r = runs.first(where: { $0.status != "completed" }) { return Tone(r) }
        if let r = runs.first(where: \.isFailure) { return Tone(r) }
        return Tone(runs[0])
    }

    private func row(_ repo: String, _ p: ChangeRequest) -> PageRow {
        let id = "\(repo)#\(p.number)"
        let key = linkedKey(repo, p), ci = checks(repo, p)
        return PageRow(id, p, key, ci?.word, ci?.symbol, busy[id], errors[id]) { [weak self] in
            self?.rowView(repo, p) ?? NSView()
        }
    }

    private func rowView(_ repo: String, _ p: ChangeRequest) -> NSView {
        let id = "\(repo)#\(p.number)"
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let kind = Chiplet(p.mine ? "Mine" : "Review", color: p.mine ? Palette.mut : Palette.acc)
        let state = p.isDraft ? "Draft" : (p.reviewDecision.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Open")
        var head = "\(name) #\(p.number) · \(p.headRefName) · +\(p.additions) −\(p.deletions)"
        if !p.mine { head = "@\(p.author.login) · " + head }
        let tail = errors[id].map { " · " + $0 } ?? ""
        let updated = parseISO(p.updatedAt) ?? Date()
        let sub = head + " · " + relativeTime(updated) + tail
        var cells: [String: NSView] = ["kind": kind, "title": TwoLine(p.title, time: updated) { head + " · " + $0 + tail }, "state": Chiplet(state)]
        if let key = linkedKey(repo, p) {
            cells["item"] = Chiplet(key, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(key, .overview)) }
        } else {
            cells["item"] = NSTextField.text("—", color: Palette.dim)
        }
        if let t = checks(repo, p) { cells["ci"] = Chiplet("CI \(t.word.lowercased())", symbol: t.symbol, color: t.color) }
        var actions: [NSView] = []
        if let verb = busy[id] {
            actions.append(InlineSpinner(verb + "…"))
        } else {
            if !p.mine { actions.append(ActionButton("Approve") { [weak self] in self?.act(repo, p, .approve(nil), verb: "Approve") }) }
            actions.append(MenuChip("Merge", symbol: "arrow.triangle.merge") { [weak self] in
                [("Squash and merge", MergeMethod.squash), ("Rebase and merge", .rebase), ("Merge commit", .merge)].map { t, m in
                    MenuAction(t) { self?.act(repo, p, .merge(m), verb: t) }
                }
            })
        }
        cells["actions"] = NSStackView(h: actions, spacing: 6)
        let r = TableRow(table, cells: cells, height: 50, label: "\(p.mine ? "My PR" : "Review request"): \(p.title), \(sub), \(state)") {
            if let u = URL(string: p.url) { NSWorkspace.shared.open(u) }
        }
        r.copyID = "\(p.number)"
        r.copyLink = p.url
        let linked = linkedKey(repo, p)
        commands.attach(r) { RowMenu.pr(repo: repo, pr: p, linkedKey: linked, caps: $0) }
        return r
    }

    // Asks first. A merge or an approval is seen by other people.
    private func act(_ repo: String, _ p: ChangeRequest, _ action: ChangeAction, verb: String) {
        AlertConfirm.ask("\(verb): \(repo.split(separator: "/").last ?? "") #\(p.number)?", info: p.title, button: verb, in: view.window) { [weak self] in
            guard let self else { return }
            let id = "\(repo)#\(p.number)"
            self.busy[id] = verb; self.errors[id] = nil
            self.reload()
            let (aid, args) = action.action(repo: repo, number: p.number)
            self.data.actions.run(aid, args) { [weak self] r in
                guard let self else { return }
                self.busy[id] = nil
                if case .ok = r {} else { self.errors[id] = "\(verb) failed: \(r.summary)" }
                self.reload()
            }
        }
    }
}

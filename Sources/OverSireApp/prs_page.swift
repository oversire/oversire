import Cocoa
import OverSireCore

// Review requests and my open PRs, with the linked item and the CI of the branch.
final class PRsPage: Page {
    private var busy: [String: String] = [:]   // row id → verb
    private var errors: [String: String] = [:]
    private let table = ColumnLayout(id: "prs", columns: [
        TableColumn(id: "kind", title: "", width: 58, min: 48),
        TableColumn(id: "title", title: "Pull request", width: 300, min: 160, flexible: true),
        TableColumn(id: "item", title: "Item", width: 112, min: 60),
        TableColumn(id: "ci", title: "CI", width: 104, min: 50, optional: true),
        TableColumn(id: "state", title: "State", width: 110, min: 50, optional: true),
        TableColumn(id: "actions", title: "", width: 170, min: 90),
    ])

    override func build(_ col: NSStackView) {
        let all = data.prGrouped.flatMap { g in g.1.map { (repo: g.0, pr: $0) } }
            .sorted { a, b in a.pr.mine != b.pr.mine ? !a.pr.mine : a.pr.updatedAt > b.pr.updatedAt }
        col.addFull(PageHeader("Pull requests", caption: "Review requests and my open PRs. A PR links to its item by branch, or by the key in the title or body.",
                               actions: [ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.data.refresh(force: true, completion: nil) }]))
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
        let reviews = all.filter { !$0.pr.mine }, mine = all.filter { $0.pr.mine }
        for (title, list, empty) in [("Review requests", reviews, "No review waits for you."), ("My pull requests", mine, "You have no open pull request.")] {
            col.addFull(SectionTitle(title, count: list.count))
            let card = ListCard()
            if !list.isEmpty { card.add(TableHeader(table)) }
            for e in list { card.add(row(e.repo, e.pr)) }
            if card.isEmpty { card.add(data.firstLoad ? SkeletonRows(count: 3, label: "Loading pull requests") : EmptyNote(empty)) }
            col.addFull(card)
        }
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

    private func row(_ repo: String, _ p: ChangeRequest) -> NSView {
        let id = "\(repo)#\(p.number)"
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let kind = Chiplet(p.mine ? "Mine" : "Review", color: p.mine ? Palette.mut : Palette.acc)
        let state = p.isDraft ? "Draft" : (p.reviewDecision.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Open")
        var sub = "\(name) #\(p.number) · \(p.headRefName) · +\(p.additions) −\(p.deletions) · \(relativeTime(parseISO(p.updatedAt) ?? Date()))"
        if !p.mine { sub = "@\(p.author.login) · " + sub }
        if let e = errors[id] { sub += " · " + e }
        var cells: [String: NSView] = ["kind": kind, "title": TwoLine(p.title, sub), "state": Chiplet(state)]
        if let key = linkedKey(repo, p) {
            cells["item"] = Chiplet(key, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(key, .overview)) }
        } else {
            cells["item"] = NSTextField.text("unlinked", size: 11.5, color: Palette.dim)
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
        let a = NSAlert()
        a.messageText = "\(verb): \(repo.split(separator: "/").last ?? "") #\(p.number)?"
        a.informativeText = p.title
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "Cancel")
        let run = { [weak self] (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn, let self else { return }
            let id = "\(repo)#\(p.number)"
            self.busy[id] = verb; self.errors[id] = nil
            self.reload()
            lastFetchError = nil
            Task { [weak self] in
                await REPO_CLIENT.perform(action, repo: repo, number: p.number)
                await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy[id] = nil
                if let e = lastFetchError { self.errors[id] = "\(verb) failed: \(e)" }
                self.data.refresh(force: true, completion: nil)
                self.reload()
                }
            }
        }
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: run) } else { run(a.runModal()) }
    }
}

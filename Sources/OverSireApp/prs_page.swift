import Cocoa

// Review requests and my open PRs, with the linked item and the CI of the branch.
final class PRsPage: Page {
    private var busy: Set<String> = []
    private var errors: [String: String] = [:]

    override func build(_ col: NSStackView) {
        let all = data.prGrouped.flatMap { g in g.1.map { (repo: g.0, pr: $0) } }
            .sorted { a, b in a.pr.mine != b.pr.mine ? !a.pr.mine : a.pr.updatedAt > b.pr.updatedAt }
        col.addFull(PageHeader("Pull requests", caption: "Review requests and my open PRs. A PR links to its item by branch, or by the key in the title or body.",
                               actions: [ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.data.refresh(force: true, completion: nil) }]))
        let reviews = all.filter { !$0.pr.mine }, mine = all.filter { $0.pr.mine }
        for (title, list, empty) in [("Review requests", reviews, "No review waits for you."), ("My pull requests", mine, "You have no open pull request.")] {
            col.addFull(SectionTitle(title, count: list.count))
            let card = ListCard()
            for e in list { card.add(row(e.repo, e.pr)) }
            if card.isEmpty { card.add(EmptyNote(data.firstLoad ? "Loading…" : empty)) }
            col.addFull(card)
        }
    }

    private func linkedKey(_ repo: String, _ p: PR) -> String? {
        data.workstreams.streams.values.first { s in s.prs.contains { $0.repo == repo && $0.pr.number == p.number } }?.key
    }

    // The latest run of each workflow on the PR branch. The worst one gives the tone.
    private func checks(_ repo: String, _ p: PR) -> Tone? {
        let runs = latestPerWorkflow((data.grouped.first { $0.0 == repo }?.1 ?? []).filter { $0.headBranch == p.headRefName })
        guard !runs.isEmpty else { return nil }
        if let r = runs.first(where: { $0.status != "completed" }) { return Tone(r) }
        if let r = runs.first(where: \.isFailure) { return Tone(r) }
        return Tone(runs[0])
    }

    private func row(_ repo: String, _ p: PR) -> NSView {
        let id = "\(repo)#\(p.number)"
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let kind = Chiplet(p.mine ? "Mine" : "Review", color: p.mine ? Palette.mut : Palette.acc)
        let state = p.isDraft ? "Draft" : (p.reviewDecision.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Open")
        var sub = "\(name) #\(p.number) · \(p.headRefName) · +\(p.additions) −\(p.deletions) · \(relativeTime(parseISO(p.updatedAt) ?? Date()))"
        if !p.mine { sub = "@\(p.author.login) · " + sub }
        if let e = errors[id] { sub += " · " + e }
        var views: [NSView] = [kind, TwoLine(p.title, sub), Spacer()]
        if let key = linkedKey(repo, p) {
            views.append(Chiplet(key, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(key, .overview)) })
        } else {
            views.append(NSTextField.text("unlinked", size: 11.5, color: Palette.dim))
        }
        if let t = checks(repo, p) { views.append(Chiplet("CI \(t.word.lowercased())", symbol: t.symbol, color: t.color)) }
        views.append(Chiplet(state))
        if busy.contains(id) {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
            views.append(spin)
        } else {
            if !p.mine { views.append(ActionButton("Approve") { [weak self] in self?.act(repo, p, .approve(nil), verb: "Approve") }) }
            views.append(MenuChip("Merge", symbol: "arrow.triangle.merge") { [weak self] in
                [("Squash and merge", "-s"), ("Rebase and merge", "-r"), ("Merge commit", "-m")].map { t, m in
                    MenuAction(t) { self?.act(repo, p, .merge(m), verb: t) }
                }
            })
        }
        let r = Row(views, height: 50, label: "\(p.mine ? "My PR" : "Review request"): \(p.title), \(sub), \(state)") {
            if let u = URL(string: p.url) { NSWorkspace.shared.open(u) }
        }
        r.menuItems = { [MenuAction("Open on GitHub") { if let u = URL(string: p.url) { NSWorkspace.shared.open(u) } }.item] }
        return r
    }

    // Asks first. A merge or an approval is seen by other people.
    private func act(_ repo: String, _ p: PR, _ action: PRAction, verb: String) {
        let a = NSAlert()
        a.messageText = "\(verb): \(repo.split(separator: "/").last ?? "") #\(p.number)?"
        a.informativeText = p.title
        a.addButton(withTitle: verb)
        a.addButton(withTitle: "Cancel")
        let run = { [weak self] (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn, let self else { return }
            let id = "\(repo)#\(p.number)"
            self.busy.insert(id); self.errors[id] = nil
            self.reload()
            lastFetchError = nil
            executePRAction(repo: repo, number: p.number, action: action) { [weak self] in
                guard let self else { return }
                self.busy.remove(id)
                if let e = lastFetchError { self.errors[id] = "\(verb) failed: \(e)" }
                self.data.refresh(force: true, completion: nil)
                self.reload()
            }
        }
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: run) } else { run(a.runModal()) }
    }
}

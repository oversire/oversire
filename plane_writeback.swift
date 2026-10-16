import Foundation

// ─── Write-back to Plane ─────────────────────────────────────────────────────
// OverSire adds facts to Plane and never changes text of other people:
// links once each, its own agent:* labels, one OverSire block at the end of the body, one comment.

// The OverSire block in an item body. Only the part between the two marker lines changes.
enum OverSireBlock {
    static let start = "OverSire block ▾ (OverSire updates this part)"
    static let end = "OverSire block ▴"

    static func wrap(_ innerHTML: String) -> String { "<p>\(start)</p>" + innerHTML + "<p>\(end)</p>" }

    // Replaces the block, or adds it at the end. The text before and after the block stays the same.
    static func merge(_ html: String, block innerHTML: String) -> String {
        let new = wrap(innerHTML)
        if let s = html.range(of: start, options: .backwards),
           let open = html.range(of: "<p", options: .backwards, range: html.startIndex..<s.lowerBound),
           let e = html.range(of: end, range: s.upperBound..<html.endIndex),
           let close = html.range(of: "</p>", range: e.upperBound..<html.endIndex) {
            return html.replacingCharacters(in: open.lowerBound..<close.upperBound, with: new)
        }
        return html + new
    }

    static func current(_ html: String) -> String? {
        guard let s = html.range(of: start, options: .backwards), let e = html.range(of: end, range: s.upperBound..<html.endIndex) else { return nil }
        return String(html[s.upperBound..<e.lowerBound])
    }
}

final class PlaneWriteBack {
    static let labelColors = ["session:working": "#56B4E9", "session:needs-input": "#E69F00", "session:done": "#009E73"]

    private struct Done: Codable {
        var links: [String] = []
        var label: String?
        var block: String?
        var commented = false
    }

    private var done: [String: Done] = [:]     // item key → what OverSire wrote
    private var inFlight: Set<String> = []
    private var lastWrite: [String: Date] = [:]
    private let path: String
    private let store: ProjectStore
    private let accounts: PlaneAccounts
    private let q = DispatchQueue(label: "com.oversire.app.writeback", qos: .utility)
    var onError: ((String) -> Void)?

    init(path: String, store: ProjectStore, accounts: PlaneAccounts) {
        self.path = path
        self.store = store
        self.accounts = accounts
        if let d = FileManager.default.contents(atPath: path), let s = try? JSONDecoder().decode([String: Done].self, from: d) { done = s }
    }

    static func label(_ phase: ItemAgent.Phase) -> String? {
        switch phase {
        case .starting, .working: return "session:working"
        case .waiting: return "session:needs-input"
        case .done: return "session:done"
        case .failed: return nil
        }
    }

    // Markdown of the block for a workstream.
    static func blockMarkdown(_ s: Workstream) -> String {
        var lines: [String] = []
        if let a = s.agent {
            let since = DateFormatter.localizedString(from: a.since, dateStyle: .short, timeStyle: .short)
            lines.append("- Session: \(a.phase == .working ? "Working since \(since)" : a.label())")
        }
        for co in s.checkouts where !co.branch.isEmpty { lines.append("- Branch: `\(co.branch)`") }
        for r in s.latestRuns.prefix(3) { lines.append("- CI: [\(r.run.workflowName ?? r.run.name) #\(r.run.number)](\(r.run.url)) \(Tone(r.run).word.lowercased())") }
        for p in s.prs.prefix(2) { lines.append("- PR: [\(p.repo) #\(p.pr.number)](\(p.pr.url)) \(p.pr.isDraft ? "draft" : p.pr.state.lowercased())") }
        lines.append("- Open in OverSire: oversire://item/\(s.key)")
        return lines.joined(separator: "\n")
    }

    // Writes what changed. At most one write per item each 2 minutes.
    func sync(_ streams: [Workstream]) {
        let cfg = AGENTS.writeBack
        guard cfg.enabled else { return }
        for s in streams where s.agent != nil {
            guard let item = s.item, let pk = s.projectKey, let snap = store.snapshots[pk], !inFlight.contains(s.key),
                  -(lastWrite[s.key] ?? .distantPast).timeIntervalSinceNow > 120,
                  let client = accounts.client(for: snap.summary.ref.workspace) else { continue }
            var state = done[s.key] ?? Done()
            let wantLabel = cfg.labels ? s.agent.flatMap { PlaneWriteBack.label($0.phase) } : nil
            var links: [(String, String)] = []
            if cfg.links {
                links += s.prs.map { ($0.pr.url, "PR \($0.repo) #\($0.pr.number)") }
                links += s.latestRuns.prefix(2).map { ($0.run.url, "CI \($0.run.workflowName ?? $0.run.name) #\($0.run.number)") }
            }
            links = links.filter { !state.links.contains($0.0) }
            let block = cfg.block ? PlaneMarkup.html(fromMarkdown: PlaneWriteBack.blockMarkdown(s)) : nil
            let review = cfg.moveToReview && !s.prs.isEmpty && snap.option(item.statusOptionId).map { $0.category == .progress || $0.category == .todo } == true
                ? snap.statusOptions.first { $0.category == .review } : nil
            let needLabel = wantLabel != nil && wantLabel != state.label
            let needBlock = block != nil && block != state.block
            guard needLabel || needBlock || !links.isEmpty || review != nil else { continue }
            inFlight.insert(s.key)
            lastWrite[s.key] = Date()
            let project = snap.summary.ref.id, id = item.id, key = s.key
            q.async { [weak self] in
                var errors: [String] = []
                for (url, title) in links {
                    if case .failure(let e) = client.addLink(project: project, item: id, url: url, title: title) { errors.append(e.message) } else { state.links.append(url) }
                }
                if needLabel, let want = wantLabel {
                    switch PlaneWriteBack.setLabel(client, project: project, item: id, want) {
                    case .success: state.label = want
                    case .failure(let e): errors.append(e.message)
                    }
                }
                if needBlock, let block {
                    let r = client.descriptionHTML(project: project, item: id).flatMap { html in
                        client.update(project: project, item: id, ["description_html": OverSireBlock.merge(html, block: block)])
                    }
                    if case .failure(let e) = r { errors.append(e.message) } else { state.block = block }
                }
                if let review, case .failure(let e) = client.update(project: project, item: id, ["state": review.id]) { errors.append(e.message) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(key)
                    self.done[key] = state
                    self.save()
                    if let e = errors.first { self.onError?("Write-back to \(key): \(e)") }
                }
            }
        }
    }

    // Keeps the labels of other people. Removes only the other session:* labels, and the old agent:* ones.
    private static func setLabel(_ c: PlaneClient, project: String, item: String, _ name: String) -> Result<Void, PlaneError> {
        c.labels(project: project).flatMap { all in
            var ids: [String: String] = [:]
            for l in all where l.name.hasPrefix("session:") || l.name.hasPrefix("agent:") { ids[l.name] = l.id }
            if ids[name] == nil {
                switch c.createLabel(project: project, name: name, color: labelColors[name] ?? "#9CA3AF") {
                case .success(let id): ids[name] = id
                case .failure(let e): return .failure(e)
                }
            }
            let mine = Set(ids.values)
            return c.labelIds(project: project, item: item).flatMap { cur in
                c.update(project: project, item: item, ["labels": cur.filter { !mine.contains($0) } + [ids[name]!]])
            }
        }
    }

    // One comment for the item, when the session ends. It never posts two.
    func comment(key: String, markdown: String, done: @escaping (Bool) -> Void) {
        guard AGENTS.writeBack.enabled, AGENTS.writeBack.sessionComment, self.done[key]?.commented != true,
              let (_, _, item) = store.item(key: key) else { done(false); return }
        store.comment(itemId: item.id, body: markdown) { [weak self] ok in
            if ok { self?.done[key, default: Done()].commented = true; self?.save() }
            done(ok)
        }
    }

    // Adds the block to a pending intake item. Accept is a second step.
    func addBlock(projectKey: String, intake: IntakeItem, markdown: String, done: @escaping (Bool) -> Void) {
        guard let snap = store.snapshots[projectKey], let client = accounts.client(for: snap.summary.ref.workspace) else { done(false); return }
        let project = snap.summary.ref.id
        let block = PlaneMarkup.html(fromMarkdown: markdown)
        q.async {
            let r = client.intakeHTML(project: project, workItem: intake.workItemId).flatMap { html in
                client.updateIntake(project: project, workItem: intake.workItemId, ["description_html": OverSireBlock.merge(html, block: block)])
            }
            DispatchQueue.main.async { done(r.isOk) }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(done) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

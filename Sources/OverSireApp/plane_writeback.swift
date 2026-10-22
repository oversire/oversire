import Foundation
import OverSireCore

// ─── Write-back to Plane ─────────────────────────────────────────────────────
// OverSire adds facts to Plane and never changes text of other people:
// links once each, its own agent:* labels, one OverSire block at the end of the body, one comment.

// The OverSire block in an item body. Only the part between the two marker lines changes.
/// A tracker that keeps item text as HTML. Write-back merges its block into that HTML.
protocol HTMLBodies: Tracker {
    func html(fromMarkdown md: String) -> String
    func descriptionHTML(_ i: ItemRef) async throws -> String
    func setDescription(_ i: ItemRef, html: String) async throws
    func intakeHTML(_ p: ProjectRef, workItem: String) async throws -> String
    func setIntakeDescription(_ p: ProjectRef, workItem: String, html: String) async throws
}

protocol LabelIdReading: Tracker { func labelIds(_ i: ItemRef) async throws -> [String] }

enum OverSireBlock {
    static let start = "OverSire block ▾ (OverSire updates this part)"
    static let end = "OverSire block ▴"
    // Items that Cat Eye wrote keep its markers. The next write replaces them.
    static let markers = [(start, end), ("Cat Eye block ▾ (Cat Eye updates this part)", "Cat Eye block ▴")]

    static func wrap(_ innerHTML: String) -> String { "<p>\(start)</p>" + innerHTML + "<p>\(end)</p>" }

    // Replaces the block, or adds it at the end. The text before and after the block stays the same.
    static func merge(_ html: String, block innerHTML: String) -> String {
        let new = wrap(innerHTML)
        for (start, end) in markers {
            if let s = html.range(of: start, options: .backwards),
               let open = html.range(of: "<p", options: .backwards, range: html.startIndex..<s.lowerBound),
               let e = html.range(of: end, range: s.upperBound..<html.endIndex),
               let close = html.range(of: "</p>", range: e.upperBound..<html.endIndex) {
                return html.replacingCharacters(in: open.lowerBound..<close.upperBound, with: new)
            }
        }
        return html + new
    }

    static func current(_ html: String) -> String? {
        for (start, end) in markers {
            if let s = html.range(of: start, options: .backwards), let e = html.range(of: end, range: s.upperBound..<html.endIndex) {
                return String(html[s.upperBound..<e.lowerBound])
            }
        }
        return nil
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
    private let trackers: TrackerDirectory
    var onError: ((String) -> Void)?

    init(path: String, store: ProjectStore, trackers: TrackerDirectory) {
        self.path = path
        self.store = store
        self.trackers = trackers
        if let d = FileManager.default.contents(atPath: path), let s = try? JSONDecoder().decode([String: Done].self, from: d) { done = s }
    }

    static func label(_ a: AgentSession) -> String? {
        if a.needsInput { return "session:needs-input" }
        switch a.phase {
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
                  let client = trackers.tracker(snap.summary.ref.workspace) else { continue }
            var state = done[s.key] ?? Done()
            let wantLabel = cfg.labels ? s.agent.flatMap { PlaneWriteBack.label($0) } : nil
            var links: [(String, String)] = []
            if cfg.links {
                links += s.prs.map { ($0.pr.url, "PR \($0.repo) #\($0.pr.number)") }
                links += s.latestRuns.prefix(2).map { ($0.run.url, "CI \($0.run.workflowName ?? $0.run.name) #\($0.run.number)") }
            }
            links = links.filter { !state.links.contains($0.0) }
            let block = cfg.block ? PlaneWriteBack.blockMarkdown(s) : nil
            let review = cfg.moveToReview && !s.prs.isEmpty && snap.option(item.statusOptionId).map { $0.category == .progress || $0.category == .todo } == true
                ? snap.statusOptions.first { $0.category == .review } : nil
            let needLabel = wantLabel != nil && wantLabel != state.label
            let needBlock = block != nil && block != state.block
            guard needLabel || needBlock || !links.isEmpty || review != nil else { continue }
            inFlight.insert(s.key)
            lastWrite[s.key] = Date()
            guard let ref = item.ref(in: snap.summary.ref) else { continue }
            let key = s.key
            Task { [weak self] in
                var errors: [String] = []
                for (url, title) in links {
                    guard let u = URL(string: url), let client = client as? any LinkManaging else { continue }
                    if case .failure(let e) = await Result(awaiting: { try await client.addLink(ref, url: u, title: title) }) {
                        errors.append(e.message)
                    } else { state.links.append(url) }
                }
                if needLabel, let want = wantLabel {
                    switch await Result(awaiting: { try await PlaneWriteBack.setLabel(client, ref, want) }) {
                    case .success: state.label = want
                    case .failure(let e): errors.append(e.message)
                    }
                }
                if needBlock, let block {
                    let r = await Result(awaiting: {
                        guard let client = client as? any HTMLBodies else { throw ProviderError.unsupported(.annotations) }
                        let html = try await client.descriptionHTML(ref)
                        try await client.setDescription(ref, html: OverSireBlock.merge(html, block: client.html(fromMarkdown: block)))
                    })
                    if case .failure(let e) = r { errors.append(e.message) } else { state.block = block }
                }
                if let review, case .failure(let e) = await Result(awaiting: { try await client.update(ref, ItemPatch(status: review.id)) }) {
                    errors.append(e.message)
                }
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
    private static func setLabel(_ t: any Tracker, _ item: ItemRef, _ name: String) async throws {
        guard let c = t as? any LabelManaging else { throw ProviderError.unsupported(.labels) }
        var ids: [String: String] = [:]
        for l in try await c.labels(item.project) where l.name.hasPrefix("session:") || l.name.hasPrefix("agent:") { ids[l.name] = l.id }
        if ids[name] == nil {
            ids[name] = try await c.createLabel(name, color: labelColors[name] ?? "#9CA3AF", in: item.project)
        }
        let mine = Set(ids.values)
        let cur: [String]
        if let c = c as? any LabelIdReading { cur = try await c.labelIds(item) } else { cur = try await c.detail(item).item.labels }
        try await c.update(item, ItemPatch(labels: cur.filter { !mine.contains($0) } + [ids[name]!]))
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
        guard let snap = store.snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else { done(false); return }
        let project = snap.summary.ref
        Task {
            let r = await Result(awaiting: {
                guard let client = client as? any HTMLBodies else { throw ProviderError.unsupported(.intake) }
                let html = try await client.intakeHTML(project, workItem: intake.workItemId)
                try await client.setIntakeDescription(project, workItem: intake.workItemId, html: OverSireBlock.merge(html, block: client.html(fromMarkdown: markdown)))
            })
            DispatchQueue.main.async { done(r.isOk) }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(done) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

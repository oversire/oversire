import Foundation
import OverSireCore

// ─── Provider events ─────────────────────────────────────────────────────────
// Mappers from the polled domain data to event rows, one for each provider protocol. Each mapper keeps the last state
// that it sent for each subject, so a poll with no change gives no row. The ids follow event.json, so a webhook of the
// same change gives the same id, and the daemon drops the repeat.

/// The rows of CI runs: ci.queued, ci.started, ci.completed and ci.rerun.
public struct CIEvents: Sendable {
    /// The id prefix: "gha" for GitHub Actions.
    public let source: String
    /// The adapter, for example "github".
    public let provider: String
    /// On the first sight of a run, older runs give no row.
    public var horizon: TimeInterval = 3 * 86400
    private var sent: [String: Int] = [:]

    public init(source: String, provider: String) {
        self.source = source
        self.provider = provider
    }

    /// The id prefix of the CI of a provider.
    public static func source(of provider: String) -> String { provider == "github" ? "gha" : provider }

    /// The new rows of the runs of one repo. item gives the item key of a run.
    public mutating func drafts(repo: String, runs: [Run], machine: String, now: Date = Date(), item: (Run) -> String?) -> [EventDraft] {
        var out: [EventDraft] = []
        for r in runs {
            let attempt = r.attempt ?? 1
            let subject = "\(r.id):\(attempt)"
            let rank = Self.rank(r.phase)
            let last = sent[subject]
            if let last, last >= rank { continue }
            if last == nil, let at = parseISO(r.updatedAt), now.timeIntervalSince(at) > horizon { continue }
            sent[subject] = rank
            func row(_ kind: Event.Kind, _ verb: String, at: Date?, _ summary: String, actorType: ActorType = .provider,
                     actor: String = "github-actions", extra: [String: JSONValue] = [:]) {
                var p = Self.payload(r, attempt: attempt)
                p.merge(extra) { _, b in b }
                out.append(EventDraft(id: "\(source):\(r.id):\(attempt):\(verb)", at: at ?? now, kind: kind, item: item(r),
                                      repo: repo, machine: machine, provider: provider, actorType: actorType, actor: actor,
                                      via: "poll", summary: summary, payload: p))
            }
            let name = "\(Self.short(repo)) \(r.workflowName ?? r.name) #\(r.number)"
            if last == nil, attempt > 1 {
                let human = r.actorLogin.map { !$0.hasSuffix("[bot]") } ?? false
                row(.ciRerun, "rerun", at: parseISO(r.createdAt), "\(name) attempt \(attempt)",
                    actorType: human ? .human : .provider, actor: human ? r.actorLogin! : "github-actions")
            }
            if rank == 0 { row(.ciQueued, "queued", at: parseISO(r.createdAt), "\(name) queued on \(r.headBranch)") }
            if rank >= 1, (last ?? -1) < 1, rank == 1 || r.startedAt != nil {
                row(.ciStarted, "started", at: parseISO(r.startedAt) ?? parseISO(r.createdAt), "\(name) started on \(r.headBranch)")
            }
            if rank == 2 {
                let c = r.conclusion ?? "failure"
                var extra: [String: JSONValue] = [:]
                if Self.conclusions.contains(c) { extra["conclusion"] = .string(c) }
                if let s = parseISO(r.startedAt) ?? parseISO(r.createdAt), let e = parseISO(r.updatedAt), e >= s {
                    extra["durationSec"] = .int(Int(e.timeIntervalSince(s)))
                }
                row(.ciCompleted, "completed", at: parseISO(r.updatedAt), "\(name) \(Self.word(c))", extra: extra)
            }
        }
        return out
    }

    /// A ci.completed row with the first failed jobs and steps.
    public static func withFailures(_ d: EventDraft, _ f: [Failure]) -> EventDraft {
        guard d.kind == .ciCompleted, !f.isEmpty else { return d }
        var d = d
        let rows = f.prefix(3).map { x -> JSONValue in
            var o: [String: JSONValue] = ["job": .string(x.job)]
            if let s = x.step { o["step"] = .string(s) }
            return .object(o)
        }
        d.payload?["failed"] = .array(Array(rows))
        d.summary = EventDraft.clip(d.summary + ": " + (f[0].step ?? f[0].job))
        return d
    }

    static let conclusions: Set<String> = ["success", "failure", "cancelled", "skipped", "timed_out"]

    static func rank(_ p: RunStatus) -> Int {
        switch p {
        case .queued: return 0
        case .running: return 1
        case .completed: return 2
        }
    }

    static func word(_ c: String) -> String {
        switch c {
        case "success": return "passed"
        case "failure": return "failed"
        case "cancelled": return "was cancelled"
        case "timed_out": return "timed out"
        default: return c.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func payload(_ r: Run, attempt: Int) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["workflow": .string(r.workflowName ?? r.name), "run": .int(r.number), "attempt": .int(attempt),
                                      "branch": .string(r.headBranch), "headSha": .string(String(r.headSha.prefix(12))),
                                      "url": .string(r.url)]
        if r.headBranch.isEmpty { p["branch"] = nil }
        return p
    }

    static func short(_ repo: String) -> String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// The rows of pull requests: pr.opened, pr.updated, pr.merged and pr.closed.
public struct ChangeEvents: Sendable {
    /// The id prefix: "gh-pr" for GitHub.
    public let source: String
    public let provider: String
    private var open: [String: [Int: ChangeRequest]] = [:]

    public init(source: String, provider: String) {
        self.source = source
        self.provider = provider
    }

    public static func source(of provider: String) -> String { provider == "github" ? "gh-pr" : provider + "-pr" }

    /// The new rows of the open changes of one repo, and the changes that left the open list. The caller reads the
    /// end state of each gone change and gives it to `ended`.
    public mutating func drafts(repo: String, open list: [ChangeRequest], machine: String, now: Date = Date(),
                                item: (ChangeRequest) -> String?) -> (drafts: [EventDraft], gone: [ChangeRequest]) {
        let before = open[repo]
        var out: [EventDraft] = []
        var next: [Int: ChangeRequest] = [:]
        for c in list {
            next[c.number] = c
            if let prev = before?[c.number] {
                if let sha = c.headSha, let old = prev.headSha, sha != old {
                    out.append(row(.prUpdated, "updated:\(sha)", c, repo: repo, machine: machine, at: parseISO(c.updatedAt) ?? now,
                                   "#\(c.number) new head \(sha.prefix(7))", item: item(c)))
                }
            } else {
                out.append(row(.prOpened, "opened", c, repo: repo, machine: machine, at: parseISO(c.createdAt) ?? now,
                               "#\(c.number) \(c.title)", item: item(c)))
            }
        }
        open[repo] = next
        let gone = (before ?? [:]).values.filter { next[$0.number] == nil }.sorted { $0.number < $1.number }
        return (out, gone)
    }

    /// The row of a change that left the open list: pr.merged or pr.closed. nil while it is still open.
    public func ended(repo: String, _ c: ChangeRequest, machine: String, now: Date = Date(), item: String?) -> EventDraft? {
        switch c.state.uppercased() {
        case "MERGED":
            let sha = c.mergeSha.map { " as \($0.prefix(7))" } ?? ""
            return row(.prMerged, "merged", c, repo: repo, machine: machine, at: parseISO(c.updatedAt) ?? now, "#\(c.number) merged\(sha)",
                       item: item, actorType: .provider, actor: provider)
        case "CLOSED":
            return row(.prClosed, "closed", c, repo: repo, machine: machine, at: parseISO(c.updatedAt) ?? now, "#\(c.number) closed", item: item)
        default: return nil
        }
    }

    private func row(_ kind: Event.Kind, _ verb: String, _ c: ChangeRequest, repo: String, machine: String, at: Date, _ summary: String,
                     item: String?, actorType: ActorType = .human, actor: String? = nil) -> EventDraft {
        var p: [String: JSONValue] = ["number": .int(c.number), "title": .string(c.title), "url": .string(c.url)]
        if !c.headRefName.isEmpty { p["branch"] = .string(c.headRefName) }
        if !c.baseRefName.isEmpty { p["base"] = .string(c.baseRefName) }
        if let s = c.headSha { p["headSha"] = .string(String(s.prefix(12))) }
        if let s = c.mergeSha { p["mergeSha"] = .string(String(s.prefix(12))) }
        return EventDraft(id: "\(source):\(repo)#\(c.number):\(verb)", at: at, kind: kind, item: item, repo: repo, machine: machine,
                          provider: provider, actorType: actorType, actor: actor ?? c.author.login, via: "poll", summary: summary, payload: p)
    }
}

/// The rows of tracker changes: item.created, item.updated, item.state_changed, comment.created and intake.created.
public enum TrackerEvents {
    /// The rows of the changes of one poll of a project. skipState: the items whose state change this app wrote already.
    public static func drafts(_ changes: [(itemId: String, ItemChange)], old: ProjectSnapshot?, new snap: ProjectSnapshot, provider: String,
                              machine: String, skipState: Set<String> = []) -> [EventDraft] {
        let project = snap.summary.identifier.lowercased()
        let byId = Dictionary(snap.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [EventDraft] = []
        var fields: [String: [String]] = [:]
        func row(_ kind: Event.Kind, _ id: String, _ i: Item, at: Date, actor: String?, _ summary: String, _ payload: [String: JSONValue]) {
            out.append(EventDraft(id: "\(provider):\(id)", at: at, kind: kind, item: i.key, project: project, machine: machine, provider: provider,
                                  actorType: actor == nil ? .provider : .human, actor: actor ?? provider, via: "poll", summary: summary,
                                  payload: payload))
        }
        for (id, change) in changes {
            guard let i = byId[id] else { continue }
            let ms = Int64(i.updatedAt.timeIntervalSince1970 * 1000)
            switch change {
            case .added:
                var p: [String: JSONValue] = ["title": .string(i.title)]
                if let s = snap.statusName(i.statusOptionId) { p["state"] = .string(s) }
                row(.itemCreated, "\(i.id):created", i, at: i.updatedAt, actor: i.author, i.title, p)
            case .status(let from, let to):
                guard !skipState.contains(id), let to else { continue }
                var p: [String: JSONValue] = ["to": .string(to)]
                if let from { p["from"] = .string(from) }
                if let g = snap.option(i.statusOptionId)?.group { p["group"] = .string(g) }
                row(.itemStateChanged, "\(i.id):state:\(i.statusOptionId ?? to):\(ms)", i, at: i.updatedAt, actor: i.updatedBy,
                    "\(from ?? "None") → \(to)", p)
            case .field(let name, _, _): fields[id, default: []].append(name)
            case .assigned, .unassigned: fields[id, default: []].append("Assignees")
            case .comments(_, let last):
                let text = (last.body ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? "New comment"
                out.append(EventDraft(id: "\(provider)-comment:\(last.id)", at: last.createdAt, kind: .commentCreated, item: i.key, project: project,
                                      machine: machine, provider: provider, actorType: last.author == nil ? .provider : .human,
                                      actor: last.author ?? provider, via: "poll", summary: text,
                                      payload: ["comment": .string(last.id), "url": .string(last.url)]))
            case .removed, .closed, .reopened, .mention, .away: continue
            }
        }
        for (id, names) in fields.sorted(by: { $0.key < $1.key }) {
            guard let i = byId[id] else { continue }
            let list = Array(Set(names)).sorted()
            row(.itemUpdated, "\(i.id):updated:\(Int64(i.updatedAt.timeIntervalSince1970 * 1000))", i, at: i.updatedAt, actor: i.updatedBy,
                list.joined(separator: ", "), ["fields": .array(list.prefix(20).map { .string($0) })])
        }
        let known = Set(old?.intake?.map(\.id) ?? [])
        if old != nil {
            for x in snap.intake ?? [] where !known.contains(x.id) {
                out.append(EventDraft(id: "\(provider)-intake:\(x.id):created", at: x.createdAt, kind: .intakeCreated, project: project,
                                      machine: machine, provider: provider, actorType: x.author == nil ? .provider : .human,
                                      actor: x.author ?? provider, via: "poll", summary: x.name,
                                      payload: ["intake": .string(x.id), "title": .string(x.name)]))
            }
        }
        return out
    }

    /// The parent key of each loaded item. An item whose parent is not loaded gives no link.
    public static func links(_ snap: ProjectSnapshot) -> [ItemLink] {
        let keys = Dictionary(snap.items.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        let parents = Dictionary((snap.index ?? []).map { ($0.id, $0.parentId) }, uniquingKeysWith: { a, _ in a })
        return snap.items.compactMap { i in
            guard let p = i.parentId ?? parents[i.id] ?? nil else { return ItemLink(item: i.key, parent: nil) }
            return keys[p].map { ItemLink(item: i.key, parent: $0) }
        }
    }
}

/// The rows of epic changes: epic.created, epic.item_added, epic.item_removed and epic.closed.
public enum EpicEvents {
    /// The rows of one poll. Without an old snapshot with epics, it writes the whole history (backfill).
    /// `mine`: the item ids that this app moved. Their rows name `me` as the human actor.
    public static func drafts(old: ProjectSnapshot?, new snap: ProjectSnapshot, provider: String, machine: String,
                              mine: Set<String> = [], me: String? = nil) -> [EventDraft] {
        guard let epics = snap.epics else { return [] }
        let project = snap.summary.identifier.lowercased()
        let backfill = old?.epics == nil
        var keys: [String: String] = [:]
        for s in [old, snap] {
            for i in s?.items ?? [] { keys[i.id] = i.key }
            for i in s?.index ?? [] { if let k = i.key { keys[i.id] = k } }
        }
        var out: [EventDraft] = []
        func row(_ kind: Event.Kind, _ id: String, at: Date, item: String?, parent: String?, itemId: String? = nil, _ summary: String,
                 _ payload: [String: JSONValue]) {
            let human = itemId.map(mine.contains) == true && me != nil
            out.append(EventDraft(id: "\(provider):\(id)", at: at, kind: kind, item: item, parentItem: parent, project: project, machine: machine,
                                  provider: provider, actorType: human ? .human : .provider, actor: human ? me! : provider, via: "poll",
                                  summary: summary, payload: payload))
        }
        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
        func title(_ id: EpicID) -> String { (epics.first { $0.id == id } ?? old?.epic(id))?.title ?? id.rawValue }
        func add(_ e: Epic, _ itemId: String, from: EpicID?) {
            guard let key = keys[itemId] else { return }
            let known = e.linkedAt?[itemId]
            let at = known ?? (backfill ? e.createdAt ?? snap.fetchedAt : snap.fetchedAt)
            var p: [String: JSONValue] = ["epic": .string(e.id.rawValue), "title": .string(e.title)]
            if let from { p["from"] = .string(from.rawValue) }
            row(.epicItemAdded, "epic-\(e.id):add:\(itemId):\(ms(at))", at: at, item: key, parent: e.eventKey, itemId: itemId,
                "Added to \(e.title)", p)
        }
        func remove(_ id: EpicID, _ itemId: String, to: EpicID?) {
            guard let key = keys[itemId] else { return }
            let e = epics.first { $0.id == id } ?? old?.epic(id)
            var p: [String: JSONValue] = ["epic": .string(id.rawValue), "title": .string(title(id))]
            if let to { p["to"] = .string(to.rawValue) }
            row(.epicItemRemoved, "epic-\(id):remove:\(itemId):\(ms(snap.fetchedAt))", at: snap.fetchedAt, item: key,
                parent: e?.eventKey, itemId: itemId, "Removed from \(title(id))", p)
        }
        func closed(_ e: Epic) {
            let at = e.updatedAt ?? snap.fetchedAt
            let state = e.state == .done ? "done" : "canceled"
            var p: [String: JSONValue] = ["epic": .string(e.id.rawValue), "title": .string(e.title), "state": .string(state)]
            p["open"] = .int(snap.rollup(e).open)
            row(.epicClosed, "epic-\(e.id):closed:\(ms(at))", at: at, item: e.eventKey, parent: nil, "\(e.title) \(state)", p)
        }
        func created(_ e: Epic) {
            var p: [String: JSONValue] = ["epic": .string(e.id.rawValue), "title": .string(e.title)]
            if let t = e.targetDate { p["targetDate"] = .string(t.formatted(.iso8601)) }
            row(.epicCreated, "epic-\(e.id):created", at: e.createdAt ?? snap.fetchedAt, item: e.eventKey, parent: nil, e.title, p)
        }

        if backfill {
            for e in epics {
                created(e)
                for m in snap.members(of: e.id).sorted(by: { $0.id < $1.id }) { add(e, m.id, from: nil) }
                if e.state.isClosed { closed(e) }
            }
            return out
        }
        let known = Set((old?.epics ?? []).map(\.id))
        for e in epics where !known.contains(e.id) { created(e) }
        for e in epics where known.contains(e.id) && e.state.isClosed && old?.epic(e.id)?.state.isClosed == false { closed(e) }
        let ids = Set(snap.items.map(\.id) + (snap.index ?? []).map(\.id))
        for id in ids.sorted() {
            let (was, now) = (old?.epicId(of: id), snap.epicId(of: id))
            guard was != now else { continue }
            if let was { remove(was, id, to: now) }
            if let now, let e = snap.epic(now) { add(e, id, from: was) }
        }
        return out
    }
}

import Foundation
import GitHubKit
import OverSireCore
import OverSireSync

// ─── Event desk ──────────────────────────────────────────────────────────────
// The event rows of this app (OVERSIRE-382): the provider polls (CI, PRs, tracker) and your actions. The rows go to the
// local daemon, which sends them home, else to the home daemon. Main thread only.

/// Takes the rows and the item links of the desk. EventSender is the real one.
protocol EventOutlet: Sendable {
    func append(_ drafts: [EventDraft]) async
    func link(_ links: [ItemLink]) async
}

extension EventSender: EventOutlet {}

final class EventDesk: @unchecked Sendable {
    /// object: the new Event of a daemon frame.
    static let received = Notification.Name("EventDeskReceived")
    static let viewEvery: TimeInterval = 600

    private let outlet: any EventOutlet
    private var ci: [String: CIEvents] = [:]
    private var prs: [String: ChangeEvents] = [:]
    private var viewed: [String: Date] = [:]
    private var held: [String: String] = [:]

    /// This Mac in the machine group.
    var machine: () -> String = { EventDesk.hostName }
    /// The email of the user. config.json keeps it.
    var email: () -> String? = { MY_EMAIL }
    var now: () -> Date = Date.init
    /// The item key of a run.
    var runItem: (String, Run) -> String? = { _, _ in nil }
    /// The item key of a change.
    var changeItem: (String, ChangeRequest) -> String? = { _, _ in nil }
    /// The adapter of the CI and the code host of a repo.
    var provider: (String) -> String = { _ in "github" }
    /// The failed jobs and steps of a run.
    var failures: (String, String) async -> [Failure] = { _, _ in [] }
    /// The end state of a change that left the open list.
    var endState: (String, ChangeRequest) async -> ChangeRequest? = { _, _ in nil }

    init(outlet: any EventOutlet) { self.outlet = outlet }

    static var hostName: String { ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac" }

    var actor: String { email() ?? NSUserName() }
    var via: String { "app@\(machine())" }

    // MARK: Provider polls

    func runs(_ res: [(String, [Run])]) {
        let at = now()
        var out: [EventDraft] = []
        for (repo, runs) in res {
            let p = provider(repo)
            var m = ci[p] ?? CIEvents(source: CIEvents.source(of: p), provider: p)
            out += m.drafts(repo: repo, runs: runs, machine: machine(), now: at) { [runItem] r in runItem(repo, r) }
            ci[p] = m
        }
        // A fresh failure gets its failed steps first. That costs two calls, so an old failure goes without them.
        let fresh = out.filter { $0.kind == .ciCompleted && $0.payload?["conclusion"] == .string("failure") && at.timeIntervalSince($0.at) < 3600 }
        let rest = out.filter { d in !fresh.contains { $0.id == d.id } }
        send(rest)
        guard !fresh.isEmpty else { return }
        let failures = failures
        Task { [self] in
            var done: [EventDraft] = []
            for d in fresh {
                let id = d.id.split(separator: ":").dropFirst().first.map(String.init) ?? ""
                done.append(CIEvents.withFailures(d, await failures(d.repo ?? "", id)))
            }
            let rows = done
            await MainActor.run { self.send(rows) }
        }
    }

    func changes(_ res: [(String, [ChangeRequest])]) {
        var out: [EventDraft] = []
        var gone: [(String, ChangeRequest)] = []
        for (repo, list) in res {
            let p = provider(repo)
            var m = prs[p] ?? ChangeEvents(source: ChangeEvents.source(of: p), provider: p)
            let r = m.drafts(repo: repo, open: list, machine: machine(), now: now()) { [changeItem] c in changeItem(repo, c) }
            prs[p] = m
            out += r.drafts
            gone += r.gone.map { (repo, $0) }
        }
        send(out)
        guard !gone.isEmpty else { return }
        let endState = endState
        Task { [self] in
            var ends: [(String, ChangeRequest)] = []
            for (repo, c) in gone { if let e = await endState(repo, c) { ends.append((repo, e)) } }
            let list = ends
            await MainActor.run {
                self.send(list.compactMap { repo, c in
                    let p = self.provider(repo)
                    return self.prs[p]?.ended(repo: repo, c, machine: self.machine(), now: self.now(), item: self.changeItem(repo, c))
                })
            }
        }
    }

    /// The changes of one tracker poll, and the parent of each item. skipState: the items whose state you set in OverSire.
    func tracker(_ changes: [(itemId: String, ItemChange)], old: ProjectSnapshot?, new snap: ProjectSnapshot, skipState: Set<String>) {
        let p = snap.summary.ref.account.provider.rawValue
        send(TrackerEvents.drafts(changes, old: old, new: snap, provider: p, machine: machine(), skipState: skipState))
        let links = TrackerEvents.links(snap)
        guard !links.isEmpty else { return }
        Task { [outlet] in await outlet.link(links) }
    }

    // MARK: Your actions

    /// A row of an action that you did in this app. verb makes the id unique with the time.
    func action(_ kind: Event.Kind, item: String?, project: String? = nil, verb: String, _ summary: String, payload: [String: JSONValue]? = nil) {
        let at = now()
        let id = "app:\(machine()):\(item ?? "-"):\(verb):\(Int64(at.timeIntervalSince1970 * 1000))"
        send([EventDraft(id: id, at: at, kind: kind, item: item, project: project?.lowercased(), machine: machine(), actorType: .human,
                         actor: actor, via: via, summary: summary, payload: payload)])
    }

    /// A row of the app itself, for you: the queue.
    func system(_ kind: Event.Kind, item: String?, project: String?, actor: String, verb: String, _ summary: String,
                payload: [String: JSONValue]? = nil) {
        let at = now()
        let id = "app:\(machine()):\(item ?? "-"):\(verb):\(Int64(at.timeIntervalSince1970 * 1000))"
        send([EventDraft(id: id, at: at, kind: kind, item: item, project: project?.lowercased(), machine: machine(), actorType: .system,
                         actor: actor, onBehalf: email(), via: via, summary: summary, payload: payload)])
    }

    /// You opened an item page or acted on an item. At most one row each 10 min for each item.
    func viewed(_ key: String, page: String) {
        let k = key.uppercased(), at = now()
        if let last = viewed[k], at.timeIntervalSince(last) < Self.viewEvery { return }
        viewed[k] = at
        action(.itemViewed, item: k, verb: "viewed", "Opened \(page)", payload: ["page": .string(page)])
    }

    /// The queue holds an item. A new reason gives a new row; the same reason again gives none.
    func held(_ key: String, project: String, lane: String, reason: String) {
        guard held[key] != reason else { return }
        held[key] = reason
        system(.queueHeld, item: key, project: project, actor: "queue", verb: "held", reason,
               payload: ["lane": .string(lane), "reason": .string(reason)])
    }

    /// You set the state of an item in OverSire. The next tracker poll skips this change.
    func stateSet(_ i: Item, in snap: ProjectSnapshot, to optionId: String) {
        guard let to = snap.option(optionId) else { return }
        var p: [String: JSONValue] = ["to": .string(to.name)]
        let from = snap.statusName(i.statusOptionId)
        if let from { p["from"] = .string(from) }
        if let g = to.group { p["group"] = .string(g) }
        action(.itemStateChanged, item: i.key, project: snap.summary.identifier, verb: "state", "\(from ?? "None") → \(to.name)", payload: p)
    }

    /// The queue no longer holds the item.
    func released(_ key: String) { held[key] = nil }

    // MARK: Daemon frames

    func received(_ e: Event) { NotificationCenter.default.post(name: Self.received, object: e) }

    private func send(_ drafts: [EventDraft]) {
        guard !drafts.isEmpty else { return }
        Task { [outlet] in await outlet.append(drafts) }
    }
}

let EVENTS: EventDesk = {
    let sender = EventSender {
        guard let (machines, live, http) = await MainActor.run(body: { () -> (Machines, [MachineLink], any HTTPTransport)? in
            guard let hub = ENV.machines else { return nil }
            return (hub.machines, hub.links.filter { hub.isLive($0.machine) }, hub.http)
        }) else { return nil }
        if let l = live.first(where: \.local) { return l.client(http: http) }
        let home = await machines.group?.home.rawValue
        return live.first { $0.machine == home }?.client(http: http)
    }
    return EventDesk(outlet: sender)
}()

// ─── Your email ──────────────────────────────────────────────────────────────

/// A tracker that knows the email of the token owner.
protocol OwnerEmail: Tracker { func ownerEmail() async -> String? }

enum MyEmail {
    /// The email of the tracker member, else of the gh user, else of git config. nil when none answers.
    static func find(trackers: [any Tracker], gh: GitHubClient, run: any CommandRunner) async -> String? {
        for t in trackers {
            if let e = await (t as? any OwnerEmail)?.ownerEmail(), e.contains("@") { return e }
        }
        if let d = try? await gh.cli(["api", "user", "--jq", ".email"]), let e = clean(d) { return e }
        if let o = try? await run.run("/usr/bin/git", ["config", "--global", "user.email"], stdin: nil, timeout: .seconds(5)),
           o.status == 0, let e = clean(o.stdout) { return e }
        return nil
    }

    static func clean(_ d: Data) -> String? {
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains("@") && s != "null" ? s : nil
    }
}

extension GHActionsBar {
    /// Gives the desk the links of this app, and finds your email once.
    func startEvents() {
        EVENTS.machine = { [weak self] in self?.machineHub.links.first(where: \.local)?.machine ?? EventDesk.hostName }
        EVENTS.runItem = { [weak self] repo, r in
            guard let self else { return nil }
            let known = Set(self.projectStore.tracked.map { $0.identifier.uppercased() })
            let prs = self.prGrouped.flatMap { g in g.1.map { (repo: g.0, pr: $0) } }
            return WorkstreamIndex.match(repo: repo, run: r, checkouts: self.workstreams.checkouts, prs: prs, known: known, rules: LINKING)?.0
        }
        EVENTS.changeItem = { [weak self] repo, c in
            guard let self else { return nil }
            let known = Set(self.projectStore.tracked.map { $0.identifier.uppercased() })
            return WorkstreamIndex.key(forPR: c, known: known, checkouts: self.workstreams.checkouts, repo: repo)
        }
        EVENTS.provider = { repo in REPO_CLIENT.branchHost(repo)?.host.account.provider.rawValue ?? "github" }
        EVENTS.failures = { repo, id in
            await REPO_CLIENT.failures(repo, runId: id, jobs: await REPO_CLIENT.jobs(repo, runId: id) ?? [])
        }
        EVENTS.endState = { repo, c in
            guard !c.headRefName.isEmpty, let (h, ref) = REPO_CLIENT.branchHost(repo) else { return nil }
            return try? await h.changes(ref, head: c.headRefName).first { $0.number == c.number }
        }
        guard MY_EMAIL == nil else { return }
        let trackers = ENV.trackers()
        Task {
            guard let e = await MyEmail.find(trackers: trackers, gh: GITHUB, run: ProcessRunner()) else { return }
            await MainActor.run {
                MY_EMAIL = e
                saveConfig()
            }
        }
    }
}

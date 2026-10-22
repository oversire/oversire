import Foundation
import OverSireCore
import OverSireAssistant

// ─── Work context ────────────────────────────────────────────────────────────
// The facts of one work item from the data that the app holds. The item page and the read actions use it,
// so they show the same facts. `facts` reads on the main thread and makes no calls.
// `load` adds the tracker timeline and the failed jobs of failed runs.

struct WorkContext {
    let data: AppData
    var machines: () -> MachinesSnapshot = { MachinesController.shared.snapshot }
    /// The cloud work orders. Empty without a cloud account.
    var orders: (AppData) -> [WorkOrder] = { $0.relay.canRun ? CloudAIRecords.load(STORE_WRITES).orders : [] }
    var jobs: (_ repo: String, _ runId: String) async -> [Job]? = { await WorkContext.readJobs($0, $1) }

    /// The job read of `load` and run.get. Tests replace it.
    static var readJobs: (_ repo: String, _ runId: String) async -> [Job]? = { await REPO_CLIENT.jobs($0, runId: $1) }

    static let maxBody = 4_000
    static let maxText = 300
    static let maxActivity = 10
    /// `load` reads the jobs of at most this many failed runs.
    static let maxJobRuns = 3

    init(_ data: AppData) { self.data = data }

    // MARK: Facts

    /// Main thread.
    func facts(_ key: String) -> WorkFacts {
        let k = key.uppercased()
        var f = WorkFacts(key: k)
        let store = data.projectStore
        let found = store.item(key: k)
        if let (pk, snap, item) = found {
            itemFacts(&f, pk: pk, snap: snap, item: item)
        } else {
            f.notes.append("OverSire has no loaded item \(k).")
        }
        let stream = data.workstreams.stream(k)
        f.prs = (stream?.prs ?? []).map { r, p in
            WorkFacts.PR(repo: r, number: p.number, title: p.title, state: p.state, url: p.url, head: p.headRefName, base: p.baseRefName,
                         draft: p.isDraft, review: p.reviewDecision, author: p.author.login, mine: p.mine, updatedAt: p.updatedAt)
        }.sorted { $0.updatedAt > $1.updatedAt }
        if let b = stream?.branches.first {
            f.branch = b
            f.branchFrom = "checkout"
        } else if let b = f.prs.first?.head {
            f.branch = b
            f.branchFrom = "pr"
        } else if let (_, snap, item) = found {
            f.branch = PROJECTS_CFG.local(snap.summary.identifier).branch(for: item)
            f.branchFrom = "template"
        }
        f.runs = runs(stream: stream, prs: f.prs)
        f.ci = stream?.ci.map { $0.word == Tone.bad.word ? "failed" : $0.word == Tone.running.word ? "running" : "ok" }
        f.sessions = sessions(k, stream: stream)
        f.questions = data.questions.entries.filter { $0.state == .open && data.questions.key($0.question)?.uppercased() == k }.map { e in
            let q = e.question
            return WorkFacts.Question(id: q.id.rawValue, text: Self.short(q.items.map(\.text).joined(separator: " / ")), items: q.items.count,
                                      via: q.via.rawValue, askedAt: q.askedAt)
        }
        f.queue = queue(k)
        f.orders = orders(data).filter { $0.itemKey?.uppercased() == k }.map {
            WorkFacts.Order(id: $0.id, state: $0.state.rawValue, runner: $0.runner, createdAt: $0.createdAt, hold: $0.hold?.text)
        }
        return f
    }

    private func itemFacts(_ f: inout WorkFacts, pk: String, snap: ProjectSnapshot, item: Item) {
        let store = data.projectStore
        f.item = Self.itemFacts(item, snap: snap, maxBody: Self.maxBody)
        let kids = snap.children(of: item.id)
        f.subItems = kids.map { WorkFacts.SubItem(key: $0.key, title: $0.title, status: snap.statusName($0.statusOptionId), done: snap.isFinished($0)) }
        let p = snap.progress(of: item.id)
        if p.total > 0 { f.progress = WorkFacts.Progress(done: p.done, total: p.total) }
        if p.total > kids.count { f.notes.append("\(p.total - kids.count) sub-items are not loaded.") }
        let k = item.key.uppercased()
        if let rels = store.relations.relations(k) {
            f.relations = rels.map { r in
                let other = store.item(key: r.item.key)
                return WorkFacts.Relation(kind: r.kind.rawValue, key: r.item.key, title: other?.item.title, done: other.map { _ in store.isDone(key: r.item.key) })
            }
        } else if store.relations.supports(k) {
            f.notes.append(store.relations.errors[k].map { "The relations did not load: \($0)" } ?? "The relations are not loaded yet.")
        }
        f.blockers = store.blockers(of: k)
        f.areas = data.areas.areas(key: k)
        f.activity = store.activity(limit: 500, project: pk).filter { $0.itemId == item.id }.prefix(Self.maxActivity).map {
            WorkFacts.Activity(at: $0.at, text: $0.text, actor: $0.actor)
        }
    }

    /// The latest run of each workflow: on each PR head, on the other linked branches, and on the base branches of the repos.
    private func runs(stream: Workstream?, prs: [WorkFacts.PR]) -> [WorkFacts.Run] {
        let byRepo = Dictionary(data.grouped.map { ($0.0, $0.1.sorted { lastActivity($0) > lastActivity($1) }) }, uniquingKeysWith: { a, _ in a })
        var out: [WorkFacts.Run] = []
        var seen = Set<String>()
        func add(_ repo: String, _ list: [Run], onBase: Bool) {
            for r in latestPerWorkflow(list) where seen.insert(repo + "|" + r.id).inserted {
                let pr = onBase ? nil : prs.first { $0.repo == repo && $0.head == r.headBranch }?.number
                var jobs: [WorkFacts.Job]?
                if r.isFailure, let hit = jobsCache[r.id], hit.updatedAt == r.updatedAt { jobs = Self.failed(hit.jobs) }
                out.append(WorkFacts.Run(repo: repo, id: r.id, workflow: r.workflowName ?? r.name, branch: r.headBranch, sha: r.headSha,
                                         status: r.status, conclusion: r.conclusion, url: r.url, updatedAt: r.updatedAt, pr: pr, onBase: onBase, failedJobs: jobs))
            }
        }
        for p in prs { add(p.repo, (byRepo[p.repo] ?? []).filter { $0.headBranch == p.head }, onBase: false) }
        let linked = Dictionary(grouping: (stream?.runs ?? []).sorted { lastActivity($0.run) > lastActivity($1.run) }, by: \.repo)
        for (repo, list) in linked.sorted(by: { $0.key < $1.key }) { add(repo, list.map(\.run), onBase: false) }
        let repos = Set(prs.map(\.repo)).union(linked.keys)
        for repo in repos.sorted() {
            let bases = Set(prs.filter { $0.repo == repo }.map(\.base))
            add(repo, (byRepo[repo] ?? []).filter { (bases.isEmpty ? DEFAULT_BRANCHES : bases).contains($0.headBranch) }, onBase: true)
        }
        return out
    }

    private func sessions(_ k: String, stream: Workstream?) -> [WorkFacts.Session] {
        let snap = machines()
        let me = snap.info?.machine.rawValue
        var out: [WorkFacts.Session] = []
        if let a = data.agentIndex.agent(k) {
            out.append(WorkFacts.Session(machine: me ?? "this Mac", local: true, agent: a.agent.rawValue,
                                         state: data.agentIndex.state(k)?.rawValue ?? "\(a.phase)", since: a.since, repo: a.repo.isEmpty ? nil : a.repo,
                                         branch: stream?.branches.first, workspace: a.card, message: a.message.map(Self.short)))
        }
        for (m, list) in snap.sessions.sorted(by: { $0.key < $1.key }) where m != me {
            for s in list where Self.key(of: s) == k {
                out.append(WorkFacts.Session(machine: m, local: false, agent: s.harness, state: s.reason == .question ? "needsInput" : s.state.rawValue,
                                             since: s.stateSince, repo: s.repo, branch: s.branch, workspace: s.workspace, message: s.lastMessage.map(Self.short)))
            }
        }
        return out
    }

    func queue(_ k: String) -> WorkFacts.Queue? {
        let q = data.queue
        guard let lane = q.lanes.first(where: { $0.entries.contains { $0.key == k } }), let i = lane.entries.firstIndex(where: { $0.key == k }) else { return nil }
        let world = q.world(workstreams: data.workstreams)
        let pick = lane.pick(state: q.state(lane.project), world: world)
        let e = lane.entries[i]
        let why: String?
        if let err = q.state(lane.project)?.error {
            why = err
        } else if let h = pick.holds[k] {
            switch h {
            case .waits(let keys): why = "Waits on the open blockers \(keys.joined(separator: ", "))."
            case .area(let a, let other): why = "The area \(a) is busy: \(other) runs."
            case .unknown: why = "The relations are not loaded yet."
            }
        } else if let next = pick.next, next != k {
            why = "\(next) starts first."
        } else if pick.entry == nil {
            let busy = world.busy(lane), slots = world.slots(lane)
            why = busy >= slots ? "No free slot: \(busy) of \(slots) sessions run." : "The start condition: \(e.condition.label)."
        } else {
            why = nil
        }
        return WorkFacts.Queue(project: lane.identifier, position: i + 1, length: lane.entries.count, condition: e.condition.rawValue, waits: why)
    }

    // MARK: Load

    /// The facts plus the tracker timeline and the failed jobs. At most `maxJobRuns` job calls.
    func load(key: String) async -> WorkFacts {
        let data = data
        var f = await MainActor.run { facts(key) }
        let timeline: [ActivityEntry] = await withCheckedContinuation { c in
            DispatchQueue.main.async {
                guard let found = data.projectStore.item(key: key) else { c.resume(returning: []); return }
                data.projectStore.timeline(itemId: found.item.id) { c.resume(returning: $0) }
            }
        }
        if !timeline.isEmpty {
            f.activity = timeline.sorted { $0.at > $1.at }.prefix(Self.maxActivity).map { e in
                if case .comments(_, let c) = e.change {
                    return WorkFacts.Activity(at: c.createdAt, text: "Comment: " + Self.short(c.body ?? ""), actor: c.author)
                }
                return WorkFacts.Activity(at: e.at, text: e.text, actor: e.actor)
            }
        }
        for i in f.runs.indices.filter({ f.runs[$0].failed && f.runs[$0].failedJobs == nil }).prefix(Self.maxJobRuns) {
            let r = f.runs[i]
            guard let list = await jobs(r.repo, r.id) else { f.notes.append("The jobs of run \(r.id) did not load."); continue }
            f.runs[i].failedJobs = Self.failed(list)
            await MainActor.run { jobsCache[r.id] = (r.updatedAt, list) }
        }
        return f
    }

    // MARK: Helpers

    /// `maxBody` 0: no body. Nil: the whole body.
    static func itemFacts(_ item: Item, snap: ProjectSnapshot, maxBody: Int?) -> WorkFacts.ItemFacts {
        let opt = snap.option(item.statusOptionId)
        var body = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = maxBody, body.count > m { body = m == 0 ? "" : String(body.prefix(m)) + "…" }
        return WorkFacts.ItemFacts(key: item.key, title: item.title, url: item.url, project: snap.summary.identifier, status: opt?.name,
                                   group: (opt?.category ?? .todo).rawValue, priority: item.fields["Priority"], assignees: item.assignees,
                                   labels: item.labels, parent: item.parentId.flatMap { p in snap.items.first { $0.id == p }?.key },
                                   updatedAt: item.updatedAt, body: body.isEmpty ? nil : body)
    }

    static func failed(_ jobs: [Job]) -> [WorkFacts.Job] {
        jobs.filter { $0.conclusion == "failure" }.map { WorkFacts.Job(id: $0.id, name: $0.name, conclusion: $0.conclusion, url: $0.url) }
    }

    static func short(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > maxText ? String(t.prefix(maxText)) + "…" : t
    }

    /// The item key of a daemon session: the branch, the workspace name, or a `.wt/<key>` folder.
    static func key(of s: DaemonSession) -> String? {
        if let b = s.branch, let k = WorkstreamIndex.key(inBranch: b, known: []) { return k }
        if let w = s.workspace, let k = WorkstreamIndex.key(in: w, known: [], whole: true) { return k }
        let parts = s.cwd.split(separator: "/").map(String.init)
        if let i = parts.lastIndex(of: ".wt"), i + 1 < parts.count { return WorkstreamIndex.key(in: parts[i + 1], known: [], whole: true) }
        return nil
    }
}

import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The read actions of the assistant. They read what the app holds and make no tracker or code host calls,
// except the jobs of one run. Each result has a short summary and JSON data of at most `JSONValue.readLimit` bytes.
struct ReadActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        [workContext, itemGet, itemList, prList, prGet, runList, runGet, sessionList, questionList, queueList, activityList, insightsSummary, cloudStatus]
    }

    private var workContext: ActionSpec {
        let link = link
        return ActionSpec(id: "work.context", title: "Work context", help: "Reads all that OverSire knows about an item: item, sub-items, relations, blockers, areas, branch, PRs, "
                   + "runs with failed jobs, agent sessions on all machines, open questions, queue position and why it waits, work orders, last activity. "
                   + "`notes` tells what is not known.", kind: .read, input: ActionSpec.args(["key": ItemActions.key], required: ["key"])) { a in
            guard let k = a.string("key"), !k.isEmpty else { return .notAllowed("Give the key of an item, for example OVERSIRE-12.") }
            guard let d = await link.main(nil as AppData?, { d, done in done(d) }) else { return .failed("The app is closing.") }
            let f = await WorkContext(d).load(key: k)
            guard f.item != nil || !f.prs.isEmpty || !f.sessions.isEmpty else { return .notAllowed("OverSire has no loaded item \(k.uppercased()).") }
            return Self.ok(f.summary, JSONValue(encoding: f))
        }
    }

    private var itemGet: ActionSpec {
        let link = link
        return ActionSpec(id: "item.get", title: "Item", help: "Reads one item: title, status, group, priority, assignees, labels, parent, Markdown body, "
                   + "sub-items, comment count and the last comment.", kind: .read, input: ActionSpec.args(["key": ItemActions.key], required: ["key"])) { a in
            await link.item(a) { _, f, done in
                var o = JSONValue(encoding: WorkContext.itemFacts(f.item, snap: f.snap, maxBody: nil))?.object ?? [:]
                o["subItems"] = JSONValue(encoding: f.snap.children(of: f.item.id).map {
                    WorkFacts.SubItem(key: $0.key, title: $0.title, status: f.snap.statusName($0.statusOptionId), done: f.snap.isFinished($0))
                })
                o["commentCount"] = .int(f.item.commentCount)
                if let c = f.item.lastComment { o["lastComment"] = JSONValue(encoding: c) }
                done(Self.ok("\(f.item.key): \(f.item.title)", .object(o)))
            }
        }
    }

    private var itemList: ActionSpec {
        let link = link
        return ActionSpec(id: "item.list", title: "Items", help: "Lists the loaded items, active first. Filters: `project`, `group` (todo, progress, review, blocked, done), "
                   + "`assignee` (a name, or me), `label`, `text`. Returns {items, total}.", kind: .read,
                   input: ActionSpec.args(["project": ItemActions.project, "group": ("string", "todo, progress, review, blocked or done."),
                                           "assignee": ("string", "An assignee name or id, or me."), "label": ("string", "A label name."),
                                           "text": ("string", "Words in the key, title or body."), "limit": ("integer", "At most this many items. Default 50, at most 200.")])) { a in
            await link.run { d, done in
                var snaps = Array(d.projectStore.snapshots.values).sorted { $0.summary.identifier < $1.summary.identifier }
                if let p = a.string("project"), !p.isEmpty {
                    guard let s = d.projectStore.snapshot(p) else { done(.notAllowed("OverSire has no loaded project \(p).")); return }
                    snaps = [s]
                }
                let group = a.string("group")?.lowercased(), who = a.string("assignee")?.lowercased(), label = a.string("label")?.lowercased()
                let all = snaps.flatMap { snap in
                    snap.sorted(snap.items).filter { i in
                        if let group, !group.isEmpty, (snap.option(i.statusOptionId)?.category ?? .todo).rawValue != group { return false }
                        if let who, !who.isEmpty {
                            let me = [snap.me, snap.meId].compactMap { $0?.lowercased() }
                            guard i.assignees.contains(where: { who == "me" ? me.contains($0.lowercased()) : $0.lowercased() == who }) else { return false }
                        }
                        if let label, !label.isEmpty, !i.labels.contains(where: { $0.lowercased() == label }) { return false }
                        return i.matches(a.string("text") ?? "")
                    }.map { WorkContext.itemFacts($0, snap: snap, maxBody: 0) }
                }
                let shown = Array(all.prefix(Self.limit(a, 50)))
                done(Self.ok("\(all.count) item\(all.count == 1 ? "" : "s").", .object(["items": JSONValue(encoding: shown) ?? .array([]), "total": .int(all.count)])))
            }
        }
    }

    private var prList: ActionSpec {
        let link = link
        return ActionSpec(id: "pr.list", title: "Pull requests", help: "Lists the loaded pull requests with their item key. `mine` true: yours; false: review requests. "
                   + "`state`: open, merged or closed. Returns {prs, total}.", kind: .read,
                   input: ActionSpec.args(["repo": RepoActions.repo, "mine": ("boolean", "True: your PRs. False: the PRs that ask for your review."),
                                           "state": ("string", "open, merged or closed."), "limit": ("integer", "Default 50, at most 200.")])) { a in
            await link.run { d, done in
                let r = a.string("repo") ?? "", mine = a.bool("mine"), state = a.string("state") ?? ""
                var list: [(repo: String, pr: ChangeRequest)] = []
                for (repo, prs) in d.prGrouped where r.isEmpty || repo.caseInsensitiveCompare(r) == .orderedSame {
                    for p in prs where (mine == nil || p.mine == mine) && (state.isEmpty || p.state.caseInsensitiveCompare(state) == .orderedSame) {
                        list.append((repo, p))
                    }
                }
                list.sort { $0.pr.updatedAt > $1.pr.updatedAt }
                let rows: [JSONValue] = list.prefix(Self.limit(a, 50)).map { Self.pr($0.repo, $0.pr, d) }
                done(Self.ok("\(list.count) PR\(list.count == 1 ? "" : "s").", .object(["prs": .array(rows), "total": .int(list.count)])))
            }
        }
    }

    private var prGet: ActionSpec {
        let link = link
        return ActionSpec(id: "pr.get", title: "Pull request", help: "Reads one loaded pull request: state, branches, review, size, labels, body, its item key and the latest run of each workflow on its head.",
                   kind: .read, input: ActionSpec.args(["repo": RepoActions.repo, "number": RepoActions.number], required: ["repo", "number"])) { a in
            await link.run { d, done in
                guard let r = a.string("repo"), let n = a.int("number"),
                      let p = d.prGrouped.first(where: { $0.0.caseInsensitiveCompare(r) == .orderedSame })?.1.first(where: { $0.number == n }) else {
                    done(.notAllowed("OverSire has no loaded PR \(a.string("repo") ?? "")#\(a.int("number") ?? 0).")); return
                }
                var o = Self.pr(r, p, d).object ?? [:]
                o["additions"] = .int(p.additions)
                o["deletions"] = .int(p.deletions)
                o["labels"] = .array(p.labels.map { .string($0.name) })
                if let b = p.body { o["body"] = .string(b) }
                let runs = latestPerWorkflow((d.grouped.first { $0.0 == r }?.1 ?? []).filter { $0.headBranch == p.headRefName }.sorted { lastActivity($0) > lastActivity($1) })
                o["runs"] = .array(runs.map { Self.run(r, $0, d) })
                done(Self.ok("\(r)#\(n) \(p.title) (\(p.state.lowercased())).", .object(o)))
            }
        }
    }

    private var runList: ActionSpec {
        let link = link
        return ActionSpec(id: "run.list", title: "Runs", help: "Lists the loaded workflow runs, newest first, with their item key. `failed` true: only the failures that count "
                   + "(the latest run of each workflow, not ignored). Returns {runs, total}.", kind: .read,
                   input: ActionSpec.args(["repo": RepoActions.repo, "failed": ("boolean", "Only the failing runs."), "branch": ("string", "Only runs on this branch."),
                                           "limit": ("integer", "Default 30, at most 200.")])) { a in
            await link.run { d, done in
                let only = a.string("repo").flatMap { $0.isEmpty ? nil : $0 }
                let groups = d.grouped.filter { g in only.map { g.0.caseInsensitiveCompare($0) == .orderedSame } ?? true }
                var list = a.bool("failed") == true ? failingRuns(groups) : groups.flatMap { g in g.1.map { (repo: g.0, run: $0) } }
                if let b = a.string("branch"), !b.isEmpty { list = list.filter { $0.run.headBranch == b } }
                list.sort { lastActivity($0.run) > lastActivity($1.run) }
                let rows = list.prefix(Self.limit(a, 30)).map { Self.run($0.repo, $0.run, d) }
                done(Self.ok("\(list.count) run\(list.count == 1 ? "" : "s")\(a.bool("failed") == true ? " failing" : "").",
                             .object(["runs": .array(rows), "total": .int(list.count)])))
            }
        }
    }

    private var runGet: ActionSpec {
        let link = link
        return ActionSpec(id: "run.get", title: "Run", help: "Reads one loaded workflow run with its jobs, the failed steps of each job and the saved AI explanation. "
                   + "Read a job log with run.log.", kind: .read,
                   input: ActionSpec.args(["repo": RepoActions.repo, "runId": RepoActions.runId, "jobs": ("boolean", "Read the jobs. Default true.")], required: ["repo", "runId"])) { a in
            guard let r = a.string("repo"), let id = a.string("runId") else { return .notAllowed("Give the repo and the run id.") }
            let found: (JSONValue, Run, [Job]?)? = await link.main(nil) { d, done in
                guard let run = d.grouped.first(where: { $0.0.caseInsensitiveCompare(r) == .orderedSame })?.1.first(where: { $0.id == id }) else { done(nil); return }
                var o = Self.run(r, run, d).object ?? [:]
                if let e = d.ciAssist.explanation(run) { o["explanation"] = .object(["cause": .string(e.cause), "fix": .string(e.fix), "confidence": .string("\(e.confidence)")]) }
                done((.object(o), run, jobsCache[id].flatMap { $0.updatedAt == run.updatedAt ? $0.jobs : nil }))
            }
            guard let (base, run, cached) = found else { return .notAllowed("OverSire has no loaded run \(id) in \(r).") }
            var o = base.object ?? [:]
            if a.bool("jobs") ?? true {
                var jobs = cached
                if jobs == nil, let fetched = await WorkContext.readJobs(r, id) {
                    jobs = fetched
                    await MainActor.run { jobsCache[id] = (run.updatedAt, fetched) }
                }
                if let jobs {
                    o["jobs"] = .array(jobs.map { j in
                        var x: [String: JSONValue] = ["id": .string(j.id), "name": .string(j.name)]
                        if let s = j.status { x["status"] = .string(s) }
                        if let c = j.conclusion { x["conclusion"] = .string(c) }
                        if let u = j.url { x["url"] = .string(u) }
                        let bad = (j.steps ?? []).filter { $0.conclusion == "failure" }.map { JSONValue.string($0.name) }
                        if !bad.isEmpty { x["failedSteps"] = .array(bad) }
                        return .object(x)
                    })
                } else {
                    o["notes"] = .array([.string("The jobs did not load.")])
                }
            }
            return Self.ok("\(run.workflowName ?? run.name) #\(run.number): \(run.conclusion ?? run.status).", .object(o))
        }
    }

    private var sessionList: ActionSpec {
        let link = link
        return ActionSpec(id: "session.list", title: "Sessions", help: "Lists the agent sessions: the item sessions on this Mac and the sessions on the other machines of the group. "
                   + "Returns {sessions}, each with the item key when OverSire knows it.", kind: .read) { _ in
            await link.run { d, done in
                let snap = MachinesController.shared.snapshot
                let ctx = WorkContext(d)
                var rows: [JSONValue] = []
                for k in d.agentIndex.agents.keys.sorted() {
                    for s in ctx.facts(k).sessions where s.local { rows.append(Self.adding(JSONValue(encoding: s), ["key": .string(k)])) }
                }
                let me = snap.info?.machine.rawValue
                for (m, list) in snap.sessions.sorted(by: { $0.key < $1.key }) where m != me {
                    for s in list {
                        let f = WorkFacts.Session(machine: m, local: false, agent: s.harness, state: s.reason == .question ? "needsInput" : s.state.rawValue,
                                                  since: s.stateSince, repo: s.repo, branch: s.branch, workspace: s.workspace, message: s.lastMessage.map(WorkContext.short))
                        rows.append(Self.adding(JSONValue(encoding: f), ["key": WorkContext.key(of: s).map(JSONValue.string) ?? .null]))
                    }
                }
                done(Self.ok("\(rows.count) session\(rows.count == 1 ? "" : "s").", .object(["sessions": .array(rows)])))
            }
        }
    }

    private var questionList: ActionSpec {
        let link = link
        return ActionSpec(id: "question.list", title: "Questions", help: "Lists the agent questions that wait for an answer, with their items and options. Answer with question.answer. "
                   + "`all` true adds the answered ones. Returns {questions}.", kind: .read,
                   input: ActionSpec.args(["all": ("boolean", "Also the answered and closed questions.")])) { a in
            await link.run { d, done in
                let list = a.bool("all") == true ? d.questions.entries : d.questions.open
                let rows: [JSONValue] = list.map { e in
                    let q = e.question
                    let state: String
                    switch e.state {
                    case .open: state = "open"
                    case .sending: state = "sending"
                    case .answeredHere, .answeredElsewhere: state = "answered"
                    case .raced: state = "raced"
                    case .gone: state = "gone"
                    }
                    return .object([
                        "id": .string(q.id.rawValue), "key": d.questions.key(q).map(JSONValue.string) ?? .null, "state": .string(state),
                        "via": .string(q.via.rawValue), "answerable": .bool(q.answerable), "askedAt": JSONValue(encoding: q.askedAt) ?? .null,
                        "items": .array(q.items.map { i in
                            .object(["id": .string(i.id), "text": .string(i.text), "kind": .string(i.kind.rawValue),
                                     "options": .array(i.options.map { .string($0.label) }), "allowsOther": .bool(i.allowsOther)])
                        }),
                    ])
                }
                done(Self.ok("\(rows.count) question\(rows.count == 1 ? "" : "s").", .object(["questions": .array(rows)])))
            }
        }
    }

    private var queueList: ActionSpec {
        let link = link
        return ActionSpec(id: "queue.list", title: "Queue", help: "Lists the queue lanes: slots, running items, and the entries in order with their start condition and why each waits. "
                   + "Also the open Planner plan changes. Returns {lanes, plans}.", kind: .read) { _ in
            await link.run { d, done in
                let q = d.queue, ctx = WorkContext(d)
                let world = q.world(workstreams: d.workstreams)
                let lanes: [JSONValue] = q.lanes.map { lane in
                    var o: [String: JSONValue] = ["project": .string(lane.identifier), "slots": .int(world.slots(lane)),
                                                  "running": .array(q.running(lane).sorted().map(JSONValue.string))]
                    if let e = q.state(lane.project)?.error { o["error"] = .string(e) }
                    o["entries"] = .array(lane.entries.map { e in
                        var x: [String: JSONValue] = ["key": .string(e.key), "title": .string(e.title), "condition": .string(e.condition.rawValue),
                                                      "source": .string(e.source.rawValue)]
                        if let f = ctx.queue(e.key) {
                            x["position"] = .int(f.position)
                            if let w = f.waits { x["waits"] = .string(w) }
                        }
                        return .object(x)
                    })
                    return .object(o)
                }
                let plans = d.suggestions.openPlans().map { s in JSONValue.object(["id": .string(s.id), "lane": s.lane.map(JSONValue.string) ?? .null]) }
                done(Self.ok("\(q.count) item\(q.count == 1 ? "" : "s") in \(q.lanes.count) lane\(q.lanes.count == 1 ? "" : "s").",
                             .object(["lanes": .array(lanes), "plans": .array(plans)])))
            }
        }
    }

    private var activityList: ActionSpec {
        let link = link
        return ActionSpec(id: "activity.list", title: "Activity", help: "Lists the tracker activity, newest first: status changes, comments, assignments. Returns {entries}.", kind: .read,
                   input: ActionSpec.args(["project": ItemActions.project, "unread": ("boolean", "Only unread entries."),
                                           "limit": ("integer", "Default 30, at most 200.")])) { a in
            await link.run { d, done in
                var pk: String?
                if let p = a.string("project"), !p.isEmpty {
                    guard let s = d.projectStore.snapshot(p) else { done(.notAllowed("OverSire has no loaded project \(p).")); return }
                    pk = s.summary.ref.storeKey
                }
                let list = d.projectStore.activity(limit: 500, project: pk).filter { a.bool("unread") != true || $0.unread }.prefix(Self.limit(a, 30))
                let rows: [JSONValue] = list.map { e in
                    .object(["at": JSONValue(encoding: e.at) ?? .null, "key": d.projectStore.item(e.itemId).map { .string($0.item.key) } ?? .null,
                             "text": .string(e.text), "actor": e.actor.map(JSONValue.string) ?? .null, "unread": .bool(e.unread), "url": .string(e.url)])
                }
                done(Self.ok("\(rows.count) entr\(rows.count == 1 ? "y" : "ies").", .object(["entries": .array(rows)])))
            }
        }
    }

    private var insightsSummary: ActionSpec {
        let link = link
        return ActionSpec(id: "insights.summary", title: "Insights", help: "Reads the counters of Home and Insights: failing and running runs, the CI pass rate of 7 days, open PRs and reviews, "
                   + "your items, items closed and PRs merged this week, session hours this week.", kind: .read) { _ in
            await link.run { d, done in
                let now = Date(), cal = Calendar.current
                let runs = d.grouped.flatMap(\.1)
                let pass = WorkStats.passRate(runs, now: now, calendar: cal)
                let rv = WorkStats.reviews(d.prGrouped.flatMap(\.1))
                let mine = MainActor.assumeIsolated { WorkPage.mine(d) }
                let todo = mine.filter { ($0.snap.option($0.item.statusOptionId)?.category ?? .todo) == .todo }.count
                let closed = WorkStats.closed(d.projectStore.activity(limit: 2000, project: nil), mine: { e in
                    d.projectStore.snapshots[e.projectKey].flatMap { s in s.items.first { $0.id == e.itemId }?.isMine(s.me) } ?? false
                }, now: now, calendar: cal)
                let merged = d.stats.merged(repos: REPOS)
                let hours = d.stats.sessionHours
                let working = d.agentIndex.agents.keys.filter { d.agentIndex.state($0) == .working }.count
                let failing = failingRuns(d.grouped).count
                let o: [String: JSONValue] = [
                    "runs": .object(["failing": .int(failing), "running": .int(runs.filter { $0.status != "completed" }.count),
                                     "passRate7d": pass.rate.map(JSONValue.double) ?? .null, "passRateDaily": .array(pass.daily.map { $0.map(JSONValue.double) ?? .null })]),
                    "prs": .object(["open": .int(d.prGrouped.reduce(0) { $0 + $1.1.count }), "reviewsWaiting": .int(rv.count),
                                    "oldestReview": rv.oldest.flatMap { JSONValue(encoding: $0) } ?? .null]),
                    "items": .object(["mineInProgress": .int(mine.count - todo), "mineNotStarted": .int(todo), "closedThisWeek": .int(closed.reduce(0, +)),
                                      "closedPerDay": .array(closed.map(JSONValue.int))]),
                    "merged": .object(["thisWeek": merged.map { .int($0.reduce(0, +)) } ?? .null, "perDay": merged.map { .array($0.map(JSONValue.int)) } ?? .null]),
                    "sessions": .object(["open": .int(d.agentIndex.agents.count), "working": .int(working),
                                         "hoursThisWeek": .double((hours.reduce(0, +) * 10).rounded() / 10), "hoursPerDay": .array(hours.map { .double(($0 * 10).rounded() / 10) })]),
                ]
                done(Self.ok("\(failing) failing run\(failing == 1 ? "" : "s") · \(rv.count) review\(rv.count == 1 ? "" : "s") wait · \(mine.count - todo) items in progress.", .object(o)))
            }
        }
    }

    private var cloudStatus: ActionSpec {
        let link = link
        return ActionSpec(id: "cloud.status", title: "Cloud status", help: "Reads the OverSire Cloud state that the app holds: on or off, the connection, the hub health and devices, "
                   + "credits, runners and work orders. It does not call the cloud.", kind: .read) { _ in
            await link.run { d, done in
                var o: [String: JSONValue] = ["enabled": .bool(RELAY.enabled), "connected": .bool(d.relay.canRun)]
                switch d.relay.state {
                case .off: o["state"] = .string("off")
                case .connecting: o["state"] = .string("connecting")
                case .live: o["state"] = .string("live")
                case .error(let e): o["state"] = .string("error"); o["error"] = .string(e)
                }
                if !RELAY.workerURL.isEmpty { o["url"] = .string(RELAY.workerURL) }
                if let t = d.relay.lastEventAt { o["lastEventAt"] = JSONValue(encoding: t) }
                if let t = d.relay.lastPoll { o["lastPoll"] = JSONValue(encoding: t) }
                if let h = d.cloudSetup.state.health {
                    o["hub"] = .object([
                        "version": h.version.map(JSONValue.string) ?? .null, "events": .int(h.events), "retentionHours": .int(h.retentionHours),
                        "rowsWrittenToday": .int(h.rowsWrittenToday),
                        "lastWebhookAt": h.lastWebhookAt.flatMap { JSONValue(encoding: Date(timeIntervalSince1970: $0 / 1000)) } ?? .null,
                        "devices": .array(h.devices.map { v in
                            .object(["name": .string(v.name ?? v.id), "connected": .bool(v.connected), "lag": .int(v.lag),
                                     "lastSeen": v.lastSeen.flatMap { JSONValue(encoding: Date(timeIntervalSince1970: $0 / 1000)) } ?? .null])
                        }),
                    ])
                }
                if d.relay.canRun {
                    let r = CloudAIRecords.load(STORE_WRITES)
                    if let b = r.billing {
                        o["credits"] = .object(["plan": .string(b.plan), "balanceUSD": .double(Double(b.balanceMicroUSD) / 1_000_000),
                                                "grantLeftUSD": .double(Double(b.grantLeftMicroUSD) / 1_000_000), "used80": .bool(b.notice80Sent)])
                    }
                    o["runners"] = .array(r.runners.map { .object(["device": .string($0.device), "online": .bool($0.online), "version": .string($0.version)]) })
                    o["orders"] = .object(Dictionary(grouping: r.orders, by: \.state.rawValue).mapValues { .int($0.count) })
                }
                let summary = !RELAY.enabled ? "OverSire Cloud is off." : "OverSire Cloud: \(o["state"]?.string ?? "off")."
                done(Self.ok(summary, .object(o)))
            }
        }
    }

    // MARK: Rows

    static func ok(_ summary: String, _ data: JSONValue?) -> ActionResult { .ok(summary: summary, data: data.map { $0.clipped() }) }

    static func limit(_ a: ActionArgs, _ fallback: Int) -> Int { min(200, max(1, a.int("limit") ?? fallback)) }

    static func adding(_ v: JSONValue?, _ fields: [String: JSONValue]) -> JSONValue {
        .object((v?.object ?? [:]).merging(fields) { _, b in b })
    }

    static func pr(_ repo: String, _ p: ChangeRequest, _ d: AppData) -> JSONValue {
        let f = WorkFacts.PR(repo: repo, number: p.number, title: p.title, state: p.state, url: p.url, head: p.headRefName, base: p.baseRefName,
                             draft: p.isDraft, review: p.reviewDecision, author: p.author.login, mine: p.mine, updatedAt: p.updatedAt)
        let k = WorkstreamIndex.key(forPR: p, known: [], checkouts: d.workstreams.checkouts, repo: repo)
        return adding(JSONValue(encoding: f), ["key": k.map(JSONValue.string) ?? .null])
    }

    static func run(_ repo: String, _ r: Run, _ d: AppData) -> JSONValue {
        var o: [String: JSONValue] = ["repo": .string(repo), "id": .string(r.id), "number": .int(r.number), "workflow": .string(r.workflowName ?? r.name),
                                      "title": .string(r.displayTitle), "branch": .string(r.headBranch), "sha": .string(r.headSha), "event": .string(r.event),
                                      "status": .string(r.status), "url": .string(r.url), "updatedAt": .string(r.updatedAt)]
        if let c = r.conclusion { o["conclusion"] = .string(c) }
        if let k = d.workstreams.link(runId: r.id)?.key { o["key"] = .string(k) }
        if IGNORED.contains(r) { o["ignored"] = .bool(true) }
        return .object(o)
    }
}

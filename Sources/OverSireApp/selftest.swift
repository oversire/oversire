import Cocoa
import OverSireCore
import OverSireSync


// Runnable check: `oversire --selftest` exercises the report math without a UI.
func runSelfTest() {
    func check(_ cond: Bool, _ msg: String) {
        if !cond { FileHandle.standardError.write(("SELFTEST FAIL: " + msg + "\n").data(using: .utf8)!); exit(1) }
    }
    func rec(_ wf: String, _ concl: String, _ dur: Double, _ branch: String = "main", ago: Double) -> DeployRecord {
        let iso = isoFmt.string(from: Date().addingTimeInterval(-ago))
        return DeployRecord(repo: "o/r", workflow: wf, title: "t", branch: branch, event: "push",
            conclusion: concl, actor: "me", url: "u/\(wf)/\(concl)/\(ago)", number: 1,
            startedAt: iso, completedAt: iso, durationSec: dur, loggedAt: iso)
    }
    let day = 86400.0
    let recs = [
        rec("deploy", "success", 120, ago: 1 * day),
        rec("deploy", "failure", 100, ago: 2 * day),
        rec("deploy", "failure", 90, ago: 3 * day),
        rec("test", "success", 600, ago: 1 * day),
        rec("deploy", "success", 130, ago: 9 * day),
        rec("deploy", "success", 140, ago: 10 * day),
    ]
    let now = Date()
    let thisR = recordsInWindow(recs, from: now.addingTimeInterval(-7 * day), to: now.addingTimeInterval(1))
    let lastR = recordsInWindow(recs, from: now.addingTimeInterval(-14 * day), to: now.addingTimeInterval(-7 * day))
    check(thisR.count == 4, "this window count \(thisR.count)")
    check(lastR.count == 2, "last window count \(lastR.count)")
    let tw = computeWindow(thisR)
    check(tw.total == 4 && tw.success == 2 && tw.failure == 2, "counts")
    check(tw.deployTotal == 3 && tw.deployFailure == 2, "deploy counts")
    check(abs((tw.passRate ?? 0) - 0.5) < 0.001, "pass rate \(tw.passRate ?? -1)")
    check(tw.branchFailures["main"] == 2, "branch failures")
    let ins = generateInsights(this: tw, last: computeWindow(lastR))
    check(ins.contains { $0.contains("slowest") }, "slowest insight present")
    check(ins.contains { $0.contains("failure source") }, "failure insight present")
    let md = buildAIReport(this: tw, last: computeWindow(lastR), insights: ins, thisRecs: thisR)
    check(md.contains("Weekly Deploy Report") && md.contains("Failed runs"), "markdown")

    // The visibility rule the icon AND the poll cadence both depend on.
    func run(_ branch: String, _ status: String) -> Run {
        Run(id: "1", name: "ci", displayTitle: "t", status: status, conclusion: nil,
            headBranch: branch, headSha: "s", event: "push", url: "u/\(branch)",
            updatedAt: "", createdAt: "", startedAt: nil, number: 1,
            workflowName: "ci", actorLogin: nil)
    }
    let bad = Run(id: "2", name: "ci", displayTitle: "t", status: "completed",
                  conclusion: "failure", headBranch: "main", headSha: "s", event: "push", url: "u/selftest-ignore",
                  updatedAt: "", createdAt: "", startedAt: nil, number: 2, workflowName: "ci", actorLogin: nil, attempt: 1)
    check(overallStatus([("o/r", [bad])]).color == C_FAILURE, "failed run turns the icon red")
    let icon = MenuIconState(runs: [("o/r", [bad])], waitingAgents: 1, unread: 0, unreadDot: false)
    check(Route(path: "agents") == .agents && Route.agents.path == "sessions", "old agents path opens Sessions")
    check(icon.color == C_FAILURE && icon.badge == "xmark.circle.fill" && icon.dot && icon.label.contains("1 session waits"), "icon: red cross, dot for a waiting session")
    check(!MenuIconState(runs: [("o/r", [run("main", "in_progress")])], waitingAgents: 0, unread: 3, unreadDot: false).dot, "icon: no dot when unread dot is off")
    check(MenuIconState(runs: [("o/r", [run("main", "in_progress")])], waitingAgents: 0, unread: 3, unreadDot: true).active, "icon: active while a run is in progress")
    IGNORED.set([bad], ignored: true)
    check(overallStatus([("o/r", [bad])]).color == C_SUCCESS, "ignored failure does not turn the icon red")
    var again = bad; again.attempt = 2
    check(!IGNORED.contains(again), "a new attempt is not ignored")
    IGNORED.set([bad], ignored: false)
    func passed(_ wf: String) -> Run {
        Run(id: "5", name: wf, displayTitle: "t", status: "completed", conclusion: "success", headBranch: "main",
            headSha: "s", event: "push", url: "u/selftest-\(wf)", updatedAt: "", createdAt: "", startedAt: nil,
            number: 3, workflowName: wf, actorLogin: nil)
    }
    let other = passed("deploy")
    check(overallStatus([("o/a", [other]), ("o/r", [passed("ci"), bad])]).color == C_SUCCESS, "a newer pass of the workflow clears the failure")
    check(overallStatus([("o/a", [other]), ("o/r", [bad])]).color == C_FAILURE, "a failure in any repo turns the icon red")
    check(Badge("main", maxChars: 15).subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "main", "short branch is not cut")
    check(Badge("dependabot/npm/lodash-4.17", maxChars: 15).subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "dependa\u{2026}sh-4.17", "long branch keeps both ends")
    func dispatch(_ wf: String, _ sha: String) -> Run {
        Run(id: "3", name: wf, displayTitle: "t", status: "completed", conclusion: "success",
            headBranch: "main", headSha: sha, event: "workflow_dispatch", url: "u/\(wf)/\(sha)",
            updatedAt: "", createdAt: "", startedAt: nil, number: 1, workflowName: wf, actorLogin: "a")
    }
    func done(_ wf: String, _ created: String, _ updated: String) -> Run {
        Run(id: "4", name: wf, displayTitle: "t", status: "completed", conclusion: "success",
            headBranch: "main", headSha: "s", event: "push", url: "u/\(wf)",
            updatedAt: updated, createdAt: created, startedAt: nil, number: 1, workflowName: wf, actorLogin: nil)
    }
    let order = byLastActivity([done("old", "2026-10-01T10:00:00Z", "2026-10-01T12:00:00Z"),
                                done("new", "2026-10-01T11:00:00Z", "2026-10-01T11:30:00Z"),
                                run("main", "in_progress")])
    check(order.map { $0.workflowName ?? "" } == ["ci", "old", "new"], "recent first sorts by completion time, active on top")
    let latest = latestPerWorkflow([dispatch("Deploy", "s2"), dispatch("Deploy", "s1"), dispatch("Build", "s1")])
    check(latest.map(\.headSha) == ["s2", "s1"], "one row per workflow keeps the newest run")
    let branches = [run("dependabot/x", "completed"), run("main", "completed")]
    check(latestPerWorkflow(branches).count == 2, "per branch keeps one run on each branch")
    check(latestPerWorkflow(branches, acrossBranches: true).map(\.headBranch) == ["dependabot/x"], "across branches keeps only the newest run")
    let chipJob = Job(id: "1", name: "release-linux-amd64", status: "completed", conclusion: "success", url: nil,
                         startedAt: nil, completedAt: nil, runnerName: nil, steps: nil)
    check((JobChip(job: chipJob, notes: [], maxW: 400).subviews.first as? NSTextField)?.stringValue == "release\u{2026}x-amd64",
          "long job names keep both ends")
    let log = "2026-10-01T23:14:09.48Z FAIL\tpkg\t300s\n2026-10-01T23:14:11.29Z ##[error]Process completed with exit code 1.\n" +
        "2026-10-01T23:14:11.32Z Post job cleanup.\n"
    check(JobLogs.errorSnippet(log) == "FAIL\tpkg\t300s\n##[error]Process completed with exit code 1.", "log snippet ends at the error")
    let cleaned = JobLogs.clean("2026-10-01T23:14:09.48Z \u{1B}[32mok\u{1B}[0m pkg\n##[group]Run x\n\n[90m12:00[0m INF done\n")
    check(cleaned == ["ok pkg", "12:00 INF done"], "log clean drops stamps, groups, blanks and ANSI \(cleaned)")
    check(JobLogs.isError("##[error]boom") && JobLogs.isError("--- FAIL: TestX") && JobLogs.isError("panic: nil map"), "error lines")
    check(!JobLogs.isError("ok  pkg 0.3s") && !JobLogs.isError("errors are fine"), "plain lines are not errors")
    let liveRun = run("main", "in_progress")
    check(RunsPage.matches(.running, run: liveRun, linked: false) && !RunsPage.matches(.failed, run: liveRun, linked: false), "running filter")
    check(RunsPage.matches(.linked, run: liveRun, linked: true) && !RunsPage.matches(.unlinked, run: liveRun, linked: true), "linked filter")
    let g = [("o/r", [run("feature-x", "in_progress"), run("main", "completed")])]
    FILTER_DEFAULT_BRANCHES = false
    check(hasActive(visibleGrouped(g)), "unfiltered: feature-branch run is active")
    FILTER_DEFAULT_BRANCHES = true
    check(visibleGrouped(g)[0].1.count == 1, "filtered: only default-branch rows visible")
    check(!hasActive(visibleGrouped(g)), "filtered: hidden run must not force the fast poll")
    FILTER_DEFAULT_BRANCHES = false

    func runAt(_ created: String, _ status: String = "completed") -> Run {
        Run(id: "1", name: "ci", displayTitle: "t", status: status, conclusion: nil,
            headBranch: "main", headSha: "s", event: "push", url: "u",
            updatedAt: created, createdAt: created, startedAt: nil, number: 1,
            workflowName: "ci", actorLogin: nil)
    }
    let unsorted = [("o/old", [runAt("2026-01-01T00:00:00Z")]),
                    ("o/none", []),
                    ("o/new", [runAt("2026-03-01T00:00:00Z")]),
                    ("o/busy", [runAt("2025-01-01T00:00:00Z", "in_progress")])]
    check(sortedByRecent(unsorted).map { $0.0 } == ["o/busy", "o/new", "o/old", "o/none"], "recent sort order")

    // Live updates: partial refresh merge keeps the other repos and the REPOS order.
    let oldG = [("o/a", [runAt("2026-01-01T00:00:00Z")]), ("o/b", [runAt("2026-01-02T00:00:00Z")])]
    let merged = mergeGrouped(oldG, [("o/b", [])], order: ["o/a", "o/b", "o/c"])
    check(merged.map { $0.0 } == ["o/a", "o/b", "o/c"], "merge order")
    check(merged[0].1.count == 1 && merged[1].1.isEmpty && merged[2].1.isEmpty, "merge replaces only refreshed repos")

    // detectTransitions(partial:) keeps the statuses of repos it did not refresh.
    func runURL(_ url: String, _ status: String) -> Run {
        Run(id: "1", name: "ci", displayTitle: "t", status: status, conclusion: "success",
            headBranch: "main", headSha: "s", event: "push", url: url,
            updatedAt: "", createdAt: "", startedAt: nil, number: 1, workflowName: "ci", actorLogin: nil)
    }
    let bar = GHActionsBar()
    bar.grouped = [("o/a", [runURL("a1", "completed")]), ("o/b", [runURL("b1", "completed")])]
    bar.detectTransitions(bar.grouped)
    bar.firstLoad = false
    bar.detectTransitions([("o/a", [runURL("a2", "completed")])], partial: true)
    check(bar.prevStatuses["b1"] == "completed", "partial transitions keep other repos")
    check(bar.prevStatuses["a2"] == "completed" && bar.prevStatuses["a1"] == nil, "partial transitions replace refreshed repo")

    check(CloudSetup.normalize("cloud.example.dev/") == "https://cloud.example.dev", "cloud URL gets https")
    check(CloudSetup.normalize("http://x.dev") == nil, "cloud URL must be https")
    check(CloudSetup.normalize("  ") == nil, "empty cloud URL")

    let token = String(repeating: "ab12", count: 16)
    check(maskSecrets("put \(token) done") == "put •••• done", "secret masking")
    check(maskSecrets("deploy abc123") == "deploy abc123", "masking leaves short hex")

    let noon = Date(timeIntervalSince1970: 86400 * 100 + 43200)
    let q = WriteQuota(rowsToday: 40_000, now: noon)
    check(q.projected == 80_000 && q.warn, "quota projection \(q.projected)")
    check(!WriteQuota(rowsToday: 1_000, now: noon).warn, "quota no warning")
    let repos = ["O/Hooked", "O/Bare", "O/Denied", "O/Waiting"]
    let sts: [String: HookStatus] = ["O/Denied": .pollingOnly("x"), "O/Waiting": .waiting]
    check(CloudSetup.unhooked(repos, hooked: nil, statuses: sts).isEmpty, "unhooked unknown before health")
    let rl = try? JSONDecoder().decode(RateLimit.self, from: Data("""
        {"resources":{"core":{"limit":5000,"used":3600,"remaining":1400,"reset":1},
        "graphql":{"limit":5000,"used":100,"reset":1},"search":{"limit":30,"used":30,"reset":1}}}
        """.utf8))
    check(rl?.percent == 72 && rl?.color == C_QUEUED, "rate limit uses the fullest of REST and GraphQL")
    check(rl?.footerLabel == "REST 72% · GQL 2%", "footer shows REST and GraphQL \(rl?.footerLabel ?? "")")
    check(CloudSetup.unhooked(repos, hooked: ["o/hooked", "o/denied"], statuses: sts) == ["O/Bare", "O/Denied"],
          "unhooked repos")
    REPO_COLORS = ["o/a": 3, "o/b": 0]
    check(repoColor("o/a") == REPO_PALETTE[3], "repo color keeps its slot")

    let wsUUID = "11111111-2222-3333-4444-555555555555"
    func projectItem(_ id: String, status: String?, fields: [String: String] = [:], assignees: [String] = [],
                     author: String? = "bea", comments: Int = 0, last: Comment? = nil) -> Item {
        Item(id: id, key: "ENG-\(id)", title: "Item \(id)", url: "https://app.plane.so/acme/browse/ENG-\(id)/",
                    statusOptionId: status, fields: fields, assignees: assignees, labels: [], author: author,
                    updatedBy: author, updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    activityAt: Date(timeIntervalSince1970: 1_700_000_000), commentCount: comments, lastComment: last,
                    mentionsMe: false)
    }
    let todoOpt = StatusOption(id: "s1", name: "Todo", color: "#888888", group: "unstarted")
    let doingOpt = StatusOption(id: "s2", name: "In progress", color: "#F59E0B", group: "started")
    func summary(_ ws: String, _ id: String, _ title: String) -> ProjectSummary {
        ProjectSummary(ref: ProjectRef(workspace: ws, id: id), identifier: "ENG", title: title, url: "", closed: false)
    }
    func projectSnap(_ items: [Item], me: String? = "ada") -> ProjectSnapshot {
        ProjectSnapshot(summary: summary("acme", wsUUID, "Board"), statusOptions: [todoOpt, doingOpt],
                        items: items, fetchedAt: Date(timeIntervalSince1970: 1_700_000_040), me: me)
    }
    // My items: an agent that waits, then failing CI, then working, then the status order.
    do {
        let snap = projectSnap([])
        func stream(_ key: String, _ phase: AgentSession.Phase?) -> Workstream {
            var s = Workstream(key: key)
            s.agent = phase.map { AgentSession(phase: $0, since: Date()) }
            return s
        }
        let got = MyItemsPage.order([
            (projectItem("1", status: "s1"), snap, nil),
            (projectItem("2", status: "s2"), snap, nil),
            (projectItem("3", status: "s1"), snap, stream("ENG-3", .working)),
            (projectItem("4", status: "s1"), snap, stream("ENG-4", .waiting)),
        ]).map(\.item.key)
        check(got == ["ENG-4", "ENG-3", "ENG-2", "ENG-1"], "my items order: \(got)")
    }
    check(ProjectStore.diff(nil, projectSnap([projectItem("a", status: "s1")])).isEmpty, "first snapshot is quiet")
    let before = projectSnap([projectItem("a", status: "s1", fields: ["Priority": "Low"], assignees: ["ada"])])
    let comment = Comment(id: "c1", author: "grace", createdAt: Date(timeIntervalSince1970: 1_700_000_050), url: "https://example/c1")
    let after = projectSnap([
        projectItem("a", status: "s2", fields: ["Priority": "High"], assignees: ["ada", "grace"], comments: 2, last: comment),
        projectItem("b", status: "s1"),
    ])
    let changes = ProjectStore.diff(before, after)
    func changed(_ id: String, _ match: (ItemChange) -> Bool) -> Bool {
        changes.contains { $0.itemId == id && match($0.1) }
    }
    check(changed("b") { if case .added = $0 { return true }; return false }, "diff added")
    check(changed("a") { if case .status(let from, let to) = $0 { return from == "Todo" && to == "In progress" }; return false }, "diff status")
    check(changed("a") { if case .field(let name, let from, let to) = $0 { return name == "Priority" && from == "Low" && to == "High" }; return false }, "diff field")
    check(changed("a") { if case .assigned(let who) = $0 { return who == "grace" }; return false }, "diff assigned")
    check(changed("a") { if case .comments(_, let last) = $0 { return last.id == "c1" }; return false }, "diff comments")
    let removed = ProjectStore.diff(after, projectSnap([projectItem("b", status: "s1")]))
    check(removed.contains { $0.itemId == "a" && $0.1 == .removed }, "diff removed")
    let oldComment = Comment(id: "c0", author: "grace", createdAt: Date(timeIntervalSince1970: 1_600_000_000), url: "")
    let lateLoad = ProjectStore.diff(before, projectSnap([projectItem("a", status: "s1", fields: ["Priority": "Low"],
                                                                       assignees: ["ada"], comments: 1, last: oldComment)]))
    check(lateLoad.isEmpty, "an old comment that loads late is quiet \(lateLoad)")
    let doneOpt0 = StatusOption(id: "s9", name: "Done", color: "", group: "completed")
    let closeSnap = ProjectSnapshot(summary: summary("acme", wsUUID, "Board"), statusOptions: [todoOpt, doneOpt0],
                                    items: [projectItem("a", status: "s9", fields: ["Priority": "Low"], assignees: ["ada"])],
                                    fetchedAt: Date())
    check(ProjectStore.diff(before, closeSnap).contains { $0.1 == .closed }, "done state closes")

    var notes: [(title: String, subtitle: String, body: String, id: String)] = []
    let notifier = ProjectNotifier(post: { notes.append(($0, $1, $2, $3)) })
    var clock = Date(timeIntervalSince1970: 1_000_000)
    notifier.now = { clock }
    let mine = projectSnap([projectItem("a", status: "s1", assignees: ["ada"])])
    let theirs = projectSnap([projectItem("b", status: "s1", assignees: ["bea"])])
    let settings = ProjectNotificationSettings()
    notifier.handle([("a", .mention)], in: mine, settings: settings)
    notifier.handle([("b", .mention)], in: theirs, settings: settings)
    check(notes.count == 1 && notes[0].id == "project:a", "mention only on my items")
    check(notes[0].title == "acme › Board" && notes[0].subtitle == "ENG-a Item a", "notification title \(notes[0])")
    notes = []
    notifier.handle([("b", .status(from: "Todo", to: "Done"))], in: theirs, settings: settings)
    notifier.handle([("a", .status(from: "Todo", to: "Done"))], in: mine, settings: settings)
    check(notes.count == 1, "status notifies my items only by default")
    notes = []
    notifier.handle([("b", .added)], in: theirs, settings: settings)
    check(notes.count == 1, "added notifies any item")
    notes = []
    clock = clock.addingTimeInterval(180)
    notifier.handle([("b", .assigned("Ada"))], in: theirs, settings: settings)
    notifier.handle([("b", .assigned("bea"))], in: theirs, settings: settings)
    check(notes.count == 1 && notes[0].body == "Assigned Ada", "assigned notifies only me")
    notes = []
    let own = ItemChange.comments(new: 1, last: Comment(id: "c", author: "Ada", createdAt: clock, url: "u"))
    notifier.handle([("a", own)], in: mine, settings: settings)
    check(notes.isEmpty, "own comments are skipped")
    notifier.handle([("a", .field(name: "Priority", from: "Low", to: "High"))], in: mine, settings: settings)
    check(notes.isEmpty, "other fields stay quiet")
    notifier.handle([("a", .mention)], in: projectSnap(mine.items, me: nil), settings: settings)
    check(notes.isEmpty, "no owner, no mine")
    notes = []
    notifier.handle([("a", .status(from: "Todo", to: "In progress"))], in: mine, settings: settings)
    clock = clock.addingTimeInterval(60)
    notifier.handle([("a", .closed)], in: mine, settings: settings)
    check(notes.count == 2 && notes[0].id == notes[1].id, "grouped notification keeps one id")
    check(notes[1].body.contains("Status") && notes[1].body.contains("Closed"), "grouped body \(notes[1].body)")
    clock = clock.addingTimeInterval(180)
    notifier.handle([("a", .reopened)], in: mine, settings: settings)
    check(notes[2].body == "Reopened", "a new window after 2 minutes")

    func relayEvent(_ json: String) -> CloudSignal? {
        try! JSONDecoder().decode(CloudEvent.self, from: Data(json.utf8)).signal(at: Date())
    }
    let plan = relayApplyPlan([
        relayEvent(#"{"seq":1,"deliveryId":"a","repo":"o/kept","kind":"workflow_run","action":"completed","runId":9}"#),
        relayEvent(#"{"seq":2,"deliveryId":"b","repo":"","org":"plane:acme","kind":"plane","action":"workitem.updated","projectId":"P1","itemId":"I1"}"#),
        relayEvent(#"{"seq":3,"deliveryId":"c","repo":"","org":"plane:acme","kind":"plane","action":"workitem.comment.created","projectId":"P1"}"#),
        relayEvent(#"{"seq":4,"deliveryId":"d","repo":"o/other","kind":"pull_request","prNumber":3}"#),
        relayEvent(#"{"seq":5,"deliveryId":"e","repo":"","org":"plane:beta","kind":"plane","action":"workitem.updated","projectId":"P2"}"#),
        relayEvent(#"{"seq":6,"deliveryId":"f","repo":"","org":"plane:beta","kind":"plane","action":"project.updated"}"#),
        relayEvent(#"{"seq":7,"deliveryId":"g","repo":"","org":"plane:beta","kind":"plane","action":"workitem.created","projectId":"P3"}"#),
        relayEvent(#"{"seq":8,"deliveryId":"h","repo":"","org":"acme","kind":"plane","projectId":"P9"}"#),
    ].compactMap { $0 }, knownRepos: ["O/Kept"])
    check(plan.repos == ["O/Kept"] && plan.completedRuns.count == 1
            && plan.completedRuns[0].0 == "O/Kept" && plan.completedRuns[0].1 == "9", "relay plan keeps known repos")
    check(plan.includePRs, "pull request events refresh PRs")
    let planned = plan.plane.map { "\($0.workspace)/\($0.project ?? "*")" }
    check(planned == ["acme/P1", "beta/*"], "relay plan groups plane events \(planned)")

    let ws = PlaneWorkspace(slug: "acme")
    check(ws.itemURL("ENG-4") == "https://app.plane.so/acme/browse/ENG-4/" && ws.url == "https://app.plane.so/acme/",
          "cloud item url")
    check(PlaneWorkspace(slug: "acme", host: "https://plane.example.com").itemURL("ENG-4")
            == "https://plane.example.com/acme/browse/ENG-4/", "self-hosted item url")
    let oldWs = try? JSONDecoder().decode(PlaneWorkspace.self, from: Data(#"{"slug":"acme"}"#.utf8))
    check(oldWs?.host == PlaneWorkspace.cloudHost, "workspace host default")

    // Plane activity rows.
    let names = ["u1": "Ada"]
    let states = [todoOpt, doingOpt]
    check(PlaneClient.change(["verb": "created"], names: names, states: states) == .added, "activity created")
    check(PlaneClient.change(["verb": "updated", "field": "state", "old_value": "Todo", "new_value": NSNull(),
                              "new_identifier": "s2"], names: names, states: states)
            == .status(from: "Todo", to: "In progress"), "activity state from id")
    check(PlaneClient.change(["verb": "updated", "field": "assignees", "new_value": "", "new_identifier": "u1"],
                             names: names, states: states) == .assigned("Ada"), "activity assigned")
    check(PlaneClient.change(["verb": "updated", "field": "priority", "old_value": "low", "new_value": "urgent"],
                             names: names, states: states) == .field(name: "Priority", from: "Low", to: "Urgent"), "activity priority")
    check(PlaneClient.change(["verb": "updated", "field": "description"], names: names, states: states) == nil,
          "unknown activity is skipped")

    // Plane rich text.
    let html = #"<h2>Context</h2><p>Hi <mention-component entity_identifier="u1" entity_name="user_mention"></mention-component>, see <a href="https://x.dev">this</a> &amp; <strong>that</strong>.</p><ul data-type="taskList"><li data-type="taskItem" data-checked="true"><p>one</p></li><li data-type="taskItem" data-checked="false"><p>two</p></li></ul><pre><code>let a = 1 &lt; 2</code></pre>"#
    let pmd = PlaneMarkup.markdown(fromHTML: html, mention: { names[$0] })
    check(pmd.contains("## Context") && pmd.contains("Hi @Ada, see [this](https://x.dev) & **that**."), "html to markdown \(pmd)")
    check(pmd.contains("- [x] one") && pmd.contains("- [ ] two") && pmd.contains("```\nlet a = 1 < 2\n```"), "tasks and code \(pmd)")
    let back = PlaneMarkup.html(fromMarkdown: pmd)
    check(back.contains(#"data-type="taskList""#) && back.contains("<h2>Context</h2>") && back.contains("&lt; 2"),
          "markdown to html \(back)")
    check(PlaneMarkup.markdown(fromHTML: PlaneMarkup.html(fromMarkdown: pmd)) == PlaneMarkup.markdown(fromHTML: back), "round trip")
    check(PlaneMarkup.html(fromMarkdown: "a <b> & c") == "<p>a &lt;b&gt; &amp; c</p>", "plain text is escaped")
    let planeTable = "<p>Work items</p><table><tbody><tr><th colspan=\"1\" rowspan=\"1\"><p>Plane</p></th><th><p>Repo</p></th></tr>"
        + "<tr><td><p>TREBI-286</p></td><td><p>Connector <code>internal/host</code></p><p>a|b</p></td></tr></tbody></table><p>After</p>"
    let tableMD = PlaneMarkup.markdown(fromHTML: planeTable)
    check(tableMD == "Work items\n\n| Plane | Repo |\n| --- | --- |\n| TREBI-286 | Connector `internal/host` a\\|b |\n\nAfter",
          "table to Markdown: \(tableMD)")
    let tableHTML = PlaneMarkup.html(fromMarkdown: tableMD)
    check(tableHTML.contains("<table><tbody><tr><th><p>Plane</p></th>") && tableHTML.contains("<td><p>Connector <code>internal/host</code> a|b</p></td>"),
          "table to HTML: \(tableHTML)")
    check(PlaneMarkup.markdown(fromHTML: tableHTML) == tableMD, "table round trip")
    let asset = "a246509a-505b-46c2-80a1-7e0dd05b475d"
    let imgMD = PlaneMarkup.markdown(fromHTML: "<p>See</p><image-component src=\"\(asset)\" width=\"200\"></image-component>")
    check(imgMD == "See\n\n![](\(asset))", "image to Markdown: \(imgMD)")
    let imgHTML = PlaneMarkup.html(fromMarkdown: imgMD)
    check(imgHTML.contains("<image-component src=\"\(asset)\"></image-component>"), "image to HTML: \(imgHTML)")
    check(PlaneMarkup.html(fromMarkdown: "![x](https://e.com/a.png)").contains("<img src=\"https://e.com/a.png\" alt=\"x\">"), "web image")

    let oldConfig = #"{"repos":["o/r"],"pollInterval":30}"#.data(using: .utf8)!
    let decoded = try? JSONDecoder().decode(AppConfig.self, from: oldConfig)
    check(decoded?.projects == nil && decoded?.repos == ["o/r"], "old config without projects decodes")

    // Projects: order, fold, filter.
    let oldProjects = try? JSONDecoder().decode(ProjectsConfig.self, from: Data(#"{"picked":["a/1"],"pollMinutes":5}"#.utf8))
    check(oldProjects?.order == [] && oldProjects?.folded == [] && oldProjects?.capture == CaptureConfig()
            && oldProjects?.picked == [] && oldProjects?.hideDoneAfterDays == 1, "old GitHub picks are dropped")
    let planeCfg = try? JSONDecoder().decode(ProjectsConfig.self, from: Data("""
    {"workspaces":[{"slug":"acme"}],"picked":["acme/\(wsUUID)","gone/\(wsUUID)","acme/3"],"allOf":["acme","gone"]}
    """.utf8))
    check(planeCfg?.picked == ["acme/\(wsUUID)"] && planeCfg?.allOf == ["acme"], "picks of unknown workspaces are dropped")
    var orderCfg = ProjectsConfig()
    orderCfg.order = ["zed/9", "ACME/2", "gone/7"]
    let ordered = orderCfg.sorted([summary("acme", "1", "Beta"), summary("acme", "2", "Alpha"), summary("zed", "9", "Zed"),
                                   summary("bolt", "3", "Bolt"), summary("acme", "4", "Aardvark")]).map(\.ref.storeKey)
    check(ordered == ["zed/9", "acme/2", "acme/4", "acme/1", "bolt/3"], "project order \(ordered)")
    orderCfg.setFolded("acme/1", true)
    check(orderCfg.isFolded("ACME/1"), "fold is case-insensitive")
    orderCfg.setFolded("acme/1", false)
    check(orderCfg.folded.isEmpty, "unfold")
    // AI dialects, without network.
    var aiCfg = AIConfig()
    aiCfg.baseURL = "https://llm.example.com/v1/"
    aiCfg.model = "m1"
    let aiReq = AIRequest(system: "SYS", user: "USER", maxTokens: 300)
    func jsonBody(_ r: URLRequest?) -> [String: Any] {
        (r?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    let oa = try? OpenAIDialect().urlRequest(aiReq, cfg: aiCfg, key: "k1")
    check(oa?.url?.absoluteString == "https://llm.example.com/v1/chat/completions", "openai url \(oa?.url?.absoluteString ?? "")")
    check(oa?.value(forHTTPHeaderField: "Authorization") == "Bearer k1", "openai bearer")
    check(jsonBody(oa)["reasoning_effort"] as? String == "low" && jsonBody(oa)["model"] as? String == "m1", "openai effort")
    check((jsonBody(oa)["messages"] as? [[String: Any]])?.first?["role"] as? String == "system", "openai system message")
    aiCfg.baseURL = "https://llm.example.com/v1"
    aiCfg.effort = "none"
    let oaNone = try? OpenAIDialect().urlRequest(aiReq, cfg: aiCfg, key: "k1")
    check(oaNone?.url?.absoluteString == "https://llm.example.com/v1/chat/completions", "openai url without slash")
    check(jsonBody(oaNone)["reasoning_effort"] == nil, "effort none leaves out the field")
    aiCfg.format = .anthropic
    aiCfg.baseURL = "https://api.anthropic.com/"
    let an = try? AnthropicDialect().urlRequest(aiReq, cfg: aiCfg, key: "k2")
    check(an?.url?.absoluteString == "https://api.anthropic.com/v1/messages", "anthropic url")
    check(an?.value(forHTTPHeaderField: "x-api-key") == "k2" && an?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01",
          "anthropic headers")
    check(jsonBody(an)["max_tokens"] as? Int == 300 && jsonBody(an)["system"] as? String == "SYS", "anthropic body")
    check(AnthropicDialect.endpoint("https://proxy.example/v1") == "https://proxy.example/v1/messages", "anthropic url with /v1")
    let oaReply = Data(#"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#.utf8)
    check((try? OpenAIDialect().text(from: oaReply, status: 200)) == "Hello", "openai reply")
    let anReply = Data(#"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Hi"},{"type":"text","text":"!"}]}"#.utf8)
    check((try? AnthropicDialect().text(from: anReply, status: 200)) == "Hi!", "anthropic reply")
    let errBody = Data(#"{"error":{"message":"Invalid API key\nmore","type":"auth"}}"#.utf8)
    do { _ = try OpenAIDialect().text(from: errBody, status: 401); check(false, "401 must throw") }
    catch { check(error as? AIError == .http(401, "Invalid API key"), "http error \(error)") }

    // Suggestion parsing.
    let sizeField = ProjectField(id: "FS", name: "Size", options: [StatusOption(id: "o1", name: "S", color: "GRAY"),
                                                                   StatusOption(id: "o2", name: "L", color: "GRAY")])
    let draftCtx = DraftContext(projects: [("ocral/\(wsUUID)", "Fritz Tasks"), ("acme/1", "Board")], fields: [sizeField])
    let reply = """
    Sure! Here it is:
    ```json
    {"title": "  \(String(repeating: "x", count: 80)).", "alternatives": ["Other", "Third"],
     "fields": {"size": "l", "Priority": "P0", "Size2": "S"}, "project": "OCRAL/\(wsUUID)", "reason": "personal"}
    ```
    """
    let sug = DraftSuggestion.parse(reply, ctx: draftCtx)
    check(sug?.title.count == 70 && sug?.alternatives == ["Other", "Third"], "suggestion title and alternatives")
    check(sug?.fields == ["Size": "L"], "unknown fields and options are dropped \(sug?.fields ?? [:])")
    check(sug?.project == "ocral/\(wsUUID)" && sug?.reason == "personal", "project key is normalized")
    check(DraftSuggestion.parse(#"{"title":"Fix it","project":"nope/1"}"#, ctx: draftCtx)?.project == nil, "unknown project dropped")
    check(DraftSuggestion.parse("no json here", ctx: draftCtx) == nil, "no JSON gives nil")
    check(unfenced("```markdown\n## Context\nText\n```") == "## Context\nText", "fence removed")

    // The AI switch needs a test that passed for the current values.
    var gate = AIConfig()
    gate.baseURL = "https://a"; gate.model = "m"; gate.enabled = true
    gate.verified = gate.fingerprint(key: "k")
    check(gate.isOn(key: "k") && !gate.isOn(key: "k2") && !gate.isOn(key: nil), "ai on only with the tested key")
    var changed = gate; changed.model = "m2"
    check(!changed.isOn(key: "k"), "model change turns ai off")
    changed = gate; changed.baseURL = "https://b"
    check(!changed.isOn(key: "k"), "url change turns ai off")
    changed = gate; changed.format = .anthropic
    check(!changed.isOn(key: "k"), "format change turns ai off")
    changed = gate; changed.enabled = false
    check(!changed.isOn(key: "k"), "disabled ai is off")
    check(changed.extraContext == "" && (try? JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8)))?.effort == "low",
          "ai config defaults")

    // Quick capture shortcut label.
    check(CaptureConfig().shortcutLabel == "⌃⌥N", "default shortcut label")
    var cap = CaptureConfig()
    cap.keyCode = 40; cap.modifiers = KeyShortcut.carbonModifiers([.command, .shift])
    check(cap.shortcutLabel == "⇧⌘K", "shortcut label \(cap.shortcutLabel)")
    cap.modifiers = 0
    check(cap.shortcutLabel == "None" && !cap.hasShortcut, "cleared shortcut")

    // Orca: reply parse, agent index, prompt template.
    if case .failure(let e) = OrcaClient.parse(Data(#"{"ok":false,"error":{"code":"runtime_unavailable","message":"no server"}}"#.utf8), stderr: "", command: "worktree ps") {
        check(e.code == "runtime_unavailable" && e.message == "no server", "orca error reply")
    } else { check(false, "orca error reply") }
    if case .failure(let e) = OrcaClient.parse(Data("boom".utf8), stderr: "connect failed", command: "status") {
        check(e.message == "orca status: connect failed", "orca non-JSON reply")
    } else { check(false, "orca non-JSON reply") }
    let psJSON = #"""
    {"ok":true,"result":{"worktrees":[
     {"worktreeId":"r1::/w::workspace:a","repo":"towertail-workspace","path":"/w","displayName":"TOWERTAIL-2","liveTerminalCount":1,"lastActivityAt":1000,
      "agents":[{"paneKey":"t1:l1","state":"done","agentType":"claude","prompt":"second","stateStartedAt":1000000},
                {"paneKey":"t2:l2","state":"waiting","agentType":"claude","prompt":"x","stateStartedAt":2000000}]},
     {"worktreeId":"r2::/c","repo":"oversire","path":"/c","displayName":"main","liveTerminalCount":1,"lastActivityAt":1000,
      "agents":[{"paneKey":"t3:l3","state":"working","agentType":"claude","prompt":"work on https://app.plane.so/ocral/browse/FRITZ-17/ now","stateStartedAt":3000000},
                {"paneKey":"t4:l4","state":"done","agentType":"claude","prompt":"no key here","stateStartedAt":3000000},
                {"paneKey":"t5:l5","state":"working","agentType":"codex","prompt":"other","stateStartedAt":3000000}]},
     {"worktreeId":"r3::/x","repo":"x","path":"/x","displayName":"TREBI-9","liveTerminalCount":0,"lastActivityAt":1000,
      "agents":[{"paneKey":"t6:l6","state":"done","agentType":"claude","stateStartedAt":3000000}]},
     {"worktreeId":"r4::/y","repo":"y","path":"/y","displayName":"OLD","isArchived":true,"agents":[]}]}}
    """#
    if case .success(let r) = OrcaClient.parse(Data(psJSON.utf8), stderr: "", command: "worktree ps") {
        let cards = OrcaClient.cards(from: r)
        check(cards.count == 3 && cards[0].agents.count == 2 && cards[0].liveTerminals == 1, "orca cards parse")
        let t0 = Date(timeIntervalSince1970: 3100)
        let launches = ["SLING-5": AgentIndex.PendingLaunch(at: t0, card: "r2::/c", paneKey: "t5:l5"),
                        "SLING-6": AgentIndex.PendingLaunch(at: t0, error: "Orca is not reachable"),
                        "SLING-7": AgentIndex.PendingLaunch(at: t0)]
        let idx = AgentIndex.index(cards, launches: launches, now: t0)
        check(idx["TOWERTAIL-2"]?.phase == .waiting && idx["TOWERTAIL-2"]?.paneKey == "t2:l2", "card name match, waiting wins")
        check(idx["FRITZ-17"]?.phase == .working && idx["FRITZ-17"]?.repo == "oversire", "prompt URL match")
        check(idx["SLING-5"]?.phase == .working && idx["SLING-5"]?.agent == "codex", "launch pane match")
        check(idx["SLING-6"]?.phase == .failed && idx["SLING-6"]?.label() == "Not started", "failed launch")
        check(idx["SLING-7"]?.phase == .starting, "pending launch")
        check(idx["TREBI-9"] == nil, "done agent of a closed terminal drops")
        check(idx.count == 5, "agent index size \(idx.count)")
        let late = AgentIndex.index(cards, launches: [:], now: t0.addingTimeInterval(2 * 86400))
        check(late["TOWERTAIL-2"]?.phase == .waiting && late["FRITZ-17"]?.phase == .working, "old waiting agents stay")
        check(AgentSession(phase: .working, since: t0).label(now: t0.addingTimeInterval(4 * 60 + 5)) == "Working 4m", "working label")
        var feed = OrcaFeed(limit: 3)
        feed.record(before: [:], after: idx)
        check(feed.events.count == 3 && feed.events.map(\.at) == feed.events.map(\.at).sorted(by: >), "feed keeps the newest events")
        var f2 = OrcaFeed()
        let w = AgentSession(phase: .working, since: t0, repo: "r")
        f2.record(before: [:], after: ["A-1": w])
        f2.record(before: ["A-1": w], after: ["A-1": w])
        let ask = AgentSession(phase: .waiting, since: t0.addingTimeInterval(60), repo: "r", message: "Pick one")
        f2.record(before: ["A-1": w], after: ["A-1": ask])
        let back = AgentSession(phase: .working, since: t0.addingTimeInterval(120), repo: "r")
        f2.record(before: ["A-1": ask], after: ["A-1": back])
        check(f2.events.map(\.text) == ["Got input, works again", "Needs input: Pick one", "Session works"], "feed transitions \(f2.events.map(\.text))")
    } else { check(false, "orca ps parse") }
    let terms = [OrcaTerminal(handle: "h1", card: "c", title: "Terminal 1", paneKey: "t1:l1", orphaned: false),
                 OrcaTerminal(handle: "h2", card: "c", title: "✳ FRITZ-27", paneKey: "t2:l2", orphaned: false)]
    check(AgentIndex.pick(terms, agent: AgentSession(phase: .working, since: Date(), paneKey: "t1:l1"), key: "FRITZ-27")?.handle == "h1", "pick by pane")
    check(AgentIndex.pick(terms, agent: AgentSession(phase: .working, since: Date(), paneKey: "gone"), key: "FRITZ-27")?.handle == "h2", "pick by key title")
    check(AgentIndex.pick(terms, agent: AgentSession(phase: .working, since: Date(), paneKey: "gone"), key: "FRITZ-9") == nil, "no wrong terminal")
    let titled = [terms[0], OrcaTerminal(handle: "h3", card: "c", title: "◐ OverSire standalone Mac app", paneKey: "pty:x", orphaned: true)]
    check(AgentIndex.pick(titled, agent: AgentSession(phase: .working, since: Date(), paneKey: "gone"), key: "FRITZ-28")?.handle == "h3", "pick the one agent title")
    let draftItem = Item(id: "u-1", key: "FRITZ-7", title: "Add quick capture", url: "https://app.plane.so/ocral/browse/FRITZ-7/",
                         statusOptionId: "s1", fields: [:], assignees: [], labels: [], author: nil, updatedBy: nil,
                         updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
    var oc = OrcaConfig()
    check(oc.prompt(for: draftItem) == "work on https://app.plane.so/ocral/browse/FRITZ-7/ in worktree group .wt/fritz-7", "orca prompt template")
    oc.prompt = "{KEY}: {title}"
    check(oc.prompt(for: draftItem) == "FRITZ-7: Add quick capture", "orca prompt fields")
    check(OrcaClient.agentCommand("claude", key: "FRITZ-7") == "claude -n 'FRITZ-7'" && OrcaClient.agentCommand("codex", key: "X-1") == "codex", "agent command")
    if let d = try? JSONDecoder().decode(ProjectsConfig.self, from: Data(#"{"orca":{"environment":"mbp","roots":{"a/b":"/w"}}}"#.utf8)) {
        check(d.orca.environment == "mbp" && d.orca.agent == "claude" && d.orca.roots["a/b"] == "/w" && d.notifications.agentDone, "orca config decode")
    } else { check(false, "orca config decode") }

    // Routes: every route survives a round trip through its URL and its path.
    for r in Route.samples {
        check(Route(url: r.url) == r, "route url round trip: \(r.path)")
        check(Route(path: r.path) == r, "route path round trip: \(r.path)")
    }
    check(Route(url: URL(string: "oversire://item/FRITZ-17")!) == .item("FRITZ-17", .overview), "oversire://item/FRITZ-17 is the item")
    check(Route(url: URL(string: "oversire:item/fritz-17/session")!) == .item("FRITZ-17", .session), "oversire:item/… without slashes")
    check(Route(url: URL(string: "oversire:///run/oversire/oversire/42")!) == .run(repo: "oversire/oversire", id: "42"), "oversire:/// run link")
    check(Route(url: URL(string: "oversire://runs/failed")!) == .runs(.failed), "runs filter link")
    check(Route(url: URL(string: "https://item/FRITZ-17")!) == nil, "other schemes are not routes")
    check(Route(url: URL(string: "oversire://item/17")!) == nil, "an item needs a key")
    check(Route(url: URL(string: "oversire://settings/nope")!) == .settings(.general), "unknown settings page opens General")
    check(Route(url: URL(string: "cateye://item/FRITZ-17")!) == .item("FRITZ-17", .overview), "old cateye links still open")

    // Accounts from the old settings. Only Keychain key names, never tokens.
    do {
        let fixture = #"""
        {"repos":["oversire/oversire","oversire/cloud","flarco/dotfiles","bad repo"],"orgs":["oversire","acme"],
         "projects":{"workspaces":[{"slug":"ocral"},{"slug":"btd","host":"https://plane.example.com"}],
                     "orca":{"environment":"mbp","agent":"codex"}},
         "accounts":[{"account":{"provider":"linear","id":"team"},"values":{},"secretKeys":["LINEAR_TOKEN"]},
                     {"account":{"provider":"plane","id":"gone"},"values":{},"secretKeys":[]}]}
        """#
        if let c = try? JSONDecoder().decode(AppConfig.self, from: Data(fixture.utf8)) {
            let a = LegacyMigration.syncAccounts(c.accounts ?? [], from: c)
            let ids = a.map { "\($0.account.provider.rawValue):\($0.account.id)" }
            check(ids == ["linear:team", "plane:ocral", "plane:btd", "github:oversire", "github:flarco", "github:acme",
                          "github-actions:oversire", "github-actions:flarco", "github-actions:acme", "orca:mbp"], "accounts \(ids)")
            check(a[2].values["host"] == "https://plane.example.com" && a[1].secretKeys == ["PLANE_TOKEN_ocral"], "plane account")
            check(a[3].values["repos"] == "oversire/oversire,oversire/cloud" && a[5].values["repos"] == "", "github repos by owner")
            check(a[9].values["agent"] == "codex" && a[9].values["cli"] == OrcaClient.defaultPath, "orca account")
        } else { check(false, "accounts fixture decode") }
    }
    check(PlaneError.http(429, "").providerError == .rateLimited(retryAfter: nil) && PlaneError.noToken.providerError == .unauthorized,
          "plane errors map to provider errors")
    check(OrcaError(code: "bad_reply", message: "x").providerError == .decoding("x"), "orca errors map to provider errors")
    do {
        let r = ProcessRunner()
        check((try? r.runSync("/bin/echo", ["hi"]))?.stdout == Data("hi\n".utf8), "process runner output")
        check((try? r.runSync("/bin/cat", [], stdin: Data("in".utf8)))?.stdout == Data("in".utf8), "process runner stdin")
        let t0 = Date()
        check((try? r.runSync("/bin/sleep", ["5"], timeout: 0.3))?.ok == false && Date().timeIntervalSince(t0) < 3, "process runner timeout")
    }

    // LegacyMigration: copy the config folder, Keychain entries and defaults one time.
    do {
        final class MemVault: SecretVault {
            var d: [String: String] = [:]
            func get(_ key: String) -> String? { d[key] }
            func set(_ key: String, _ value: String) { d[key] = value }
            func keys() -> [String] { Array(d.keys) }
        }
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "oversire-migration-\(UUID().uuidString)"
        try? fm.createDirectory(atPath: home + "/.config/cat-eye", withIntermediateDirectories: true)
        fm.createFile(atPath: home + "/.config/cat-eye/config.json", contents: Data("{\"repos\":[\"o/r\"]}".utf8))
        var vaults: [String: MemVault] = [:]
        func vault(_ s: String) -> SecretVault { if let v = vaults[s] { return v }; let v = MemVault(); vaults[s] = v; return v }
        vault("com.flarco.cat-eye.plane").set("ocral", "tok")
        vault("com.flarco.cat-eye.ai").set("KEY", "old")
        vault("com.oversire.app.ai").set("KEY", "new")
        let suite = "oversire-selftest-\(UUID().uuidString)"
        let defs = UserDefaults(suiteName: suite)!
        let m = LegacyMigration(home: home, vault: vault, oldDefaults: { ["ignoredFailures": ["a"]] }, newDefaults: defs)
        check(m.run(), "migration: first run migrates")
        check(fm.contents(atPath: home + "/.config/oversire/config.json") != nil, "migration: config folder copied")
        check(fm.fileExists(atPath: home + "/.config/cat-eye/config.json"), "migration: old folder stays")
        check(vault("com.oversire.app.plane").get("ocral") == "tok", "migration: Keychain entry copied")
        check(vault("com.oversire.app.ai").get("KEY") == "new", "migration: a new Keychain value wins")
        check(defs.stringArray(forKey: "ignoredFailures") == ["a"], "migration: defaults copied")
        check(!m.run(), "migration: the marker stops a second run")
        defs.removePersistentDomain(forName: suite)
        try? fm.removeItem(atPath: home)
    }
    let router = Router()
    router.go(.inbox(.all)); router.go(.inbox(.intake)); router.go(.runs(.all))
    check(router.backStack == [.home, .inbox(.intake)], "a tab change replaces the history entry")
    router.back()
    check(router.current == .inbox(.intake) && router.canGoForward, "back goes to the page before")
    router.forward()
    check(router.current == .runs(.all) && !router.canGoForward, "forward returns")
    router.back(); router.go(.agents)
    check(!router.canGoForward, "a new page clears forward")

    // Workstream linking: branches and SHAs → item key, or unlinked.
    do {
        func wr(_ branch: String, sha: String = "0000", title: String = "t") -> Run {
            Run(id: "9", name: "ci", displayTitle: title, status: "completed", conclusion: "success", headBranch: branch,
                headSha: sha, event: "push", url: "u", updatedAt: "", createdAt: "", startedAt: nil, number: 1,
                workflowName: "ci", actorLogin: nil)
        }
        let known: Set<String> = ["FRITZ", "TOWERTAIL", "TREBI"]
        let cos = [
            Checkout(path: "/w/.wt/towertail-42/towertail", repo: "towertail/towertail", branch: "towertail-42", head: "abc", key: "TOWERTAIL-42", cardId: "c1"),
            Checkout(path: "/w/.wt/trebi-7/trebi", repo: "o/trebi", branch: "fix-login", head: "def", key: "TREBI-7", cardId: nil),
            Checkout(path: "/w/.wt/trebi-8/trebi", repo: "o/trebi", branch: "main", head: "999", key: "TREBI-8", cardId: nil),
        ]
        func pr(_ branch: String, _ title: String) -> ChangeRequest {
            try! JSONDecoder().decode(ChangeRequest.self, from: Data("""
            {"number":1,"title":"\(title)","state":"OPEN","author":{"login":"a"},"headRefName":"\(branch)","baseRefName":"main",
             "url":"u","createdAt":"","updatedAt":"","reviewDecision":null,"additions":0,"deletions":0,"isDraft":false,"labels":[],"body":null}
            """.utf8))
        }
        let prs = [(repo: "o/app", pr: pr("feature-x", "Add export (FRITZ-31)"))]
        let rules = LinkRules()
        let table: [(String, Run, String?, LinkReason?)] = [
            ("towertail/towertail", wr("other", sha: "abc"), "TOWERTAIL-42", .head),
            ("towertail/towertail", wr("towertail-42"), "TOWERTAIL-42", .branch),
            ("o/trebi", wr("fix-login"), "TREBI-7", .branch),
            ("o/trebi", wr("main"), nil, nil),                       // a default branch never links by name
            ("o/app", wr("fritz-28/desktop-app"), "FRITZ-28", .prefix),
            ("o/app", wr("FRITZ-28-desktop"), "FRITZ-28", .prefix),
            ("o/app", wr("release-2"), nil, nil),                    // RELEASE is not a tracked project
            ("o/app", wr("my-fritz-28"), nil, nil),                  // the key must start the branch
            ("o/app", wr("feature-x"), "FRITZ-31", .pr),
            ("o/app", wr("feature-y", title: "Fix the build for trebi-12"), "TREBI-12", .trailer),
            ("o/other", wr("fix-login"), nil, nil),                  // same branch name, other repo
        ]
        for (repo, r, want, why) in table {
            let got = WorkstreamIndex.match(repo: repo, run: r, checkouts: cos, prs: prs, known: known, rules: rules)
            check(got?.0 == want && got?.1 == why, "link \(repo) \(r.headBranch)@\(r.headSha): got \(got.map { "\($0.0) \($0.1)" } ?? "nil")")
        }
        var off = LinkRules(); off.head = false
        check(WorkstreamIndex.match(repo: "towertail/towertail", run: wr("x", sha: "abc"), checkouts: cos, prs: [], known: known, rules: off) == nil,
              "a rule switched off does not link")
        check(WorkstreamIndex.key(in: "TOWERTAIL-42", known: known, whole: true) == "TOWERTAIL-42", "card name is a key")
        check(WorkstreamIndex.key(in: "TOWERTAIL-42 notes", known: known, whole: true) == nil, "card name with more text is not a key")
        check(WorkstreamIndex.repoName(remote: "git@github.com:towertail/towertail.git") == "towertail/towertail", "ssh remote")
        check(WorkstreamIndex.repoName(remote: "https://github.com/oversire/oversire") == "oversire/oversire", "https remote")
    }

    // Needs you: kind first, an unwatched failure before a watched one, then newest first.
    do {
        let now = Date()
        func n(_ k: NeedsYou.Kind, _ t: String, _ body: String = "", ago: Double) -> NeedsYou {
            NeedsYou(kind: k, title: t, body: body, at: now.addingTimeInterval(-ago), route: .home)
        }
        let got = NeedsYou.ranked([
            n(.intake, "intake", ago: 1), n(.review, "review", ago: 5),
            n(.runFailed, "watched", "FRITZ-1 · the session watches it", ago: 1), n(.runFailed, "loose", "app · main · unlinked", ago: 50),
            n(.agentWaiting, "old ask", ago: 600), n(.agentWaiting, "new ask", ago: 10), n(.aiCheck, "check", ago: 2),
        ]).map(\.title)
        check(got == ["new ask", "old ask", "check", "loose", "watched", "review", "intake"], "needs-you rank: \(got)")
    }

    // Queue: only the first entry starts, only with a free slot, and only when its condition holds.
    do {
        var lane = QueueLane(project: "ws/p", identifier: "FRITZ")
        lane.entries = [QueueEntry(key: "FRITZ-2", title: "b", added: Date()), QueueEntry(key: "FRITZ-3", title: "c", added: Date())]
        var busy = 0, ci = false, done = false
        var hour = 12
        func world() -> QueueWorld {
            let d = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
            return QueueWorld(busy: { _ in busy }, slots: { _ in 1 }, ciPassed: { _ in ci }, done: { _ in done }, now: d)
        }
        check(WorkQueue.due(lane, world: world())?.key == "FRITZ-2", "queue: a free slot starts the first entry")
        busy = 1
        check(WorkQueue.due(lane, world: world()) == nil, "queue: no free slot, no start")
        busy = 0
        lane.lastStarted = "FRITZ-1"
        lane.entries[0].condition = .ciPassed
        check(WorkQueue.due(lane, world: world()) == nil, "queue: waits for CI of the one above")
        ci = true
        check(WorkQueue.due(lane, world: world())?.key == "FRITZ-2", "queue: CI passed, start")
        lane.entries[0].condition = .done
        check(WorkQueue.due(lane, world: world()) == nil, "queue: waits until the one above is done")
        done = true
        check(WorkQueue.due(lane, world: world())?.key == "FRITZ-2", "queue: the one above is done, start")
        lane.entries[0].condition = .tonight
        check(WorkQueue.due(lane, world: world()) == nil, "queue: tonight waits at noon")
        hour = 23
        check(WorkQueue.due(lane, world: world())?.key == "FRITZ-2", "queue: tonight starts at 23:00")
        lane.entries.removeAll()
        check(WorkQueue.due(lane, world: world()) == nil, "queue: empty lane")
    }

    // AI checks: heuristics first, then the parse of the AI reply.
    do {
        var s = AgentSignals(phase: .working, quietMinutes: 4, tail: [], ci: nil, prOpen: false, status: .progress)
        check(AgentJudge.heuristic(s, quietLimit: 10) == nil, "check: not quiet long enough")
        s.quietMinutes = 15
        s.tail = ["$ go test -run X", "FAIL", "$ go test -run X", "FAIL", "$ go test -run X"]
        check(AgentJudge.heuristic(s, quietLimit: 10)?.0 == .stuck, "check: the same command three times is stuck")
        s.tail = ["Waiting for review."]; s.ci = .ok; s.prOpen = true
        check(AgentJudge.heuristic(s, quietLimit: 10)?.0 == .done, "check: open PR and green CI is done")
        s.ci = nil; s.prOpen = false
        check(AgentJudge.heuristic(s, quietLimit: 10) == nil, "check: unclear goes to AI")
        let p = AgentJudge.parse("```json\n{\"verdict\":\"stuck\",\"evidence\":[\"a\",\"b\"],\"nudge\":\"Add a timeout\"}\n```")
        check(p?.0 == .stuck && p?.1 == ["a", "b"] && p?.2 == "Add a timeout", "check: parse the AI reply")
        check(AgentJudge.parse("no json") == nil, "check: a bad reply is nil")
        let o = AgentJudge.parseOrder(#"{"order":["fritz-3","FRITZ-2"],"reason":"3 first"}"#, keys: ["FRITZ-2", "FRITZ-3"])
        check(o?.order == ["FRITZ-3", "FRITZ-2"], "order: parse")
        check(AgentJudge.parseOrder(#"{"order":["FRITZ-2","FRITZ-3"]}"#, keys: ["FRITZ-2", "FRITZ-3"]) == nil, "order: same order is no suggestion")
        check(AgentJudge.parseOrder(#"{"order":["FRITZ-2"]}"#, keys: ["FRITZ-2", "FRITZ-3"]) == nil, "order: a missing key is refused")
        // Session notes: transcript lines, the size cap, and the summary parse.
        let jsonl = [
            #"{"type":"mode","mode":"normal"}"#,
            #"{"type":"user","message":{"role":"user","content":"work on FRITZ-38\nplease"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"I read the code."},{"type":"tool_use","name":"Edit","input":{"file_path":"/r/session.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"./build.sh"}}]}}"#,
        ].joined(separator: "\n")
        let sl = SessionNotes.lines(jsonl: jsonl)
        check(sl == ["user: work on FRITZ-38 please", "assistant: I read the code.", "tool Edit: /r/session.swift", "tool Bash: ./build.sh"], "session lines \(sl)")
        let many = (0..<5000).map { "line \($0) " + String(repeating: "x", count: 40) }
        let capped = SessionNotes.cap(many, limit: 24_000)
        check(capped.count <= 24_000 && capped.hasPrefix("line 0 ") && capped.hasSuffix("line 4999 " + String(repeating: "x", count: 40)), "session cap keeps the task and the end")
        check(SessionNotes.cap(["a", "b"]) == "a\nb", "session cap leaves short text")
        check(SessionNotes.folder(cwd: "/Users/f/Projects/oversire/.wt/x_y") == "-Users-f-Projects-oversire--wt-x-y", "claude project folder")
        let sp = SessionNotes.parse("```json\n{\"done\":[\"Added the session tab\"],\"files\":[\"item_page.swift\"],\"decisions\":[],\"questions\":[\"Post on done?\"]}\n```")
        check(sp?.done == ["Added the session tab"] && sp?.questions.count == 1 && sp?.markdown.contains("**Open questions**") == true, "session summary parse")
        check(SessionNotes.parse(#"{"done":[],"files":[],"questions":[]}"#) == nil, "empty summary is nil")
    }

    // CI assist: flaky runs, explanation parse, digest facts.
    do {
        func run(_ id: Int, _ sha: String, _ c: String, _ at: String, wf: String = "ci") -> Run {
            Run(id: String(id), name: wf, displayTitle: "t", status: "completed", conclusion: c, headBranch: "main", headSha: sha, event: "push",
                url: "u/ci-\(id)", updatedAt: at, createdAt: at, startedAt: nil, number: id, workflowName: wf, actorLogin: nil)
        }
        let hist = [run(1, "a", "failure", "2026-10-01T10:00:00Z"), run(2, "a", "success", "2026-10-01T10:10:00Z"),
                    run(3, "b", "success", "2026-10-01T11:00:00Z"), run(4, "b", "failure", "2026-10-01T11:10:00Z"),
                    run(5, "c", "failure", "2026-10-01T12:00:00Z"), run(6, "c", "success", "2026-10-01T12:05:00Z", wf: "lint")]
        check(CIAssist.flakyRuns(hist) == ["2"], "flaky: fail then pass on one commit and workflow \(CIAssist.flakyRuns(hist))")
        var retry = run(7, "d", "success", "2026-10-01T13:00:00Z"); retry.attempt = 2
        check(CIAssist.passedOnRetry(old: (1, true), new: retry), "flaky: attempt 2 passed after attempt 1 failed")
        check(!CIAssist.passedOnRetry(old: (2, true), new: retry), "flaky: same attempt is not a retry")
        check(!CIAssist.passedOnRetry(old: nil, new: retry), "flaky: no history, no mark")
        let e = CIAssist.parseExplanation("```json\n{\"cause\":\"The test needs Postgres 16.\",\"fix\":\"Pin the image.\",\"confidence\":\"sure\"}\n```")
        check(e?.cause == "The test needs Postgres 16." && e?.fix == "Pin the image." && e?.confidence == "low", "explain: parse \(String(describing: e))")
        check(CIAssist.parseExplanation("{\"cause\":\"\"}") == nil, "explain: empty cause is nil")
        let now = parseISO("2026-10-01T20:00:00Z")!
        let facts = CIAssist.digestFacts(runs: [("o/r", hist), ("o/old", [run(9, "z", "failure", "2026-09-01T10:00:00Z")])], agents: [], queued: 2, intake: 0, now: now)
        let oldAI = try? JSONDecoder().decode(AIConfig.self, from: Data(#"{"enabled":true,"model":"m","tidy":false}"#.utf8))
        check(oldAI?.enabled == true && oldAI?.tidy == false && oldAI?.flaky == true && oldAI?.digest == false && oldAI?.digestHour == 8, "old AI config decodes with the new defaults")
        let oldAgents = try? JSONDecoder().decode(AgentsConfig.self, from: Data(#"{"autoStart":false}"#.utf8))
        check(oldAgents?.autoStart == false && oldAgents?.writeBack.enabled == true && oldAgents?.aiMode == .ask, "old agents config decodes")
        check((try? JSONDecoder().decode(GeneralConfig.self, from: Data("{}".utf8)))?.theme == .dark, "empty general config is dark")
        check(facts == ["6 runs in the last 24 h: 3 passed, 3 failed.", "Failures: r 3.", "2 items wait in the queue."], "digest facts \(facts)")
    }

    // Intake agent: the last JSON with a verdict, also when the terminal wraps it.
    do {
        let lines = ["⏺ I read the code.", "{\"verdict\":\"vague\",\"findings\":[\"No steps\"],", "\"block\":\"## Missing\\n- steps\",\"priority\":\"low\",\"labels\":[\"bug\"]}", "> "]
        let r = IntakeReport.parse(lines)
        check(r?.verdict == "vague" && r?.findings == ["No steps"] && r?.labels == ["bug"] && r?.priority == "low", "intake: parse \(String(describing: r))")
        check(IntakeReport.parse(["no result yet", "{\"other\":1}"]) == nil, "intake: no verdict, no report")
        let pr = IntakeAgent.prompt("{KEY} {title} {url} {body}", key: "TREBI-9", title: "T", url: "u", body: "")
        check(pr == "TREBI-9 T u (no description)", "intake: prompt fill")
    }

    // OverSire block: replace between the markers, keep the text around it.
    do {
        let body = "<p>Author text</p><ul><li>a</li></ul>"
        let once = OverSireBlock.merge(body, block: "<p>v1</p>")
        check(once == body + "<p>\(OverSireBlock.start)</p><p>v1</p><p>\(OverSireBlock.end)</p>", "block: added at the end")
        let twice = OverSireBlock.merge(once + "<p>Later note</p>", block: "<p>v2</p>")
        check(twice == body + "<p>\(OverSireBlock.start)</p><p>v2</p><p>\(OverSireBlock.end)</p><p>Later note</p>", "block: replaced in place")
        check(OverSireBlock.current(twice) == "</p><p>v2</p><p>", "block: read back")
        let plane = "<p>x</p><p class=\"editor-paragraph-block\">\(OverSireBlock.start)</p><p>old</p><p class=\"editor-paragraph-block\">\(OverSireBlock.end)</p>"
        check(OverSireBlock.merge(plane, block: "<p>new</p>") == "<p>x</p>" + OverSireBlock.wrap("<p>new</p>"), "block: Plane classes on the marker lines")
        let legacy = "<p>x</p><p>Cat Eye block ▾ (Cat Eye updates this part)</p><p>old</p><p>Cat Eye block ▴</p>"
        check(OverSireBlock.current(legacy) == "</p><p>old</p><p>", "block: reads the Cat Eye markers")
        check(OverSireBlock.merge(legacy, block: "<p>new</p>") == "<p>x</p>" + OverSireBlock.wrap("<p>new</p>"), "block: replaces the Cat Eye block")
        // A relay event that changes a run changes the fingerprint; the same poll result does not.
        func fr(_ status: String, _ c: String?) -> Run {
            Run(id: "9", name: "ci", displayTitle: "t", status: status, conclusion: c, headBranch: "fritz-1/x", headSha: "s", event: "push",
                url: "u/9", updatedAt: "", createdAt: "", startedAt: nil, number: 9, workflowName: "ci", actorLogin: nil)
        }
        let fpA = DataFingerprint(runs: [("o/r", [fr("in_progress", nil)])], prs: [], agents: [:], snapshots: [], lanes: [])
        let fpB = DataFingerprint(runs: [("o/r", [fr("in_progress", nil)])], prs: [], agents: [:], snapshots: [], lanes: [])
        let fpC = DataFingerprint(runs: [("o/r", [fr("completed", "failure")])], prs: [], agents: [:], snapshots: [], lanes: [])
        let fpD = DataFingerprint(runs: [("o/r", [fr("in_progress", nil)])], prs: [], agents: ["FRITZ-1": AgentSession(phase: .waiting, since: .distantPast)], snapshots: [], lanes: [])
        check(fpA == fpB && fpA != fpC && fpA != fpD, "fingerprint: same poll same value; run or agent change differs")
        var ws1 = Workstream(key: "FRITZ-1")
        ws1.checkouts = [Checkout(path: "/w", repo: "o/r", branch: "fritz-1/x", head: "s", key: "FRITZ-1", cardId: nil)]
        check(WorkstreamIndex.match(repo: "o/r", run: fr("completed", "failure"), checkouts: ws1.checkouts, prs: [], known: ["FRITZ"], rules: LinkRules()) != nil,
              "event: a run on the item branch links to the workstream")
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        func dr(_ c: String, ago: Double) -> DeployRecord {
            DeployRecord(repo: "o/r", workflow: "ci", title: "t", branch: "main", event: "push", conclusion: c, actor: "a", url: "u\(ago)\(c)",
                         number: 1, startedAt: nil, completedAt: isoFmt.string(from: noon.addingTimeInterval(-ago)), durationSec: 60, loggedAt: "")
        }
        let daily = InsightsPage.daily([dr("success", ago: 60), dr("failure", ago: 120), dr("success", ago: 86_400 * 2)], days: 3, now: noon)
        check(daily.count == 3 && daily[2].rate == 0.5 && daily[1].rate == nil && daily[0].rate == 1, "insights: daily pass rate with a gap")
        var ws = Workstream(key: "FRITZ-1")
        ws.agent = AgentSession(phase: .working, since: Date().addingTimeInterval(-3_000))
        let md = PlaneWriteBack.blockMarkdown(ws)
        check(md.contains("Working since") && !md.contains("50m"), "block: no running time, so it does not change each minute")
    }

    print("SELFTEST OK — \(ins.count) insights, report \(md.count) chars")
}


import XCTest
import OverSireCore
import OverSireAssistant
@testable import OverSireApp

final class WorkContextTests: XCTestCase {
    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "SLING")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let session = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w1"), id: "t1")
    private var readJobs: ((String, String) async -> [Job]?)!
    private var jobCalls = 0

    override func setUp() {
        readJobs = WorkContext.readJobs
        WorkContext.readJobs = { [weak self] _, id in
            await MainActor.run { self?.jobCalls += 1 }
            return [Job(id: "j1", name: "test", status: "completed", conclusion: "failure", url: "https://github.com/o/r/runs/\(id)/j1",
                        startedAt: nil, completedAt: nil, runnerName: nil,
                        steps: [Step(name: "swift test", status: "completed", conclusion: "failure", startedAt: nil, completedAt: nil)]),
                    Job(id: "j2", name: "lint", status: "completed", conclusion: "success", url: nil, startedAt: nil, completedAt: nil, runnerName: nil, steps: nil)]
        }
    }

    override func tearDown() {
        WorkContext.readJobs = readJobs
        MachinesController.shared.use(MachinesSnapshot())
    }

    private func item(_ n: Int, title: String? = nil, parent: String? = nil, status: String = "s1") -> Item {
        var i = Item(id: "i\(n)", key: "SLING-\(n)", title: title ?? "Item \(n)", url: "https://plane/SLING-\(n)", statusOptionId: status,
                     fields: ["Priority": "High"], assignees: ["ada"], labels: ["sync"], author: nil, updatedBy: nil, updatedAt: t0, activityAt: t0,
                     commentCount: 2, lastComment: nil, mentionsMe: false)
        i.parentId = parent
        i.body = "The sync drops rows."
        return i
    }

    private func pr(_ n: Int, head: String, updated: String) -> ChangeRequest {
        ChangeRequest(number: n, title: "Fix part \(n)", state: "OPEN", author: .init(login: "ada"), headRefName: head, baseRefName: "main",
                      url: "https://github.com/o/r/pull/\(n)", createdAt: updated, updatedAt: updated, reviewDecision: nil, additions: 3,
                      deletions: 1, isDraft: false, labels: [], body: "Body \(n)", mine: true)
    }

    private func run(_ id: Int, branch: String, conclusion: String) -> Run {
        Run(id: "\(id)", name: "CI", displayTitle: "Run \(id)", status: "completed", conclusion: conclusion, headBranch: branch, headSha: "sha\(id)",
            event: "pull_request", url: "https://github.com/o/r/actions/runs/\(id)", updatedAt: "2026-10-20T10:0\(id % 10):00Z",
            createdAt: "2026-10-20T09:00:00Z", startedAt: "2026-10-20T09:00:00Z", number: id, workflowName: "CI", actorLogin: nil)
    }

    private func remote(_ branch: String) -> MachinesSnapshot {
        var s = MachinesSnapshot()
        s.sessions["studio"] = [DaemonSession(id: "s-9", machine: "studio", runtime: "oversire", harness: "codex", cwd: "/w", repo: "o/r", branch: branch,
                                              state: .waiting, reason: .question, lastMessage: "Which schema?", stateSince: t0, updatedAt: t0, sources: ["wire"])]
        return s
    }

    /// SLING-1 with a sub-item, 2 PRs, a failed run on a PR head, a local session, a session on "studio" and an open question.
    private func seeded(items extra: Int = 0) -> TestAppData {
        let d = TestAppData()
        var items = [item(1, title: "Fix the sync"), item(2, parent: "i1", status: "s2"), item(3)]
        items += (0..<extra).map { item(100 + $0, title: String(repeating: "Long title ", count: 8)) }
        d.projectStore.seed(ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false),
                                            statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted"),
                                                            StatusOption(id: "s2", name: "Done", color: "#000", group: "completed")],
                                            items: items, fetchedAt: t0))
        d.prGrouped = [("o/r", [pr(11, head: "sling-1/fix", updated: "2026-10-20T10:00:00Z"), pr(12, head: "sling-1/docs", updated: "2026-10-21T10:00:00Z")])]
        d.grouped = [("o/r", [run(29, branch: "sling-1/fix", conclusion: "failure"), run(22, branch: "sling-1/docs", conclusion: "success"),
                              run(23, branch: "main", conclusion: "success")])]
        d.agentIndex.seed("SLING-1", AgentSession(phase: .working, since: t0, card: "w1", paneKey: "w1:1", repo: "o/r", message: "Tests run."))
        let q = SessionQuestion(id: QuestionID(rawValue: "fake:q1"), session: session, origin: .session,
                                items: [QuestionItem(id: "q1", text: "Drop the old rows?", kind: .single, options: [.init(label: "Yes"), .init(label: "No")])],
                                via: .askReply, askedAt: t0)
        d.questions.seed([QuestionBoard.Entry(question: q, state: .open, firstSeen: t0)], keys: [session: "SLING-1"])
        d.workstreams.rebuild(store: d.projectStore, agents: d.agentIndex, runs: d.grouped, prs: d.prGrouped)
        return d
    }

    private func call(_ d: TestAppData, _ id: String, _ args: [String: JSONValue] = [:]) async -> (String, [String: Any]) {
        let r = await d.actions.run(id, ActionArgs(.object(args)))
        guard case .ok(let summary, let data, _) = r else { XCTFail("\(id): \(r)"); return ("", [:]) }
        let text = data?.text ?? "null"
        XCTAssertLessThanOrEqual(text.utf8.count, JSONValue.readLimit, id)
        guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { XCTFail("\(id): no JSON object: \(text)"); return (summary, [:]) }
        XCTAssertFalse(summary.isEmpty, id)
        return (summary, o)
    }

    // MARK: WorkContext

    func testFactsHoldPRsRunsSessionsAndQuestions() async {
        let d = seeded()
        var ctx = WorkContext(d)
        let snap = remote("sling-1/fix")
        ctx.machines = { snap }
        let f = await ctx.load(key: "sling-1")

        XCTAssertEqual(f.item?.key, "SLING-1")
        XCTAssertEqual(f.item?.status, "Todo")
        XCTAssertEqual(f.subItems.map(\.key), ["SLING-2"])
        XCTAssertEqual(f.progress, WorkFacts.Progress(done: 1, total: 1))
        XCTAssertEqual(f.prs.map(\.number), [12, 11])
        XCTAssertEqual(f.branch, "sling-1/docs")
        XCTAssertEqual(f.branchFrom, "pr")

        let failed = f.runs.first { $0.id == "29" }
        XCTAssertEqual(failed?.pr, 11)
        XCTAssertEqual(failed?.failedJobs?.map(\.name), ["test"])
        XCTAssertEqual(f.runs.first { $0.id == "23" }?.onBase, true)
        XCTAssertEqual(f.ci, "failed")
        XCTAssertEqual(jobCalls, 1)

        XCTAssertEqual(f.sessions.count, 2)
        XCTAssertEqual(f.sessions.first { $0.local }?.machine, "this Mac")
        let other = f.sessions.first { !$0.local }
        XCTAssertEqual(other?.machine, "studio")
        XCTAssertEqual(other?.state, "needsInput")

        XCTAssertEqual(f.questions.map(\.text), ["Drop the old rows?"])
        XCTAssertTrue(f.summary.hasPrefix("SLING-1 Todo · 2 PRs · CI failed · 2 sessions · 1 question"), f.summary)

        // The jobs are in the cache now: a second load makes no call.
        _ = await ctx.load(key: "SLING-1")
        XCTAssertEqual(jobCalls, 1)
    }

    func testUnknownKeyGivesNoItem() async {
        let d = seeded()
        let f = await MainActor.run { WorkContext(d).facts("NOPE-1") }
        XCTAssertNil(f.item)
        XCTAssertEqual(f.summary, "No loaded item NOPE-1.")
        let r = await d.actions.run("work.context", ActionArgs(.object(["key": .string("NOPE-1")])))
        guard case .notAllowed = r else { return XCTFail("\(r)") }
    }

    // MARK: Read tools

    func testReadToolsAreReadKind() {
        let kind = Dictionary(uniqueKeysWithValues: TestAppData().actions.all.map { ($0.id, $0.kind) })
        for id in ["work.context", "item.get", "item.list", "pr.list", "pr.get", "run.list", "run.get", "session.list", "question.list",
                   "queue.list", "activity.list", "insights.summary", "cloud.status"] {
            XCTAssertEqual(kind[id], .read, id)
        }
    }

    func testReadToolsGiveTheDataOfTheirHelp() async {
        let d = seeded()
        await MainActor.run { MachinesController.shared.use(remote("sling-1/fix")) }
        _ = await d.actions.run("queue.add", ActionArgs(.object(["key": .string("SLING-3")])))

        var (s, o) = await call(d, "work.context", ["key": .string("SLING-1")])
        XCTAssertTrue(s.hasPrefix("SLING-1"), s)
        XCTAssertEqual((o["prs"] as? [Any])?.count, 2)
        XCTAssertEqual((o["sessions"] as? [Any])?.count, 2)
        XCTAssertNotNil(o["notes"])

        (s, o) = await call(d, "item.get", ["key": .string("SLING-1")])
        XCTAssertEqual(o["body"] as? String, "The sync drops rows.")
        XCTAssertEqual(o["commentCount"] as? Int, 2)
        XCTAssertEqual((o["subItems"] as? [[String: Any]])?.first?["key"] as? String, "SLING-2")

        (s, o) = await call(d, "item.list", ["group": .string("todo"), "assignee": .string("ada")])
        XCTAssertEqual(o["total"] as? Int, 2)
        XCTAssertEqual((o["items"] as? [[String: Any]])?.compactMap { $0["key"] as? String }.sorted(), ["SLING-1", "SLING-3"])

        (s, o) = await call(d, "pr.list", ["mine": .bool(true)])
        XCTAssertEqual(o["total"] as? Int, 2)
        XCTAssertEqual((o["prs"] as? [[String: Any]])?.first?["key"] as? String, "SLING-1")

        (s, o) = await call(d, "pr.get", ["repo": .string("o/r"), "number": .int(11)])
        XCTAssertEqual(o["body"] as? String, "Body 11")
        XCTAssertEqual((o["runs"] as? [[String: Any]])?.first?["id"] as? String, "29")

        (s, o) = await call(d, "run.list", ["failed": .bool(true)])
        XCTAssertEqual(o["total"] as? Int, 1)
        XCTAssertEqual((o["runs"] as? [[String: Any]])?.first?["key"] as? String, "SLING-1")

        (s, o) = await call(d, "run.get", ["repo": .string("o/r"), "runId": .string("29")])
        let jobs = o["jobs"] as? [[String: Any]]
        XCTAssertEqual(jobs?.count, 2)
        XCTAssertEqual(jobs?.first?["failedSteps"] as? [String], ["swift test"])

        (s, o) = await call(d, "session.list")
        let sessions = o["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 2)
        XCTAssertEqual(Set(sessions?.compactMap { $0["key"] as? String } ?? []), ["SLING-1"])

        (s, o) = await call(d, "question.list")
        let q = (o["questions"] as? [[String: Any]])?.first
        XCTAssertEqual(q?["key"] as? String, "SLING-1")
        XCTAssertEqual(q?["state"] as? String, "open")

        (s, o) = await call(d, "queue.list")
        let lane = (o["lanes"] as? [[String: Any]])?.first
        XCTAssertEqual(lane?["project"] as? String, "SLING")
        XCTAssertEqual((lane?["entries"] as? [[String: Any]])?.first?["key"] as? String, "SLING-3")
        XCTAssertNotNil(o["plans"])

        (s, o) = await call(d, "activity.list", ["limit": .int(5)])
        XCTAssertNotNil(o["entries"] as? [Any])

        (s, o) = await call(d, "insights.summary")
        for k in ["runs", "prs", "items", "merged", "sessions"] { XCTAssertNotNil(o[k], k) }
        XCTAssertEqual((o["runs"] as? [String: Any])?["failing"] as? Int, 1)

        (s, o) = await call(d, "cloud.status")
        XCTAssertNotNil(o["state"])
        XCTAssertEqual(o["connected"] as? Bool, false)
    }

    func testListOverTheByteLimitIsCutWithANote() async {
        let d = seeded(items: 220)
        let (_, o) = await call(d, "item.list", ["limit": .int(200)])
        let shown = (o["items"] as? [Any])?.count ?? 0
        XCTAssertGreaterThan(shown, 0)
        XCTAssertLessThan(shown, 200)
        XCTAssertEqual(o["total"] as? Int, 223)
        XCTAssertEqual(o["cut"] as? String, "items: showing \(shown) of 200")
    }

    // MARK: Byte limit

    func testClipKeepsSmallValuesAndCutsLargeOnes() throws {
        let small = JSONValue.object(["a": .int(1)])
        XCTAssertEqual(small.clipped(to: 100), small)

        let list = JSONValue.array((0..<500).map { .string("entry \($0)") })
        let cut = list.clipped(to: 1000)
        XCTAssertLessThanOrEqual(cut.text.utf8.count, 1000)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(cut.text.utf8)))
        XCTAssertTrue(cut.object?["cut"]?.string?.hasPrefix("items: showing ") == true, cut.text)

        let text = JSONValue.object(["body": .string(String(repeating: "é", count: 2000)), "key": .string("SLING-1")]).clipped(to: 500)
        XCTAssertLessThanOrEqual(text.text.utf8.count, 500)
        XCTAssertEqual(text.object?["key"], .string("SLING-1"))
        XCTAssertEqual(text.object?["cut"], .string("body: text cut"))
    }
}

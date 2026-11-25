import OverSireCore
import OverSireSync
import UserNotifications
import XCTest
@testable import OverSireApp

/// One test for each row of the approved preview: the exact title, subtitle, body and level.
final class NoticeTextTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // 14:13:20 UTC
    private let utc = TimeZone(identifier: "UTC")!
    private let ref = ProjectRef(workspace: "ocral", id: "p1")

    private func item(_ key: String = "OVERSIRE-597", title: String = "Link a hand-started agent session to its item", status: String = "done",
                      author: String? = "Ada", updatedBy: String? = "Ada", priority: String? = nil, body: String? = nil,
                      last: Comment? = nil) -> Item {
        Item(id: "i-\(key)", key: key, title: title, url: "https://plane.example/\(key)", statusOptionId: status,
             fields: priority.map { ["Priority": $0] } ?? [:], assignees: ["fritz"], labels: [], author: author, updatedBy: updatedBy,
             updatedAt: t0, activityAt: t0, commentCount: last == nil ? 0 : 1, lastComment: last, mentionsMe: false, body: body)
    }

    private func snap(_ items: [Item]) -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "OVERSIRE", title: "oversire", url: "", closed: false),
                        statusOptions: [StatusOption(id: "todo", name: "Todo", color: "", group: "unstarted"),
                                        StatusOption(id: "done", name: "Done", color: "", group: "completed")],
                        items: items, fetchedAt: t0, me: "fritz")
    }

    private func notice(_ steps: [[ItemChange]], _ i: Item) -> Notice? {
        var net = ItemNet()
        for (n, list) in steps.enumerated() { net.add(list, at: t0 + Double(n) * 240) }
        return Notice.item(net, item: i, itemId: i.id, in: snap([i]), zone: utc)
    }

    private func assert(_ n: Notice?, _ title: String, _ subtitle: String, _ body: String, _ level: Notice.Level,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(n?.title, title, file: file, line: line)
        XCTAssertEqual(n?.subtitle, subtitle, file: file, line: line)
        XCTAssertEqual(n?.body, body, file: file, line: line)
        XCTAssertEqual(n?.level, level, file: file, line: line)
    }

    private func comment(_ body: String?, by who: String = "Ada", at: Date? = nil) -> Comment {
        Comment(id: UUID().uuidString, author: who, createdAt: at ?? t0, url: "u", body: body)
    }

    // MARK: Tracker items

    func testClosed() {
        let n = notice([[.status(from: "Todo", to: "Done"), .closed]], item("TOWERTAIL-258", title: "Rules API"))
        assert(n, "✓ Done · TOWERTAIL-258", "Rules API", "Was Todo.", .active)
        XCTAssertEqual(n?.category, .item)
        XCTAssertEqual(n?.id, "project:i-TOWERTAIL-258")
    }

    func testDoneAgain() {
        let n = notice([[.status(from: "Done", to: "In Progress"), .reopened], [.status(from: "In Progress", to: "Done"), .closed]], item())
        assert(n, "✓ Done again · OVERSIRE-597", "Link a hand-started agent session to its item",
               "Reopened at 14:13, closed at 14:17. No net change.", .passive)
    }

    func testStatusMove() {
        let n = notice([[.status(from: "In Progress", to: "In Review")]], item("OVERSIRE-610", title: "Retry the relay after a sleep"))
        assert(n, "→ In Review · OVERSIRE-610", "Retry the relay after a sleep", "Was In Progress.", .active)
        let again = notice([[.status(from: "Todo", to: "Todo")]], item())
        XCTAssertEqual(again?.body, "Set again.")
        XCTAssertEqual(again?.level, .passive)
    }

    func testMentionQuotesComment() {
        let c = comment("@fritz can you check the relay timeout before we ship? The hub drops after 30 s on hotel Wi-Fi.")
        let n = notice([[.comments(new: 1, last: c), .mention]], item("OVERSIRE-588", title: "Cloud relay timeouts", last: c))
        assert(n, "@ Ada mentioned you · OVERSIRE-588", "Cloud relay timeouts",
               "\"@fritz can you check the relay timeout before we ship? The hub drops after 30 s on hotel Wi-Fi.\"", .active)
        XCTAssertEqual(n?.category, .comment)
    }

    func testMentionInBody() {
        let i = item("OVERSIRE-612", title: "Show the step", author: "Grace", body: "## Ask\n\n@fritz please **check** this.")
        let n = notice([[.added, .mention]], i)
        assert(n, "@ Grace mentioned you · OVERSIRE-612", "Show the step", "\"Ask @fritz please check this.\"\nNew item.", .active)
    }

    func testOneComment() {
        let c = comment("I see the same drop on the mba. Logs attached to the item.")
        let n = notice([[.comments(new: 1, last: c)]], item("OVERSIRE-588", title: "Cloud relay timeouts", last: c))
        assert(n, "💬 Ada · OVERSIRE-588", "Cloud relay timeouts", "\"I see the same drop on the mba. Logs attached to the item.\"", .active)
        let empty = notice([[.comments(new: 1, last: comment(nil))]], item())
        XCTAssertEqual(empty?.body, "New comment.")
    }

    func testThreeComments() {
        let n = notice([[.comments(new: 1, last: comment("old", at: t0))], [.comments(new: 2, last: comment("newest", by: "Bea", at: t0 + 200))]], item())
        assert(n, "💬 3 comments · OVERSIRE-597", "Link a hand-started agent session to its item", "\"newest\"", .active)
    }

    func testAssigned() {
        let n = notice([[.assigned("fritz")]], item("TOWERTAIL-260", title: "Snooze from the watch", status: "todo", priority: "High"))
        assert(n, "→ Assigned to you · TOWERTAIL-260", "Snooze from the watch", "Todo · Priority High · by Ada", .active)
        XCTAssertEqual(n?.category, .assigned)
    }

    func testNewItem() {
        let n = notice([[.added]], item("OVERSIRE-612", title: "Show the runbook step in the menu bar", status: "todo", priority: "Medium"))
        assert(n, "＋ New item · OVERSIRE-612", "Show the runbook step in the menu bar", "Todo · Priority Medium · by Ada", .active)
    }

    func testFieldsArePassive() {
        let one = notice([[.field(name: "Priority", from: "Low", to: "High")]], item())
        assert(one, "✎ Priority · OVERSIRE-597", "Link a hand-started agent session to its item", "Priority: Low → High", .passive)
        let two = notice([[.field(name: "Priority", from: "Low", to: "High"), .unassigned("bea")]], item())
        XCTAssertEqual(two?.title, "✎ 2 fields · OVERSIRE-597")
        XCTAssertEqual(two?.body, "Priority: Low → High\nUnassigned bea")
    }

    func testIntakeNew() {
        let i = IntakeItem(id: "in1", workItemId: "w1", name: "Crash when the daemon restarts during a sync", priority: nil, createdAt: t0,
                           author: "Ada", source: nil)
        let n = Notice.intake(i, .new, body: "The app stops when the daemon restarts in the middle of a store sync. Seen twice on the mbp.", in: snap([]))
        assert(n, "＋ Intake · oversire", "Crash when the daemon restarts during a sync",
               "The app stops when the daemon restarts in the middle of a store sync. Seen twice on the mbp.", .active)
        XCTAssertEqual(n.id, "intake:\(ref.storeKey)|w1")
        XCTAssertEqual(n.category, .intake)
        XCTAssertEqual(Notice.intake(i, .accepted(key: "OVERSIRE-9"), body: nil, in: snap([])).body, "Now OVERSIRE-9.")
        XCTAssertEqual(Notice.intake(i, .changed, body: nil, in: snap([])).level, .passive)
    }

    func testIntakeNewNoBody() {
        let i = IntakeItem(id: "in1", workItemId: "w1", name: "Crash", priority: nil, createdAt: t0, author: "Ada", source: nil)
        XCTAssertEqual(Notice.intake(i, .new, body: nil, in: snap([])).body, "From Ada.")
        XCTAssertEqual(Notice.intake(i, .new, body: "  \n", in: snap([])).body, "From Ada.")
    }

    // MARK: Agents and runbooks

    private var session: AgentSession {
        AgentSession(phase: .waiting, since: t0, agent: .claude, message: "Should I also change the daemon route, or only the app?")
    }

    func testAgentWaitingHasNoPrefix() {
        let i = item()
        let n = Notice.agent("OVERSIRE-597", session, item: i, project: snap([i]))
        assert(n, "⏸ Needs your input · OVERSIRE-597", "Claude · Link a hand-started agent session to its item",
               "Should I also change the daemon route, or only the app?", .timeSensitive)
        XCTAssertEqual(n.id, "agent:i-OVERSIRE-597")
        XCTAssertEqual(n.category, .agentWaiting)
    }

    func testAgentDone() {
        var a = session
        a.phase = .done
        a.message = "I changed 3 files. swift test passes."
        let n = Notice.agent("OVERSIRE-597", a, item: item(), project: nil)
        assert(n, "✓ Agent done · OVERSIRE-597", "Claude · Link a hand-started agent session to its item", "I changed 3 files. swift test passes.", .active)
        XCTAssertEqual(n.thread, "oversire", "no project: the app stack")
        a.message = String(repeating: "a", count: 300)
        XCTAssertLessThanOrEqual(Notice.agent("K-1", a, item: nil, project: nil).body.count, 200)
    }

    func testQuestion() {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "daemon", id: "mba"), id: "w"), id: "t")
        let q = SessionQuestion(id: "daemon:mba:q1", session: s, origin: .session,
                                items: [QuestionItem(id: "q1", text: "Which branch is the base: main or release/1.4?", kind: .single,
                                                     options: [.init(label: "main"), .init(label: "release/1.4")], allowsOther: true)],
                                via: .form, askedAt: t0)
        let n = Notice.question(q, key: "OVERSIRE-597", agent: .claude, item: item(), project: snap([item()]))
        assert(n, "? Question · OVERSIRE-597", "Claude · Link a hand-started agent session to its item",
               "Which branch is the base: main or release/1.4?", .timeSensitive)
        XCTAssertEqual(n.id, "agent:OVERSIRE-597")
        XCTAssertEqual(n.category, .question(options: ["main", "release/1.4"], approve: false, reply: true))
        XCTAssertEqual(n.target.question, "daemon:mba:q1")
    }

    func testRunbookGate() {
        let steps = ["plan", "review", "deploy", "check", "close"].map { RunbookStep(id: $0, name: $0.capitalized, agent: "claude", prompt: "") }
        let itemRef = ItemRef(project: ref, id: "i12", key: "OVERSIRE-12", url: URL(string: "https://plane.example/OVERSIRE-12")!)
        let r = RunbookRun(id: "rb_1", item: itemRef, machine: "mba", runtime: "orca", repo: "/src",
                           runbook: Runbook(id: "release", name: "Release", steps: steps), agents: [:], state: .gate, current: "deploy",
                           steps: [], started: t0, updated: t0)
        let row = NeedsYou(kind: .gate, key: "OVERSIRE-12", reason: "Approve the deploy to production.", at: t0, route: .item("OVERSIRE-12", .runbook))
        let n = Notice.runbook(r, row, project: snap([]))
        assert(n, "⏸ Runbook waits · OVERSIRE-12", "Release · step 3 of 5: Deploy", "Approve the deploy to production.", .timeSensitive)
        XCTAssertEqual(n.id, "runbook:OVERSIRE-12")
    }

    // MARK: CI

    private func run(_ conclusion: String?, status: String = "completed") -> Run {
        Run(id: "77", name: "release", displayTitle: "t", status: status, conclusion: conclusion, headBranch: "main", headSha: "s", event: "push",
            url: "https://github.com/oversire/cli/actions/runs/77", updatedAt: "2026-11-25T12:04:12Z", createdAt: "2026-11-25T12:00:00Z",
            startedAt: "2026-11-25T12:00:00Z", number: 1, workflowName: "release", actorLogin: nil)
    }

    func testCIFailedWithFailureAndLink() {
        let f = CIFailureView(job: "build", jobId: "1", step: "go test", messages: [])
        let n = Notice.ciEnded(repo: "oversire/cli", run("failure"), failure: f, linked: "OVERSIRE-601")
        assert(n, "✕ CI failed · oversire/cli", "release · main · \(run("failure").durationText)", "Failed at build › go test. Linked to OVERSIRE-601.", .active)
        XCTAssertEqual(n.id, "end-https://github.com/oversire/cli/actions/runs/77")
        XCTAssertEqual(n.thread, "oversire/cli")
        XCTAssertEqual(n.category, .ciFailed)
    }

    func testCIFailedNoJobsDoc() {
        XCTAssertEqual(Notice.ciEnded(repo: "oversire/cli", run("failure"), failure: nil, linked: nil).body, "")
        XCTAssertEqual(Notice.ciEnded(repo: "oversire/cli", run("timed_out"), failure: nil, linked: "K-1").body, "Linked to K-1.")
    }

    func testCIPassedPassiveEmptyBody() {
        let n = Notice.ciEnded(repo: "oversire/cli", run("success"), failure: nil, linked: "K-1")
        XCTAssertEqual(n.title, "✓ CI passed · oversire/cli")
        XCTAssertEqual(n.body, "")
        XCTAssertEqual(n.level, .passive)
        XCTAssertEqual(Notice.ciEnded(repo: "o/r", run("cancelled"), failure: nil, linked: nil).title, "⊘ CI cancelled · o/r")
    }

    func testCIStartedPassive() {
        let n = Notice.ciStarted(repo: "oversire/oversire", run(nil, status: "in_progress"))
        assert(n, "▶ CI started · oversire/oversire", "release · main", "", .passive)
        XCTAssertEqual(n.id, "start-https://github.com/oversire/cli/actions/runs/77")
    }

    func testRerun403Hint() {
        let n = Notice.rerunFailed(repo: "oversire/cli", run("failure"), errors: ["release: HTTP 403: Resource not accessible by integration"])
        assert(n, "✕ Re-run failed · oversire/cli", "release · main", "GitHub refused the re-run (HTTP 403). Check the gh login scopes.", .active)
        XCTAssertEqual(n.id, "rerun-https://github.com/oversire/cli/actions/runs/77")
        XCTAssertEqual(Notice.rerunFailed(repo: "o/r", run("failure"), errors: ["a: x", "b: y"]).body, "a: x\nb: y")
    }

    // MARK: OverSire

    func testProblem() {
        let p = Problem(key: "k", area: .sync, job: "plane sync", host: "ocral", subject: nil, message: "The request timed out.", count: 4,
                        first: t0, last: t0)
        let n = Notice.problem(p, zone: utc)
        assert(n, "⚠ Plane sync fails · ocral", "Since 14:13 · 4 tries", "The request timed out.", .active)
        XCTAssertEqual(n.id, "problem-k")
        let net = Problem(key: "n", area: .net, job: "HTTP", host: "127.0.0.1:7690", subject: "home", message: "", count: 1, first: t0, last: t0)
        XCTAssertEqual(Notice.problem(net, zone: utc).title, "⚠ HTTP 127.0.0.1:7690 fails · home")
        XCTAssertEqual(Notice.problem(net, zone: utc).subtitle, "Since 14:13 · 1 try")
    }

    func testUpdateReady() {
        let n = Notice.updateReady("1.4.2")
        assert(n, "⬆ Update ready · OverSire 1.4.2", "", "Install it from Settings › General.", .active)
        XCTAssertEqual(n.id, "update-ready-1.4.2")
        XCTAssertEqual(Notice.updated("1.4.2").title, "✓ Updated · OverSire 1.4.2")
        XCTAssertEqual(Notice.updated("1.4.2").level, .passive)
    }

    func testJoin() {
        let r = JoinRequestFrame(request: "rq1", machine: "mbp", host: "mbp.local", confirm: "4821", expiresAt: t0)
        let n = Notice.join(r, group: "My machines")
        assert(n, "⊕ Join request · mbp", "My machines", "Code 4821. Check that the same code shows on mbp.", .timeSensitive)
        XCTAssertEqual(n.id, "join:rq1", "the id of the Approve and Deny route")
        XCTAssertEqual(NoticeCenter.content(n).categoryIdentifier, UserJoinNotifier.category)
    }

    // MARK: Rules

    func testNoTitleHasWorkspace() {
        let i = item()
        let all: [Notice?] = [
            notice([[.added]], i), notice([[.closed]], i), notice([[.status(from: "Todo", to: "Done")]], i),
            Notice.agent("OVERSIRE-597", session, item: i, project: snap([i])),
            Notice.intake(IntakeItem(id: "a", workItemId: "b", name: "n", priority: nil, createdAt: t0, author: nil, source: nil), .new, body: nil, in: snap([])),
        ]
        for n in all.compactMap({ $0 }) {
            XCTAssertFalse(n.title.contains("ocral"), n.title)
            XCTAssertFalse(n.title.contains("›"), n.title)
            XCTAssertFalse(n.title.unicodeScalars.contains("\u{FE0F}"), n.title)
        }
    }

    func testThreads() {
        let i = item()
        XCTAssertEqual(notice([[.added]], i)?.thread, ref.storeKey)
        XCTAssertEqual(Notice.agent("K", session, item: i, project: snap([i])).thread, ref.storeKey)
        XCTAssertEqual(Notice.ciStarted(repo: "o/r", run(nil, status: "in_progress")).thread, "o/r")
        XCTAssertEqual(Notice.updateReady("1").thread, "oversire")
        let n = Notice(id: "x", title: "T", subtitle: "S", body: "B", thread: "th", category: .comment)
        let c = NoticeCenter.content(n)
        XCTAssertEqual([c.title, c.subtitle, c.body, c.threadIdentifier, c.categoryIdentifier], ["T", "S", "B", "th", "comment"])
    }

    func testQuoteCapsAndFlattens() {
        XCTAssertEqual(Notice.quote("**Bold** [link](https://x)\n\n- one\n- `two`"), "\"Bold link one two\"")
        XCTAssertEqual(Notice.excerpt("![img](a.png)\n```\ncode\n```\n"), nil)
        let long = Notice.excerpt(String(repeating: "word ", count: 100), limit: 20)
        XCTAssertEqual(long?.count, 20)
        XCTAssertTrue(long?.hasSuffix("…") == true)
        XCTAssertNil(Notice.quote(nil))
    }

    func testEmptyNetGivesNoNotice() {
        XCTAssertNil(notice([[.field(name: "Priority", from: "Low", to: "High")], [.field(name: "Priority", from: "High", to: "Low")]], item()))
    }
}

final class NoticeCenterTests: XCTestCase {
    private final class FakeCenter: NoticePosting {
        var delivered: [UNNotificationRequest] = []
        var removed: [[String]] = []
        func deliver(_ request: UNNotificationRequest) { delivered.append(request) }
        func removeDelivered(_ ids: [String]) { removed.append(ids) }
    }

    func testPostAndWithdraw() {
        let fake = FakeCenter()
        let c = NoticeCenter(center: fake)
        c.post(Notice(id: "project:1", title: "✓ Done · K-1", thread: "a/p"))
        c.withdraw(["project:1"])
        XCTAssertEqual(fake.delivered.map(\.identifier), ["project:1"])
        XCTAssertEqual(fake.delivered.first?.content.threadIdentifier, "a/p")
        XCTAssertEqual(fake.removed, [["project:1"]])
    }
}

import Foundation
import OverSireAssistant
import OverSireCore
import UserNotifications
import XCTest
@testable import OverSireApp

final class NoticeCategoryTests: XCTestCase {
    private func ids(_ c: NoticeCategory) -> [String] { c.actions.map(\.id) }

    private func question(_ items: [QuestionItem], via: SessionQuestion.Via = .form) -> NoticeCategory? {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "daemon", id: "mba"), id: "w"), id: "t")
        let q = SessionQuestion(id: "daemon:mba:q1", session: s, origin: .session, items: items, via: via, askedAt: Date())
        return Notice.question(q, key: "K-1", agent: .claude, item: nil, project: nil).category
    }

    private func single(_ n: Int, other: Bool = false, id: String = "q1") -> QuestionItem {
        QuestionItem(id: id, text: "Pick one", kind: .single, options: (1...n).map { .init(label: "o\($0)") }, allowsOther: other)
    }

    func testFixedCategoriesHaveDecidedActions() {
        let want: [NoticeCategory: [String]] = [
            .item: ["open", "read"], .comment: ["open", "reply"], .assigned: ["open", "work"], .open: ["open"], .intake: ["open", "groom"],
            .agentWaiting: ["session", "reply"], .agentDone: ["changes", "open"], .runbook: ["run"], .ciFailed: ["logs", "rerun"],
            .problem: ["logs"], .update: ["install", "later"], .join: ["approve", "deny"],
        ]
        XCTAssertEqual(Set(NoticeCategory.fixed.map(\.id)).count, NoticeCategory.fixed.count)
        for c in NoticeCategory.fixed { XCTAssertEqual(ids(c), want[c], c.id) }
        XCTAssertEqual(NoticeCategory.ciFailed.actions.map(\.title), ["Open logs", "Re-run failed"])
        XCTAssertEqual(NoticeCategory.update.actions.map(\.title), ["Install now", "Later"])
    }

    func testJoinKeepsIds() {
        XCTAssertEqual(NoticeCategory.join.id, "join-request")
        XCTAssertEqual(UserJoinNotifier.approve, "approve")
        XCTAssertEqual(UserJoinNotifier.deny, "deny")
        let c = NoticeCenter.category(.join)
        XCTAssertEqual(c.actions.map(\.title), ["Approve", "Deny"])
        XCTAssertTrue(c.actions[1].options.contains(.destructive))
    }

    func testQuestionThreeOptionsAndReply() {
        let c = question([single(3, other: true)])
        XCTAssertEqual(c.map(ids), ["answer:o1", "answer:o2", "answer:o3", "reply"])
        XCTAssertEqual(c?.id, "question.o1|o2|o3.r")
        XCTAssertEqual(question([single(2)]).map(ids), ["answer:o1", "answer:o2"])
        XCTAssertEqual(question([QuestionItem(id: "q1", text: "Why?", kind: .free)]).map(ids), ["session", "reply"])
    }

    func testApproveQuestionShowsApproveDeny() {
        let c = question([.approve(id: "p", text: "Run rm -rf build?")])
        XCTAssertEqual(c.map(ids), ["approve", "deny"])
        XCTAssertEqual(c?.id, "question..a")
    }

    func testMultiItemQuestionHasNoOptions() {
        XCTAssertEqual(question([single(2, other: true), single(2, id: "q2")]).map(ids), ["session"])
        XCTAssertEqual(question([single(4, other: true)]).map(ids), ["session", "reply"], "4 options do not fit")
        XCTAssertEqual(question([QuestionItem(id: "q1", text: "Pick", kind: .multi, options: [.init(label: "a")])]).map(ids), ["session"])
        XCTAssertEqual(question([single(2, other: true)], via: .waiting).map(ids), ["session"], "the session takes no answer here")
    }

    func testActionIdRoundTrip() {
        let all: [NoticeAction] = [.open, .markRead, .reply, .startWork, .groom, .openSession, .reviewChanges, .openLogs, .rerunFailed, .openRun,
                                   .install, .later, .approve, .deny, .answer("release/1.4: the branch")]
        for a in all { XCTAssertEqual(NoticeAction(id: a.id), a, a.id) }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertNil(NoticeAction(id: UNNotificationDefaultActionIdentifier))
        XCTAssertNil(NoticeAction(id: UNNotificationDismissActionIdentifier))
    }

    func testForegroundFlags() {
        let front: [NoticeAction] = [.open, .startWork, .groom, .openSession, .reviewChanges, .openLogs, .openRun]
        let back: [NoticeAction] = [.markRead, .reply, .rerunFailed, .install, .later, .approve, .deny, .answer("a")]
        for a in front { XCTAssertTrue(a.foreground, a.id) }
        for a in back { XCTAssertFalse(a.foreground, a.id) }
        let options = NoticeCenter.category(.ciFailed).actions.map(\.options)
        XCTAssertEqual(options, [.foreground, []])
    }
}

final class NoticeTargetTests: XCTestCase {
    func testUserInfoRoundTrip() {
        let t = NoticeTarget(key: "K-1", itemId: "i1", project: "ocral/p1", question: "q", repo: "o/r", run: "9", version: "1.2", request: "rq")
        XCTAssertEqual(NoticeTarget(userInfo: t.userInfo), t)
        XCTAssertEqual(NoticeTarget(key: "K-1").userInfo, ["key": "K-1"])
        XCTAssertEqual(NoticeTarget(userInfo: [:]), NoticeTarget())
    }
}

final class NoticeRouteTests: XCTestCase {
    private func route(_ id: String) -> Route? {
        NoticeRoute.route(id, item: { ["i1": "K-1", "K-1": "K-1", "K-2": "K-2"][$0] }) { url in url == "https://gh/run/9" ? ("o/r", "9") : nil }
    }

    func testProjectAgentRunbookRoutes() {
        XCTAssertEqual(route("project:i1"), .item("K-1", .overview))
        XCTAssertEqual(route("agent:K-2"), .item("K-2", .session))
        XCTAssertEqual(route("runbook:K-1"), .item("K-1", .runbook))
        XCTAssertNil(route("project:gone"), "an item that is not loaded")
    }

    func testRunRouteAndFallback() {
        XCTAssertEqual(route("end-https://gh/run/9"), .run(repo: "o/r", id: "9"))
        XCTAssertEqual(route("start-https://gh/run/9"), .run(repo: "o/r", id: "9"))
        XCTAssertEqual(route("end-https://gh/run/1"), .runs(.all))
    }

    func testRerunPrefix() {
        XCTAssertEqual(route("rerun-https://gh/run/9"), .run(repo: "o/r", id: "9"))
    }

    func testQuestionWithoutKeyIsNil() {
        XCTAssertNil(route("agent:question"))
    }

    func testProblemRoute() {
        XCTAssertEqual(route("problem-sync|ocral"), .settings(.logs))
        XCTAssertNil(route("update-ready-1.2"))
    }

    func testFailedOpensThePageOfItsNotice() {
        XCTAssertEqual(route("failed:agent:K-2"), .item("K-2", .session))
        XCTAssertEqual(Notice.failed(.reply, id: "agent:K-2", subject: "K-2", reason: "", thread: "t", target: NoticeTarget()).id, "failed:agent:K-2")
    }
}

@MainActor
final class NoticeResponderTests: XCTestCase {
    /// The action calls, in order.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(String, JSONValue)] = []
        func add(_ id: String, _ v: JSONValue) { lock.lock(); list.append((id, v)); lock.unlock() }
        var all: [(id: String, args: JSONValue)] { lock.lock(); defer { lock.unlock() }; return list.map { (id: $0.0, args: $0.1) } }
    }

    private let calls = Calls()
    private var opened: [Route] = []
    private var posted: [Notice] = []
    private var groomed: [String] = []
    private var installs = 0
    private var startable = true

    private func responder(fail: String? = nil) -> NoticeResponder {
        let calls = calls
        let ids = ["item.markRead", "item.comment", "session.send", "session.start", "question.answer", "ci.rerun"]
        let list = ActionList(ids.map { id in
            ActionSpec(id: id, title: id, help: "", kind: .change) { a in
                calls.add(id, a.values)
                return id == fail ? .failed("The tracker is down.") : .ok(summary: "ok")
            }
        })
        return NoticeResponder(actions: list, open: { [unowned self] in self.opened.append($0) }, canStart: { [unowned self] _ in self.startable },
                               groom: { [unowned self] in self.groomed.append($0) }, install: { [unowned self] in self.installs += 1 },
                               post: { [unowned self] in self.posted.append($0) })
    }

    private func pressed(_ id: String, _ category: NoticeCategory?, _ t: NoticeTarget) -> NoticeResponder.Pressed {
        NoticeResponder.Pressed(id: id, category: category?.id ?? "", target: t, thread: "ocral/p1")
    }

    private let item = NoticeTarget(key: "K-1", itemId: "i1", project: "ocral/p1")

    func testReplyPostsComment() async {
        await responder().handle(.reply, on: pressed("project:i1", .comment, item), text: " Looks good. ")
        XCTAssertEqual(calls.all.map(\.id), ["item.comment"])
        XCTAssertEqual(calls.all.first?.args, .object(["key": .string("K-1"), "body": .string("Looks good.")]))
    }

    func testMarkRead() async {
        await responder().handle(.markRead, on: pressed("project:i1", .item, item), text: nil)
        XCTAssertEqual(calls.all.map(\.id), ["item.markRead"])
        XCTAssertEqual(calls.all.first?.args["key"], .string("K-1"))
    }

    func testSessionReplyRunsWithoutConfirm() async {
        await responder().handle(.reply, on: pressed("agent:i1", .agentWaiting, item), text: "Use main.")
        XCTAssertEqual(calls.all.map(\.id), ["session.send"])
        XCTAssertEqual(calls.all.first?.args, .object(["key": .string("K-1"), "text": .string("Use main.")]))
    }

    func testAnswerOption() async {
        var t = item
        t.question = "daemon:mba:q1"
        let q = NoticeCategory.question(options: ["main", "release"], approve: false, reply: true)
        await responder().handle(.answer("release"), on: pressed("agent:K-1", q, t), text: nil)
        await responder().handle(.deny, on: pressed("agent:K-1", .question(options: [], approve: true, reply: false), t), text: nil)
        XCTAssertEqual(calls.all.map(\.id), ["question.answer", "question.answer"])
        XCTAssertEqual(calls.all.map { $0.args["answer"] }, [.string("release"), .string(QuestionItem.deny)])
        XCTAssertEqual(calls.all.first?.args["id"], .string("daemon:mba:q1"))
    }

    func testQuestionReplyText() async {
        var t = item
        t.question = "daemon:mba:q1"
        await responder().handle(.reply, on: pressed("agent:K-1", .question(options: [], approve: false, reply: true), t), text: "Both.")
        XCTAssertEqual(calls.all.map(\.id), ["question.answer"])
        XCTAssertEqual(calls.all.first?.args, .object(["id": .string("daemon:mba:q1"), "answer": .string("Both.")]))
    }

    func testRerunUsesCIRerunFailedOnly() async {
        await responder().handle(.rerunFailed, on: pressed("end-u", .ciFailed, NoticeTarget(repo: "o/r", run: "9")), text: nil)
        XCTAssertEqual(calls.all.map(\.id), ["ci.rerun"])
        XCTAssertEqual(calls.all.first?.args, .object(["repo": .string("o/r"), "run": .string("9"), "failedOnly": .bool(true)]))
    }

    func testFailurePostsNotice() async {
        await responder(fail: "item.comment").handle(.reply, on: pressed("project:i1", .comment, item), text: "Hi")
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.title, "✕ Reply not sent · K-1")
        XCTAssertEqual(posted.first?.body, "The tracker is down.")
        XCTAssertEqual(posted.first?.thread, "ocral/p1", "the same stack")
        XCTAssertEqual(posted.first?.id, "failed:project:i1")
    }

    func testEmptyReplyDoesNothing() async {
        await responder().handle(.reply, on: pressed("project:i1", .comment, item), text: "  \n")
        await responder().handle(.reply, on: pressed("project:i1", .comment, item), text: nil)
        XCTAssertTrue(calls.all.isEmpty)
        XCTAssertTrue(posted.isEmpty)
    }

    func testOpenActionsRoute() async {
        let r = responder()
        await r.handle(.openSession, on: pressed("agent:i1", .agentWaiting, item), text: nil)
        await r.handle(.reviewChanges, on: pressed("agent:i1", .agentDone, item), text: nil)
        await r.handle(.openRun, on: pressed("runbook:K-1", .runbook, item), text: nil)
        await r.handle(.openLogs, on: pressed("end-u", .ciFailed, NoticeTarget(repo: "o/r", run: "9")), text: nil)
        await r.handle(.openLogs, on: pressed("problem-x", .problem, NoticeTarget()), text: nil)
        XCTAssertEqual(opened, [.item("K-1", .session), .item("K-1", .changes), .item("K-1", .runbook), .run(repo: "o/r", id: "9"), .settings(.logs)])
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testStartWorkStartsOrOpens() async {
        await responder().handle(.startWork, on: pressed("project:i1", .assigned, item), text: nil)
        XCTAssertEqual(calls.all.map(\.id), ["session.start"])
        startable = false
        await responder().handle(.startWork, on: pressed("project:i1", .assigned, item), text: nil)
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(opened, [.item("K-1", .overview)])
    }

    func testGroomInstallLater() async {
        let r = responder()
        await r.handle(.groom, on: pressed("intake:ocral/p1|i9", .intake, NoticeTarget(itemId: "i9", project: "ocral/p1")), text: nil)
        await r.handle(.install, on: pressed("update-ready-1.2", .update, NoticeTarget(version: "1.2")), text: nil)
        await r.handle(.later, on: pressed("update-ready-1.2", .update, NoticeTarget(version: "1.2")), text: nil)
        XCTAssertEqual(groomed, ["ocral/p1"])
        XCTAssertEqual(installs, 1)
        XCTAssertTrue(calls.all.isEmpty)
    }
}

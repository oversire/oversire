import XCTest
import OverSireCore
@testable import OverSireApp

final class LogStoreTests: XCTestCase {
    private var dir = ""
    private var now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        dir = NSTemporaryDirectory() + "oversire-logs-\(UUID().uuidString)"
        LOGS_CFG = LogConfig()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        LOGS_CFG = LogConfig()
    }

    private func store() -> LogStore {
        LogStore(dir: dir, problems: ProblemTracker(path: nil, now: { [unowned self] in now }), now: { [unowned self] in now })
    }

    private func line(_ message: String = "Done", level: LogLevel = .ok, job: String = "Status", host: String? = "local-cli", at: Date? = nil) -> LogEntry {
        LogEntry(at: at ?? now, level: level, area: .ai, job: job, host: host, message: message)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    func testEachDayGetsItsFileAndALaunchReadsThemBack() {
        let s = store()
        let yesterday = now.addingTimeInterval(-86_400)
        s.write(line("first", at: yesterday))
        s.write(line("second"))
        XCTAssertEqual(files(), [LogStore.day(yesterday) + ".jsonl", LogStore.day(now) + ".jsonl"])
        XCTAssertEqual(store().entries.map(\.message), ["second", "first"], "newest first, from the files")
    }

    func testALaunchDropsTheFilesOlderThanTheKeepDays() {
        let s = store()
        for d in 0..<9 { s.write(line("day \(d)", at: now.addingTimeInterval(-Double(d) * 86_400))) }
        XCTAssertEqual(files().count, 9)
        let again = store()
        XCTAssertEqual(files().count, 7, "7 days: today and the 6 days before")
        XCTAssertEqual(again.entries.last?.message, "day 6")
        LOGS_CFG.keepDays = 1
        again.prune()
        XCTAssertEqual(files(), [LogStore.day(now) + ".jsonl"])
    }

    func testSecretsNeverReachTheFile() throws {
        let s = store()
        s.secrets = ["my-very-secret-key"]
        var e = line("401 from the server: invalid x-api-key: abc123 · Authorization: Bearer tok_987654321 · key my-very-secret-key", level: .error)
        e.input = "token=ghp_0123456789abcdefABCDEF and sk-ant-api03-zzzzzzzzzzzz"
        e.outputTail = #"{"api_key": "plane_api_1234567890abcdef"}"#
        s.write(e)
        let text = try String(contentsOfFile: dir + "/" + files()[0], encoding: .utf8)
        for secret in ["abc123", "tok_987654321", "my-very-secret-key", "ghp_0123456789abcdefABCDEF", "sk-ant-api03", "plane_api_1234567890abcdef"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("401 from the server"))
        XCTAssertEqual(s.entries.first?.message.contains("[removed]"), true)
    }

    func testTheSettingsDropTheAITextAndTheRoutineLines() {
        let s = store()
        LOGS_CFG.keepAIText = false
        var e = line()
        e.input = "the prompt"
        e.output = "the reply"
        s.write(e)
        XCTAssertNil(s.entries.first?.input)
        XCTAssertNil(s.entries.first?.output)

        var poll = line(job: "Plane poll")
        poll.verbose = true
        s.write(poll)
        XCTAssertEqual(s.entries.count, 1, "Normal detail keeps no routine ok line")
        LOGS_CFG.debug = true
        s.write(poll)
        XCTAssertEqual(s.entries.count, 2)
    }

    func testClearRemovesTheFiles() {
        let s = store()
        s.write(line())
        s.clear()
        XCTAssertTrue(files().isEmpty)
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertEqual(s.bytes, 0)
    }
}

final class ProblemTrackerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_790_000_000)

    private func line(_ level: LogLevel, host: String = "mbp", _ message: String = "python3 not found") -> LogEntry {
        LogEntry(at: now, level: level, area: .sessions, job: "History read", subject: "OVERSIRE-1", host: host, message: message)
    }

    func testErrorsOfOneKeyAddToOneProblem() {
        let t = ProblemTracker(path: nil, now: { [unowned self] in now })
        var opened: [String] = []
        t.opened = { opened.append($0.key) }
        t.record(line(.error))
        now += 60
        t.record(line(.error, "exit 127"))
        t.record(line(.error, host: "studio"))
        XCTAssertEqual(t.open.count, 2)
        let p = t.problem("sessions|History read|mbp")
        XCTAssertEqual(p?.count, 2)
        XCTAssertEqual(p?.message, "exit 127")
        XCTAssertEqual(opened, ["sessions|History read|mbp", "sessions|History read|studio"], "a notice only when a problem opens")
    }

    func testTheNextSuccessClearsTheProblem() {
        let t = ProblemTracker(path: nil)
        t.record(line(.error))
        t.record(line(.ok, host: "studio", "12 turns"))
        XCTAssertEqual(t.open.count, 1, "another host does not clear it")
        t.record(line(.ok, "12 turns"))
        XCTAssertTrue(t.open.isEmpty)
    }

    func testThreeWarningsInARowOpenAProblem() {
        let t = ProblemTracker(path: nil)
        t.record(line(.warn))
        t.record(line(.warn))
        XCTAssertTrue(t.open.isEmpty, "a fallback that works is a warning")
        t.record(line(.ok))
        t.record(line(.warn))
        t.record(line(.warn))
        XCTAssertTrue(t.open.isEmpty, "a success starts the count again")
        t.record(line(.warn))
        XCTAssertEqual(t.open.first?.count, 3)
    }

    func testDismissHidesTheProblemUntilItsNextError() {
        let t = ProblemTracker(path: nil)
        var opened = 0
        t.opened = { _ in opened += 1 }
        t.record(line(.error))
        t.dismiss("sessions|History read|mbp")
        XCTAssertTrue(t.open.isEmpty)
        t.record(line(.warn))
        XCTAssertTrue(t.open.isEmpty, "a warning does not show it again")
        t.record(line(.error))
        XCTAssertEqual(t.open.first?.count, 3)
        XCTAssertEqual(opened, 2)
    }

    func testAProblemClosesAfter24HoursAndItIsSaved() throws {
        let path = NSTemporaryDirectory() + "problems-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let t = ProblemTracker(path: path, now: { [unowned self] in now })
        t.record(line(.error))
        XCTAssertEqual(ProblemTracker(path: path, now: { [unowned self] in now }).open.count, 1, "a launch reads the problems back")
        now += 25 * 3600
        XCTAssertTrue(ProblemTracker(path: path, now: { [unowned self] in now }).open.isEmpty, "its job stopped")
    }
}

final class LogListModelTests: XCTestCase {
    private let entries = [
        LogEntry(level: .ok, area: .ai, job: "Status", subject: "OVERSIRE-137", message: "Blocked on you"),
        LogEntry(level: .warn, area: .sessions, job: "History read", subject: "TOWERTAIL-61", host: "mbp", message: "Used the screen only"),
        LogEntry(level: .error, area: .sync, job: "GitHub poll", host: "gh", message: "Could not read the runs"),
        LogEntry(level: .ok, area: .runner, job: "Work order", subject: "OVERSIRE-149", host: "D1", message: "Done"),
    ]

    func testTheFiltersAndTheSearch() {
        var m = LogListModel()
        XCTAssertEqual(m.rows(entries).count, 4)
        m.filter = .problems
        XCTAssertEqual(m.rows(entries).map(\.job), ["History read", "GitHub poll"])
        m.filter = .runner
        XCTAssertEqual(m.rows(entries).map(\.job), ["Work order"])
        m.filter = .all
        m.text = "oversire-1"
        XCTAssertEqual(m.rows(entries).map(\.job), ["Status", "Work order"])
        m.text = "MBP"
        XCTAssertEqual(m.rows(entries).map(\.job), ["History read"])
    }

    func testTheDetailsAndTheDuration() {
        var e = entries[0]
        e.engine = "local-cli"
        e.model = ""
        e.tokensIn = 2864
        e.tokensOut = 612
        XCTAssertEqual(LogListModel.details(e).map(\.0), ["Engine", "Tokens", "Time"])
        XCTAssertEqual(LogListModel.details(e)[1].1, "2864 in · 612 out")
        XCTAssertEqual(LogListModel.took(840), "840 ms")
        XCTAssertEqual(LogListModel.took(6200), "6.2 s")
        XCTAssertEqual(LogListModel.took(nil), "—")
    }

    func testAWorkOrderLogsItsEnd() {
        let order = WorkOrder(id: "w1", runner: "D1", runtime: "orca", order: .read(SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "w"), id: "s1"), lines: 5), suggestion: "s",
                              createdAt: Date(), expiresAt: Date(), state: .failed, result: WorkOrderResult(error: "orca: no such card"))
        let e = WorkOrderLog.entry(order)
        XCTAssertEqual(e?.level, .error)
        XCTAssertEqual(e?.message, "orca: no such card")
        XCTAssertEqual(e?.problemKey, "runner|Work order|D1")
        var queued = order
        queued.state = .queued
        XCTAssertNil(WorkOrderLog.entry(queued))
    }

    func testTheMenuIconTellsTheProblems() {
        let k = MenuIconState(runs: [], waitingAgents: 0, unread: 0, unreadDot: false, problems: 2)
        XCTAssertTrue(k.label.hasSuffix("· 2 problems"))
        XCTAssertEqual(MenuIconState(runs: [], waitingAgents: 0, unread: 0, unreadDot: false).problems, 0)
    }

}

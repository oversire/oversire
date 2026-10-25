import XCTest
import OverSireCore
import OverSireAI
import OverSireTestKit
@testable import OverSireApp

@MainActor
final class ItemSummariesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var dir: URL!
    private var engine: FakeAIEngine!
    private var sums: ItemSummaries!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("item-summaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        engine = FakeAIEngine()
        engine.on(.itemSummary, .success(#"{"gist":"The page shows the status.","points":["a"],"open":[]}"#))
        sums = ItemSummaries(path: dir.path + "/sums.json") { [unowned self] in AIClient(cfg: AIConfig(), router: AIRouter(engines: [self.engine])) }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func item(_ key: String, body: String, days: Double) -> Item {
        Item(id: key, key: key, title: "Title of \(key)", url: "", statusOptionId: nil, fields: [:], assignees: [], labels: [], author: nil,
             updatedBy: nil, updatedAt: now, activityAt: now.addingTimeInterval(-days * 86400), commentCount: 0, lastComment: nil,
             mentionsMe: false, body: body)
    }

    private func settle() {
        let done = expectation(forNotification: ItemSummaries.changed, object: sums) { [unowned self] _ in self.sums.busy.isEmpty }
        wait(for: [done], timeout: 5)
    }

    func testTickSummarizesTheNewestOpenItemOnce() {
        let long = String(repeating: "A long description. ", count: 100)
        let items = [(item("A-1", body: long, days: 2), true), (item("A-2", body: long, days: 1), true),
                     (item("A-3", body: long, days: 0.5), false), (item("A-4", body: long, days: 9), true),
                     (item("A-5", body: "Short.", days: 0.1), true)]
        sums.tick(items, now: now)
        settle()
        XCTAssertEqual(engine.tasks.count, 1)
        XCTAssertNotNil(sums.summary("A-2"), "the newest open item goes first; a done item waits")
        sums.tick(items, now: now)
        settle()
        XCTAssertNotNil(sums.summary("A-1"))
        sums.tick(items, now: now)
        XCTAssertEqual(engine.tasks.count, 2, "no call for a done, an old or a short item")
    }

    func testNoCallWhenAnotherAppOwnsTheAutomations() {
        let items = [(item("A-1", body: String(repeating: "A long description. ", count: 100), days: 1), true)]
        sums.mayAct = { false }
        sums.tick(items, now: now)
        XCTAssertTrue(sums.busy.isEmpty)
        XCTAssertEqual(engine.tasks.count, 0)
        sums.mayAct = { true }
        sums.tick(items, now: now)
        settle()
        XCTAssertEqual(engine.tasks.count, 1)
    }

    func testANewDescriptionGetsANewSummaryAndAFailureDoesNotRepeat() {
        let long = String(repeating: "A long description. ", count: 100)
        sums.tick([(item("A-1", body: long, days: 1), true)], now: now)
        settle()
        engine.on(.itemSummary, .success("no json"))
        let changed = [(item("A-1", body: long + " More.", days: 0), true)]
        XCTAssertTrue(sums.isStale("A-1", body: long + " More."))
        sums.tick(changed, now: now)
        settle()
        XCTAssertEqual(engine.tasks.count, 2)
        XCTAssertNotNil(sums.errors["A-1"])
        sums.tick(changed, now: now)
        XCTAssertEqual(engine.tasks.count, 2, "one try for each description")
    }

    func testParseOfALongReplyFitsTheLimitWithWholeSentences() throws {
        let line = "The daemon polls once and logs hint events for each Mac of the group."
        let o: [String: Any] = ["gist": String(repeating: "A long gist sentence. ", count: 12), "points": (1...6).map { "\(line) \($0)" },
                                "open": ["Which adapter option is best for the home daemon of the user?", "How does the daemon get a Plane token?", "A third."]]
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        let s = try XCTUnwrap(ItemSummary.parse(reply, hash: "h"))
        XCTAssertLessThanOrEqual(s.length, ItemSummary.maxLength)
        XCTAssertLessThanOrEqual(s.gist.count, ItemSummary.maxGist)
        XCTAssertTrue(s.gist.hasSuffix("."), "the gist ends at a sentence end: \(s.gist)")
        XCTAssertLessThanOrEqual(s.points.count, 3)
        XCTAssertLessThanOrEqual(s.open.count, 2)
        XCTAssertTrue(s.points.allSatisfy { $0.hasPrefix(line) }, "no line is cut")
        XCTAssertEqual(s.version, ItemSummary.version)
    }

    func testParseOfAShortReplyKeepsAllOfIt() throws {
        let s = try XCTUnwrap(ItemSummary.parse(#"{"gist":"Fix the menu.","points":["Phase 1.","Use a lease."],"open":["Which token?"]}"#, hash: "h"))
        XCTAssertEqual(s.gist, "Fix the menu.")
        XCTAssertEqual(s.points, ["Phase 1.", "Use a lease."])
        XCTAssertEqual(s.open, ["Which token?"])
        XCTAssertTrue(s.markdown.contains("**Open:** Which token?"))
    }

    func testAGistWithNoSentenceEndIsCutAtAWord() {
        let g = ItemSummary.clip(String(repeating: "word ", count: 60), ItemSummary.maxGist)
        XCTAssertLessThanOrEqual(g.count, ItemSummary.maxGist)
        XCTAssertTrue(g.hasSuffix("word…"))
    }

    func testACachedVersionOneSummaryIsStale() throws {
        let body = String(repeating: "A long description. ", count: 100).trimmingCharacters(in: .whitespaces)
        let old = #"{"A-1":{"gist":"Old.","points":[],"open":[],"hash":"\#(ItemSummary.hash(body))","at":0}}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("old.json"))
        let cached = ItemSummaries(path: dir.path + "/old.json") { [unowned self] in AIClient(cfg: AIConfig(), router: AIRouter(engines: [self.engine])) }
        XCTAssertEqual(cached.summary("A-1")?.version, 1)
        XCTAssertTrue(cached.isStale("A-1", body: body))
        sums = cached
        sums.tick([(item("A-1", body: body, days: 1), true)], now: now)
        settle()
        XCTAssertEqual(engine.tasks.count, 1, "the page refreshes an old summary once")
        XCTAssertFalse(sums.isStale("A-1", body: body))
    }
}

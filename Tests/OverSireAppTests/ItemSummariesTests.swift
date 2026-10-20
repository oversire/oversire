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
}

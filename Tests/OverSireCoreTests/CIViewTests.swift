import XCTest
import OverSireCore
import OverSireTestKit

/// The contract fixture Contract/fixtures/<type>/<name>.json.
private func fixture(_ type: String, _ name: String, file: String = #filePath) throws -> Data {
    let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Contract/fixtures/\(type)/\(name).json"))
}

final class CIViewTests: XCTestCase {
    func testStateDocRoundTrip() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let doc = try dec.decode(CIStateDoc.self, from: fixture("ci-state-doc", "degraded"))
        XCTAssertTrue(doc.degraded)
        XCTAssertEqual(doc.source, .poll)
        let budget = try XCTUnwrap(doc.budget)
        XCTAssertEqual(budget.remaining, 312)
        XCTAssertEqual(budget.resetAt, ISO8601DateFormatter().date(from: "2026-11-21T15:00:00Z"))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let back = try dec.decode(CIStateDoc.self, from: enc.encode(doc))
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.budget?.resetAt, budget.resetAt)
    }

    func testRunViewFromRun() {
        let r = FakeCI.run(id: "5", status: "in_progress", conclusion: nil, attempt: 1)
        let v = CIRunView(r)
        XCTAssertEqual(v.id, "5")
        XCTAssertEqual(v.attempt, 1)
    }

    func testFailureViewFromFailure() {
        let v = CIFailureView(Failure(job: "test", step: "go test", messages: ["x"]), jobId: "7", logTail: nil, url: nil)
        XCTAssertEqual(v.job, "test")
        XCTAssertEqual(v.jobId, "7")
        XCTAssertEqual(v.step, "go test")
        XCTAssertEqual(v.messages, ["x"])
        XCTAssertNil(v.logTail)
    }
}

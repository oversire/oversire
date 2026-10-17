import OverSireCore
import XCTest
@testable import OverSireApp

final class CloudAIRecordsTests: XCTestCase {
    func testEmptyStatus() {
        let r = CloudAIRecords()
        XCTAssertEqual(r.jobsStatus, "No jobs")
        XCTAssertEqual(r.suggestionsStatus, "None open")
        XCTAssertEqual(r.runnerStatus, "No work orders")
    }

    func testStatusFromTheContractFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Contract/fixtures").standardized
        func all<R: Decodable>(_ folder: String, _ type: R.Type) throws -> [R] {
            let dir = root.appendingPathComponent(folder)
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                .map { try d.decode(R.self, from: Data(contentsOf: $0)) }
        }
        let r = CloudAIRecords(jobs: try all("job", AIJob.self), suggestions: try all("suggestion", Suggestion.self),
                               orders: try all("work-order", WorkOrder.self))
        let on = r.jobs.filter(\.enabled).count
        XCTAssertEqual(r.jobsStatus, "\(on) of \(r.jobs.count) on")
        let open = r.suggestions.filter { $0.state == .open }.count
        XCTAssertEqual(r.suggestionsStatus, open == 0 ? "None open" : "\(open) open")
        XCTAssertTrue(r.runnerStatus.hasSuffix("waiting") || r.runnerStatus == "No work orders")
    }
}

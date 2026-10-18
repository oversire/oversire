import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

final class CloudReplicationTests: XCTestCase {
    let base = URL(string: "https://cloud.test")!
    let op = StoreOp(collection: "pins", id: "p1", op: .delete, hlc: "001790000005000-000000-mac", device: "mac")

    func testPushAndPull() async throws {
        let http = RecordedHTTP()
        let wire = String(decoding: try JSONEncoder().encode(op), as: UTF8.self)
        http.on("POST", "https://cloud.test/v1/store/ops", 200, #"{"accepted":[\#(wire)],"head":3}"#)
        http.on("GET", "https://cloud.test/v1/store/ops?after=2&limit=500", 200, #"{"ops":[\#(wire)],"cursor":3,"more":false,"reset":false}"#)
        let r = CloudReplication(base: base, token: "tok", http: http)
        let accepted = try await r.push([op])
        XCTAssertEqual(accepted, [op])
        let sent = try JSONDecoder().decode([String: [StoreOp]].self, from: XCTUnwrap(http.requests[0].httpBody))
        XCTAssertEqual(sent, ["ops": [op]])
        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let page = try await r.pull(after: Cursor(rawValue: "2"))
        XCTAssertEqual(page, StorePull(ops: [op], cursor: Cursor(rawValue: "3")))
    }

    func testUnauthorized() async {
        let http = RecordedHTTP()
        http.on("GET", "https://cloud.test/v1/store/ops?after=0&limit=500", 401, #"{"error":"unauthorized"}"#)
        do {
            _ = try await CloudReplication(base: base, token: "tok", http: http).pull(after: nil)
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unauthorized)
        }
    }
}

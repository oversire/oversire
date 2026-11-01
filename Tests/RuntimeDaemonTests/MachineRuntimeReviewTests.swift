import Foundation
import OverSireCore
import OverSireTestKit
import RuntimeDaemon
import XCTest

/// Each review route sends the right request and decodes the contract fixture of its reply.
final class MachineRuntimeReviewTests: XCTestCase {
    private func fixture(_ type: String, _ name: String, file: String = #filePath) throws -> Data {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Contract/fixtures/\(type)/\(name).json"))
    }

    private func runtime(_ replies: [ScriptedHTTP.Reply]) -> (MachineRuntime, ScriptedHTTP) {
        let http = ScriptedHTTP(replies)
        return (MachineRuntime(machine: "mini", client: DaemonClient(base: URL(string: "http://mini:7690")!, token: "t", http: http)), http)
    }

    private func line(_ r: URLRequest) -> String { "\(r.httpMethod ?? "GET") \(r.url!.path)\(r.url!.query.map { "?" + $0 } ?? "")" }

    func testReadRoutesDecodeTheFixtures() async throws {
        let (rt, http) = runtime([.init(body: try fixture("reviews-page", "mixed")), .init(body: try fixture("review-detail", "code")),
                                  .init(body: try fixture("review-detail", "plan")), .init(body: try fixture("file-diff", "modified"))])
        let rs: any ReviewSource = rt
        XCTAssertEqual(rs.machine, "mini")

        let page = try await rs.reviews(kind: nil)
        XCTAssertEqual(page.reviews.map(\.key), ["SLING-170", "OVERSIRE-366", "OVERSIRE-371"])
        XCTAssertEqual(page.reviews[1].merge, .conflict)
        XCTAssertEqual(page.notPushed.first?.ahead, 7)

        let code = try await rs.review("SLING-170", kind: .code)
        XCTAssertEqual(code.files.count, 4)
        XCTAssertEqual(code.pending.map(\.id), ["c_4e5f6a7b"])
        XCTAssertEqual(code.pending.first?.anchor, .code(repo: "sling-cli", path: "core/dbio/database/database_clickhouse.go", line: 228, from: 227, side: .new))

        let plan = try await rs.review("OVERSIRE-371", kind: .plan)
        XCTAssertEqual(plan.plan?.blocks.map(\.id), ["goal", "tests"])

        let diff = try await rs.diff("SLING-170", repo: "sling-cli", path: "core/dbio/database/database.go")
        XCTAssertEqual(diff.hunks.first?.lines.count, 7)

        XCTAssertEqual(http.requests.map(line), [
            "GET /v1/reviews",
            "GET /v1/reviews/SLING-170?kind=code",
            "GET /v1/reviews/OVERSIRE-371?kind=plan",
            "GET /v1/reviews/SLING-170/diff?repo=sling-cli&path=core/dbio/database/database.go",
        ])
        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testCommentRoutes() async throws {
        let comment = try JSONSerialization.data(withJSONObject: [
            "id": "c_99999999", "key": "SLING-170", "round": 2, "state": "pending",
            "anchor": ["repo": "sling-cli", "path": "a.go", "line": 4, "from": 2, "side": "new"],
            "text": "Why?", "createdAt": "2026-11-01T14:20:00Z",
        ])
        let (rt, http) = runtime([.init(status: 201, body: comment), .init(body: Data("{}".utf8)), .init(status: 204, body: Data()),
                                  .init(status: 204, body: Data()), .init(status: 409, body: Data(#"{"error":"the comment is not pending"}"#.utf8))])
        let draft = CommentDraft(kind: .code, anchor: .code(repo: "sling-cli", path: "a.go", line: 4, from: 2, side: .new), text: "Why?")
        let c = try await rt.addComment("SLING-170", draft)
        XCTAssertEqual(c.id, "c_99999999")
        try await rt.editComment("SLING-170", id: c.id, CommentEdit(text: "Why so?"))
        try await rt.deleteComment("SLING-170", id: c.id, kind: .code)
        try await rt.markViewed("SLING-170", ViewedMark(repo: "sling-cli", path: "a+b.go", viewed: true))
        do {
            try await rt.editComment("SLING-170", id: "c_0a1b2c3d", CommentEdit(text: "x"))
            XCTFail("a submitted comment must not change")
        } catch ProviderError.vendor(let code, let message) {
            XCTAssertEqual(code, "409")
            XCTAssertEqual(message, "the comment is not pending")
        }

        XCTAssertEqual(http.requests.map(line), [
            "POST /v1/reviews/SLING-170/comments",
            "PATCH /v1/reviews/SLING-170/comments/c_99999999",
            "DELETE /v1/reviews/SLING-170/comments/c_99999999?kind=code",
            "PUT /v1/reviews/SLING-170/viewed",
            "PATCH /v1/reviews/SLING-170/comments/c_0a1b2c3d",
        ])
        XCTAssertEqual(http.body(0)["text"] as? String, "Why?")
        XCTAssertEqual((http.body(0)["anchor"] as? [String: Any])?["from"] as? Int, 2)
        XCTAssertEqual(http.body(1)["text"] as? String, "Why so?")
        XCTAssertEqual(http.body(3)["path"] as? String, "a+b.go")
        XCTAssertEqual(http.requests[3].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSubmitMergeAndFix() async throws {
        let (rt, http) = runtime([.init(body: try fixture("review-round", "queued")), .init(body: try fixture("merge-result", "conflict")),
                                  .init(body: try fixture("merge-result", "merged")), .init(body: try fixture("review-round", "new-session-failed")),
                                  .init(status: 409, body: Data(#"{"error":"a session of SLING-170 works"}"#.utf8))])
        let round = try await rt.submit("SLING-170", SubmitReview(kind: .code, verdict: .requestChanges, summary: "Two things.", postToTracker: true))
        XCTAssertEqual(round.delivery, .queued)
        let conflict = try await rt.merge("SLING-170", MergeRequest(removeGroup: true))
        XCTAssertFalse(conflict.merged)
        XCTAssertTrue(conflict.repos.contains { $0.result == .conflict })
        let merged = try await rt.merge("SLING-170", MergeRequest(removeGroup: true))
        XCTAssertTrue(merged.merged)
        let fix = try await rt.fix("SLING-170")
        XCTAssertNotNil(fix.error)
        do {
            _ = try await rt.merge("SLING-170", MergeRequest(removeGroup: false))
            XCTFail("a failed check must throw")
        } catch ProviderError.vendor(let code, _) { XCTAssertEqual(code, "409") }

        XCTAssertEqual(http.requests.map(line), [
            "POST /v1/reviews/SLING-170/submit", "POST /v1/reviews/SLING-170/merge", "POST /v1/reviews/SLING-170/merge",
            "POST /v1/reviews/SLING-170/fix?kind=code", "POST /v1/reviews/SLING-170/merge",
        ])
        XCTAssertEqual(http.body(0)["verdict"] as? String, "requestChanges")
        XCTAssertEqual(http.body(0)["postToTracker"] as? Bool, true)
        XCTAssertEqual(http.body(1)["removeGroup"] as? Bool, true)
    }
}

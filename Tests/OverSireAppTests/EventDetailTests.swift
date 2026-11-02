import Foundation
import OverSireCore
import XCTest
@testable import OverSireApp

final class JSONTreeTests: XCTestCase {
    func text(_ l: JSONTree.Line) -> String { l.parts.map(\.text).joined() }

    let sample: JSONValue = .object([
        "url": .string("https://x.dev/a/b"),
        "failed": .array([.object(["job": .string("go test"), "step": .string("vet")])]),
        "ok": .bool(false), "n": .int(3), "none": .null, "empty": .object([:]),
    ])

    func testKeysSortedAndNestedFolded() {
        let lines = JSONTree().lines(sample)
        XCTAssertEqual(lines.map(text), [
            "{",
            "\"empty\": {},",
            "\"failed\": [",
            "{ … }  2 keys",
            "],",
            "\"n\": 3,",
            "\"none\": null,",
            "\"ok\": false,",
            "\"url\": \"https://x.dev/a/b\"",
            "}",
        ])
        XCTAssertNil(lines[0].fold, "the root never folds")
        XCTAssertEqual(lines[2].fold, "$/failed")
        XCTAssertEqual(lines[3].fold, "$/failed/0")
        XCTAssertFalse(lines[3].open)
        XCTAssertEqual(lines[3].depth, 2)
        XCTAssertEqual(lines[2].parts.map(\.role), [.key, .punct, .punct])
        XCTAssertEqual(lines[7].parts.map(\.role), [.key, .punct, .literal, .punct])
    }

    func testFlipAndAll() {
        var t = JSONTree()
        t.flip("$/failed/0")
        XCTAssertTrue(t.lines(sample).map(text).contains("\"job\": \"go test\","))
        t.flip("$/failed")
        XCTAssertTrue(t.lines(sample).map(text).contains("\"failed\": [ … ]  1 item,"))
        t.setAll(open: false)
        XCTAssertTrue(t.lines(sample).map(text).contains("\"failed\": [ … ]  1 item,"))
        t.setAll(open: true)
        XCTAssertTrue(t.lines(sample).map(text).contains("\"step\": \"vet\""))
    }

    func testLongStringFolds() {
        let long = String(repeating: "a", count: 100)
        var t = JSONTree()
        let line = t.lines(.object(["log": .string(long)]))[1]
        XCTAssertEqual(line.fold, "$/log")
        XCTAssertEqual(text(line), "\"log\": \"" + String(repeating: "a", count: 72) + "…\"  +28 chars")
        t.flip("$/log")
        XCTAssertEqual(text(t.lines(.object(["log": .string(long)]))[1]), "\"log\": \"\(long)\"")
    }

    func testPretty() {
        XCTAssertEqual(JSONTree.pretty(.object(["b": .int(1), "a": .string("x/y")])), "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
    }
}

final class EventTagTests: XCTestCase {
    func testWords() {
        let words = ["comment.created": "comment", "item.state_changed": "status", "item.viewed": "viewed", "ci.completed": "CI",
                     "prompt.submitted": "prompt", "turn.ended": "turn", "git.commit": "git", "pr.merged": "PR", "release.published": "release",
                     "question.answered": "answer", "job.ran": "job"]
        for (k, w) in words { XCTAssertEqual(EventTag(Event.Kind(rawValue: k)).word, w, k) }
    }

    func testHeadline() {
        func e(_ s: String) -> Event {
            Event(seq: 1, seenAt: Date(), draft: EventDraft(id: "x", at: Date(), kind: .commentCreated, actorType: .human, actor: "a", via: "v", summary: s))
        }
        XCTAssertEqual(e("## Root cause").headline, "Root cause")
        XCTAssertEqual(e("#2243 failed").headline, "#2243 failed")
        XCTAssertEqual(e("plain").headline, "plain")
    }
}

final class CommentBookTests: XCTestCase {
    func comment(_ id: String) -> Comment { Comment(id: id, author: nil, createdAt: Date(), url: "", body: "body \(id)") }

    func testFetchOnceThenText() {
        var calls = 0
        var pending: ((Result<[Comment], ProviderError>) -> Void)?
        let book = CommentBook { key, done in
            XCTAssertEqual(key, "OVERSIRE-1")
            calls += 1
            pending = done
        }
        var done = 0
        XCTAssertEqual(book.body(key: "oversire-1", id: "c1") { done += 1 }, .loading)
        XCTAssertEqual(book.body(key: "OVERSIRE-1", id: "c1") {}, .loading)
        pending?(.success([comment("c1")]))
        XCTAssertEqual(done, 1)
        XCTAssertEqual(book.body(key: "OVERSIRE-1", id: "c1") {}, .text("body c1"))
        XCTAssertEqual(calls, 1)
    }

    func testMissingAfterOneFetch() {
        var calls = 0
        let book = CommentBook { _, done in calls += 1; done(.success([]) ) }
        XCTAssertEqual(book.body(key: "K-1", id: "gone") {}, .loading)
        XCTAssertEqual(book.body(key: "K-1", id: "gone") {}, .missing)
        XCTAssertEqual(calls, 1)
    }

    func testFailureStaysThenRetries() {
        var calls = 0
        let book = CommentBook { _, done in calls += 1; done(.failure(.transport("offline"))) }
        let t = Date()
        _ = book.body(key: "K-1", id: "c1", now: t) {}
        XCTAssertEqual(book.body(key: "K-1", id: "c1", now: t.addingTimeInterval(30)) {}, .failed("offline"))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(book.body(key: "K-1", id: "c1", now: Date().addingTimeInterval(CommentBook.retry + 1)) {}, .loading)
        XCTAssertEqual(calls, 2)
    }
}

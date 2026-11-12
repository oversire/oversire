import AppKit
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

/// A comment fetch that counts its calls. It fails while `failure` is set.
private final class CommentScript {
    var calls = 0
    var failure: ProviderError?
    var list: [Comment] = []
    var fetch: CommentBook.Fetch {
        { [self] _, done in
            calls += 1
            if let failure { done(.failure(failure)) } else { done(.success(list)) }
        }
    }
}

@MainActor
final class CommentBookTests: XCTestCase {
    private let clock = ManualSchedule()
    private let script = CommentScript()

    private func comment(_ id: String) -> Comment { Comment(id: id, author: nil, createdAt: Date(), url: "", body: "body \(id)") }

    private func book() -> CommentBook {
        CommentBook(now: { Date(timeIntervalSince1970: 1_793_000_000 + self.clock.now) }, schedule: clock.schedule, fetch: script.fetch)
    }

    private func texts(_ v: NSView) -> [String] { (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts) }
    private func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

    func testFetchOnceThenText() async {
        script.list = [comment("c1")]
        let book = book()
        var done = 0
        XCTAssertEqual(book.body(key: "oversire-1", id: "c1") { done += 1 }, .loading)
        XCTAssertEqual(book.body(key: "OVERSIRE-1", id: "c1") { done += 1 }, .loading)
        await book.settled("OVERSIRE-1")
        XCTAssertEqual(done, 1)
        XCTAssertEqual(book.body(key: "OVERSIRE-1", id: "c1") {}, .text("body c1"))
        XCTAssertEqual(script.calls, 1)
    }

    func testMissingAfterOneFetch() async {
        let book = book()
        XCTAssertEqual(book.body(key: "K-1", id: "gone") {}, .loading)
        await book.settled("K-1")
        XCTAssertEqual(book.body(key: "K-1", id: "gone") {}, .missing)
        XCTAssertEqual(book.body(key: "K-1", id: "gone") {}, .missing)
        XCTAssertEqual(script.calls, 1)
    }

    func testAFailedCommentTriesAgainByItself() async {
        script.failure = .transport("offline")
        let book = book()
        XCTAssertEqual(book.body(key: "K-1", id: "c1") {}, .loading)
        await book.settled("K-1")
        XCTAssertEqual(book.body(key: "K-1", id: "c1") {}, .failed("offline"))
        XCTAssertEqual(book.body(key: "K-1", id: "c1") {}, .failed("offline"), "a page rebuild does not read again")
        XCTAssertEqual(script.calls, 1)
        XCTAssertEqual(book.part("K-1")?.retry?.k, 1)
        script.failure = nil
        script.list = [comment("c1")]
        clock.advance(5)
        await book.settled("K-1")
        XCTAssertEqual(script.calls, 2)
        XCTAssertEqual(book.body(key: "K-1", id: "c1") {}, .text("body c1"))
    }

    func testTheFailedCommentNoteHasTryAgain() async throws {
        script.failure = .transport("offline")
        let book = book()
        _ = book.body(key: "K-1", id: "c1") {}
        await book.settled("K-1")
        let part = try XCTUnwrap(book.part("K-1"))
        guard case .failed(let why) = book.body(key: "K-1", id: "c1", done: {}) else { return XCTFail("the body failed") }
        let e = Event(seq: 1, seenAt: Date(), draft: EventDraft(id: "x", at: Date(), kind: .commentCreated, item: "K-1", actorType: .human, actor: "a", via: "v", summary: "s"))
        let card = EventDetailCard(e, pageKey: "K-1", body: .failed(why), bodyPart: part, mode: .rendered, markdown: MarkdownView(width: 600),
                                   go: { _ in }, onMode: { _ in }, onClose: {})
        let all = texts(card)
        XCTAssertTrue(all.contains("The comment did not load."))
        XCTAssertTrue(all.contains("offline"))
        XCTAssertFalse(all.contains { $0.contains("loads again in a minute") })
        script.failure = nil
        let again = try XCTUnwrap(buttons(card).first { $0.title == "Try again" })
        again.performClick(nil)
        await book.settled("K-1")
        XCTAssertEqual(script.calls, 2)
        XCTAssertEqual(book.body(key: "K-1", id: "c1") {}, .missing, "the good list has no c1")
    }
}

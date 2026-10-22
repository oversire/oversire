import XCTest
import OverSireCore
import OverSireAI
@testable import OverSireAssistant
import OverSireTestKit

final class ChatRouterTests: XCTestCase {
    func collect(_ s: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var out: [ChatEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    let req = ChatRequest(thread: "t", system: "", messages: [])

    func testSkipsAnEngineWithNoSetup() async throws {
        let a = FakeChatEngine(id: "a", available: false), b = FakeChatEngine(id: "b")
        let ev = try await collect(ChatRouter(engines: [a, b]).turn(req, prefer: "a"))
        XCTAssertEqual(ev.first, .engineChanged(from: "a", to: "b", reason: "a is not set up."))
        XCTAssertEqual(ev.last, .end(.done))
    }

    func testMovesOnWhenUnavailableBeforeText() async throws {
        let a = FakeChatEngine(id: "a"), b = FakeChatEngine(id: "b")
        a.script([.event(.usage(AIUsage(input: 1, output: 0))), .fail(.unavailable("limit"))])
        let ev = try await collect(ChatRouter(engines: [a, b]).turn(req, prefer: "a"))
        XCTAssertEqual(ev, [.usage(AIUsage(input: 1, output: 0)), .engineChanged(from: "a", to: "b", reason: "limit"), .textDelta("ok"), .end(.done)])
    }

    func testFailsWhenUnavailableAfterText() async throws {
        let a = FakeChatEngine(id: "a"), b = FakeChatEngine(id: "b")
        a.script([.event(.textDelta("x")), .fail(.unavailable("limit"))])
        do {
            _ = try await collect(ChatRouter(engines: [a, b]).turn(req, prefer: "a"))
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? AIError, .unavailable("limit"))
        }
        XCTAssertTrue(b.requests.isEmpty)
    }

    func testNoEngine() async throws {
        do {
            _ = try await collect(ChatRouter(engines: [FakeChatEngine(available: false)]).turn(req, prefer: nil))
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? AIError, .unavailable("fake-chat is not set up."))
        }
    }

    func testFakeEnginePassesTheConformanceSuite() async {
        let e = FakeChatEngine()
        e.reply(.textDelta("Hello."))
        e.reply(.toolCall(ToolCall(id: "call_1", tool: "echo", args: .object(["text": .string("hi")]))))
        e.reply(.textDelta("It said hi."))
        e.script([.event(.textDelta("1")), .wait(.seconds(30)), .event(.end(.done))])
        let r = await ChatEngineConformance.run(e)
        XCTAssertTrue(r.passed, r.description)
    }
}

final class ThreadStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("blobs-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testWriteAndRead() async throws {
        let s = ThreadStore(store: MemoryStore(), blobDir: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        try await s.save(AssistantThread(id: "a", title: "A", createdAt: t0, engine: .apiKey))
        try await s.save(AssistantThread(id: "b", title: "B", createdAt: t0.addingTimeInterval(10), engine: .apiKey))
        try await s.save(AssistantMessage(id: "m2", thread: "a", role: .assistant, at: t0.addingTimeInterval(2), parts: [.text("two")]))
        try await s.save(AssistantMessage(id: "m1", thread: "a", role: .user, at: t0.addingTimeInterval(1), parts: [.text("one")]))
        try await s.save(AssistantMessage(id: "m3", thread: "b", role: .user, at: t0, parts: [.text("other")]))
        let ids = try await s.threads().map(\.id)
        XCTAssertEqual(ids, ["b", "a"])
        let texts = try await s.messages("a").map(\.text)
        XCTAssertEqual(texts, ["one", "two"])
        try await s.delete(thread: "a")
        let left = try await s.messages("a")
        XCTAssertTrue(left.isEmpty)
        let gone = try await s.thread("a")
        XCTAssertNil(gone)
    }

    func testBlobDedup() async throws {
        let s = ThreadStore(store: MemoryStore(), blobDir: dir)
        let a = try await s.put(blob: Data("png".utf8))
        let b = try await s.put(blob: Data("png".utf8))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
        let back = await s.blob(a)
        XCTAssertEqual(back, Data("png".utf8))
        let bad = await s.blob("../x")
        XCTAssertNil(bad)
    }

    func testRetention() async throws {
        let s = ThreadStore(store: MemoryStore(), blobDir: dir)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let kept = try await s.put(blob: Data("kept".utf8))
        let lost = try await s.put(blob: Data("lost".utf8))
        try await s.save(AssistantThread(id: "old", title: "", createdAt: now.addingTimeInterval(-10 * 86_400), engine: .apiKey))
        try await s.save(AssistantThread(id: "pin", title: "", createdAt: now.addingTimeInterval(-90 * 86_400), engine: .apiKey, pinned: true))
        try await s.save(AssistantThread(id: "new", title: "", createdAt: now.addingTimeInterval(-86_400), engine: .apiKey))
        try await s.save(AssistantMessage(id: "m1", thread: "old", role: .user, at: now, parts: [.image(blob: lost, mime: "image/png", width: nil, height: nil)]))
        try await s.save(AssistantMessage(id: "m2", thread: "new", role: .user, at: now, parts: [.file(blob: kept, name: "a.txt", mime: "text/plain", bytes: 4)]))

        try await s.prune(.always, now: now)
        var ids = try await s.threads().map(\.id).sorted()
        XCTAssertEqual(ids, ["new", "old", "pin"])

        try await s.prune(.days7, now: now)
        ids = try await s.threads().map(\.id).sorted()
        XCTAssertEqual(ids, ["new", "pin"])
        let old = try await s.messages("old")
        XCTAssertTrue(old.isEmpty)
        let k = await s.blob(kept), l = await s.blob(lost)
        XCTAssertNotNil(k)
        XCTAssertNil(l)
    }
}

final class RedactorTests: XCTestCase {
    func testShapesAndValues() {
        let r = Redactor(secrets: ["my-keychain-value", "short"])
        XCTAssertEqual(r.redact("a my-keychain-value b"), "a [secret] b")
        XCTAssertEqual(r.redact("short stays"), "short stays")
        XCTAssertEqual(r.redact("ghp_0123456789abcdefghijABCDEFGHIJ"), "[secret]")
        XCTAssertEqual(r.redact("github_pat_11ABCDEFG0123456789_abcdefghij"), "[secret]")
        XCTAssertEqual(r.redact("key sk-ant-api03-abcdefghijklmnop end"), "key [secret] end")
        XCTAssertEqual(r.redact("plane_api_0123456789abcdef0123"), "[secret]")
        XCTAssertEqual(r.redact("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"), "Authorization: [secret]")
        XCTAssertEqual(r.redact("task-1234 and sk-short"), "task-1234 and sk-short")
        XCTAssertEqual(r.redact(.object(["a": .array([.string("x ghp_0123456789abcdefghijABCDEFGHIJ")]), "n": .int(3)])),
                       .object(["a": .array([.string("x [secret]")]), "n": .int(3)]))
    }
}

final class ActionTests: XCTestCase {
    func testToolNames() async {
        let reg = ToolRegistry([
            ActionSpec(id: "item.setStatus", title: "Set status", help: "h", kind: .change) { _ in .ok(summary: "") },
            ActionSpec(id: "settings.open", title: "Open", help: "h", kind: .settings) { _ in .ok(summary: "") },
        ])
        XCTAssertEqual(reg.tools.map(\.name), ["item_setStatus"])
        XCTAssertEqual(reg.spec("item_setStatus")?.id, "item.setStatus")
        XCTAssertEqual(reg.spec("item.setStatus")?.id, "item.setStatus")
        XCTAssertNil(reg.spec("settings_open"))
    }

    func testCatalogRun() async {
        let list = ActionList([ActionSpec(id: "a.b", title: "B", help: "", kind: .read) { args in .ok(summary: args.string("x") ?? "-") }])
        let ok = await list.run("a.b", ActionArgs(.object(["x": .string("y")])))
        XCTAssertEqual(ok, .ok(summary: "y"))
        let missing = await list.run("a.c", ActionArgs())
        XCTAssertEqual(missing, .notAllowed("No action a.c."))
    }

    func testArgsSchema() {
        let s = ActionSpec.args(["key": ("string", "The item key.")], required: ["key"])
        XCTAssertEqual(s["required"], .array([.string("key")]))
        XCTAssertEqual(s["properties"]?["key"]?["type"], .string("string"))
    }

    func testPagePromptText() {
        let p = PageContext(route: "prs", title: "Pull requests", rows: (1...25).map { .init(id: "#\($0)", text: "PR \($0)") }, selection: ["#3"])
        let t = p.promptText()
        XCTAssertTrue(t.hasPrefix("Pull requests (route prs). Selected: #3. Rows in view:\n- #1: PR 1"))
        XCTAssertTrue(t.hasSuffix("- and 5 more"))
    }

    func testPermissions() {
        let p = AssistantPermissions(read: .askEach, change: .allow)
        XCTAssertEqual(p.rule(.read), .askEach)
        XCTAssertEqual(p.rule(.change), .allow)
        XCTAssertEqual(p.rule(.outward), .askEach)
        XCTAssertEqual(p.rule(.settings), .never)
    }
}

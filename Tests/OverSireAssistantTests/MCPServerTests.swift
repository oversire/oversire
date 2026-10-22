import XCTest
import OverSireCore
import OverSireAI
@testable import OverSireAssistant
import OverSireTestKit

final class MCPServerTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func setup(_ engine: FakeChatEngine, _ specs: [ActionSpec], now: @escaping @Sendable () -> Date = Date.init) -> (AssistantLoop, MCPServer) {
        let loop = AssistantLoop(router: ChatRouter(engines: [engine]), catalog: ActionList(specs), policy: RuleConfirmPolicy(),
                                 store: ThreadStore(store: MemoryStore(), blobDir: dir), system: { _, _ in "" })
        return (loop, MCPServer(loop: loop, now: now))
    }

    func post(_ s: MCPServer, _ token: String, _ body: Any) async throws -> (Int, [String: Any]) {
        let data = try JSONSerialization.data(withJSONObject: body)
        let r = await s.handle(HTTPMessage(method: "POST", path: "/mcp", headers: ["authorization": "Bearer \(token)"], body: data))
        return (r.status, (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:])
    }

    func rpc(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    let read = ActionSpec(id: "item.get", title: "Get item", help: "Reads an item.", kind: .read, input: ActionSpec.args(["key": ("string", "Key")])) { a in
        .ok(summary: "OVERSIRE-\(a.string("key") ?? "?")", data: .object(["state": .string("Todo")]))
    }
    let merge = ActionSpec(id: "pr.merge", title: "Merge", help: "Merges a PR.", kind: .outward) { _ in .ok(summary: "merged") }

    func testReader() {
        var r = HTTPRequestReader()
        XCTAssertEqual(r.feed(Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Le".utf8)), .more)
        XCTAssertEqual(r.feed(Data("ngth: 4\r\nAuthorization: Bearer t\r\n\r\nab".utf8)), .more)
        XCTAssertEqual(r.feed(Data("cd".utf8)), .done(HTTPMessage(method: "POST", path: "/mcp", headers: ["host": "x", "content-length": "4", "authorization": "Bearer t"], body: Data("abcd".utf8))))
        var big = HTTPRequestReader()
        guard case .bad(let reply) = big.feed(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(reply.status, 413)
        XCTAssertTrue(String(decoding: HTTPReply(status: 202).wire, as: UTF8.self).hasPrefix("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n"))
    }

    func testAuthPathAndMethod() async throws {
        let (_, s) = setup(FakeChatEngine(), [read])
        let token = await s.token(for: "t-1")
        let again = await s.token(for: "t-1")
        XCTAssertEqual(token, again)
        let (bad, _) = try await post(s, "nope", rpc(1, "ping"))
        XCTAssertEqual(bad, 401)
        let none = await s.handle(HTTPMessage(method: "POST", path: "/mcp", headers: [:], body: Data()))
        XCTAssertEqual(none.status, 401)
        let path = await s.handle(HTTPMessage(method: "POST", path: "/other", headers: ["authorization": "Bearer \(token)"], body: Data()))
        XCTAssertEqual(path.status, 404)
        let get = await s.handle(HTTPMessage(method: "GET", path: "/mcp", headers: ["authorization": "Bearer \(token)"], body: Data()))
        XCTAssertEqual(get.status, 405)
        await s.close(thread: "t-1")
        let (closed, _) = try await post(s, token, rpc(1, "ping"))
        XCTAssertEqual(closed, 401)
    }

    func testJSONRPC() async throws {
        let (_, s) = setup(FakeChatEngine(), [read, merge])
        let token = await s.token(for: "t-1")
        let (st, ini) = try await post(s, token, rpc(1, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2"]]))
        XCTAssertEqual(st, 200)
        let res = try XCTUnwrap(ini["result"] as? [String: Any])
        XCTAssertEqual(res["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((res["serverInfo"] as? [String: Any])?["name"] as? String, "oversire")
        let (note, _) = try await post(s, token, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertEqual(note, 202)
        let (_, ping) = try await post(s, token, rpc(2, "ping"))
        XCTAssertNotNil(ping["result"])
        let (_, unknown) = try await post(s, token, rpc(3, "resources/list"))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let (_, list) = try await post(s, token, rpc(4, "tools/list"))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["item_get", "pr_merge"])
        XCTAssertEqual((tools[0]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertNotNil(tools[0]["inputSchema"] as? [String: Any])
        let parse = await s.handle(HTTPMessage(method: "POST", path: "/mcp", headers: ["authorization": "Bearer \(token)"], body: Data("{".utf8)))
        XCTAssertEqual(parse.status, 400)
    }

    func testToolsCallGoesThroughTheLoop() async throws {
        let e = FakeChatEngine(runsTools: true)
        e.script([.wait(.seconds(30)), .event(.end(.done))])
        let (loop, s) = setup(e, [read, merge])
        let token = await s.token(for: "t-1")
        // No run of the thread: the call is denied.
        let (_, idle) = try await post(s, token, rpc(1, "tools/call", ["name": "item_get", "arguments": ["key": "1"]]))
        XCTAssertEqual((idle["result"] as? [String: Any])?["isError"] as? Bool, true)

        let stream = await loop.send([.text("Merge 12")], in: AssistantThread(id: "t-1", title: "", createdAt: Date(), engine: "fake-chat"))
        let watcher = Task {
            var events: [ChatEvent] = []
            for await ev in stream {
                events.append(ev)
                if case .approvalNeeded(let c, _) = ev { await loop.answer(c.id, .deny) }
            }
            return events
        }
        let (_, ok) = try await post(s, token, rpc(2, "tools/call", ["name": "item_get", "arguments": ["key": "153"]]))
        let okRes = try XCTUnwrap(ok["result"] as? [String: Any])
        XCTAssertEqual(okRes["isError"] as? Bool, false)
        XCTAssertEqual((okRes["content"] as? [[String: Any]])?.first?["text"] as? String, "OVERSIRE-153\n{\"state\":\"Todo\"}")

        let (_, missing) = try await post(s, token, rpc(3, "tools/call", ["name": "nope"]))
        XCTAssertEqual(((missing["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String, "Failed: No tool nope.")

        // The call waits for the card; the answer is no.
        let (_, denied) = try await post(s, token, rpc(4, "tools/call", ["name": "pr_merge", "arguments": ["number": 12]]))
        let d = try XCTUnwrap(denied["result"] as? [String: Any])
        XCTAssertEqual(d["isError"] as? Bool, true)
        XCTAssertTrue(((d["content"] as? [[String: Any]])?.first?["text"] as? String ?? "").hasPrefix("Denied:"))

        await loop.cancel("t-1")
        let events = await watcher.value
        XCTAssertEqual(events.filter { if case .approvalNeeded = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.last, .end(.cancelled))
    }

    func testPrune() async {
        final class Clock: @unchecked Sendable {
            var t = Date(timeIntervalSince1970: 0)
        }
        let c = Clock()
        let (_, s) = setup(FakeChatEngine(), [], now: { c.t })
        _ = await s.token(for: "a")
        c.t = c.t.addingTimeInterval(29 * 60)
        var empty = await s.prune()
        XCTAssertFalse(empty)
        c.t = c.t.addingTimeInterval(2 * 60)
        empty = await s.prune()
        XCTAssertTrue(empty)
    }
}

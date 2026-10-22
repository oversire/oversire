import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireAI

struct Blobs: BlobReading {
    let all: [String: Data]
    func blob(_ id: String) async -> Data? { all[id] }
}

final class APIKeyChatTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat")

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.dir.appendingPathComponent(name)) }

    func reply(_ name: String, status: Int = 200) throws -> ScriptedHTTP.Reply { ScriptedHTTP.Reply(status: status, body: try fixture(name)) }

    func engine(_ format: AIFormat, _ http: ScriptedHTTP, timeouts: ChatTimeouts = ChatTimeouts()) -> APIKeyEngine {
        let base = format == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
        return APIKeyEngine(config: APIKeyConfig(format: format, baseURL: base, model: "m1"), key: "k", http: http, timeouts: timeouts)
    }

    func collect(_ s: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var out: [ChatEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    func text(_ ev: [ChatEvent]) -> String { ev.map { if case .textDelta(let t) = $0 { return t }; return "" }.joined() }
    func calls(_ ev: [ChatEvent]) -> [ToolCall] { ev.compactMap { if case .toolCall(let c) = $0 { return c }; return nil } }

    func testConformance() async throws {
        for f in ["anthropic", "openai"] {
            let http = ScriptedHTTP([try reply("\(f)/text.sse"), try reply("\(f)/tool.sse"), try reply("\(f)/after-tool.sse"),
                                     ScriptedHTTP.Reply(body: try fixture("\(f)/text.sse"), ends: false)])
            let r = await ChatEngineConformance.run(engine(AIFormat(rawValue: f)!, http))
            XCTAssertTrue(r.passed, "\(f): \(r)")
        }
    }

    func testTextInManyChunkings() async throws {
        for seed in UInt64(1)...8 {
            let a = ScriptedHTTP([try reply("anthropic/text.sse")], chunkSeed: seed)
            let ev = try await collect(engine(.anthropic, a).turn(ChatEngineConformance.text))
            XCTAssertEqual(text(ev), "Hello! How can I help?")
            XCTAssertEqual(ev.suffix(2), [.usage(AIUsage(input: 30, output: 9, cached: 5)), .end(.done)])

            let o = ScriptedHTTP([try reply("openai/text.sse")], chunkSeed: seed)
            let oev = try await collect(engine(.openai, o).turn(ChatEngineConformance.text))
            XCTAssertEqual(text(oev), "Hello! How can I help?")
            XCTAssertEqual(oev.suffix(2), [.usage(AIUsage(input: 20, output: 9, cached: 4)), .end(.done)])
        }
    }

    func testOneToolCall() async throws {
        let a = try await collect(engine(.anthropic, ScriptedHTTP([try reply("anthropic/tool.sse")])).turn(ChatEngineConformance.toolCall))
        XCTAssertEqual(text(a), "I will call echo.")
        XCTAssertEqual(calls(a), [ToolCall(id: "toolu_01A", tool: "echo", args: .object(["text": .string("hi")]))])
        let o = try await collect(engine(.openai, ScriptedHTTP([try reply("openai/tool.sse")])).turn(ChatEngineConformance.toolCall))
        XCTAssertEqual(calls(o), [ToolCall(id: "call_abc", tool: "echo", args: .object(["text": .string("hi")]))])
        XCTAssertEqual(o.last, .end(.done))
    }

    func testParallelToolCalls() async throws {
        let want = [("hi"), ("there")]
        let a = try await collect(engine(.anthropic, ScriptedHTTP([try reply("anthropic/parallel.sse")])).turn(ChatEngineConformance.toolCall))
        XCTAssertEqual(calls(a).map(\.id), ["toolu_01A", "toolu_01B"])
        XCTAssertEqual(calls(a).map { $0.args["text"]?.string }, want)
        let o = try await collect(engine(.openai, ScriptedHTTP([try reply("openai/parallel.sse")])).turn(ChatEngineConformance.toolCall))
        XCTAssertEqual(calls(o).map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(calls(o).map { $0.args["text"]?.string }, want)
    }

    func testThinking() async throws {
        let a = try await collect(engine(.anthropic, ScriptedHTTP([try reply("anthropic/thinking.sse")])).turn(ChatEngineConformance.text))
        let thoughts = a.compactMap { if case .thoughtDelta(let t, let s) = $0 { return (t, s) }; return nil }
        XCTAssertEqual(thoughts.map(\.0).joined(), "The user wants a greeting.")
        XCTAssertEqual(thoughts.compactMap(\.1), ["EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds"])
        XCTAssertEqual(text(a), "Hello.")
        let o = try await collect(engine(.openai, ScriptedHTTP([try reply("openai/reasoning.sse")])).turn(ChatEngineConformance.text))
        XCTAssertEqual(o.first, .thoughtDelta("Think first.", signature: nil))
    }

    func testErrorMidStream() async throws {
        let a = try await collect(engine(.anthropic, ScriptedHTTP([try reply("anthropic/error-mid.sse")])).turn(ChatEngineConformance.text))
        XCTAssertEqual(a, [.textDelta("Hal"), .error(code: "api_error", message: "Internal server error"), .end(.error)])
        let o = try await collect(engine(.openai, ScriptedHTTP([try reply("openai/error-mid.sse")])).turn(ChatEngineConformance.text))
        XCTAssertEqual(o, [.textDelta("Hal"), .error(code: "server_error", message: "The server had an error."), .end(.error)])
    }

    func testBusyGivesUnavailable() async throws {
        let cases: [(AIFormat, ScriptedHTTP.Reply, String)] = [
            (.anthropic, try reply("anthropic/429.json", status: 429), "Number of request tokens has exceeded your per-minute rate limit."),
            (.anthropic, try reply("anthropic/overloaded.sse"), "Overloaded"),
            (.anthropic, ScriptedHTTP.Reply(status: 529, body: Data()), "The AI endpoint is busy (HTTP 529)."),
            (.openai, try reply("openai/429.json", status: 429), "Rate limit reached for gpt-5-mini."),
        ]
        for (f, r, msg) in cases {
            do {
                _ = try await collect(engine(f, ScriptedHTTP([r])).turn(ChatEngineConformance.text))
                XCTFail("no error for \(msg)")
            } catch {
                XCTAssertEqual(error as? AIError, .unavailable(msg))
            }
        }
    }

    func testOtherHTTPErrors() async throws {
        do {
            _ = try await collect(engine(.anthropic, ScriptedHTTP([try reply("anthropic/401.json", status: 401)])).turn(ChatEngineConformance.text))
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? AIError, .http(401, "invalid x-api-key"))
        }
    }

    func testTimeouts() async throws {
        let quick = ChatTimeouts(firstByte: 0.3, idle: 0.3)
        let start = Date()
        do {
            _ = try await collect(engine(.openai, ScriptedHTTP([ScriptedHTTP.Reply(body: Data(), ends: false)]), timeouts: quick).turn(ChatEngineConformance.text))
            XCTFail("no timeout")
        } catch {
            XCTAssertEqual(error as? AIError, .timeout)
        }
        // A chunk resets the clock; the stream then stops for good.
        do {
            let open = ScriptedHTTP([ScriptedHTTP.Reply(body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n".utf8), ends: false)])
            _ = try await collect(engine(.openai, open, timeouts: quick).turn(ChatEngineConformance.text))
            XCTFail("no timeout")
        } catch {
            XCTAssertEqual(error as? AIError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testStreamEndsEarly() async throws {
        let cut = try fixture("anthropic/text.sse").prefix(400)
        do {
            _ = try await collect(engine(.anthropic, ScriptedHTTP([ScriptedHTTP.Reply(body: Data(cut))])).turn(ChatEngineConformance.text))
            XCTFail("no error")
        } catch {
            guard case .badReply? = error as? AIError else { return XCTFail("\(error)") }
        }
    }

    // ─── Requests ────────────────────────────────────────────────────────────

    let history = ChatRequest(
        thread: "t", system: "SYS",
        messages: [
            ChatMessage(role: .user, parts: [.text("Look at this."), .image(blob: "b1", mime: "image/png", width: 2, height: 2),
                                             .file(blob: "b2", name: "notes.txt", mime: "text/plain", bytes: 5)]),
            ChatMessage(role: .assistant, parts: [
                .thought("Think.", signature: "sig1"), .text("I will look."),
                .toolCall(ToolCall(id: "c1", tool: "echo", args: .object(["text": .string("hi")]), kind: .read)),
                .approval(Approval(call: "c1", decision: .allowedByRule, by: "kind:read")),
                .toolResult(ToolResult(call: "c1", status: .ok, summary: "echo", data: .string("hi"))),
                .text("Then this."),
                .toolCall(ToolCall(id: "c2", tool: "echo", args: .object([:]))),
                .toolResult(ToolResult(call: "c2", status: .denied, summary: "The developer said no.")),
                .navigation(route: "prs", focus: nil, from: nil),
                .text("Done."),
            ]),
            ChatMessage(role: .user, parts: [.text("Thanks")]),
        ],
        tools: [ChatEngineConformance.echo], maxTokens: 500,
        blobs: Blobs(all: ["b1": Data([1, 2, 3]), "b2": Data("hello".utf8)]))

    func testAnthropicChatRequest() async throws {
        let req = try await AnthropicDialect().chatRequest(history, cfg: APIKeyConfig(format: .anthropic, baseURL: "https://api.anthropic.com", model: "m"), key: "k")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 500)
        XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["name"] as? String, "echo")
        XCTAssertNotNil((body["tools"] as? [[String: Any]])?.first?["input_schema"])
        let msgs = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user", "assistant", "user"])
        let types = msgs.map { ($0["content"] as? [[String: Any]] ?? []).map { $0["type"] as? String ?? "" } }
        XCTAssertEqual(types, [["text", "image", "text"], ["thinking", "text", "tool_use"], ["tool_result"], ["text", "tool_use"],
                               ["tool_result"], ["text"], ["text"]])
        let first = msgs[0]["content"] as! [[String: Any]]
        XCTAssertEqual((first[1]["source"] as? [String: Any])?["data"] as? String, "AQID")
        XCTAssertEqual(first[2]["text"] as? String, "File notes.txt:\n```\nhello\n```")
        let thinking = (msgs[1]["content"] as! [[String: Any]])[0]
        XCTAssertEqual(thinking["signature"] as? String, "sig1")
        let denied = (msgs[4]["content"] as! [[String: Any]])[0]
        XCTAssertEqual(denied["is_error"] as? Bool, true)
        XCTAssertEqual(denied["content"] as? String, "Denied: The developer said no.")
        XCTAssertEqual(((msgs[2]["content"] as! [[String: Any]])[0])["content"] as? String, "echo\nhi")
    }

    func testOpenAIChatRequest() async throws {
        let req = try await OpenAIDialect().chatRequest(history, cfg: APIKeyConfig(baseURL: "https://api.openai.com/v1", model: "m"), key: "k")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual(((body["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String, "echo")
        let msgs = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "assistant", "tool", "assistant", "user"])
        let user = try XCTUnwrap(msgs[1]["content"] as? [[String: Any]])
        XCTAssertEqual((user[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,AQID")
        let a = msgs[2]
        XCTAssertEqual(a["content"] as? String, "I will look.")
        let call = try XCTUnwrap((a["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["id"] as? String, "c1")
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, #"{"text":"hi"}"#)
        XCTAssertEqual(msgs[3]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(msgs[5]["content"] as? String, "Denied: The developer said no.")
        XCTAssertEqual(msgs[6]["content"] as? String, "Done.")
        XCTAssertEqual(msgs[7]["content"] as? String, "Thanks")
    }

    func testNoStreamingTransport() async throws {
        struct Plain: HTTPTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ProviderError.transport("no") }
        }
        let e = APIKeyEngine(config: APIKeyConfig(baseURL: "https://x", model: "m"), key: "k", http: Plain())
        do {
            _ = try await collect(e.turn(ChatEngineConformance.text))
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? AIError, .notConfigured)
        }
    }
}

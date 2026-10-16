import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireAI

final class APIKeyEngineTests: XCTestCase {
    let prompt = AIPrompt(system: "SYS", user: "USER", maxTokens: 300)

    func body(_ r: URLRequest?) -> [String: Any] {
        (r?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func testOpenAIRequest() throws {
        var cfg = APIKeyConfig(baseURL: "https://llm.example.com/v1/", model: "m1")
        let oa = try OpenAIDialect().urlRequest(prompt, cfg: cfg, key: "k1")
        XCTAssertEqual(oa.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(oa.value(forHTTPHeaderField: "Authorization"), "Bearer k1")
        XCTAssertEqual(body(oa)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body(oa)["model"] as? String, "m1")
        XCTAssertEqual((body(oa)["messages"] as? [[String: Any]])?.first?["role"] as? String, "system")
        cfg.baseURL = "https://llm.example.com/v1"
        cfg.effort = "none"
        let none = try OpenAIDialect().urlRequest(prompt, cfg: cfg, key: "k1")
        XCTAssertEqual(none.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertNil(body(none)["reasoning_effort"], "effort none leaves out the field")
    }

    func testAnthropicRequest() throws {
        let cfg = APIKeyConfig(format: .anthropic, baseURL: "https://api.anthropic.com/", model: "m", maxTokens: 999)
        let an = try AnthropicDialect().urlRequest(prompt, cfg: cfg, key: "k2")
        XCTAssertEqual(an.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(an.value(forHTTPHeaderField: "x-api-key"), "k2")
        XCTAssertEqual(an.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(body(an)["max_tokens"] as? Int, 300)
        XCTAssertEqual(body(an)["system"] as? String, "SYS")
        let open = try AnthropicDialect().urlRequest(AIPrompt(system: "", user: ""), cfg: cfg, key: "k2")
        XCTAssertEqual(body(open)["max_tokens"] as? Int, 999, "no prompt limit uses the setting")
        XCTAssertEqual(AnthropicDialect.endpoint("https://proxy.example/v1"), "https://proxy.example/v1/messages")
    }

    func testReplies() throws {
        let oa = Data(#"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#.utf8)
        XCTAssertEqual(try OpenAIDialect().text(from: oa, status: 200), "Hello")
        let parts = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}]}"#.utf8)
        XCTAssertEqual(try OpenAIDialect().text(from: parts, status: 200), "AB")
        let an = Data(#"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Hi"},{"type":"text","text":"!"}]}"#.utf8)
        XCTAssertEqual(try AnthropicDialect().text(from: an, status: 200), "Hi!")
        let err = Data(#"{"error":{"message":"Invalid API key\nmore","type":"auth"}}"#.utf8)
        XCTAssertThrowsError(try OpenAIDialect().text(from: err, status: 401)) {
            XCTAssertEqual($0 as? AIError, .http(401, "Invalid API key"))
        }
        XCTAssertThrowsError(try AnthropicDialect().text(from: Data("<html>".utf8), status: 200)) {
            XCTAssertEqual($0 as? AIError, .badReply("<html>"))
        }
    }

    func testRunThroughTheTransport() async throws {
        let http = RecordedHTTP()
        http.on("POST", "https://llm.example.com/v1/chat/completions", 200, #"{"choices":[{"message":{"content":"Tidy text"}}]}"#)
        let engine = APIKeyEngine(config: APIKeyConfig(baseURL: "https://llm.example.com/v1", model: "m"), key: "k", http: http)
        let available = await engine.available()
        XCTAssertTrue(available)
        let text = try await engine.run(AITask(kind: .tidy, input: AIInput(text: "note", context: ["extra": "Use British English."])))
        XCTAssertEqual(text, "Tidy text")
        let sent = body(http.requests.first)["messages"] as? [[String: Any]]
        XCTAssertTrue((sent?[0]["content"] as? String)?.hasSuffix("Extra instructions from the user:\nUse British English.") == true)
        XCTAssertEqual(sent?[1]["content"] as? String, "note")

        let down = APIKeyEngine(config: APIKeyConfig(baseURL: "https://down.example", model: "m"), key: "k", http: http)
        do { _ = try await down.send(prompt); XCTFail("no answer") } catch {
            XCTAssertEqual(error as? AIError, .network("no answer for POST https://down.example/chat/completions"))
        }
        let unset = await APIKeyEngine(config: APIKeyConfig(), key: "k", http: http).available()
        XCTAssertFalse(unset)
    }
}

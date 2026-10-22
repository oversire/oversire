import XCTest
import OverSireCore
import OverSireAI
import OverSireTestKit

/// One tool round trip with each API format. Run with OVERSIRE_LIVE=1 and ANTHROPIC_API_KEY or OPENAI_API_KEY.
/// ANTHROPIC_MODEL and OPENAI_MODEL change the model.
final class APIKeyChatLiveTests: XCTestCase {
    func testToolRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        let setups: [(AIFormat, String?, String, String)] = [
            (.anthropic, env["ANTHROPIC_API_KEY"], "https://api.anthropic.com", env["ANTHROPIC_MODEL"] ?? "claude-haiku-5-5"),
            (.openai, env["OPENAI_API_KEY"], "https://api.openai.com/v1", env["OPENAI_MODEL"] ?? "gpt-5-mini"),
        ]
        var ran = 0
        for (format, key, base, model) in setups {
            guard let key, !key.isEmpty else { continue }
            ran += 1
            let engine = APIKeyEngine(config: APIKeyConfig(format: format, baseURL: base, model: model, maxTokens: 512), key: key, http: LiveStream())
            var first: [ChatEvent] = []
            for try await e in engine.turn(ChatEngineConformance.toolCall) { first.append(e) }
            let call = try XCTUnwrap(first.compactMap { if case .toolCall(let c) = $0 { return c }; return nil }.first, "\(format): no tool call")
            XCTAssertEqual(call.tool, "echo")
            var req = ChatEngineConformance.toolCall
            req.messages.append(ChatMessage(role: .assistant, parts: [.toolCall(call), .toolResult(ToolResult(call: call.id, status: .ok, summary: "echo", data: .string("hi")))]))
            var second: [ChatEvent] = []
            for try await e in engine.turn(req) { second.append(e) }
            XCTAssertTrue(second.contains { if case .textDelta = $0 { return true }; return false }, "\(format): no text after the result")
            XCTAssertTrue(second.contains { if case .usage = $0 { return true }; return false }, "\(format): no usage")
        }
        if ran == 0 { throw XCTSkip("set ANTHROPIC_API_KEY or OPENAI_API_KEY") }
    }
}

/// A URLSession transport that streams, as in the app.
struct LiveStream: HTTPTransport, HTTPStreaming {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await URLSession.shared.data(for: request)
        return (d, r as! HTTPURLResponse)
    }

    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (bytes, r) = try await URLSession.shared.bytes(for: request)
        let stream = AsyncThrowingStream<Data, Error> { out in
            let task = Task {
                do {
                    var buf = Data()
                    for try await b in bytes {
                        buf.append(b)
                        if b == UInt8(ascii: "\n") {
                            out.yield(buf)
                            buf = Data()
                        }
                    }
                    if !buf.isEmpty { out.yield(buf) }
                    out.finish()
                } catch { out.finish(throwing: error) }
            }
            out.onTermination = { _ in task.cancel() }
        }
        return (r as! HTTPURLResponse, stream)
    }
}

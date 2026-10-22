import Foundation
import OverSireCore
import OverSireAI

/// The suite for a ChatEngine. It sends four requests in this order: `text`, `toolCall`, `afterToolResult`, `cancel`.
/// The factory sets up the engine (replay fixtures, a fake) so that each request gets its reply:
/// text: a text answer; toolCall: a call of echo; afterToolResult: a text answer; cancel: any long answer.
public enum ChatEngineConformance {
    public static let echo = ToolSpec(
        name: "echo", title: "Echo", description: "Gives back the text.", kind: .read,
        input: .object(["type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])]),
                        "required": .array([.string("text")])]))

    public static let text = ChatRequest(thread: "conformance", system: "Answer in one short sentence.",
                                         messages: [ChatMessage(role: .user, parts: [.text("Say hello.")])], maxTokens: 64)

    public static let toolCall = ChatRequest(thread: "conformance", system: "Use the tools.",
                                             messages: [ChatMessage(role: .user, parts: [.text("Call echo with the text hi.")])],
                                             tools: [echo], maxTokens: 128)

    public static let afterToolResult = ChatRequest(
        thread: "conformance", system: "Use the tools.",
        messages: [
            ChatMessage(role: .user, parts: [.text("Call echo with the text hi.")]),
            ChatMessage(role: .assistant, parts: [
                .toolCall(ToolCall(id: "call_1", tool: "echo", args: .object(["text": .string("hi")]))),
                .toolResult(ToolResult(call: "call_1", status: .ok, summary: "hi", data: .string("hi"))),
            ]),
        ],
        tools: [echo], maxTokens: 128)

    public static let cancel = ChatRequest(thread: "conformance", system: "Answer at length.",
                                           messages: [ChatMessage(role: .user, parts: [.text("Count to 500.")])], maxTokens: 2000)

    public static func run(_ engine: any ChatEngine) async -> ConformanceReport {
        var r = ConformanceReport()
        r.expect(await engine.available(), "\(engine.id) is not available")

        if let ev = await r.step("text", { try await collect(engine.turn(text)) }) {
            r.expect(ev.contains { if case .textDelta(let t) = $0 { return !t.isEmpty }; return false }, "text: no textDelta")
            r.expect(!ev.contains { if case .toolCall = $0 { return true }; return false }, "text: a tool call with no tools")
            r.expect(ev.contains { if case .usage = $0 { return true }; return false }, "text: no usage")
            r.expect(ev.last == .end(.done), "text: the last event is \(String(describing: ev.last)), not end(done)")
        }
        if let ev = await r.step("toolCall", { try await collect(engine.turn(toolCall)) }) {
            let calls = ev.compactMap { if case .toolCall(let c) = $0 { return c }; return nil }
            r.expect(!calls.isEmpty, "toolCall: no tool call")
            for c in calls {
                r.expect(!c.id.isEmpty, "toolCall: a call with no id")
                r.expect(c.tool == echo.name, "toolCall: unknown tool \(c.tool)")
                r.expect(c.args.object != nil, "toolCall: args are not an object")
            }
            r.expect(ev.last.map { if case .end = $0 { return true }; return false } ?? false, "toolCall: no end event")
        }
        if let ev = await r.step("afterToolResult", { try await collect(engine.turn(afterToolResult)) }) {
            r.expect(ev.contains { if case .textDelta = $0 { return true }; return false }, "afterToolResult: no text")
            r.expect(ev.last == .end(.done), "afterToolResult: no end(done)")
        }

        // A consumer that stops must stop the turn soon.
        let start = Date()
        let task = Task {
            for try await ev in engine.turn(cancel) { if case .textDelta = ev { break } }
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            task.cancel()
        }
        _ = await task.result
        watchdog.cancel()
        r.expect(Date().timeIntervalSince(start) < 2, "cancel: the turn did not stop in 2 s")
        return r
    }

    static func collect(_ s: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var out: [ChatEvent] = []
        for try await e in s { out.append(e) }
        return out
    }
}

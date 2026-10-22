import XCTest
import AgentBinder
import OverSireCore
import OverSireAI
import OverSireTestKit
@testable import AIEngineAgentBinder

final class AgentBinderChatTests: XCTestCase {
    final class Host: ChatToolHost, @unchecked Sendable {
        private let lock = NSLock()
        private var _closed: [String] = []
        var closed: [String] { lock.withLock { _closed } }
        func endpoint(thread: String) async throws -> (url: URL, token: String) { (URL(string: "http://127.0.0.1:1/mcp")!, "t-\(thread)") }
        func closed(thread: String) async { lock.withLock { _closed.append(thread) } }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        var ids: [String] { lock.withLock { _ids } }
        func add(_ s: String) { lock.withLock { _ids.append(s) } }
    }

    static let full = Features(mcpInject: .flags, instructions: true, resume: true, permissions: true)

    private func engine(_ script: String, limits: PlanLimits = PlanLimits(), features: Features = full,
                        host: Host = Host()) async -> AgentBinderChat {
        let rt = Runtime(options: .init(clientName: "oversire-tests", useLoginShellPath: false))
        await rt.setDriver(FakeDriver(script: script), for: .fake)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-chat-\(UUID().uuidString)")
        return AgentBinderChat(config: LocalCLIConfig(harness: "fake"), runtime: rt, limits: limits, tools: host,
                               workRoot: root, features: { _ in features })
    }

    private func request(_ texts: [String], thread: String = "t1", session: String? = nil,
                         onSession: (@Sendable (String) -> Void)? = nil) -> ChatRequest {
        let msgs = texts.enumerated().map { i, t in ChatMessage(role: i % 2 == 0 ? .user : .assistant, parts: [.text(t)]) }
        return ChatRequest(thread: thread, system: "Help.", messages: msgs, session: session, onSession: onSession)
    }

    private func collect(_ s: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var out: [ChatEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    private func text(_ ev: [ChatEvent]) -> String {
        ev.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
    }

    func testTheEventMap() async throws {
        let ids = Box()
        let e = await engine(#"""
            read -r line
            echo '{"type":"init","session_id":"s1"}'
            echo '{"type":"thought","text":"hmm","delta":true}'
            echo '{"type":"assistant","text":"Hel","delta":true}'
            echo '{"type":"assistant","text":"lo","delta":true}'
            echo '{"type":"assistant","text":"Hello"}'
            echo '{"type":"tool","id":"c1","name":"mcp__oversire__item_get","input":"{\"id\":\"A-1\"}"}'
            echo '{"type":"tool","id":"c1","name":"mcp__oversire__item_get","status":"completed","output":"A-1 ok"}'
            echo '{"type":"tool","id":"c2","name":"Bash","input":"ls"}'
            echo '{"type":"assistant","text":"Done."}'
            echo '{"type":"usage","input":10,"output":5}'
            echo '{"type":"result","subtype":"success","text":"Done."}'
            """#)
        let ev = try await collect(e.turn(request(["Hi"], onSession: { ids.add($0) })))
        XCTAssertEqual(ev.first, .thoughtDelta("hmm", signature: nil))
        XCTAssertEqual(text(ev), "Hello\n\nDone.", "the whole message after the deltas adds nothing")
        XCTAssertTrue(ev.contains(.toolCall(ToolCall(id: "c1", tool: "item_get", args: .object(["id": .string("A-1")])))))
        XCTAssertTrue(ev.contains(.toolResult(ToolResult(call: "c1", status: .ok, summary: "A-1 ok"))))
        XCTAssertFalse(ev.contains { if case .toolCall(let c) = $0 { return c.tool == "Bash" }; return false }, "no chip for a tool that is not ours")
        XCTAssertTrue(ev.contains(.usage(AIUsage(input: 10, output: 5))))
        XCTAssertEqual(ev.last, .end(.done))
        XCTAssertEqual(ids.ids, ["s1"])
    }

    func testOnlyTheOverSireToolsAreAllowed() async throws {
        let e = await engine(#"""
            read -r line
            echo '{"type":"permission","id":"p1","tool":"Bash","input":"rm -rf /"}'
            read -r d1
            echo '{"type":"permission","id":"p2","tool":"mcp__oversire__item_get","input":"{}"}'
            read -r d2
            case "$d1" in *'"allow":false'*'only the OverSire tools'*) echo '{"type":"assistant","text":"bash denied. "}' ;; esac
            case "$d2" in *'"allow":true'*) echo '{"type":"assistant","text":"ours allowed."}' ;; esac
            echo '{"type":"result","subtype":"success","text":""}'
            """#)
        let ev = try await collect(e.turn(request(["Hi"])))
        XCTAssertEqual(text(ev), "bash denied. \n\nours allowed.")
    }

    // The fake echoes "history" when the prompt has the earlier text of the chat.
    static let history = #"""
        while read -r line; do
          case "$line" in *'Earlier in this chat'*) t=history ;; *) t=plain ;; esac
          printf '{"type":"assistant","text":"%s"}\n' "$t"
          echo '{"type":"result","subtype":"success","text":""}'
        done
        """#

    func testANewSessionGetsTheHistoryAndAResumeDoesNot() async throws {
        let e = await engine(Self.history)
        let fresh = try await collect(e.turn(request(["Hi", "Hello", "And now?"])))
        XCTAssertEqual(text(fresh), "history")
        let again = try await collect(e.turn(request(["Hi", "Hello", "And now?", "history", "More?"])))
        XCTAssertEqual(text(again), "plain", "the open session knows the chat")

        let resumed = try await collect(e.turn(request(["Hi", "Hello", "And now?"], thread: "t2", session: "abc")))
        XCTAssertEqual(text(resumed), "plain")

        let noResume = await engine(Self.history, features: Features(mcpInject: .flags))
        let started = try await collect(noResume.turn(request(["Hi", "Hello", "And now?"], session: "abc")))
        XCTAssertEqual(text(started), "history", "a CLI with no resume starts again with the history")
    }

    func testCloseEndsTheSessionAndTellsTheHost() async throws {
        let host = Host()
        let e = await engine(Self.history, host: host)
        _ = try await collect(e.turn(request(["Hi"])))
        await e.close(thread: "t1")
        XCTAssertEqual(host.closed, ["t1"])
        let ev = try await collect(e.turn(request(["Hi", "plain", "Again"])))
        XCTAssertEqual(text(ev), "history", "a closed thread opens a new session")
    }

    func testCancelStopsTheTurnAndTheNextTurnWorks() async throws {
        let e = await engine(#"""
            while read -r line; do
              case "$line" in
                *Hi*) echo '{"type":"assistant","text":"turn"}'; echo '{"type":"result","subtype":"success","text":""}' ;;
                *) echo '{"type":"assistant","text":"1, 2","delta":true}'; sleep 30 ;;
              esac
            done
            """#)
        let start = Date()
        let stream = e.turn(request(["Count to 500."]))
        let task = Task { for try await ev in stream { if case .textDelta = ev { break } } }
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        // The fake stops on the interrupt (SIGTERM). The next turn starts a new session.
        let ev = try await collect(e.turn(request(["Count to 500.", "1, 2", "Hi"])))
        XCTAssertEqual(text(ev), "turn")
    }

    func testAPlanLimitGivesTheTurnToTheNextEngine() async throws {
        let limits = PlanLimits()
        await limits.set(Limits(windows: [LimitWindow(key: .weekly, minutes: 10080, usedPercent: 95)]))
        let e = await engine(Self.history, limits: limits)
        do { _ = try await collect(e.turn(request(["Hi"]))); XCTFail("pause") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("The week plan window is at 95%. Jobs pause above 90%."))
        }
        let other = FakeChatEngine(id: .apiKey)
        let ev = try await collect(ChatRouter(engines: [e, other]).turn(request(["Hi"]), prefer: .localCLI))
        XCTAssertEqual(ev.first, .engineChanged(from: .localCLI, to: .apiKey, reason: "The week plan window is at 95%. Jobs pause above 90%."))
    }

    func testALimitRefusalIsUnavailable() async throws {
        let e = await engine(#"""
            read -r line
            echo '{"type":"error","error":"Usage limit","code":"limit","end_reason":"limit"}'
            echo '{"type":"result","subtype":"error","is_error":true,"text":"Usage limit reached"}'
            """#)
        do { _ = try await collect(e.turn(request(["Hi"]))); XCTFail("limit") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("fake refused the call on a plan limit."))
        }
    }

    func testACLIWithNoMCPCannotChat() async {
        let e = await engine(Self.history, features: Features())
        let ok = await e.available()
        XCTAssertFalse(ok)
    }

    func testConformance() async throws {
        let e = await engine(#"""
            while read -r line; do
              case "$line" in
                *hello*) echo '{"type":"assistant","text":"Hello."}'; echo '{"type":"usage","input":3,"output":2}'; echo '{"type":"result","subtype":"success","text":""}' ;;
                *echo*) echo '{"type":"tool","id":"c1","name":"mcp__oversire__echo","input":"{\"text\":\"hi\"}"}'
                        echo '{"type":"tool","id":"c1","name":"mcp__oversire__echo","status":"completed","output":"hi"}'
                        echo '{"type":"assistant","text":"It said hi."}'; echo '{"type":"result","subtype":"success","text":""}' ;;
                *) echo '{"type":"assistant","text":"1","delta":true}'; sleep 30 ;;
              esac
            done
            """#)
        let r = await ChatEngineConformance.run(e)
        XCTAssertTrue(r.passed, r.description)
    }
}

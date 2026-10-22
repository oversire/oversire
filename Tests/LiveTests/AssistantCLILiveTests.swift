import XCTest
import AgentBinder
import OverSireCore
import OverSireAI
import OverSireAssistant
import AIEngineAgentBinder
import OverSireTestKit

extension MCPListener: ChatToolHost {}

/// Claude Code through AgentBinder calls one OverSire read tool over the MCP socket.
/// Run with OVERSIRE_LIVE=1 and a logged-in `claude`. CLAUDE_MODEL changes the model.
final class AssistantCLILiveTests: XCTestCase {
    func testClaudeCallsAReadTool() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let calls = Counter()
        let get = ActionSpec(id: "item.get", title: "Get item", help: "Reads one tracker item by key.", kind: .read,
                             input: ActionSpec.args(["key": ("string", "The item key, for example OVERSIRE-7")], required: ["key"])) { a in
            calls.add()
            return .ok(summary: a.string("key") ?? "?", data: .object(["state": .string("Blue Heron")]))
        }
        let server = MCPServer()
        let listener = MCPListener(server: server)
        let chat = AgentBinderChat(config: LocalCLIConfig(harness: "claude", model: env["CLAUDE_MODEL"] ?? ""),
                                   runtime: Runtime(options: .init(clientName: "oversire-live")), limits: PlanLimits(),
                                   tools: listener, workRoot: dir.appendingPathComponent("work"))
        let loop = AssistantLoop(router: ChatRouter(engines: [chat]), catalog: ActionList([get]), policy: RuleConfirmPolicy(),
                                 store: ThreadStore(store: MemoryStore(), blobDir: dir.appendingPathComponent("blobs")),
                                 system: { _, _ in "You are the OverSire assistant. Answer in one short sentence." })
        await server.attach(loop)
        guard await chat.available() else { throw XCTSkip("claude is not set up") }

        let thread = AssistantThread(title: "New chat", createdAt: Date(), engine: .localCLI)
        var text = ""
        var errors: [String] = []
        for await e in await loop.send([.text("What is the state of item OVERSIRE-7? Use the item_get tool.")], in: thread) {
            switch e {
            case .textDelta(let t): text += t
            case .error(_, let m): errors.append(m)
            default: break
            }
        }
        await chat.close(thread: thread.id)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(calls.value, 1, "the tool ran once through the loop")
        XCTAssertTrue(text.contains("Blue Heron"), text)
        XCTAssertFalse(listener.isRunning, "the socket stops with the last thread")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

import Foundation
import OverSireCore
import OverSireAI

/// A chat engine with scripted turns. Each turn takes the next script; with no script left it says "ok".
/// Each request is kept.
public final class FakeChatEngine: ChatEngine, @unchecked Sendable {
    public enum Step: Sendable {
        case event(ChatEvent)
        case wait(Duration)
        case fail(AIError)
    }

    public let id: EngineID
    public let runsTools: Bool
    private let lock = NSLock()
    private var isAvailable: Bool
    private var scripts: [[Step]] = []
    private var sent: [ChatRequest] = []

    public init(id: EngineID = "fake-chat", available: Bool = true, runsTools: Bool = false) {
        self.id = id
        self.runsTools = runsTools
        isAvailable = available
    }

    public var requests: [ChatRequest] { lock.withLock { sent } }

    public func setAvailable(_ on: Bool) { lock.withLock { isAvailable = on } }

    public func script(_ steps: [Step]) { lock.withLock { scripts.append(steps) } }

    /// A turn with these events, a usage and the end.
    public func reply(_ events: ChatEvent...) {
        script(events.map(Step.event) + [.event(.usage(AIUsage(input: 10, output: 5))), .event(.end(.done))])
    }

    public func available() async -> Bool { lock.withLock { isAvailable } }

    public func turn(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let steps: [Step] = lock.withLock {
            sent.append(request)
            return scripts.isEmpty ? [.event(.textDelta("ok")), .event(.end(.done))] : scripts.removeFirst()
        }
        return AsyncThrowingStream { out in
            let task = Task {
                for s in steps {
                    switch s {
                    case .event(let e): out.yield(e)
                    case .wait(let d):
                        do { try await Task.sleep(for: d) } catch { break }
                    case .fail(let e):
                        out.finish(throwing: e)
                        return
                    }
                }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}

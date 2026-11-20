import Foundation
import OverSireCore

extension BigTimerTracker {
    /// More than two keep-alives (25 s each) plus a margin.
    public var liveFeedTimeout: Duration { .seconds(60) }

    public func liveFeed(lastEventID: String?) async throws -> AsyncThrowingStream<LiveSignal, Error> {
        let bytes = try await api.stream("/v1/stream", lastEventID: lastEventID)
        return AsyncThrowingStream { cont in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await chunk in bytes {
                        let events = parser.feed(chunk)
                        if events.isEmpty { cont.yield(LiveSignal(.alive)) }
                        for e in events { cont.yield(Self.signal(for: e)) }
                    }
                    for e in parser.finish() { cont.yield(Self.signal(for: e)) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// The data of `changes` is not read: the source always pulls from its own cursor.
    static func signal(for e: SSEEvent) -> LiveSignal {
        switch e.event {
        case "changes": return LiveSignal(.changed, id: e.id)
        case "resync": return LiveSignal(.resync, id: e.id)
        default: return LiveSignal(.alive, id: e.id)
        }
    }
}

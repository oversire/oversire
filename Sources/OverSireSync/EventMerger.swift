import Foundation
import OverSireCore

/// Joins the sources into one stream and drops repeats by id.
/// While the cloud is live, polling slows to its safety interval.
public actor EventMerger: EventSource {
    private let polling: PollingSource?
    private let cloud: CloudSource?
    private let sources: [any EventSource]
    private var seen: RecentIDs
    private var tasks: [Task<Void, Never>] = []
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var generation = 0

    public init(polling: PollingSource?, cloud: CloudSource? = nil, others: [any EventSource] = [], capacity: Int = 2000) {
        self.polling = polling
        self.cloud = cloud
        sources = [polling as (any EventSource)?, cloud].compactMap { $0 } + others
        seen = RecentIDs(capacity: capacity)
    }

    public nonisolated func events() -> AsyncStream<ProviderEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: ProviderEvent.self)
        Task { await self.start(cont) }
        return stream
    }

    public func health() async -> SourceHealth {
        if let cloud, await cloud.health() == .live { return .live }
        if let polling { return await polling.health() }
        return await cloud?.health() ?? .off
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        continuation?.finish()
        continuation = nil
    }

    private func start(_ cont: AsyncStream<ProviderEvent>.Continuation) async {
        stop()
        generation += 1
        let gen = generation
        continuation = cont
        cont.onTermination = { _ in Task { await self.stop(generation: gen) } }
        tasks = sources.map { s in
            // A cancel ends the stream, and the source stops.
            Task { for await e in s.events() { self.forward(e) } }
        }
        if let cloud, let polling {
            let health = await cloud.healthUpdates()
            tasks.append(Task {
                for await h in health { await polling.setCloudLive(h == .live) }
            })
        }
    }

    private func stop(generation gen: Int) {
        if gen == generation { stop() }
    }

    private func forward(_ e: ProviderEvent) {
        guard seen.insert(e.id) else { return }
        continuation?.yield(e)
    }
}

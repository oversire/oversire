import Foundation
import OverSireCore

/// The events table of the daemon. A member daemon sends its rows to the home daemon. New rows come as event frames.
extension MachineRuntime: EventSink {
    public func append(_ drafts: [EventDraft]) async throws {
        guard !drafts.isEmpty else { return }
        try await client.appendEvents(drafts)
    }

    public func setItemLinks(_ links: [ItemLink]) async throws { try await client.setItemLinks(links) }

    public func events(_ q: Event.Query) async throws -> Event.Page { try await client.events(q) }
}

import Foundation
import OverSireCore

extension OrcaRuntime {
    /// The agent sessions of all workspaces. A changed state gives one session event.
    /// The first poll sets the baseline and gives no events.
    public func poll(since: Cursor?) async throws -> EventPage {
        let seen = since.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.rawValue.utf8)) }
        var now: [String: String] = [:]
        var events: [ProviderEvent] = []
        for w in try await workspaces() {
            for a in w.agents {
                guard let pane = a.paneKey else { continue }
                let key = w.id + "|" + pane
                let state = "\(a.phase)@\(Int(a.since.timeIntervalSince1970))"
                now[key] = state
                guard let seen, seen[key] != state else { continue }
                events.append(ProviderEvent(id: "orca-\(account.id)-\(key)-\(state)", provider: .orca, account: account, kind: .session,
                                            action: "\(a.phase)", subject: .session(SessionRef(workspace: workspaceRef(w.id), id: pane)),
                                            at: a.since, summary: EventSummary(title: w.name, status: "\(a.phase)",
                                                                               actor: a.agent.rawValue)))
            }
        }
        let data = try JSONEncoder().encode(now)
        return EventPage(events: events.sorted { $0.at < $1.at }, cursor: Cursor(rawValue: String(decoding: data, as: UTF8.self)),
                         busy: now.values.contains { $0.hasPrefix("working@") })
    }
}

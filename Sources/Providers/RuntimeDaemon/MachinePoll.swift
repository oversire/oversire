import Foundation
import OverSireCore

extension MachineRuntime {
    /// The agent sessions in the workspaces of the machine. A changed state gives one session event.
    /// The first poll sets the baseline and gives no events.
    public func poll(since: Cursor?) async throws -> EventPage {
        let seen = since.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.rawValue.utf8)) }
        var now: [String: String] = [:]
        var events: [ProviderEvent] = []
        for s in try await client.sessions().sessions {
            guard let ws = s.workspace else { continue }
            let key = ws + "|" + s.id
            let state = "\(s.state.rawValue)@\(Int(s.stateSince.timeIntervalSince1970))"
            now[key] = state
            guard let seen, seen[key] != state else { continue }
            let title = s.repo ?? (s.cwd as NSString).lastPathComponent
            events.append(ProviderEvent(id: "daemon-\(machine)-\(key)-\(state)", provider: .daemon, account: account, kind: .session,
                                        action: s.state.rawValue, subject: .session(SessionRef(workspace: WorkspaceRef(account: account, id: ws), id: s.id)),
                                        at: s.stateSince, summary: EventSummary(title: title, status: s.state.rawValue, actor: s.harness)))
        }
        let data = try JSONEncoder().encode(now)
        return EventPage(events: events.sorted { $0.at < $1.at }, cursor: Cursor(rawValue: String(decoding: data, as: UTF8.self)),
                         busy: now.values.contains { $0.hasPrefix("working@") })
    }
}

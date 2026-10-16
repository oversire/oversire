import Foundation
import OverSireCore

extension PlaneTracker {
    /// The cursor holds the newest updated_at of each project. A new project sets its baseline and gives no events.
    public func poll(since: Cursor?) async throws -> EventPage {
        var marks = since.flatMap { try? JSONDecoder().decode([String: Date].self, from: Data($0.rawValue.utf8)) } ?? [:]
        var events: [ProviderEvent] = []
        let q = [URLQueryItem(name: "order_by", value: "-updated_at"),
                 URLQueryItem(name: "fields", value: "id,name,sequence_id,created_at,updated_at")]
        for p in try await projects() where !p.closed {
            let rows = try await api.list("\(ws)/projects/\(p.ref.id)/issues/", query: q, max: 50)
            let newest = rows.compactMap { parseISO($0["updated_at"] as? String) }.max()
            guard let mark = marks[p.ref.id] else {
                marks[p.ref.id] = newest ?? Date(timeIntervalSince1970: 0)
                continue
            }
            for r in rows {
                guard let id = PlaneAPI.id(r["id"]), let at = parseISO(r["updated_at"] as? String), at > mark else { continue }
                let key = "\(p.identifier)-\(PlaneAPI.int(r["sequence_id"]) ?? 0)"
                let ref = ItemRef(project: p.ref, id: id, key: key, url: URL(string: workspace.itemURL(key))!)
                let created = parseISO(r["created_at"] as? String).map { abs($0.timeIntervalSince(at)) < 1 } ?? false
                let action = created ? "created" : "updated"
                events.append(ProviderEvent(id: "plane-\(id)-\(action)-\(Int(at.timeIntervalSince1970))", provider: .plane,
                                            account: account, kind: .item, action: action, subject: .item(ref), at: at,
                                            summary: EventSummary(title: r["name"] as? String)))
            }
            if let newest, newest > mark { marks[p.ref.id] = newest }
        }
        let data = try JSONEncoder().encode(marks)
        return EventPage(events: events.sorted { $0.at < $1.at }, cursor: Cursor(rawValue: String(decoding: data, as: UTF8.self)))
    }
}

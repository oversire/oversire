import Foundation

// macOS notifications for project changes. "My items" means the token owner is an
// assignee or the author. The user's own comments are skipped. Changes to one
// item inside two minutes become one notification (same id, combined body).

final class ProjectNotifier {
    var now: () -> Date = Date.init
    private let post: (_ title: String, _ subtitle: String, _ body: String, _ id: String) -> Void
    private var window: [String: (body: String, at: Date)] = [:]

    init(post: @escaping (_ title: String, _ subtitle: String, _ body: String, _ id: String) -> Void) {
        self.post = post
    }

    func handle(_ changes: [(itemId: String, ItemChange)], in snapshot: ProjectSnapshot, settings: ProjectNotificationSettings) {
        let login = snapshot.me
        var byItem: [String: [ItemChange]] = [:]
        for (id, change) in changes {
            if isOwn(change, me: login) { continue }
            let item = snapshot.items.first { $0.id == id }
            if !allows(change, item: item, me: login, settings: settings) { continue }
            byItem[id, default: []].append(change)
        }
        for (id, list) in byItem {
            let item = snapshot.items.first { $0.id == id }
            let text = list.map(\.text).joined(separator: "\n")
            let title = snapshot.summary.ref.workspace + " › " + snapshot.summary.title
            let subtitle = item.map { "\($0.key) \($0.title)" } ?? "Work item"
            let stamp = now()
            let body: String
            if let prev = window[id], stamp.timeIntervalSince(prev.at) < 120 {
                body = prev.body + "\n" + text
                window[id] = (body, prev.at)
            } else {
                body = text
                window[id] = (body, stamp)
            }
            post(title, subtitle, body, "project:\(id)")
        }
    }

    func intake(_ lines: [(IntakeItem, String)], in snapshot: ProjectSnapshot) {
        let title = snapshot.summary.ref.workspace + " › " + snapshot.summary.title
        for (item, text) in lines {
            post(title, item.name, text, "intake:\(snapshot.summary.ref.key)|\(item.workItemId)")
        }
    }

    func allows(_ change: ItemChange, item: ProjectItem?, me login: String?, settings: ProjectNotificationSettings) -> Bool {
        let mine = item?.isMine(login) ?? false
        switch change {
        case .mention:
            return settings.mention && mine
        case .comments:
            return mine ? settings.comment.mine : settings.comment.any
        case .status:
            return mine ? settings.status.mine : settings.status.any
        case .added:
            return mine ? settings.added.mine : settings.added.any
        case .assigned(let who):
            return settings.assigned && who.lowercased() == login?.lowercased()
        case .closed, .reopened:
            return mine ? settings.closed.mine : settings.closed.any
        case .field, .removed, .unassigned:
            return mine ? settings.otherFields.mine : settings.otherFields.any
        }
    }

    private func isOwn(_ change: ItemChange, me login: String?) -> Bool {
        guard let me = login?.lowercased(), !me.isEmpty else { return false }
        return change.commentAuthor?.lowercased() == me
    }
}

import Foundation
import OverSireCore

// macOS notifications for project changes. "My items" means the token owner is an
// assignee or the author. The user's own comments are skipped. Changes to one
// item inside two minutes become one notification (same id) that shows the net change.

final class ProjectNotifier {
    var now: () -> Date = Date.init
    private let post: (Notice) -> Void
    private let withdraw: (String) -> Void
    private var window: [String: (net: ItemNet, at: Date)] = [:]

    init(post: @escaping (Notice) -> Void = { _ in }, withdraw: @escaping (String) -> Void = { _ in }) {
        self.post = post
        self.withdraw = withdraw
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
        let stamp = now()
        window = window.filter { stamp.timeIntervalSince($0.value.at) < 120 }
        for (id, list) in byItem {
            var net = window[id]?.net ?? ItemNet()
            net.add(list, at: stamp)
            window[id] = (net, window[id]?.at ?? stamp)
            let item = snapshot.items.first { $0.id == id }
            if let n = Notice.item(net, item: item, itemId: id, in: snapshot) { post(n) } else { withdraw("project:\(id)") }
        }
    }

    func intake(_ i: IntakeItem, _ line: IntakeLine, body: String?, in snapshot: ProjectSnapshot) {
        post(.intake(i, line, body: body, in: snapshot))
    }

    func allows(_ change: ItemChange, item: Item?, me login: String?, settings: ProjectNotificationSettings) -> Bool {
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
        case .away:
            return false
        }
    }

    private func isOwn(_ change: ItemChange, me login: String?) -> Bool {
        guard let me = login?.lowercased(), !me.isEmpty else { return false }
        return change.commentAuthor?.lowercased() == me
    }
}

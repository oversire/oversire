import Foundation
import OverSireCore

/// An in-memory tracker with one project "FAKE" and four statuses.
public final class FakeTracker: Tracker, @unchecked Sendable {
    public let base: FakeProvider
    public var id: ProviderID { base.id }
    public var account: AccountID { base.account }
    public var capabilities: Set<Capability> { base.capabilities }
    public var pollPolicy: PollPolicy { base.pollPolicy }
    public var keyFormat: KeyFormat { .projectDash }

    private var projectList: [ProjectSummary] = []
    private var statusList: [String: [StatusOption]] = [:]
    private var itemList: [String: [Item]] = [:]
    private var commentList: [String: [Comment]] = [:]

    public init(account: String = "fake", capabilities: Set<Capability> = []) {
        base = FakeProvider(id: "fake-tracker", account: account, capabilities: capabilities)
        let ref = ProjectRef(account: base.account, id: "p1", key: "FAKE")
        projectList = [ProjectSummary(ref: ref, identifier: "FAKE", title: "Fake project", url: "https://tracker.fake/FAKE", closed: false)]
        statusList[ref.id] = [StatusOption(id: "s-todo", name: "Todo", color: "#9CA3AF", group: "unstarted"),
                              StatusOption(id: "s-doing", name: "In Progress", color: "#F59E0B", group: "started"),
                              StatusOption(id: "s-review", name: "In Review", color: "#3B82F6", group: "started"),
                              StatusOption(id: "s-done", name: "Done", color: "#22C55E", group: "completed")]
    }

    public var project: ProjectRef { projectList[0].ref }

    public func probe() async throws -> Identity { try await base.probe() }
    public func poll(since: Cursor?) async throws -> EventPage { try await base.poll(since: since) }

    public func projects() async throws -> [ProjectSummary] { try base.locked { projectList } }

    public func statuses(_ p: ProjectRef) async throws -> [StatusOption] {
        try base.locked {
            guard let s = statusList[p.id] else { throw ProviderError.notFound }
            return s
        }
    }

    public func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] {
        try base.locked {
            let all = (itemList[p.id] ?? []).sorted { $0.activityAt > $1.activityAt }
            return Array(all.filter { since == nil || $0.activityAt >= since! }.prefix(limit))
        }
    }

    public func detail(_ i: ItemRef) async throws -> ItemDetail {
        try base.locked {
            guard let item = itemList[i.project.id]?.first(where: { $0.id == i.id }) else { throw ProviderError.notFound }
            return ItemDetail(item: item, comments: commentList[i.id] ?? [])
        }
    }

    public func comments(_ i: ItemRef) async throws -> [Comment] { try await detail(i).comments }

    public func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef {
        try base.locked {
            guard let summary = projectList.first(where: { $0.ref.id == p.id }) else { throw ProviderError.notFound }
            let n = (itemList[p.id]?.count ?? 0) + 1
            let key = "\(summary.identifier)-\(n)"
            let url = "https://tracker.fake/\(key)"
            let now = base.now()
            let item = Item(id: "i\(n)", key: key, title: d.title, url: url, statusOptionId: d.status ?? statusList[p.id]?.first?.id,
                            fields: [:], assignees: [], labels: d.labels, author: "me", updatedBy: "me", updatedAt: now, activityAt: now,
                            commentCount: 0, lastComment: nil, mentionsMe: false, body: d.bodyMarkdown, parentId: d.parent)
            itemList[p.id, default: []].append(item)
            let ref = ItemRef(project: p, id: item.id, key: key, url: URL(string: url)!)
            base.emit(.item, "created", .item(ref), title: d.title)
            return ref
        }
    }

    public func update(_ i: ItemRef, _ patch: ItemPatch) async throws {
        try base.locked {
            guard let at = itemList[i.project.id]?.firstIndex(where: { $0.id == i.id }) else { throw ProviderError.notFound }
            let o = itemList[i.project.id]![at]
            let now = base.now()
            itemList[i.project.id]![at] = Item(
                id: o.id, key: o.key, title: patch.title ?? o.title, url: o.url, statusOptionId: patch.status ?? o.statusOptionId,
                fields: o.fields, assignees: patch.assignees ?? o.assignees, labels: patch.labels ?? o.labels, author: o.author,
                updatedBy: "me", updatedAt: now, activityAt: now, commentCount: o.commentCount, lastComment: o.lastComment,
                mentionsMe: o.mentionsMe, body: patch.bodyMarkdown ?? o.body, parentId: patch.parent ?? o.parentId)
            base.emit(.item, "updated", .item(i), title: patch.title ?? o.title)
        }
    }

    public func comment(_ i: ItemRef, markdown: String) async throws {
        try base.locked {
            guard let at = itemList[i.project.id]?.firstIndex(where: { $0.id == i.id }) else { throw ProviderError.notFound }
            let c = Comment(id: "c\((commentList[i.id]?.count ?? 0) + 1)-\(i.id)", author: "me", createdAt: base.now(),
                            url: i.url.absoluteString, body: markdown)
            commentList[i.id, default: []].append(c)
            itemList[i.project.id]![at].commentCount += 1
            itemList[i.project.id]![at].lastComment = c
            base.emit(.comment, "created", .item(i))
        }
    }
}

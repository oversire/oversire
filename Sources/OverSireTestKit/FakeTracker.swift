import Foundation
import OverSireCore

/// An in-memory tracker with one project "FAKE" and four statuses.
public final class FakeTracker: Tracker, ProjectSettingsEditing, @unchecked Sendable {
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
    private var settingsList: [String: ProjectSettings] = [:]
    private var patchList: [ProjectSettingsPatch] = []
    private var editable: Set<ProjectSettingsField> = [.name, .description, .logo, .lead, .defaultAssignee, .visibility, .features, .labels]

    public init(account: String = "fake", capabilities: Set<Capability> = [.projectSettings, .projectSettingsEdit]) {
        base = FakeProvider(id: "fake-tracker", account: account, capabilities: capabilities)
        let ref = ProjectRef(account: base.account, id: "p1", key: "FAKE")
        projectList = [ProjectSummary(ref: ref, identifier: "FAKE", title: "Fake project", url: "https://tracker.fake/FAKE", closed: false)]
        statusList[ref.id] = [StatusOption(id: "s-todo", name: "Todo", color: "#9CA3AF", group: "unstarted"),
                              StatusOption(id: "s-doing", name: "In Progress", color: "#F59E0B", group: "started"),
                              StatusOption(id: "s-review", name: "In Review", color: "#3B82F6", group: "started"),
                              StatusOption(id: "s-done", name: "Done", color: "#22C55E", group: "completed")]
        let me = PersonRef(id: "u-me", name: "me")
        settingsList[ref.id] = ProjectSettings(
            name: "Fake project", key: "FAKE", description: "A project of the **fake** tracker.",
            logo: ProjectLogo(kind: .emoji, value: "🦊"), lead: me, defaultAssignee: me, visibility: .private,
            statuses: statusList[ref.id]!, labels: [StatusOption(id: "l-bug", name: "bug", color: "#EF4444")],
            priorities: StatusOption.priorities.map(\.id), members: [ProjectMember(person: me, role: "admin")],
            features: [.iterations: true, .modules: false, .intake: true, .pages: true, .estimates: false],
            readOnlyFeatures: [.estimates])
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

    // MARK: Project settings

    public var editableSettings: Set<ProjectSettingsField> {
        get { base.lockedValue { editable } }
        set { base.lockedValue { editable = newValue } }
    }

    /// The patches that update received, oldest first.
    public var patches: [ProjectSettingsPatch] { base.lockedValue { patchList } }

    /// Replaces the settings of a project. The page tests and --uishots use it.
    public func setSettings(_ s: ProjectSettings, for p: ProjectRef? = nil) {
        base.lockedValue { settingsList[(p ?? project).id] = s }
    }

    public func settings(_ p: ProjectRef) async throws -> ProjectSettings {
        try base.locked {
            guard let s = settingsList[p.id] else { throw ProviderError.notFound }
            return s
        }
    }

    public func update(_ p: ProjectRef, _ patch: ProjectSettingsPatch) async throws {
        try base.locked {
            guard var s = settingsList[p.id] else { throw ProviderError.notFound }
            guard patch.fields.isSubset(of: editable) else { throw ProviderError.unsupported(.projectSettingsEdit) }
            if patch.isEmpty { return }
            patchList.append(patch)
            func person(_ id: String?) -> PersonRef? { id.map { id in s.members.first { $0.person.id == id }?.person ?? PersonRef(id: id, name: id) } }
            if let v = patch.name { s.name = v }
            if let v = patch.description { s.description = v }
            if let v = patch.logo { s.logo = v }
            if let v = patch.lead { s.lead = person(v) }
            if let v = patch.defaultAssignee { s.defaultAssignee = person(v) }
            if let v = patch.visibility { s.visibility = v }
            for (f, on) in patch.features ?? [:] where !s.readOnlyFeatures.contains(f) { s.features[f] = on }
            for l in patch.newLabels ?? [] { s.labels.append(StatusOption(id: "l-\(s.labels.count + 1)", name: l.name, color: l.color)) }
            settingsList[p.id] = s
            if let at = projectList.firstIndex(where: { $0.ref.id == p.id }), patch.name != nil || patch.logo != nil {
                let o = projectList[at]
                projectList[at] = ProjectSummary(ref: o.ref, identifier: o.identifier, title: s.name, url: o.url, closed: o.closed, logo: s.logo)
            }
        }
    }
}

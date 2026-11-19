import Foundation
@testable import OverSireCore

/// Plan test data. `demo` is the data of the Map.dc.html design, with today = Nov 18, 2026.
struct PlanFixture {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
    static let project = ProjectRef(account: AccountID(provider: "plane", id: "acme"), id: "4", key: "OVERSIRE")
    static let todo = StatusOption(id: "todo", name: "Todo", color: "", group: "unstarted")
    static let backlog = StatusOption(id: "backlog", name: "Backlog", color: "", group: "backlog")
    static let doing = StatusOption(id: "doing", name: "In Progress", color: "", group: "started")
    static let done = StatusOption(id: "done", name: "Done", color: "", group: "completed")

    var items: [Item] = []
    var epics: [Epic] = []
    var relations: [String: [ItemRelation]] = [:]
    var signals = PlanSignals()

    static func key(_ n: Int) -> String { "OVERSIRE-\(n)" }

    static func date(_ day: PlanDay) -> Date { calendar.date(byAdding: .day, value: day, to: calendar.startOfDay(for: today))! }

    static func ymd(_ day: PlanDay) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date(day))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func ref(_ key: String) -> ItemRef {
        ItemRef(project: project, id: key, key: key, url: URL(string: "https://plane/\(key)")!)
    }

    /// `start` and `days` set the Start and Due fields.
    mutating func item(_ n: Int, _ epic: String?, _ status: StatusOption = todo, _ title: String? = nil, start: PlanDay? = nil,
                       days: Int? = nil, updatedAt: Date = PlanFixture.today) {
        var fields: [String: String] = [:]
        if let days {
            let s = start ?? 0
            fields["Start"] = Self.ymd(s)
            fields["Due"] = Self.ymd(s + days - 1)
        } else if let start {
            fields["Start"] = Self.ymd(start)
        }
        items.append(Item(id: Self.key(n), key: Self.key(n), title: title ?? "Item \(n)", url: "", statusOptionId: status.id,
                          fields: fields, assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: updatedAt,
                          activityAt: updatedAt, commentCount: 0, lastComment: nil, mentionsMe: false,
                          epicId: epic.map(EpicID.init(rawValue:))))
    }

    mutating func epic(_ id: String, _ title: String? = nil, _ state: EpicState = .active, start: PlanDay? = nil, due: PlanDay? = nil) {
        epics.append(Epic(id: EpicID(rawValue: id), title: title ?? id, state: state, startDate: start.map(Self.date),
                          targetDate: due.map(Self.date), url: "", project: Self.project))
    }

    mutating func block(_ n: Int, by blockers: Int...) {
        relations[Self.key(n), default: []] += blockers.map { ItemRelation(kind: .blockedBy, item: Self.ref(Self.key($0))) }
    }

    var snap: ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: Self.project, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                        statusOptions: [Self.todo, Self.backlog, Self.doing, Self.done], items: items, fetchedAt: Self.today,
                        epics: epics)
    }

    var graph: PlanGraph {
        PlanGraph.build(snap, epics: epics, relations: relations, signals: signals, today: Self.today, calendar: Self.calendar)
    }

    var schedule: PlanSchedule { PlanSchedule.build(graph) }

    func node(_ n: Int) -> PlanNode? { graph.nodes[Self.key(n)] }

    func title(_ key: String) -> String { items.first { $0.key == key }?.title ?? key }

    func name(_ id: EpicID) -> String { epics.first { $0.id == id }?.title ?? id.rawValue }

    /// The design data. Day 0 of the design is Nov 2. Its TODAY (16) is day 0 here.
    static var demo: PlanFixture {
        var f = PlanFixture()
        f.epic("rd", "Review desk", start: -16, due: -2)
        f.epic("cs", "Cloud store", start: -16, due: 23)
        f.epic("rb", "Runbooks v2", start: -13, due: 16)
        f.epic("ep", "Epics", start: -9, due: 0)
        f.epic("mc", "Mobile client", .planned, due: 40)
        f.epic("c2", "Contract v2", .planned, due: 16)
        f.epic("pl", "Planner cloud", .planned)
        f.epic("ln", "Linear tracker", .planned)
        f.epic("gl", "GitLab host", .planned)

        let doneCounts = ["rd": 6, "cs": 2, "rb": 3, "ep": 11]
        var n = 300
        for (e, c) in doneCounts.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<c {
                f.item(n, e, done, "Done \(n)", updatedAt: today.addingTimeInterval(-86400 * 3))
                n += 1
            }
        }

        f.item(425, "rd", doing, "Changes menu", start: -1, days: 2)
        f.item(421, "rd", doing, "Approval checks", start: -2, days: 1)
        f.item(426, "rd", todo, "Keyboard review", days: 2)
        f.item(429, "rd", backlog, "Review docs", days: 1)
        f.item(431, "cs", todo, "Store schema", days: 2)
        f.item(432, "cs", todo, "Sync from Mac", days: 3)
        f.item(433, "cs", todo, "Conflict rules", days: 2)
        f.item(460, "rb", doing, "Step retries", start: -1, days: 2)
        f.item(461, "rb", todo, "Run history", days: 2)
        f.item(462, "rb", backlog, "Runbook templates", days: 2)
        f.item(435, "mc", todo, "Status feed", days: 3)
        f.item(436, "mc", backlog, "Push alerts", days: 2)
        f.item(437, "mc", backlog, "Approve from phone", days: 2)
        f.item(440, "c2", todo, "Rename fields", days: 2)
        f.item(441, "c2", todo, "Schema check in CI", days: 1)
        f.item(470, "pl", backlog, "Area claims API", days: 3)
        f.item(471, "pl", backlog, "Hub order job", days: 3)
        f.item(450, "ln", todo, "Linear discovery", days: 1)
        f.item(451, "ln", backlog, "Linear adapter", days: 4)
        f.item(452, "ln", backlog, "Linear webhooks", days: 2)
        f.item(480, "gl", backlog, "GitLab discovery", days: 1)

        f.block(426, by: 421)
        f.block(429, by: 426)
        f.block(432, by: 431, 440)
        f.block(433, by: 432)
        f.block(461, by: 460)
        f.block(462, by: 461)
        f.block(435, by: 432)
        f.block(436, by: 435)
        f.block(437, by: 421)
        f.block(441, by: 440)
        f.block(470, by: 431)
        f.block(471, by: 470)
        f.block(451, by: 450)
        f.block(452, by: 451)

        f.signals = PlanSignals(working: [key(425): "Claude on mba", key(460): "Codex on mbp"],
                                input: [key(421): "Count a skipped CI job as green?"])
        return f
    }
}

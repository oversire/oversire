import Foundation
import OverSireCore
@testable import OverSireApp

/// A project with four epics. "Review desk" has 8 items (6 done) and is late. "Epics" has 1 open item.
/// "Planned" has none. "Old" is done and has 1 done item. Two items have no epic.
enum EpicFixture {
    static let ref = ProjectRef(workspace: "w", id: "p")
    static let deskId: EpicID = "desk"
    static let now = Date()

    static func item(_ n: Int, state: String, epic: EpicID?, others: [EpicID]? = nil) -> Item {
        Item(id: "i\(n)", key: "ENG-\(n)", title: "Item \(n)", url: "u", statusOptionId: state, fields: [:], assignees: [], labels: [], author: nil,
             updatedBy: nil, updatedAt: now, activityAt: now, commentCount: 0, lastComment: nil, mentionsMe: false, epicId: epic, otherEpicIds: others)
    }

    static func epic(_ id: EpicID, _ title: String, _ state: EpicState = .active, target: Double? = nil) -> Epic {
        Epic(id: id, title: title, state: state, targetDate: target.map { now.addingTimeInterval($0 * 86_400) }, url: "u", project: ref)
    }

    static func snap(epics: Bool = true, deskOthers: [EpicID]? = nil) -> ProjectSnapshot {
        var items: [Item] = (1...6).map { item($0, state: "d", epic: deskId) }
        items.append(item(7, state: "t", epic: deskId, others: deskOthers))
        items.append(item(8, state: "t", epic: deskId))
        items += [item(9, state: "t", epic: "e2"), item(10, state: "d", epic: "old"), item(11, state: "t", epic: nil), item(12, state: "t", epic: "gone")]
        let list = epics ? [epic("e2", "Epics", target: 10), epic(deskId, "Review desk", target: -2), epic("plan", "Planned", .planned), epic("old", "Old", .done)] : nil
        return ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "ENG", title: "Board", url: "", closed: false),
                               statusOptions: [StatusOption(id: "t", name: "Todo", color: "", group: "unstarted"),
                                               StatusOption(id: "d", name: "Done", color: "", group: "completed")],
                               items: items, fetchedAt: now, epics: list)
    }
}

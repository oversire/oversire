import Cocoa
import OverSireCore

// ─── --uishots: epics ────────────────────────────────────────────────────────
// Sample epics in the OVERSIRE snapshot, in memory only. The store on disk stays as it is.
// The members are real items of the snapshot. "Review desk" has 8 members, 6 done, and a target date 2 days ago.

extension UIShots {
    /// The id of the epic that the shots open.
    static let epicID: EpicID = "uishots-epic"

    func seedEpics() {
        guard let snap = projectStore.snapshot("OVERSIRE") else { print("UISHOTS epics: no OVERSIRE project"); return }
        let now = Date()
        let day = { (d: Double) in now.addingTimeInterval(-d * 86_400) }
        let roots = snap.rootItems
        var used = Set<String>()
        func take(_ n: Int, closed: Bool, prefer: [String] = []) -> [Item] {
            let pool = roots.filter { !used.contains($0.id) && snap.isClosed($0.statusOptionId) == closed }
                .sorted { a, b in
                    let (pa, pb) = (prefer.contains(a.key), prefer.contains(b.key))
                    return pa != pb ? pa : a.updatedAt > b.updatedAt
                }
            let out = Array(pool.prefix(n))
            out.forEach { used.insert($0.id) }
            return out
        }
        let desk = take(6, closed: true) + take(2, closed: false, prefer: ["OVERSIRE-137", "OVERSIRE-141"])
        guard desk.count == 8 else { print("UISHOTS epics: needs 8 items, has \(desk.count)"); return }
        let ready = take(2, closed: true), finished = take(2, closed: true), later = take(2, closed: false)
        let ref = snap.summary.ref
        let me = snap.me ?? "Ada"
        func epic(_ id: EpicID, _ title: String, _ state: EpicState, goal: String? = nil, start: Double? = nil, target: Double? = nil) -> Epic {
            Epic(id: id, title: title, goal: goal, state: state, nativeState: state.rawValue, lead: me, startDate: start.map(day),
                 targetDate: target.map { day($0) }, url: "https://plane.example/ocral/projects/oversire/modules/\(id.rawValue)", project: ref,
                 createdAt: day(30), updatedAt: day(1))
        }
        let goal = """
        Give the reviewer one desk for **plans and diffs**.

        - Show the open reviews of all Macs in one list.
        - Mark the review that waits for you.
        - Keep the verdict of a review with its item.
        """
        let epics = [epic(Self.epicID, "Review desk", .active, goal: goal, start: 30, target: 2),
                     epic("uishots-ready", "Planner docs", .active, start: 20, target: -5),
                     epic("uishots-later", "Mobile client", .planned, target: -40),
                     epic("uishots-done", "Contract v2", .done, start: 60, target: 10)]
        let members: [EpicID: [Item]] = [Self.epicID: desk, "uishots-ready": ready, "uishots-later": later, "uishots-done": finished]
        var byItem: [String: EpicID] = [:]
        for (id, list) in members { list.forEach { byItem[$0.id] = id } }

        // The copy has the epic id on each member. The Item type has no setter for it, so the JSON carries it.
        let items = snap.items.map { i -> Item in
            guard let id = byItem[i.id], var o = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(i))) as? [String: Any] else { return i }
            o["epicId"] = id.rawValue
            return (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) } ?? i
        }
        projectStore.seed(ProjectSnapshot(summary: snap.summary, statusOptions: snap.statusOptions, items: items, fetchedAt: snap.fetchedAt,
                                          fields: snap.fields, me: snap.me, meId: snap.meId, index: snap.index, intake: snap.intake, epics: epics))

        // The rows for the burn-up: 6 members join before the chart starts, 2 join later, and 6 close one by one.
        let key = epics[0].eventKey
        var epicRows: [Event] = [], memberRows: [Event] = []
        var seq: Int64 = 9000
        func row(_ id: String, _ at: Date, _ kind: Event.Kind, item: String, parent: String?, summary: String, payload: [String: JSONValue]? = nil) -> Event {
            seq += 1
            return Event(seq: seq, seenAt: at, draft: EventDraft(id: id, at: at, kind: kind, item: item, parentItem: parent, project: "oversire", provider: "plane",
                                                                  actorType: .human, actor: me, via: "plane", summary: summary, payload: payload))
        }
        epicRows.append(row("uishots-epic-created", day(30), .epicCreated, item: key, parent: nil, summary: "Review desk"))
        let joined: [Double] = [29, 28, 28, 27, 26, 25, 12, 6]
        for (n, item) in desk.enumerated() {
            epicRows.append(row("uishots-add-\(n)", day(joined[n]), .epicItemAdded, item: item.key, parent: key, summary: "Added to Review desk"))
        }
        let closed: [Double] = [17, 14, 10, 7, 4, 1]
        for (n, item) in desk.prefix(6).enumerated() {
            memberRows.append(row("uishots-done-\(n)", day(closed[n]), .itemStateChanged, item: item.key, parent: nil, summary: "\(item.key) moved to Done",
                                  payload: ["group": .string("completed")]))
        }
        JOURNAL.reads = false
        JOURNAL.lookPath = nil
        JOURNAL.seed(key, epicRows)
        EPIC_BURNUPS.enabled = false
        EPIC_BURNUPS.seed(key, memberRows)
        print("UISHOTS epics \(desk.map(\.key))")
    }
}

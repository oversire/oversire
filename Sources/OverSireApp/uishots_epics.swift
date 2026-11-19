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

extension UIShots {
    /// epic-steps: the Steps tab of "Review desk" with 5 open steps: working, ready, ready, no spec, and one that waits on a step.
    /// epic-steps-question: the same, and the first ready step waits on an answer.
    func epicStepsState(_ scene: String, in w: AppWindow) {
        guard let snap = projectStore.snapshot("OVERSIRE") else { print("UISHOTS no OVERSIRE project"); return }
        var open = snap.items.filter { $0.epicId == Self.epicID && !snap.isFinished($0) }
        let todo = snap.statusOptions.first { $0.group == "unstarted" }, backlog = snap.statusOptions.first { $0.group == "backlog" }
        let extra = snap.rootItems.filter { $0.epicId == nil && !snap.isClosed($0.statusOptionId) }.sorted { $0.key < $1.key }.prefix(max(0, 5 - open.count))
        open = (open + extra).sorted { PlanGraph.keyOrder($0.key, $1.key) }
        guard open.count == 5, let todo, let backlog else { print("UISHOTS epic-steps: needs 5 open items and the unstarted and backlog states"); return }
        let status: [String: String] = [open[1].id: todo.id, open[2].id: todo.id, open[3].id: backlog.id, open[4].id: todo.id]
        let items = snap.items.map { i -> Item in
            let inEpic = open.contains { $0.id == i.id }
            guard inEpic, var o = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(i))) as? [String: Any] else { return i }
            o["epicId"] = Self.epicID.rawValue
            if let s = status[i.id] { o["statusOptionId"] = s }
            return (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) } ?? i
        }
        projectStore.seed(ProjectSnapshot(summary: snap.summary, statusOptions: snap.statusOptions, items: items, fetchedAt: snap.fetchedAt,
                                          fields: snap.fields, me: snap.me, meId: snap.meId, index: snap.index, intake: snap.intake, epics: snap.epics))

        let ref = snap.summary.ref
        for i in open { projectStore.relations.seed(i.key, []) }
        if let blocker = open[2].ref(in: ref) { projectStore.relations.seed(open[4].key, [ItemRelation(kind: .blockedBy, item: blocker)]) }

        let now = Date()
        agentIndex.hold = true
        agentIndex.seed(open[0].key, AgentSession(phase: .working, since: now.addingTimeInterval(-14 * 60), card: "uishots-steps", paneKey: "p-steps",
                                                  agent: .claude, repo: "oversire", startedAt: now.addingTimeInterval(-14 * 60)))
        let gists = ["Add Open, Revert and Copy path to the right-click menu of a changed file.",
                     "Block Approve until CI is green and no thread is open.",
                     "J and K move between files; A approves; R asks for changes.",
                     "Write the page of the review desk in the docs.",
                     "Show the review desk of each Mac in one list."]
        for (i, item) in open.enumerated() {
            itemSummaries.seed(item.key, ItemSummary(gist: gists[i], hash: ItemSummary.hash((item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines))))
        }

        let account = ENV.machines?.sessions?.account ?? AccountID(provider: .daemon, id: "mba")
        let session = SessionRef(workspace: WorkspaceRef(account: account, id: "w-steps"), id: "term-steps")
        let id = QuestionID(rawValue: "daemon:mba:steps")
        var entries = questions.entries.filter { $0.id != id }
        if scene == "epic-steps-question" {
            let ask = QuestionItem(id: "q1", header: "CI", text: "Count a skipped CI job as green?", why: "A skipped job has no result.", kind: .single,
                                   options: [.init(label: "Yes"), .init(label: "No")], allowsOther: true)
            let at = now.addingTimeInterval(-2 * 86_400)
            entries.append(QuestionBoard.Entry(question: SessionQuestion(id: id, session: session, origin: .session, items: [ask], via: .form, askedAt: at),
                                               state: .open, firstSeen: at))
        }
        questions.seed(entries, keys: [session: open[1].key])
        w.router.go(.epic("OVERSIRE", Self.epicID.rawValue, .steps))
    }
}

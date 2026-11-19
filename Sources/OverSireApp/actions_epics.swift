import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The epic actions. They write through ProjectStore. Each needs a tracker with the epics capability.
struct EpicActions {
    let link: ActionLink

    static let project = ("string", "The project identifier, for example OVERSIRE.")
    static let epic = ("string", "The epic id or title.")
    static let day = ("string", "A date as YYYY-MM-DD. `none` removes it.")

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "item.setEpic", title: "Set epic", help: "Puts an item in an epic of its project, or takes it out. Give the epic id or title, or `none`.",
                       kind: .change, input: ActionSpec.args(["key": ItemActions.key, "epic": ("string", "The epic id or title. `none` takes the item out of its epic.")],
                                                              required: ["key", "epic"]), capability: .epics) { a in
                await link.item(a) { d, f, done in
                    let text = a.string("epic") ?? ""
                    var target: Epic?
                    if text.caseInsensitiveCompare("none") != .orderedSame {
                        guard let e = f.snap.findEpic(text) else { done(.notAllowed(f.snap.unknownEpic(text))); return }
                        target = e
                    }
                    d.projectStore.setEpic(target?.id, itemId: f.item.id, by: a.caller.actor) {
                        done(ActionLink.stored(d, $0, target.map { "\(f.item.key) is in \($0.title)." } ?? "\(f.item.key) is in no epic."))
                    }
                }
            },
            ActionSpec(id: "epic.list", title: "List epics", help: "Lists the epics of a project, or of all projects, with the progress, the late days and the next items to start.",
                       kind: .read, input: ActionSpec.args(["project": Self.project]), capability: .epics) { a in
                await link.run { d, done in
                    let snaps: [ProjectSnapshot]
                    if let p = a.string("project") {
                        guard let s = d.projectStore.snapshot(p) else { done(.notAllowed("OverSire has no loaded project \(p).")); return }
                        snaps = [s]
                    } else {
                        snaps = d.projectStore.allEpics.reduce(into: [ProjectSnapshot]()) { out, e in
                            if !out.contains(where: { $0.summary.ref.storeKey == e.snap.summary.ref.storeKey }) { out.append(e.snap) }
                        }
                    }
                    var rows: [JSONValue] = []
                    for s in snaps {
                        let blocked = Set(s.items.filter { !d.projectStore.blockers(of: $0.key).isEmpty }.map(\.id))
                        let keys = Dictionary(s.items.map { ($0.id, $0.key) }, uniquingKeysWith: { x, _ in x })
                        for e in s.epics ?? [] {
                            let r = s.rollup(e, blocked: blocked)
                            var o: [String: JSONValue] = [
                                "project": .string(s.summary.identifier), "id": .string(e.id.rawValue), "title": .string(e.title),
                                "state": .string(e.state.rawValue), "progress": .string("\(r.done) of \(r.total) done"),
                                "next": .array(r.next.compactMap { keys[$0] }.map(JSONValue.string)),
                            ]
                            if let late = r.lateDays { o["lateDays"] = .int(late) }
                            if r.readyToClose { o["readyToClose"] = .bool(true) }
                            rows.append(.object(o))
                        }
                    }
                    done(.ok(summary: "\(rows.count) epic\(rows.count == 1 ? "" : "s").", data: .array(rows)))
                }
            },
            ActionSpec(id: "epic.create", title: "New epic", help: "Makes an epic in a project. Returns its id.", kind: .change,
                       input: ActionSpec.args(["project": Self.project, "title": ("string", "The title."), "goal": ("string", "The goal, in Markdown."),
                                               "targetDate": Self.day, "startDate": Self.day, "lead": ("string", "A person id from people.list.")],
                                              required: ["project", "title"]), capability: .epics) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    guard let title = a.string("title"), !title.isEmpty else { done(.notAllowed("Give a title.")); return }
                    var draft = EpicDraft(title: title, goal: a.string("goal"), lead: a.string("lead"))
                    for name in ["targetDate", "startDate"] {
                        guard let text = a.string(name) else { continue }
                        guard let day = Self.parseDay(text) else { done(.notAllowed("\(name) must be a date as YYYY-MM-DD.")); return }
                        if name == "targetDate" { draft.targetDate = day } else { draft.startDate = day }
                    }
                    d.projectStore.createEpic(draft, projectKey: snap.summary.ref.storeKey, by: a.caller.actor) { r in
                        switch r {
                        case .success(let e): done(.ok(summary: "Epic \(e.title) is made.", data: .object(["id": .string(e.id.rawValue)])))
                        case .failure(let e): done(.failed(d.projectStore.lastError ?? e.message))
                        }
                    }
                }
            },
            ActionSpec(id: "epic.update", title: "Update epic", help: "Changes the title, the goal, the state, the dates or the lead of an epic. "
                           + "State: planned, active, paused, done or canceled.", kind: .change,
                       input: ActionSpec.args(["project": Self.project, "epic": Self.epic, "title": ("string", "The new title."),
                                               "goal": ("string", "The new goal, in Markdown."), "state": ("string", "planned, active, paused, done or canceled."),
                                               "targetDate": Self.day, "startDate": Self.day, "lead": ("string", "A person id. `none` removes the lead.")],
                                              required: ["project", "epic"]), capability: .epics) { a in
                await link.epic(a) { d, f, done in
                    var patch = EpicPatch(title: a.string("title"), goal: a.string("goal"), lead: a.string("lead"))
                    if let s = a.string("state") {
                        guard let state = EpicState(rawValue: s.lowercased()) else {
                            done(.notAllowed("No state \(s). Use: \(EpicState.allCases.map(\.rawValue).joined(separator: ", ")).")); return
                        }
                        patch.state = state
                    }
                    if patch.lead?.lowercased() == "none" { (patch.lead, patch.clear) = (nil, patch.clear.union([.lead])) }
                    for (name, field) in [("targetDate", EpicField.targetDate), ("startDate", .startDate)] {
                        guard let text = a.string(name) else { continue }
                        if text.lowercased() == "none" { patch.clear.insert(field); continue }
                        guard let day = Self.parseDay(text) else { done(.notAllowed("\(name) must be a date as YYYY-MM-DD.")); return }
                        if field == .targetDate { patch.targetDate = day } else { patch.startDate = day }
                    }
                    guard !patch.isEmpty else { done(.notAllowed("Give a field to change.")); return }
                    d.projectStore.updateEpic(f.epic, patch, by: a.caller.actor) { ok in
                        let title = patch.title ?? f.epic.title
                        if ok {
                            let fields = ["title", "goal", "state", "targetDate", "startDate", "lead"].filter { a.string($0) != nil }
                            var p: [String: JSONValue] = ["epic": .string(f.epic.id.rawValue), "title": .string(title),
                                                          "fields": .array(fields.map(JSONValue.string))]
                            if let s = patch.state { p["state"] = .string(s.rawValue) }
                            let actor = a.caller.actor
                            d.projectStore.events.action(.epicUpdated, item: f.epic.eventKey, project: f.snap.summary.identifier, verb: "epic-update",
                                                         "\(title) updated: \(fields.joined(separator: ", "))", payload: p,
                                                         actorType: actor.type, actor: actor.name)
                        }
                        done(ActionLink.stored(d, ok, "Epic \(title) is updated."))
                    }
                }
            },
            ActionSpec(id: "epic.close", title: "Close epic", help: "Sets an epic to done. An epic with open items does not close.", kind: .change,
                       input: ActionSpec.args(["project": Self.project, "epic": Self.epic], required: ["project", "epic"]), capability: .epics) { a in
                await link.epic(a) { d, f, done in
                    guard !f.epic.state.isClosed else { done(.notAllowed("\(f.epic.title) is \(f.epic.state.rawValue) already.")); return }
                    let open = f.snap.rollup(f.epic).open
                    guard open == 0 else { done(.notAllowed("\(open) item\(open == 1 ? " is" : "s are") open.")); return }
                    d.projectStore.updateEpic(f.epic, EpicPatch(state: .done), by: a.caller.actor) { done(ActionLink.stored(d, $0, "Epic \(f.epic.title) is done.")) }
                }
            },
            ActionSpec(id: "epic.addItems", title: "Add items to epic", help: "Puts items in an epic of their project. An item sits in one epic only.", kind: .change,
                       input: ActionSpec.args(["project": Self.project, "epic": Self.epic, "keys": ("array", "The item keys.")],
                                              required: ["project", "epic", "keys"]), capability: .epics) { a in
                await link.epic(a) { d, f, done in
                    let keys = a.list("keys").map { $0.uppercased() }
                    guard !keys.isEmpty else { done(.notAllowed("Give the item keys.")); return }
                    var ids: [String] = []
                    for k in keys {
                        guard let i = f.snap.items.first(where: { $0.key.uppercased() == k }) else {
                            done(.notAllowed("\(f.snap.summary.identifier) has no loaded item \(k).")); return
                        }
                        ids.append(i.id)
                    }
                    func next(_ n: Int) {
                        guard n < ids.count else { done(.ok(summary: "\(n) item\(n == 1 ? " is" : "s are") in \(f.epic.title).")); return }
                        d.projectStore.setEpic(f.epic.id, itemId: ids[n], by: a.caller.actor) { ok in
                            if ok { next(n + 1) } else { done(.failed("\(keys[n]) did not move. \(d.projectStore.lastError ?? "")" + (n > 0 ? " \(n) before it moved." : ""))) }
                        }
                    }
                    next(0)
                }
            },
            ActionSpec(id: "epic.removeItems", title: "Remove items from epic", help: "Takes items out of their epic. The items stay in their project.",
                       kind: .change, input: ActionSpec.args(["project": Self.project, "keys": ("array", "The item keys.")], required: ["project", "keys"]),
                       capability: .epics) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    let keys = a.list("keys").map { $0.uppercased() }
                    guard !keys.isEmpty else { done(.notAllowed("Give the item keys.")); return }
                    var items: [Item] = []
                    for k in keys {
                        guard let i = snap.items.first(where: { $0.key.uppercased() == k }) else {
                            done(.notAllowed("\(snap.summary.identifier) has no loaded item \(k).")); return
                        }
                        items.append(i)
                    }
                    let moving = items.filter { $0.epicId != nil }
                    func next(_ n: Int) {
                        guard n < moving.count else {
                            done(.ok(summary: "\(n) item\(n == 1 ? " is" : "s are") in no epic." + (moving.count < items.count ? " \(items.count - moving.count) had no epic." : "")))
                            return
                        }
                        d.projectStore.setEpic(nil, itemId: moving[n].id, by: a.caller.actor) { ok in
                            if ok { next(n + 1) } else { done(.failed("\(moving[n].key) did not move. \(d.projectStore.lastError ?? "")" + (n > 0 ? " \(n) before it moved." : ""))) }
                        }
                    }
                    next(0)
                }
            },
            ActionSpec(id: "epic.show", title: "Show epic", help: "Gives an epic: the progress, the members, the numbered next steps and the forecast.",
                       kind: .read, input: ActionSpec.args(["project": Self.project, "epic": Self.epic], required: ["project", "epic"]),
                       capability: .epics) { a in
                await link.epic(a) { d, f, done in
                    d.projectStore.loadPlan(f.snap.summary.ref.storeKey)
                    let m = PlanModel.build(data: d, snap: f.snap, controls: PlanControls())
                    done(.ok(summary: m.epicText(f.epic), data: m.epicJSON(f.epic)))
                }
            },
            ActionSpec(id: "epic.plan", title: "Project plan", help: "Gives the plan of a project, or of one epic: the ordered steps, the critical path, "
                           + "the slack and the forecast of each epic. Relations that did not load yet can change the order.",
                       kind: .read, input: ActionSpec.args(["project": Self.project, "epic": ("string", "The epic id or title. Empty: all open epics.")],
                                                            required: ["project"]), capability: .epics) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    var only: Epic?
                    if let text = a.string("epic"), !text.isEmpty {
                        guard let e = snap.findEpic(text) else { done(.notAllowed(snap.unknownEpic(text))); return }
                        only = e
                    }
                    d.projectStore.loadPlan(snap.summary.ref.storeKey)
                    let m = PlanModel.build(data: d, snap: snap, controls: PlanControls())
                    done(.ok(summary: m.planText(only: only), data: m.planJSON(only: only)))
                }
            },
        ]
    }

    /// A day as YYYY-MM-DD, in the calendar of the Mac.
    static func parseDay(_ s: String) -> Date? {
        let n = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard n.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: n[0], month: n[1], day: n[2]))
    }
}

extension ActionLink {
    /// Runs `body` with the project of the `project` arg and its epic of the `epic` arg: the id, else the title.
    func epic(_ a: ActionArgs, _ body: @escaping (AppData, (snap: ProjectSnapshot, epic: Epic), @escaping (ActionResult) -> Void) -> Void) async -> ActionResult {
        await run { d, done in
            guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
            }
            let text = a.string("epic") ?? ""
            guard let e = snap.findEpic(text) else { done(.notAllowed(snap.unknownEpic(text))); return }
            body(d, (snap, e), done)
        }
    }
}

extension ProjectSnapshot {
    /// An epic by id, else by title.
    func findEpic(_ s: String) -> Epic? {
        epics?.first { $0.id.rawValue == s } ?? epics?.first { $0.title.caseInsensitiveCompare(s) == .orderedSame }
    }

    func unknownEpic(_ s: String) -> String {
        let id = summary.identifier
        guard let list = epics, !list.isEmpty else { return "\(id) has no epics." }
        return "\(id) has no epic \(s). It has: \(list.map(\.title).joined(separator: ", "))."
    }
}

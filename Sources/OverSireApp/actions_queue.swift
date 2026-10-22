import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The queue and Planner actions: WorkQueue and SuggestionBook.
struct QueueActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        let link = link
        let key = ItemActions.key
        let device: () -> String? = { RELAY.deviceID.isEmpty ? nil : RELAY.deviceID }
        return [
            ActionSpec(id: "queue.add", title: "Add to queue", help: "Adds the item to the queue lane of its project. The queue starts it when a slot is free.",
                       kind: .change, input: ActionSpec.args(["key": key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    guard !d.queue.contains(f.item.key) else { done(.ok(summary: "\(f.item.key) is in the queue.")); return }
                    d.queue.add(f.item, snap: f.snap)
                    done(.ok(summary: "\(f.item.key) is in the queue of \(f.snap.summary.identifier)."))
                }
            },
            ActionSpec(id: "queue.remove", title: "Remove from queue", help: "Removes the item from its queue lane.", kind: .change,
                       input: ActionSpec.args(["key": key], required: ["key"])) { a in
                await link.run { d, done in
                    guard let k = a.string("key")?.uppercased(), d.queue.contains(k) else { done(.notAllowed("\(a.string("key") ?? "It") is not in the queue.")); return }
                    d.queue.remove(k)
                    done(.ok(summary: "\(k) is out of the queue."))
                }
            },
            ActionSpec(id: "queue.move", title: "Move in queue", help: "Moves the item up (negative) or down (positive) in its lane.", kind: .change,
                       input: ActionSpec.args(["key": key, "by": ("integer", "Steps: -1 is one up, 1 is one down.")], required: ["key", "by"])) { a in
                await link.run { d, done in
                    guard let k = a.string("key")?.uppercased(), d.queue.contains(k) else { done(.notAllowed("\(a.string("key") ?? "It") is not in the queue.")); return }
                    d.queue.move(k, by: a.int("by") ?? 0)
                    done(.ok(summary: "\(k) moved."))
                }
            },
            ActionSpec(id: "queue.start", title: "Start now", help: "Starts the queue entry now, also when no slot is free. `root` sets the Orca workspace of a project that has none.",
                       kind: .outward, input: ActionSpec.args(["key": key, "root": ("string", "The Orca workspace path.")], required: ["key"]), capability: .sessionInput) { a in
                await link.run { d, done in
                    guard let k = a.string("key")?.uppercased(), let lane = d.queue.lanes.first(where: { $0.entries.contains { $0.key == k } }) else {
                        done(.notAllowed("\(a.string("key") ?? "It") is not in the queue.")); return
                    }
                    if let e = d.queue.start(k, project: lane.project, root: a.string("root")) { done(.notAllowed(e)) } else { done(.ok(summary: "\(k) starts.")) }
                }
            },
            ActionSpec(id: "queue.setSlots", title: "Set slots", help: "Sets how many sessions of a project run at a time (1 to 4).", kind: .settings,
                       input: ActionSpec.args(["project": ItemActions.project, "slots": ("integer", "1 to 4.")], required: ["project", "slots"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else { done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return }
                    let n = min(4, max(1, a.int("slots") ?? 1)), pk = snap.summary.ref.storeKey
                    AGENTS.slots[pk] = n
                    saveConfig()
                    // The hub gate reads the slots from the Planner settings.
                    if d.planner.settings(pk).slots != n { d.planner.update(pk) { $0.slots = n } }
                    done(.ok(summary: "\(snap.summary.identifier) runs \(n) session\(n == 1 ? "" : "s") at a time."))
                }
            },
            ActionSpec(id: "plan.accept", title: "Apply plan", help: "Applies a Planner change. `drop` lists the line indexes to leave out.", kind: .change,
                       input: ActionSpec.args(["id": ("string", "The suggestion id."), "drop": ("array", "Line indexes to leave out.")], required: ["id"])) { a in
                await link.run { d, done in
                    guard let id = a.string("id"), d.suggestions.openPlans().contains(where: { $0.id == id }) else { done(.notAllowed("No open plan change \(a.string("id") ?? "").")); return }
                    d.suggestions.accept(id, drop: Set(a.list("drop").compactMap { Int($0) }), by: device())
                    done(.ok(summary: "The plan change is applied."))
                }
            },
            ActionSpec(id: "plan.dismiss", title: "Dismiss plan", help: "Dismisses a Planner change.", kind: .change,
                       input: ActionSpec.args(["id": ("string", "The suggestion id.")], required: ["id"])) { a in
                await link.run { d, done in
                    guard let id = a.string("id") else { done(.notAllowed("Give the suggestion id.")); return }
                    d.suggestions.dismiss(id, by: device())
                    done(.ok(summary: "The plan change is dismissed."))
                }
            },
        ]
    }
}

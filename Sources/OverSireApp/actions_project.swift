import Foundation
import OverSireCore
import OverSireAssistant

// The project actions. The north star is the vision entry of the project memory.
struct ProjectActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "project.northStar", title: "North star", help: "Gives the north star of a project: one short text about the goal of the work.",
                       kind: .read, input: ActionSpec.args(["project": EpicActions.project], required: ["project"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    guard let v = d.memory.vision(of: snap.summary.ref) else {
                        done(.ok(summary: "\(snap.summary.identifier) has no north star.")); return
                    }
                    done(.ok(summary: v.text, data: .object(["text": .string(v.text)])))
                }
            },
            ActionSpec(id: "project.setNorthStar", title: "Set north star", help: "Sets the north star of a project: 1 to \(MemoryDraft.maxText) characters.",
                       kind: .change, input: ActionSpec.args(["project": EpicActions.project, "text": ("string", "The north star text.")],
                                                              required: ["project", "text"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    let text: String
                    do { text = try ProjectMemory.clean(a.string("text") ?? "") } catch {
                        if case ProjectMemory.SaveError.tooLong(let n) = error {
                            done(.failed("A north star has at most \(MemoryDraft.maxText) characters. This one has \(n).")); return
                        }
                        done(.failed("\(error)")); return
                    }
                    guard !text.isEmpty else { done(.notAllowed("Give a text.")); return }
                    do { try d.memory.saveVision(text, of: snap.summary.ref) } catch { done(.failed("\(error)")); return }
                    let ident = snap.summary.identifier
                    d.projectStore.events.action(.projectNorthStarSet, item: nil, project: ident, verb: "north-star",
                                                 "North star of \(ident) set (\(text.count) characters)",
                                                 payload: ["project": .string(ident), "length": .int(text.count)],
                                                 actorType: a.caller.actor.type, actor: a.caller.actor.name)
                    done(.ok(summary: "The north star of \(ident) is set."))
                }
            },
        ]
    }
}

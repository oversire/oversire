import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The intake actions. They triage through ProjectStore.
struct IntakeActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        [
            triage("intake.accept", "Accept", "Accepts an intake item: it becomes a work item.", .change) { _ in .accept },
            triage("intake.decline", "Decline", "Declines an intake item.", .change) { _ in .decline },
            triage("intake.snooze", "Snooze", "Hides an intake item until a day at 9:00.", .change,
                   extra: ["days": ("integer", "Days from today. Default 1."), "until": ("string", "An ISO 8601 time, in place of days.")]) { a in
                if let t = a.string("until").flatMap({ ISO8601DateFormatter().date(from: $0) }) { return .snooze(until: t) }
                let d = Calendar.current.date(byAdding: .day, value: max(1, a.int("days") ?? 1), to: Date()) ?? Date()
                return .snooze(until: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d)
            },
            triage("intake.merge", "Mark as duplicate", "Marks an intake item as a duplicate of a work item.", .change,
                   extra: ["of": ("string", "The key or id of the work item that it duplicates.")], required: ["of"]) { a in
                nil
            },
            triage("intake.delete", "Delete", "Deletes an intake item and its work item. This cannot be undone.", .outward) { _ in .delete },
            triage("intake.edit", "Edit", "Writes the description or the priority of an intake item. The item stays in the intake.", .change,
                   extra: ["body": ("string", "The new description, in Markdown."), "priority": ("string", "The priority: urgent, high, medium, low or none.")]) { a in
                .update(IntakeEdit(patch: ItemPatch(priority: a.string("priority"), bodyMarkdown: a.string("body"))))
            },
            ActionSpec(id: "intake.triageAll", title: "Triage all with AI", help: "Starts the AI Enhance worker for each pending intake item of a project.", kind: .change,
                       input: ActionSpec.args(["project": ItemActions.project], required: ["project"]), capability: .intake) { [link] a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? ""), let items = snap.intake else {
                        done(.notAllowed("\(a.string("project") ?? "The project") has no intake.")); return
                    }
                    guard !items.isEmpty else { done(.ok(summary: "The intake of \(snap.summary.identifier) is empty.")); return }
                    items.forEach { d.enhanceAgent.start(projectKey: snap.summary.ref.storeKey, target: .intake($0)) }
                    done(.ok(summary: "The AI worker starts for \(items.count) intake item\(items.count == 1 ? "" : "s")."))
                }
            },
        ]
    }

    /// `action` gives nil when the action needs a lookup in the snapshot (intake.merge).
    private func triage(_ id: String, _ title: String, _ help: String, _ kind: ActionKind, extra: [String: (String, String)] = [:],
                        required: [String] = [], _ action: @escaping (ActionArgs) -> IntakeAction?) -> ActionSpec {
        let link = link
        var props = extra
        props["project"] = ItemActions.project
        props["id"] = ("string", "The intake item id.")
        return ActionSpec(id: id, title: title, help: help, kind: kind, input: ActionSpec.args(props, required: ["project", "id"] + required), capability: .intake) { a in
            await link.run { d, done in
                guard let snap = d.projectStore.snapshot(a.string("project") ?? ""),
                      let item = snap.intake?.first(where: { $0.id == a.string("id") || $0.workItemId == a.string("id") }) else {
                    done(.notAllowed("No pending intake item \(a.string("id") ?? "") in \(a.string("project") ?? "").")); return
                }
                var act = action(a)
                if act == nil, let of = a.string("of") {
                    guard let target = d.projectStore.item(key: of) ?? d.projectStore.item(of) else { done(.notAllowed("OverSire has no loaded item \(of).")); return }
                    act = .duplicate(of: target.item.id)
                }
                guard let act else { done(.notAllowed("Give the key of the work item.")); return }
                d.projectStore.triage(projectKey: snap.summary.ref.storeKey, item: item, action: act) {
                    done(ActionLink.stored(d, $0, "\(title): \(item.name)."))
                }
            }
        }
    }
}

extension IntakeAction {
    /// The catalog action of a triage. nil for an edit with relations or other fields: only the AI worker writes one.
    func action(project: String, id: String) -> (id: String, args: [String: JSONValue])? {
        var args: [String: JSONValue] = ["project": .string(project), "id": .string(id)]
        switch self {
        case .accept: return ("intake.accept", args)
        case .decline: return ("intake.decline", args)
        case .delete: return ("intake.delete", args)
        case .snooze(let t): args["until"] = .string(ISO8601DateFormatter().string(from: t)); return ("intake.snooze", args)
        case .duplicate(let of): args["of"] = .string(of); return ("intake.merge", args)
        case .update(let e):
            guard e.relations.isEmpty, e.patch == ItemPatch(priority: e.patch.priority, bodyMarkdown: e.patch.bodyMarkdown) else { return nil }
            if let b = e.patch.bodyMarkdown { args["body"] = .string(b) }
            if let p = e.patch.priority { args["priority"] = .string(p) }
            return ("intake.edit", args)
        }
    }
}

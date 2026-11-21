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
                if let t = a.string("until").flatMap({ isoFmt.date(from: $0) }) { return .snooze(until: t) }
                let d = Calendar.current.date(byAdding: .day, value: max(1, a.int("days") ?? 1), to: Date()) ?? Date()
                return .snooze(until: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d)
            },
            triage("intake.merge", "Mark as duplicate", "Marks an intake item as a duplicate of a work item.", .change,
                   extra: ["of": ("string", "The key or id of the work item that it duplicates.")], required: ["of"]) { a in
                nil
            },
            triage("intake.delete", "Delete", "Deletes an intake item and its work item. This cannot be undone.", .outward) { _ in .delete },
            triage("intake.edit", "Edit", "Writes the description, the priority, other fields or relations of an intake item. The item stays in the intake.", .change,
                   extra: ["body": ("string", "The new description, in Markdown."), "priority": ("string", "The priority: urgent, high, medium, low or none."),
                           "patch": ("object", "The change: ItemPatch. `body` and `priority` replace the same fields of it."),
                           "relations": ("array", "The relations to add: [ItemRelation].")],
                   objects: ["relations"]) { a in
                var patch = a["patch"].flatMap { try? MirrorCodec.value(ItemPatch.self, from: $0) } ?? ItemPatch()
                if let b = a.string("body") { patch.bodyMarkdown = b }
                if let p = a.string("priority") { patch.priority = p }
                let relations = a["relations"].flatMap { try? MirrorCodec.value([ItemRelation].self, from: $0) } ?? []
                return .update(IntakeEdit(patch: patch, relations: relations))
            },
            ActionSpec(id: "intake.create", title: "New intake item", help: "Makes an intake item in a project. Returns the key, the work item id, the url and the intake item.", kind: .change,
                       input: ActionSpec.args(["project": ItemActions.project, "title": ("string", "The title."), "body": ("string", "The Markdown description."),
                                               "priority": ("string", "A priority name.")], required: ["project", "title"]),
                       capability: .intakeCreate) { [link] a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else { done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return }
                    guard d.projectStore.has(.intakeCreate, in: snap) else { done(ActionLink.unsupported(snap, "intake")); return }
                    let draft = ItemDraft(title: a.string("title") ?? "", bodyMarkdown: a.string("body"), priority: a.string("priority"))
                    d.projectStore.createIntake(draft, projectKey: snap.summary.ref.storeKey, by: a.caller.actor) { r in
                        switch r {
                        case .failure(let e): done(.failed(e.message))
                        case .success(let made):
                            guard let intake = try? MirrorCodec.body(made.intake) else { done(.failed("The tracker gave an intake item that OverSire cannot read.")); return }
                            done(.ok(summary: "\(made.item.key) is in the intake.",
                                     data: .object(["key": .string(made.item.key), "id": .string(made.item.id), "url": .string(made.item.url.absoluteString), "intake": intake])))
                        }
                    }
                }
            },
            ActionSpec(id: "intake.triageAll", title: "Triage all with AI", help: "Starts an Enhance session for each pending intake item of a project.", kind: .change,
                       input: ActionSpec.args(["project": ItemActions.project], required: ["project"]), capability: .intake) { [link] a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? ""), let items = snap.intake else {
                        done(.notAllowed("\(a.string("project") ?? "The project") has no intake.")); return
                    }
                    guard !items.isEmpty else { done(.ok(summary: "The intake of \(snap.summary.identifier) is empty.")); return }
                    items.forEach { d.enhanceAgent.start(projectKey: snap.summary.ref.storeKey, target: .intake($0)) }
                    done(.ok(summary: "Enhance starts for \(items.count) intake item\(items.count == 1 ? "" : "s")."))
                }
            },
        ]
    }

    /// `action` gives nil when the action needs a lookup in the snapshot (intake.merge).
    private func triage(_ id: String, _ title: String, _ help: String, _ kind: ActionKind, extra: [String: (String, String)] = [:],
                        required: [String] = [], objects: [String] = [], _ action: @escaping (ActionArgs) -> IntakeAction?) -> ActionSpec {
        let link = link
        var props = extra
        props["project"] = ItemActions.project
        props["id"] = ("string", "The intake item id.")
        return ActionSpec(id: id, title: title, help: help, kind: kind, input: ActionSpec.args(props, required: ["project", "id"] + required, objects: objects), capability: .intake) { a in
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
    /// The catalog action of a triage. nil for `.pending`: only the undo of Groom uses it.
    /// A simple edit keeps `body` and `priority`. Other edits send `patch` and `relations`.
    func action(project: String, id: String) -> (id: String, args: [String: JSONValue])? {
        var args: [String: JSONValue] = ["project": .string(project), "id": .string(id)]
        switch self {
        case .accept: return ("intake.accept", args)
        case .decline: return ("intake.decline", args)
        case .delete: return ("intake.delete", args)
        case .pending: return nil
        case .snooze(let t): args["until"] = .string(isoFmt.string(from: t)); return ("intake.snooze", args)
        case .duplicate(let of): args["of"] = .string(of); return ("intake.merge", args)
        case .update(let e):
            let p = e.patch
            if e.relations.isEmpty, p == ItemPatch(priority: p.priority, bodyMarkdown: p.bodyMarkdown) {
                if let b = p.bodyMarkdown { args["body"] = .string(b) }
                if let x = p.priority { args["priority"] = .string(x) }
            } else {
                if !p.isEmpty, let v = try? MirrorCodec.body(p) { args["patch"] = v }
                if !e.relations.isEmpty, let v = try? JSONValue.encoded(e.relations) { args["relations"] = v }
            }
            return ("intake.edit", args)
        }
    }
}

extension JSONValue {
    /// Any value as JSON, also an array. `MirrorCodec.body` takes objects only.
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        JSONValue(any: try JSONSerialization.jsonObject(with: MirrorCodec.encoder().encode(value)))
    }
}

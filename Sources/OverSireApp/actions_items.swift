import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The tracker actions. They write through ProjectStore.
struct ItemActions {
    let link: ActionLink

    static let key = ("string", "The item key, for example OVERSIRE-12.")
    static let project = ("string", "The project identifier, for example OVERSIRE.")

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "item.setStatus", title: "Set status", help: "Sets the status of an item. Give the status name or id.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "status": ("string", "The status name, for example In Progress.")], required: ["key", "status"])) { a in
                await link.item(a) { d, f, done in
                    guard let o = f.snap.statusOptions.find(a.string("status") ?? "") else {
                        done(.notAllowed("\(f.snap.summary.identifier) has no status \(a.string("status") ?? ""). It has: \(f.snap.statusOptions.names)."))
                        return
                    }
                    d.projectStore.setStatus(itemId: f.item.id, optionId: o.id) { done(ActionLink.stored(d, $0, "\(f.item.key) is \(o.name).")) }
                }
            },
            ActionSpec(id: "item.setPriority", title: "Set priority", help: "Sets the priority of an item. Give the priority name or id.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "priority": ("string", "The priority name, for example high.")], required: ["key", "priority"])) { a in
                await link.item(a) { d, f, done in
                    let options = f.snap.fields.first { $0.id == ProjectSnapshot.priorityFieldId }?.options ?? []
                    guard let o = options.find(a.string("priority") ?? "") else {
                        done(.notAllowed("\(f.snap.summary.identifier) has no priority \(a.string("priority") ?? ""). It has: \(options.names)."))
                        return
                    }
                    d.projectStore.update(itemId: f.item.id, ItemPatch(priority: o.id), failure: "Could not change the priority") {
                        done(ActionLink.stored(d, $0, "\(f.item.key) has priority \(o.name)."))
                    }
                }
            },
            ActionSpec(id: "item.update", title: "Update item", help: "Changes the title or the parent of an item.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "title": ("string", "The new title."), "parent": ("string", "The key of the new parent item.")],
                                              required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    var patch = ItemPatch(title: a.string("title"))
                    if let p = a.string("parent") {
                        guard let parent = d.projectStore.item(key: p) else { done(.notAllowed("OverSire has no loaded item \(p).")); return }
                        patch.parent = parent.item.id
                    }
                    guard !patch.isEmpty else { done(.notAllowed("Give a title or a parent.")); return }
                    d.projectStore.update(itemId: f.item.id, patch, failure: "Could not change the item") { done(ActionLink.stored(d, $0, "\(f.item.key) is updated.")) }
                }
            },
            ActionSpec(id: "item.edit", title: "Edit item", help: "Sets the title and the Markdown description of an item.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "title": ("string", "The title. Empty keeps it."), "body": ("string", "The Markdown description.")],
                                              required: ["key", "body"])) { a in
                await link.item(a) { d, f, done in
                    let title = a.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? f.item.title
                    d.projectStore.edit(itemId: f.item.id, title: title, body: a.string("body") ?? "") { done(ActionLink.stored(d, $0, "\(f.item.key) is edited.")) }
                }
            },
            ActionSpec(id: "item.comment", title: "Comment", help: "Adds a Markdown comment to an item.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "body": ("string", "The Markdown comment.")], required: ["key", "body"])) { a in
                await link.item(a) { d, f, done in
                    guard let body = a.string("body"), !body.isEmpty else { done(.notAllowed("The comment is empty.")); return }
                    d.projectStore.comment(itemId: f.item.id, body: body) { done(ActionLink.stored(d, $0, "Comment added to \(f.item.key).")) }
                }
            },
            ActionSpec(id: "item.assignMe", title: "Assign to me", help: "Assigns the item to the developer.", kind: .change,
                       input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.assignMe(itemId: f.item.id) { done(ActionLink.stored(d, $0, "\(f.item.key) is assigned to you.")) }
                }
            },
            ActionSpec(id: "item.assign", title: "Assign", help: "Sets the assignees of an item. Give person ids from people.list.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "people": ("array", "Person ids. An empty list removes all assignees.")], required: ["key", "people"])) { a in
                await link.item(a) { d, f, done in
                    let ids = a.list("people")
                    d.projectStore.update(itemId: f.item.id, ItemPatch(assignees: ids), failure: "Could not assign the item") {
                        done(ActionLink.stored(d, $0, ids.isEmpty ? "\(f.item.key) has no assignee." : "\(f.item.key) is assigned."))
                    }
                }
            },
            ActionSpec(id: "item.start", title: "Start", help: "Sets the item to the first in-progress state and assigns it to the developer. It does not start an agent.",
                       kind: .change, input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.start(itemId: f.item.id) { done(ActionLink.stored(d, $0, "\(f.item.key) is in progress.")) }
                }
            },
            ActionSpec(id: "item.reopen", title: "Reopen", help: "Moves a done item back to in progress.", kind: .change,
                       input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.reopen(itemId: f.item.id) { done(ActionLink.stored(d, $0, "\(f.item.key) is open again.")) }
                }
            },
            ActionSpec(id: "item.closeSubItems", title: "Close sub-items", help: "Sets the open sub-items of an item to done, each with a comment. `keys` limits the list: keys or item ids.",
                       kind: .outward, input: ActionSpec.args(["key": Self.key, "keys": ("array", "The sub-item keys to close. Empty: all open sub-items.")], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    var ids = f.snap.openDescendants(of: f.item.id)
                    let only = Set(a.list("keys").map { $0.uppercased() })
                    if !only.isEmpty {
                        ids = ids.filter { id in only.contains(id.uppercased()) || f.snap.items.first { $0.id == id }.map { only.contains($0.key.uppercased()) } ?? false }
                    }
                    guard !ids.isEmpty else { done(.notAllowed("\(f.item.key) has no open sub-items to close.")); return }
                    d.projectStore.closeSubItems(ids, parentId: f.item.id) { done(ActionLink.stored(d, $0, "\(ids.count) sub-item\(ids.count == 1 ? "" : "s") of \(f.item.key) closed.")) }
                }
            },
            ActionSpec(id: "item.create", title: "New item", help: "Makes a work item in a project. Returns its key.", kind: .change,
                       input: ActionSpec.args(["project": Self.project, "title": ("string", "The title."), "body": ("string", "The Markdown description."),
                                               "status": ("string", "A status name."), "priority": ("string", "A priority name."),
                                               "parent": ("string", "The key of the parent item.")], required: ["project", "title"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else { done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return }
                    var options: [String: String] = [:]
                    if let s = a.string("status") {
                        guard let o = snap.statusOptions.find(s) else { done(.notAllowed("No status \(s). Use: \(snap.statusOptions.names).")); return }
                        options[ProjectSnapshot.statusFieldId] = o.id
                    }
                    if let p = a.string("priority") {
                        let list = snap.fields.first { $0.id == ProjectSnapshot.priorityFieldId }?.options ?? []
                        guard let o = list.find(p) else { done(.notAllowed("No priority \(p). Use: \(list.names).")); return }
                        options[ProjectSnapshot.priorityFieldId] = o.id
                    }
                    let parent = a.string("parent").flatMap { d.projectStore.item(key: $0) }
                    let new = NewItem(projectKey: snap.summary.ref.storeKey, title: a.string("title") ?? "", body: a.string("body") ?? "", fieldOptions: options)
                    d.projectStore.create(new) { ok, err in
                        guard ok, let id = d.projectStore.lastCreated, let made = d.projectStore.item(id) else { done(.failed(err ?? "The tracker did not make the item.")); return }
                        guard let parent else { done(.ok(summary: "\(made.item.key) is made.", data: .object(["key": .string(made.item.key)]))); return }
                        d.projectStore.update(itemId: id, ItemPatch(parent: parent.item.id), failure: "Could not set the parent") { _ in
                            done(.ok(summary: "\(made.item.key) is made under \(parent.item.key).", data: .object(["key": .string(made.item.key)])))
                        }
                    }
                }
            },
            ActionSpec(id: "item.relate", title: "Relate items", help: "Adds or removes a relation: blockedBy, blocks or relatesTo.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "kind": ("string", "blockedBy, blocks or relatesTo."), "other": ("string", "The key of the other item."),
                                               "remove": ("boolean", "True removes the relation.")], required: ["key", "kind", "other"]),
                       capability: .relations) { a in
                await link.item(a) { d, f, done in
                    guard let o = a.string("other"), let other = d.projectStore.item(key: o), let ref = other.item.ref(in: other.snap.summary.ref) else {
                        done(.notAllowed("OverSire has no loaded item \(a.string("other") ?? "").")); return
                    }
                    let rel = ItemRelation(kind: RelationKind(rawValue: a.string("kind") ?? "relatesTo"), item: ref)
                    let patch = a.bool("remove") == true ? RelationPatch(remove: [rel]) : RelationPatch(add: [rel])
                    d.projectStore.relate(itemId: f.item.id, patch) { done(ActionLink.stored(d, $0, "\(f.item.key) \(rel.kind) \(other.item.key).")) }
                }
            },
            ActionSpec(id: "item.setAreas", title: "Set code areas", help: "Sets the code areas of an item. The queue does not start two items with the same area at a time.",
                       kind: .change, input: ActionSpec.args(["key": Self.key, "areas": ("array", "Area names: lower-case letters, digits and hyphens.")], required: ["key", "areas"])) { a in
                await link.item(a) { d, f, done in
                    guard let ref = f.item.ref(in: f.snap.summary.ref) else { done(.failed("The item has no tracker ref.")); return }
                    let saved = d.areas.save(a.list("areas"), for: ref)
                    done(.ok(summary: saved.isEmpty ? "\(f.item.key) has no areas." : "\(f.item.key) areas: \(saved.joined(separator: ", ")).", data: .array(saved.map(JSONValue.string))))
                }
            },
            ActionSpec(id: "item.markRead", title: "Mark as read", help: "Clears the unread mark of an item.", kind: .change,
                       input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.markRead(itemId: f.item.id)
                    done(.ok(summary: "\(f.item.key) is read."))
                }
            },
            ActionSpec(id: "project.refresh", title: "Refresh project", help: "Loads a project again from the tracker.", kind: .change,
                       input: ActionSpec.args(["project": Self.project], required: ["project"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else { done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return }
                    d.projectStore.refresh([snap.summary.ref.storeKey], force: true) { done(ActionLink.stored(d, $0, "\(snap.summary.identifier) is loaded again.")) }
                }
            },
        ]
    }
}

extension ProjectStore {
    /// A snapshot by store key or by identifier.
    func snapshot(_ key: String) -> ProjectSnapshot? {
        snapshots[key] ?? snapshots.values.first { $0.summary.identifier.caseInsensitiveCompare(key) == .orderedSame }
    }
}

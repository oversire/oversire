import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The tracker actions. They write through ProjectStore.
struct ItemActions {
    let link: ActionLink

    static let key = ("string", "The item key, for example OVERSIRE-12.")
    static let project = ("string", "The project identifier, for example OVERSIRE.")
    static let relationKinds: [RelationKind] = [.blockedBy, .blocks, .relatesTo, .duplicate]
    /// The relation kind of a word, in any case.
    static func relationKind(_ word: String) -> RelationKind? { relationKinds.first { $0.rawValue.lowercased() == word.lowercased() } }
    /// The largest file of `item.attach`, in bytes.
    static let maxAttachBytes = 10 << 20
    static let startArg = ("string", "The start day as YYYY-MM-DD. `none` or an empty text removes it.")
    static let dueArg = ("string", "The due day as YYYY-MM-DD. `none` or an empty text removes it.")
    static let estimateArg = ("string", "The estimate in the units of the tracker, for example M for Big Timer. `none` or an empty text removes it.")
    static let worktreeArg = ("string", "The worktree group folder: a path relative to the workspace root, an absolute path, or a template with {key}. Default .wt/{key}.")
    static let machineArg = ("string", "The machine that holds the folder. Default: the machine that runs the sessions.")
    static let branchArg = ("string", "The planned branch. Default: the branch template of the project.")
    static let shareArg = ("boolean", "True: the sub-item works in the group of its parent.")

    static func bindRequest(_ a: ActionArgs) -> BindRequest {
        BindRequest(worktree: a.string("worktree"), machine: a.string("machine"), branch: a.string("branch"), shareParentGroup: a.bool("shareParentGroup") == true)
    }

    /// The day as YYYY-MM-DD. `none` and an empty text give an empty text, which removes the date. A bad day gives nil.
    static func day(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.lowercased() == "none" { return "" }
        let n = t.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard t.count == 10, n.count == 3, let date = Calendar.current.date(from: DateComponents(year: n[0], month: n[1], day: n[2])) else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return c.year == n[0] && c.month == n[1] && c.day == n[2] ? t : nil
    }

    struct Schedule {
        var startDate: String?
        var dueDate: String?
        var estimate: String?
        var isEmpty: Bool { startDate == nil && dueDate == nil && estimate == nil }
    }

    /// The `startDate`, `dueDate` and `estimate` args. A bad value or a tracker with no support gives the refusal.
    static func schedule(_ a: ActionArgs, _ d: AppData, _ snap: ProjectSnapshot) -> (Schedule, ActionResult?) {
        var out = Schedule()
        for name in ["startDate", "dueDate"] {
            guard let text = a.string(name) else { continue }
            guard let day = Self.day(text) else { return (out, .notAllowed("\(name) must be a date as YYYY-MM-DD.")) }
            guard d.projectStore.has(.dates, in: snap) else { return (out, ActionLink.unsupported(snap, "dates")) }
            if name == "startDate" { out.startDate = day } else { out.dueDate = day }
        }
        if let text = a.string("estimate") {
            guard d.projectStore.has(.estimate, in: snap) else { return (out, ActionLink.unsupported(snap, "estimates")) }
            let t = text.trimmingCharacters(in: .whitespaces)
            out.estimate = t.lowercased() == "none" ? "" : t
        }
        return (out, nil)
    }

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "item.setStatus", title: "Set status", help: "Sets the status of an item. Give the status name or id, "
                           + "or a category word: todo, progress, review, blocked or done. A parent with open sub-items does not close without `force`.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "status": ("string", "The status name, for example In Progress."),
                                               "force": ("boolean", "True closes a parent that has open sub-items."),
                                               "subItems": ("boolean", "True sets the open sub-items at all levels to the same status.")], required: ["key", "status"])) { a in
                await link.item(a) { d, f, done in
                    guard let o = f.snap.status(named: a.string("status") ?? "") else {
                        done(.notAllowed("\(f.snap.summary.identifier) has no status \(a.string("status") ?? ""). It has: \(f.snap.statusOptions.names)."))
                        return
                    }
                    let force = a.bool("force") ?? false
                    let n = f.snap.blockingSubItems(f.item, to: o.id)
                    guard force || n == 0 || a.bool("subItems") == true else {
                        done(.notAllowed(ProjectStore.openSubItemsReason(f.item.key, n) + " Set subItems to true (CLI: --sub-items), or set force to true."))
                        return
                    }
                    let finish = { (ok: Bool) in done(ActionLink.stored(d, ok, "\(f.item.key) is \(o.name).")) }
                    if a.bool("subItems") == true {
                        d.projectStore.setStatusWithSubItems(itemId: f.item.id, optionId: o.id, by: a.caller.actor, done: finish)
                    } else {
                        d.projectStore.setStatus(itemId: f.item.id, optionId: o.id, force: force, by: a.caller.actor, done: finish)
                    }
                }
            },
            ActionSpec(id: "item.setPriority", title: "Set priority", help: "Sets the priority of an item. Give the priority name or id.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "priority": ("string", "The priority name, for example high.")], required: ["key", "priority"]),
                       capability: .priority) { a in
                await link.item(a) { d, f, done in
                    guard f.snap.hasPriority else { done(.notAllowed("\(ENV.trackerName(f.snap.summary.ref.account)) has no priority.")); return }
                    let options = f.snap.fields.first { $0.id == ProjectSnapshot.priorityFieldId }?.options ?? []
                    guard let o = options.find(a.string("priority") ?? "") else {
                        done(.notAllowed("\(f.snap.summary.identifier) has no priority \(a.string("priority") ?? ""). It has: \(options.names)."))
                        return
                    }
                    d.projectStore.update(itemId: f.item.id, ItemPatch(priority: o.id), failure: "Could not change the priority", by: a.caller.actor) {
                        done(ActionLink.stored(d, $0, "\(f.item.key) has priority \(o.name)."))
                    }
                }
            },
            ActionSpec(id: "item.setLabels", title: "Set labels", help: "Sets the labels of an item. Give `labels` (ids or names) to set all of them, "
                           + "or give `add` and `remove` to change some. An empty `labels` list removes all labels.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "labels": ("array", "The label ids or names. They replace the labels of the item."),
                                               "add": ("array", "The label ids or names to add."), "remove": ("array", "The label ids or names to remove.")], required: ["key"]),
                       capability: .labels) { a in
                await link.item(a) { d, f, done in
                    guard d.projectStore.has(.labels, in: f.snap) else { done(ActionLink.unsupported(f.snap, "labels")); return }
                    let add = a.list("add"), remove = a.list("remove")
                    guard a["labels"] != nil || !add.isEmpty || !remove.isEmpty else { done(.notAllowed("Give labels, or add and remove.")); return }
                    guard a["labels"] == nil || (add.isEmpty && remove.isEmpty) else { done(.notAllowed("Give labels, or add and remove, not both.")); return }
                    d.projectStore.labels(projectKey: f.snap.summary.ref.storeKey) { r in
                        switch r {
                        case .failure(let e): done(.failed(e.message))
                        case .success(let all):
                            func ids(_ names: [String]) -> [String]? {
                                var out: [String] = []
                                for n in names {
                                    guard let l = all.find(n) else { done(.notAllowed("No label \(n). Use: \(all.names).")); return nil }
                                    if !out.contains(l.id) { out.append(l.id) }
                                }
                                return out
                            }
                            var target: [String]
                            if a["labels"] != nil {
                                guard let set = ids(a.list("labels")) else { return }
                                target = set
                            } else {
                                guard let adding = ids(add), let removing = ids(remove) else { return }
                                var current: [String] = []
                                for n in f.item.labels {
                                    guard let l = all.find(n) else {
                                        done(.notAllowed("\(f.item.key) has the label \(n), which \(f.snap.summary.identifier) does not list. Give labels to set all."))
                                        return
                                    }
                                    current.append(l.id)
                                }
                                target = current + adding.filter { !current.contains($0) }
                                target.removeAll { removing.contains($0) }
                            }
                            let names = target.compactMap { id in all.first { $0.id == id }?.name }
                            d.projectStore.update(itemId: f.item.id, ItemPatch(labels: target), failure: "Could not change the labels", by: a.caller.actor, labelNames: names) { ok in
                                guard ok else { done(ActionLink.stored(d, false, "")); return }
                                done(.ok(summary: names.isEmpty ? "\(f.item.key) has no labels." : "\(f.item.key) labels: \(names.joined(separator: ", ")).",
                                         data: .object(["labels": .array(names.map(JSONValue.string))])))
                            }
                        }
                    }
                }
            },
            ActionSpec(id: "item.update", title: "Update item", help: "Changes the title, the parent or other fields of an item, then adds relations. The parent `none` removes the parent.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "title": ("string", "The new title."),
                                               "parent": ("string", "The key of the new parent item. `none` or an empty text removes the parent."),
                                               "startDate": Self.startArg, "dueDate": Self.dueArg, "estimate": Self.estimateArg,
                                               "patch": ("object", "The change: ItemPatch. `title`, `parent`, `startDate`, `dueDate` and `estimate` replace the same fields of it."),
                                               "relations": ("array", "The relations to add: [ItemRelation].")],
                                              required: ["key"], objects: ["relations"])) { a in
                await link.item(a) { d, f, done in
                    var patch = a["patch"].flatMap { try? MirrorCodec.value(ItemPatch.self, from: $0) } ?? ItemPatch()
                    if let t = a.string("title") { patch.title = t }
                    let (when, refusal) = Self.schedule(a, d, f.snap)
                    if let refusal { done(refusal); return }
                    if let v = when.startDate { patch.startDate = v }
                    if let v = when.dueDate { patch.dueDate = v }
                    if let v = when.estimate { patch.estimate = v }
                    if let p = a.string("parent") {
                        guard d.projectStore.has(.subItems, in: f.snap) else { done(ActionLink.unsupported(f.snap, "sub-items")); return }
                        if p.isEmpty || p.lowercased() == "none" {
                            patch.parent = ""
                        } else {
                            guard let parent = d.projectStore.item(key: p) else { done(.notAllowed("OverSire has no loaded item \(p).")); return }
                            patch.parent = parent.item.id
                        }
                    }
                    let relations = a["relations"].flatMap { try? MirrorCodec.value([ItemRelation].self, from: $0) } ?? []
                    guard !patch.isEmpty || !relations.isEmpty else { done(.notAllowed("Give a title, a parent, a start, a due day, an estimate, a patch or relations.")); return }
                    let finish = { (ok: Bool) in done(ActionLink.stored(d, ok, "\(f.item.key) is updated.")) }
                    let relate = {
                        guard !relations.isEmpty else { finish(true); return }
                        d.projectStore.relate(itemId: f.item.id, RelationPatch(add: relations), by: a.caller.actor, done: finish)
                    }
                    guard !patch.isEmpty else { relate(); return }
                    d.projectStore.update(itemId: f.item.id, patch, failure: "Could not change the item", by: a.caller.actor) { $0 ? relate() : finish(false) }
                }
            },
            ActionSpec(id: "item.edit", title: "Edit item", help: "Sets the title, the Markdown description, the dates and the estimate of an item in one write. Only the given fields change.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "title": ("string", "The title. Empty keeps it."), "body": ("string", "The Markdown description."),
                                               "startDate": Self.startArg, "dueDate": Self.dueArg, "estimate": Self.estimateArg],
                                              required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    let (when, refusal) = Self.schedule(a, d, f.snap)
                    if let refusal { done(refusal); return }
                    let patch = ItemPatch(title: a.string("title").flatMap { $0.isEmpty ? nil : $0 }, bodyMarkdown: a.string("body"),
                                          startDate: when.startDate, dueDate: when.dueDate, estimate: when.estimate)
                    guard !patch.isEmpty else { done(.notAllowed("Give a title, a body, a start, a due day or an estimate.")); return }
                    d.projectStore.edit(itemId: f.item.id, patch, by: a.caller.actor) { done(ActionLink.stored(d, $0, "\(f.item.key) is edited.")) }
                }
            },
            ActionSpec(id: "item.comment", title: "Comment", help: "Adds a Markdown comment to an item.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "body": ("string", "The Markdown comment.")], required: ["key", "body"])) { a in
                await link.item(a) { d, f, done in
                    guard let body = a.string("body"), !body.isEmpty else { done(.notAllowed("The comment is empty.")); return }
                    d.projectStore.comment(itemId: f.item.id, body: body, by: a.caller.actor) { done(ActionLink.stored(d, $0, "Comment added to \(f.item.key).")) }
                }
            },
            ActionSpec(id: "item.assignMe", title: "Assign to me", help: "Assigns the item to the developer.", kind: .change,
                       input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.assignMe(itemId: f.item.id, by: a.caller.actor) { done(ActionLink.stored(d, $0, "\(f.item.key) is assigned to you.")) }
                }
            },
            ActionSpec(id: "item.favorite", title: "Favorite", help: "Adds the item to Favorites, or removes it. Favorites show first in each list.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "on": ("boolean", "False removes the item from Favorites. Default true.")], required: ["key"])) { a in
                await link.item(a) { _, f, done in
                    let on = a.bool("on") ?? true
                    guard let ref = f.item.ref(in: f.snap.summary.ref) else { done(.failed("The item \(f.item.key) has no link.")); return }
                    if FAVORITES.set(ref, on: on) {
                        EVENTS.action(on ? .itemFavorited : .itemUnfavorited, item: f.item.key, project: f.snap.summary.identifier, verb: "favorite",
                                      on ? "Added to Favorites" : "Removed from Favorites")
                    }
                    done(.ok(summary: on ? "\(f.item.key) is in Favorites." : "\(f.item.key) is not in Favorites."))
                }
            },
            ActionSpec(id: "item.assign", title: "Assign", help: "Sets the assignees of an item. Give person ids or names from project.people, or `me`.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "people": ("array", "Person ids, names or `me`. An empty list removes all assignees.")],
                                              required: ["key", "people"])) { a in
                await link.item(a) { d, f, done in
                    let wanted = a.list("people")
                    d.projectStore.options(projectKey: f.snap.summary.ref.storeKey) { options in
                        var ids: [String] = []
                        for w in wanted {
                            let id: String
                            if w.lowercased() == "me", let me = f.snap.meId {
                                id = me
                            } else if let m = options.members.find(w) {
                                id = m.id
                            } else if options.members.isEmpty {
                                id = w   // The tracker has no member list: keep the id as given.
                            } else {
                                done(.notAllowed("No person \(w) in \(f.snap.summary.identifier). Use: \(options.members.names)."))
                                return
                            }
                            if !ids.contains(id) { ids.append(id) }
                        }
                        d.projectStore.update(itemId: f.item.id, ItemPatch(assignees: ids), failure: "Could not assign the item", by: a.caller.actor) {
                            done(ActionLink.stored(d, $0, ids.isEmpty ? "\(f.item.key) has no assignee." : "\(f.item.key) is assigned."))
                        }
                    }
                }
            },
            ActionSpec(id: "item.start", title: "Start", help: "Sets the item to the first in-progress state and assigns it to the developer. It does not start an agent.",
                       kind: .change, input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.start(itemId: f.item.id, by: a.caller.actor) { done(ActionLink.stored(d, $0, "\(f.item.key) is in progress.")) }
                }
            },
            ActionSpec(id: "item.reopen", title: "Reopen", help: "Moves a done item back to in progress.", kind: .change,
                       input: ActionSpec.args(["key": Self.key], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    d.projectStore.reopen(itemId: f.item.id, by: a.caller.actor) { done(ActionLink.stored(d, $0, "\(f.item.key) is open again.")) }
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
            ActionSpec(id: "item.create", title: "New item", help: "Makes a work item in a project. Returns its key, id and url.", kind: .change,
                       input: ActionSpec.args(["project": Self.project, "title": ("string", "The title."), "body": ("string", "The Markdown description."),
                                               "status": ("string", "A status name, id or category word."), "priority": ("string", "A priority name."),
                                               "parent": ("string", "The key of the parent item."),
                                               "labels": ("array", "Label names. See project.labels."),
                                               "epic": ("string", "The epic id or title in the project."),
                                               "startDate": Self.startArg, "dueDate": Self.dueArg, "estimate": Self.estimateArg,
                                               "worktree": Self.worktreeArg, "machine": Self.machineArg, "branch": Self.branchArg,
                                               "shareParentGroup": Self.shareArg],
                                              required: ["project", "title"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else { done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return }
                    var options: [String: String] = [:]
                    if let s = a.string("status") {
                        guard let o = snap.status(named: s) else { done(.notAllowed("No status \(s). Use: \(snap.statusOptions.names).")); return }
                        options[ProjectSnapshot.statusFieldId] = o.id
                    }
                    if let p = a.string("priority") {
                        guard snap.hasPriority else { done(.notAllowed("\(ENV.trackerName(snap.summary.ref.account)) has no priority.")); return }
                        let list = snap.fields.first { $0.id == ProjectSnapshot.priorityFieldId }?.options ?? []
                        guard let o = list.find(p) else { done(.notAllowed("No priority \(p). Use: \(list.names).")); return }
                        options[ProjectSnapshot.priorityFieldId] = o.id
                    }
                    var parent: Item?
                    if let p = a.string("parent"), !p.isEmpty {
                        guard d.projectStore.has(.subItems, in: snap) else { done(ActionLink.unsupported(snap, "sub-items")); return }
                        guard let found = d.projectStore.item(key: p) else { done(.notAllowed("OverSire has no loaded item \(p).")); return }
                        parent = found.item
                    }
                    var epic: Epic?
                    if let text = a.string("epic") {
                        guard d.has(.epics), let e = snap.findEpic(text) else { done(.notAllowed(snap.unknownEpic(text))); return }
                        epic = e
                    }
                    let names = a.list("labels")
                    if !names.isEmpty, !d.projectStore.has(.labels, in: snap) { done(ActionLink.unsupported(snap, "labels")); return }
                    let (when, refusal) = Self.schedule(a, d, snap)
                    if let refusal { done(refusal); return }
                    let make = { (labelIds: [String]) in
                        let new = NewItem(projectKey: snap.summary.ref.storeKey, title: a.string("title") ?? "", body: a.string("body") ?? "",
                                          fieldOptions: options, labels: labelIds, parent: parent?.id, epic: epic?.id,
                                          startDate: when.startDate.flatMap { $0.isEmpty ? nil : $0 }, dueDate: when.dueDate.flatMap { $0.isEmpty ? nil : $0 },
                                          estimate: when.estimate.flatMap { $0.isEmpty ? nil : $0 })
                        d.projectStore.create(new, by: a.caller.actor) { r in
                            switch r {
                            case .failure(let e): done(.failed(e.message))
                            case .success(let m):
                                let note = parent.map { " under \($0.key)" } ?? ""
                                var data: [String: JSONValue] = ["key": .string(m.ref.key), "id": .string(m.ref.id), "url": .string(m.ref.url.absoluteString)]
                                var tail = ""
                                if let epic { tail = m.epicError.map { ". It is not in \(epic.title): \($0)" } ?? " in \(epic.title)" }
                                switch d.binder.bind(key: m.ref.key, title: a.string("title") ?? "", parent: parent?.key, project: snap.summary,
                                                     Self.bindRequest(a), source: .create, actor: a.caller.actor) {
                                case .success(let b): data["worktree"] = b.json
                                case .failure(let e): tail += ". No worktree binding: \(e.message.dropLast())"
                                }
                                done(.ok(summary: "\(m.ref.key) is made\(note)\(tail).", data: .object(data)))
                            }
                        }
                    }
                    guard !names.isEmpty else { make([]); return }
                    d.projectStore.labels(projectKey: snap.summary.ref.storeKey) { r in
                        switch r {
                        case .failure(let e): done(.failed(e.message))
                        case .success(let all):
                            var ids: [String] = []
                            for n in names {
                                guard let l = all.find(n) else { done(.notAllowed("No label \(n). Use: \(all.names).")); return }
                                if !ids.contains(l.id) { ids.append(l.id) }
                            }
                            make(ids)
                        }
                    }
                }
            },
            ActionSpec(id: "item.bindWorktree", title: "Bind worktree", help: "Sets the fixed worktree folder of an item. The daemon finds its review through it.",
                       kind: .change, input: ActionSpec.args(["key": Self.key, "worktree": Self.worktreeArg, "machine": Self.machineArg, "branch": Self.branchArg,
                                                             "shareParentGroup": Self.shareArg], required: ["key"])) { a in
                await link.item(a) { d, f, done in
                    let parent = f.item.parentId.flatMap { pid in f.snap.items.first { $0.id == pid }?.key }
                    switch d.binder.bind(key: f.item.key, title: f.item.title, parent: parent, project: f.snap.summary, Self.bindRequest(a),
                                         source: .link, actor: a.caller.actor) {
                    case .success(let b): done(.ok(summary: "\(f.item.key) works in \(b.group) on \(b.machine).", data: .object(["key": .string(f.item.key), "worktree": b.json])))
                    case .failure(let e): done(.notAllowed("No worktree binding for \(f.item.key): \(e.message)"))
                    }
                }
            },
            ActionSpec(id: "item.relate", title: "Relate items", help: "Adds or removes a relation: blockedBy, blocks, relatesTo or duplicate.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "kind": ("string", "blockedBy, blocks, relatesTo or duplicate."), "other": ("string", "The key of the other item."),
                                               "remove": ("boolean", "True removes the relation.")], required: ["key", "kind", "other"]),
                       capability: .relations) { a in
                await link.item(a) { d, f, done in
                    let word = a.string("kind") ?? ""
                    guard let kind = Self.relationKind(word) else {
                        done(.notAllowed("No relation kind \(word). Use: \(Self.relationKinds.map(\.rawValue).joined(separator: ", "))."))
                        return
                    }
                    guard d.projectStore.has(.relations, in: f.snap) else { done(ActionLink.unsupported(f.snap, "relations")); return }
                    guard let o = a.string("other"), let other = d.projectStore.item(key: o), let ref = other.item.ref(in: other.snap.summary.ref) else {
                        done(.notAllowed("OverSire has no loaded item \(a.string("other") ?? "").")); return
                    }
                    let rel = ItemRelation(kind: kind, item: ref)
                    let patch = a.bool("remove") == true ? RelationPatch(remove: [rel]) : RelationPatch(add: [rel])
                    d.projectStore.relate(itemId: f.item.id, patch, by: a.caller.actor) { done(ActionLink.stored(d, $0, "\(f.item.key) \(rel.kind) \(other.item.key).")) }
                }
            },
            ActionSpec(id: "item.link", title: "Add link", help: "Adds a web link to an item.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "url": ("string", "An http or https URL."), "title": ("string", "The link title. Default: the URL.")],
                                              required: ["key", "url"]),
                       capability: .links) { a in
                await link.item(a) { d, f, done in
                    let raw = a.string("url") ?? ""
                    guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else {
                        done(.notAllowed("Give an http or https URL.")); return
                    }
                    guard d.projectStore.has(.links, in: f.snap) else { done(ActionLink.unsupported(f.snap, "links")); return }
                    let title = a.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? raw
                    d.projectStore.addLink(itemId: f.item.id, url: url, title: title, by: a.caller.actor) { ok in
                        guard ok else { done(.failed(d.projectStore.lastError ?? "The tracker did not take the link.")); return }
                        d.projectStore.events.action(.itemLinkAdded, item: f.item.key, project: f.snap.summary.identifier, verb: "link", title,
                                                     payload: ["url": .string(raw), "title": .string(title)],
                                                     actorType: a.caller.actor.type, actor: a.caller.actor.name, via: a.caller.actor.via)
                        done(.ok(summary: "Link added to \(f.item.key)."))
                    }
                }
            },
            ActionSpec(id: "item.attach", title: "Attach file", help: "Uploads a file to an item. The file is base64 text of at most \(Self.maxAttachBytes >> 20) MB. "
                           + "For an item that is not loaded yet, give `project`, `id` and `url` too.", kind: .change,
                       input: ActionSpec.args(["key": Self.key, "name": ("string", "The file name."), "data": ("string", "The file bytes as base64."),
                                               "mimeType": ("string", "The media type. Default application/octet-stream."),
                                               "project": Self.project, "id": ("string", "The work item id. For an item that is not loaded."),
                                               "url": ("string", "The item URL. For an item that is not loaded.")],
                                              required: ["key", "name", "data"]),
                       capability: .attachments) { a in
                guard let key = a.string("key")?.uppercased(), !key.isEmpty else { return .notAllowed("Give the key of an item, for example OVERSIRE-12.") }
                return await link.run { d, done in
                    let snap: ProjectSnapshot, ref: ItemRef
                    if let f = d.projectStore.item(key: key) {
                        guard let r = f.item.ref(in: f.snap.summary.ref) else { done(.failed("The item has no tracker ref.")); return }
                        snap = f.snap
                        ref = r
                    } else if let p = a.string("project"), let id = a.string("id"), !id.isEmpty {
                        guard let s = d.projectStore.snapshot(p) else { done(.notAllowed("OverSire has no loaded project \(p).")); return }
                        snap = s
                        ref = ItemRef(project: s.summary.ref, id: id, key: key, url: a.string("url").flatMap(URL.init(string:)) ?? URL(string: s.summary.url) ?? URL(fileURLWithPath: "/"))
                    } else {
                        done(.notAllowed("OverSire has no loaded item \(key).")); return
                    }
                    guard d.projectStore.has(.attachments, in: snap) else { done(ActionLink.unsupported(snap, "attachments")); return }
                    guard let name = a.string("name"), !name.isEmpty else { done(.notAllowed("Give the file name.")); return }
                    guard let data = a.string("data").flatMap({ Data(base64Encoded: $0) }) else { done(.notAllowed("The data is not base64.")); return }
                    guard data.count <= Self.maxAttachBytes else {
                        done(.notAllowed("The file has \((data.count + (1 << 20) - 1) >> 20) MB. The limit is \(Self.maxAttachBytes >> 20) MB.")); return
                    }
                    let mime = a.string("mimeType").flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
                    d.projectStore.attach(AttachmentUpload(name: name, mimeType: mime, data: data), to: ref) { r in
                        switch r {
                        case .failure(let e): done(.failed(e.message))
                        case .success(let id):
                            d.projectStore.events.action(.itemAttachmentAdded, item: key, project: snap.summary.identifier, verb: "attach", name,
                                                         payload: ["attachment": .string(id), "name": .string(name), "size": .int(data.count), "mimeType": .string(mime)],
                                                         actorType: a.caller.actor.type, actor: a.caller.actor.name, via: a.caller.actor.via)
                            done(.ok(summary: "\(name) is attached to \(key).", data: .object(["id": .string(id)])))
                        }
                    }
                }
            },
            ActionSpec(id: "item.setAreas", title: "Set code areas", help: "Sets the code areas of an item. The queue does not start two items with the same area at a time.",
                       kind: .change, input: ActionSpec.args(["key": Self.key, "areas": ("array", "Area names: lower-case letters, digits and hyphens.")], required: ["key", "areas"])) { a in
                await link.item(a) { d, f, done in
                    guard let ref = f.item.ref(in: f.snap.summary.ref) else { done(.failed("The item has no tracker ref.")); return }
                    let saved = d.areas.save(a.list("areas"), for: ref)
                    d.projectStore.events.action(.itemAreasSet, item: f.item.key, project: f.snap.summary.identifier, verb: "areas",
                                                 saved.isEmpty ? "No areas" : saved.joined(separator: ", "), payload: ["areas": .array(saved.map(JSONValue.string))],
                                                 actorType: a.caller.actor.type, actor: a.caller.actor.name, via: a.caller.actor.via)
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
                    d.projectStore.refresh([snap.summary.ref.storeKey], force: true, priority: .user) { done(ActionLink.stored(d, $0, "\(snap.summary.identifier) is loaded again.")) }
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

extension ProjectStore {
    /// The tracker name of an item key or a project key. No match gives the names of all trackers.
    func trackerName(of key: String?) -> String {
        guard let key else { return ENV.trackerNames() }
        let snap = item(key: key)?.1 ?? snapshot(key)
        return snap.map { ENV.trackerName($0.summary.ref.account) } ?? ENV.trackerNames()
    }
}

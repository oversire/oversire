import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The intake actions. They triage through ProjectStore.
struct IntakeActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        [
            list,
            triage("intake.accept", "Accept", "Accepts an intake item: it becomes a work item.", .change) { _, _, _ in .accept },
            triage("intake.decline", "Decline", "Declines an intake item.", .change) { _, _, _ in .decline },
            triage("intake.snooze", "Snooze", "Hides an intake item until a day at 9:00.", .change,
                   extra: ["days": ("integer", "Days from today. Default 1."),
                           "until": ("string", "A day as YYYY-MM-DD (9:00 local time), or an ISO 8601 time, in place of days.")]) { a, _, _ in
                if let u = a.string("until") {
                    guard let t = Self.snoozeTime(u) else { throw IntakeArgError(message: "Give until as YYYY-MM-DD or an ISO 8601 time.") }
                    return .snooze(until: t)
                }
                let d = Calendar.current.date(byAdding: .day, value: max(1, a.int("days") ?? 1), to: Date()) ?? Date()
                return .snooze(until: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d)
            },
            triage("intake.merge", "Mark as duplicate", "Marks an intake item as a duplicate of a work item.", .change,
                   extra: ["of": ("string", "The key or id of the work item that it duplicates. An intake key also works.")], required: ["of"], refs: ["of"]) { _, refs, item in
                guard let keep = refs["of"] else { throw IntakeArgError(message: "Give the key of the work item.") }
                guard keep.id != item.workItemId else { throw IntakeArgError(message: "An item cannot duplicate itself.") }
                return .duplicate(of: keep.id)
            },
            triage("intake.delete", "Delete", "Deletes an intake item and its work item. This cannot be undone.", .outward) { _, _, _ in .delete },
            triage("intake.edit", "Edit", "Writes the description, the priority, other fields or relations of an intake item. The item stays in the intake.", .change,
                   extra: ["body": ("string", "The new description, in Markdown."), "priority": ("string", "The priority: urgent, high, medium, low or none."),
                           "patch": ("object", "The change: ItemPatch. `body` and `priority` replace the same fields of it."),
                           "relations": ("array", "The relations to add: [ItemRelation]."),
                           "parent": ("string", "The key of the parent item, or none to remove the parent."),
                           "kind": ("string", "With other: the relation to add: blockedBy, blocks, relatesTo or duplicate."),
                           "other": ("string", "With kind: the key of the other item.")],
                   objects: ["relations"], refs: ["parent", "other"]) { a, refs, _ in
                var patch = a["patch"].flatMap { try? MirrorCodec.value(ItemPatch.self, from: $0) } ?? ItemPatch()
                if let b = a.string("body") { patch.bodyMarkdown = b }
                if let p = a.string("priority") { patch.priority = p }
                if let p = a.string("parent") { patch.parent = p.lowercased() == "none" ? "" : refs["parent"]?.id }
                var relations = a["relations"].flatMap { try? MirrorCodec.value([ItemRelation].self, from: $0) } ?? []
                if a.string("kind") != nil || a.string("other") != nil {
                    guard let word = a.string("kind"), let other = refs["other"] else { throw IntakeArgError(message: "Give kind and other together.") }
                    guard let kind = ItemActions.relationKind(word) else {
                        throw IntakeArgError(message: "No relation kind \(word). Use: \(ItemActions.relationKinds.map(\.rawValue).joined(separator: ", ")).")
                    }
                    relations.append(ItemRelation(kind: kind, item: other))
                }
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

    // MARK: Lookup

    /// Runs `body` on the main thread and waits. Nil when the app closes.
    private func onMain<T>(_ body: @escaping (AppData, @escaping (T) -> Void) -> Void) async -> T? {
        await link.main(nil as T?) { d, done in body(d) { done($0) } }
    }

    private typealias Found = (snap: ProjectSnapshot, item: IntakeItem, key: String?)
    private enum Located { case found(Found), refused(ActionResult) }

    /// The project and the intake item of the `project` and `id` args.
    private func locate(_ a: ActionArgs) async -> Located {
        let project = a.string("project") ?? "", id = a.string("id") ?? ""
        let r: Located? = await onMain { d, done in
            guard let snap = d.projectStore.snapshot(project) else { done(.refused(.notAllowed("OverSire has no loaded project \(project)."))); return }
            guard d.projectStore.has(.intake, in: snap) else { done(.refused(ActionLink.unsupported(snap, "intake"))); return }
            d.projectStore.findIntake(id, projectKey: snap.summary.ref.storeKey) { r in
                switch r {
                case .success(let f): done(.found((snap, f.item, f.key)))
                case .failure(.notFound): done(.refused(.notAllowed("No intake item \(id) in \(project).")))
                case .failure(let e): done(.refused(.failed(e.message)))
                }
            }
        }
        return r ?? .refused(.failed("The app is closing."))
    }

    /// A loaded item, or an intake item, by key or id.
    private func ref(_ value: String, in snap: ProjectSnapshot) async -> ItemRef? {
        await onMain { d, done in
            if let f = d.projectStore.item(key: value) ?? d.projectStore.item(value) {
                done(f.item.ref(in: f.snap.summary.ref)); return
            }
            d.projectStore.findIntake(value, projectKey: snap.summary.ref.storeKey) { r in
                guard case .success(let f) = r else { done(nil); return }
                done(ItemRef(project: snap.summary.ref, id: f.item.workItemId, key: f.key ?? value,
                             url: URL(string: snap.summary.url) ?? URL(fileURLWithPath: "/")))
            }
        }.flatMap { $0 }
    }

    // MARK: List

    private var list: ActionSpec {
        ActionSpec(id: "intake.list", title: "List intake", help: "Lists the intake items of a project, or of all projects that have an intake. "
                   + "Give id for one item. detail adds the body and the labels.", kind: .read,
                   input: ActionSpec.args(["project": ItemActions.project, "status": ("string", "pending (default), snoozed or all. All is pending and snoozed."),
                                           "id": ("string", "One item: the intake item id, the work item id or the key."),
                                           "detail": ("boolean", "Add the body and the labels."), "limit": ("integer", "The most rows. Default 50, at most 200.")]),
                   capability: .intake) { [self] a in await readList(a) }
    }

    private func readList(_ a: ActionArgs) async -> ActionResult {
        let given = a.string("status"), id = a.string("id")
        var statuses: Set<IntakeStatus>
        switch (given ?? "pending").lowercased() {
        case "pending": statuses = [.pending]
        case "snoozed": statuses = [.snoozed]
        case "all": statuses = [.pending, .snoozed]
        default: return .notAllowed("No intake status \(given ?? ""). Use: pending, snoozed or all.")
        }
        if id != nil, given == nil { statuses = [.pending, .snoozed] }
        let want = statuses
        let limit = min(max(a.int("limit") ?? 50, 1), 200)
        let project = a.string("project")

        let picked: [ProjectSnapshot]? = await onMain { d, done in
            if let p = project {
                guard let s = d.projectStore.snapshot(p) else { done([]); return }
                done([s])
            } else {
                done(d.projectStore.snapshots.values.sorted { $0.summary.identifier < $1.summary.identifier })
            }
        }
        var snaps = picked ?? []
        if let project {
            guard let s = snaps.first else { return .notAllowed("OverSire has no loaded project \(project).") }
            guard await onMain({ d, done in done(d.projectStore.has(.intake, in: s)) }) == true else { return ActionLink.unsupported(s, "intake") }
        } else {
            var withIntake: [ProjectSnapshot] = []
            for s in snaps {
                if await onMain({ d, done in done(d.projectStore.has(.intake, in: s)) }) == true { withIntake.append(s) }
            }
            guard !withIntake.isEmpty else { return .notAllowed("\(ENV.trackerNames()) has no intake.") }
            snaps = withIntake
        }

        var all: [(snap: ProjectSnapshot, item: IntakeItem, key: String?)] = []
        for snap in snaps {
            let pk = snap.summary.ref.storeKey
            if let id {
                let r: Result<(item: IntakeItem, key: String?), ProviderError>? = await onMain { d, done in
                    d.projectStore.findIntake(id, projectKey: pk, statuses: want, done: done)
                }
                switch r {
                case .success(let f)?: all.append((snap, f.item, f.key))
                case .failure(let e)? where e != .notFound && snaps.count == 1: return .failed(e.message)
                default: continue
                }
                break
            }
            let r: Result<[IntakeItem], ProviderError>? = await onMain { d, done in d.projectStore.intakeItems(projectKey: pk, statuses: want, done: done) }
            guard case .success(let items)? = r else {
                if case .failure(let e)? = r, snaps.count == 1 { return .failed(e.message) }
                continue
            }
            let keys: [String?] = await onMain { d, done in
                d.projectStore.fillIntakeKeys(projectKey: pk, for: items) { done(items.map { d.projectStore.intakeKey(of: $0, in: snap) }) }
            } ?? []
            for (n, item) in items.enumerated() { all.append((snap, item, n < keys.count ? keys[n] : nil)) }
        }
        if let id, all.isEmpty { return .notAllowed("No intake item \(id) in \(project ?? "the loaded projects").") }
        all.sort { $0.item.createdAt < $1.item.createdAt }
        let shown = Array(all.prefix(limit))

        var details: [String: IntakeDetail] = [:]
        if a.bool("detail") == true {
            for snap in snaps {
                let items = shown.filter { $0.snap.summary.ref.storeKey == snap.summary.ref.storeKey }.map(\.item)
                guard !items.isEmpty else { continue }
                let pk = snap.summary.ref.storeKey
                let got: [String: IntakeDetail] = await onMain { d, done in d.projectStore.intakeDetails(projectKey: pk, items: items, done: done) } ?? [:]
                details.merge(got) { $1 }
            }
        }
        let rows: [JSONValue] = shown.map { s in
            var o: [String: JSONValue] = ["project": .string(s.snap.summary.identifier), "id": .string(s.item.id), "workItemId": .string(s.item.workItemId),
                                          "title": .string(s.item.name), "createdAt": .string(isoFmt.string(from: s.item.createdAt)),
                                          "status": .string((s.item.status ?? .pending).rawValue)]
            if let k = s.key { o["key"] = .string(k) }
            if let v = s.item.priority { o["priority"] = .string(v) }
            if let v = s.item.author { o["author"] = .string(v) }
            if let v = s.item.source { o["source"] = .string(v) }
            if let v = s.item.snoozedUntil { o["snoozedUntil"] = .string(isoFmt.string(from: v)) }
            if let d = details[s.item.workItemId] {
                o["body"] = .string(d.body)
                o["labels"] = .array(d.labels.map(JSONValue.string))
            }
            return .object(o)
        }
        return .ok(summary: "\(all.count) intake item\(all.count == 1 ? "" : "s").", data: .object(["items": .array(rows), "total": .int(all.count)]))
    }

    // MARK: Triage

    /// `action` gets the args, the items that `refs` name, and the intake item. It throws for a bad arg.
    private func triage(_ id: String, _ title: String, _ help: String, _ kind: ActionKind, extra: [String: (String, String)] = [:],
                        required: [String] = [], objects: [String] = [], refs: [String] = [],
                        _ action: @escaping (ActionArgs, [String: ItemRef], IntakeItem) throws -> IntakeAction?) -> ActionSpec {
        var props = extra
        props["project"] = ItemActions.project
        props["id"] = ("string", "The intake item id, the work item id or the key, for example OVERSIRE-12.")
        props["comment"] = ("string", "A comment for the work item, in Markdown. It goes first. When it fails, the item stays as it is.")
        return ActionSpec(id: id, title: title, help: help, kind: kind, input: ActionSpec.args(props, required: ["project", "id"] + required, objects: objects),
                          capability: .intake) { [self] a in
            let found: Found
            switch await locate(a) {
            case .refused(let r): return r
            case .found(let f): found = f
            }
            var named: [String: ItemRef] = [:]
            for name in refs {
                guard let value = a.string(name), !(name == "parent" && value.lowercased() == "none") else { continue }
                guard let r = await ref(value, in: found.snap) else { return .notAllowed("OverSire has no loaded item \(value).") }
                named[name] = r
            }
            let act: IntakeAction
            do {
                guard let x = try action(a, named, found.item) else { return .notAllowed("Give the key of the work item.") }
                act = x
            } catch let e as IntakeArgError {
                return .notAllowed(e.message)
            } catch {
                return .failed(error.localizedDescription)
            }
            let label = found.key.map { "\(title) \($0)" } ?? title
            return await onMain { d, done in
                d.projectStore.triage(projectKey: found.snap.summary.ref.storeKey, item: found.item, action: act, comment: a.string("comment"), by: a.caller.actor) {
                    done(ActionLink.stored(d, $0, "\(label): \(found.item.name)."))
                }
            } ?? .failed("The app is closing.")
        }
    }

    /// `until` as a time: ISO 8601, or YYYY-MM-DD at 9:00 local time.
    static func snoozeTime(_ text: String) -> Date? {
        if let t = parseISO(text) { return t }
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let day = f.date(from: text) else { return nil }
        return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)
    }
}

/// A bad arg of an intake action. The action answers with `notAllowed`.
struct IntakeArgError: Error { let message: String }

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

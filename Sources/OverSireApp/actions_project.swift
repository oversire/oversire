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
            ActionSpec(id: "project.statuses", title: "Statuses", help: "Lists the statuses of a project with their group and category. Returns [{id, name, group, category, color}].",
                       kind: .read, input: ActionSpec.args(["project": EpicActions.project], required: ["project"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    let rows = snap.statusOptions.map { o -> JSONValue in
                        var r: [String: JSONValue] = ["id": .string(o.id), "name": .string(o.name), "category": .string(o.category.rawValue), "color": .string(o.color)]
                        if let g = o.group { r["group"] = .string(g) }
                        return .object(r)
                    }
                    done(.ok(summary: "\(rows.count) statuses in \(snap.summary.identifier).", data: .array(rows)))
                }
            },
            ActionSpec(id: "project.labels", title: "Labels", help: "Lists the labels of a project. Returns [{id, name, color}].",
                       kind: .read, input: ActionSpec.args(["project": EpicActions.project], required: ["project"]), capability: .labels) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    guard d.projectStore.has(.labels, in: snap) else { done(ActionLink.unsupported(snap, "labels")); return }
                    d.projectStore.labels(projectKey: snap.summary.ref.storeKey) { r in
                        switch r {
                        case .failure(let e): done(.failed(e.message))
                        case .success(let list):
                            let rows = list.map { JSONValue.object(["id": .string($0.id), "name": .string($0.name), "color": .string($0.color)]) }
                            done(.ok(summary: "\(rows.count) labels in \(snap.summary.identifier).", data: .array(rows)))
                        }
                    }
                }
            },
            ActionSpec(id: "project.people", title: "Project people", help: "Lists the tracker members of a project. Use the ids or names with item.assign. Returns [{id, name, me}].",
                       kind: .read, input: ActionSpec.args(["project": EpicActions.project], required: ["project"])) { a in
                await link.run { d, done in
                    guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    guard d.projectStore.tracker(of: snap.summary.ref) is any MemberListing else {
                        done(.notAllowed("\(ENV.trackerName(snap.summary.ref.account)) has no member list.")); return
                    }
                    d.projectStore.options(projectKey: snap.summary.ref.storeKey) { options in
                        let rows = options.members.map { JSONValue.object(["id": .string($0.id), "name": .string($0.name), "me": .bool($0.id == snap.meId)]) }
                        done(.ok(summary: "\(rows.count) people in \(snap.summary.identifier).", data: .array(rows)))
                    }
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
                                                 actorType: a.caller.actor.type, actor: a.caller.actor.name, via: a.caller.actor.via)
                    done(.ok(summary: "The north star of \(ident) is set."))
                }
            },
            ActionSpec(id: "project.updateSettings", title: "Update project settings",
                       help: "Changes the settings of a project in its tracker: name, description, logo, lead, default assignee, visibility, features or new labels.",
                       kind: .change,
                       input: ActionSpec.args(["project": EpicActions.project, "patch": ("object", "The change: ProjectSettingsPatch. A missing key stays as it is. A null clears the logo, the lead or the default assignee.")],
                                              required: ["project", "patch"]),
                       capability: .projectSettingsEdit) { a in
                await link.run { d, done in
                    let store = d.projectStore
                    guard let snap = store.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    guard let v = a["patch"], let patch = try? MirrorCodec.value(ProjectSettingsPatch.self, from: v) else {
                        done(.notAllowed("Give a change.")); return
                    }
                    guard !patch.isEmpty else { done(.notAllowed("Give a change.")); return }
                    let ref = snap.summary.ref, name = ENV.trackerName(ref.account)
                    guard let t = store.tracker(of: ref) as? any ProjectSettingsEditing else { done(ActionLink.unsupported(snap, "project settings editing")); return }
                    if let field = patch.fields.sorted(by: { $0.rawValue < $1.rawValue }).first(where: { !t.editableSettings.contains($0) }) {
                        done(.notAllowed("\(name) cannot change \(field.label.lowercased()).")); return
                    }
                    let fields = patch.fields.map(\.rawValue).sorted()
                    CallPriority.task(.user) {
                        let r = await Result(awaiting: { try await t.update(ref, patch) })
                        DispatchQueue.main.async {
                            if case .failure(let e) = r { done(.failed(e.message)); return }
                            let ident = snap.summary.identifier
                            store.events.action(.projectSettingsChanged, item: nil, project: ident, verb: "settings",
                                                "Settings of \(ident) changed: \(fields.joined(separator: ", "))",
                                                payload: ["project": .string(ident), "fields": .array(fields.map(JSONValue.string))],
                                                actorType: a.caller.actor.type, actor: a.caller.actor.name, via: a.caller.actor.via)
                            store.refresh([ref.storeKey], force: true) { _ in }
                            done(.ok(summary: "Changed \(fields.joined(separator: ", ")) of \(ident) in \(name)."))
                        }
                    }
                }
            },
            ActionSpec(id: "project.catalogRefresh", title: "Refresh the project list",
                       help: "Fetches the projects of a tracker workspace again. A client app uses it for the picker of Track a project.", kind: .change,
                       input: ActionSpec.args(["workspace": ("string", "The tracker account id. Leave out to fetch all workspaces.")])) { a in
                await link.run { d, done in
                    let catalog = d.projectCatalog
                    let workspace = a.string("workspace")
                    if let workspace, !catalog.workspaces.contains(workspace) { done(.notAllowed("No workspace \(workspace).")); return }
                    let targets = workspace.map { [$0] } ?? catalog.workspaces
                    final class Token { var observer: Any? }
                    let token = Token()
                    token.observer = NotificationCenter.default.addObserver(forName: ProjectCatalog.changed, object: catalog, queue: .main) { _ in
                        var loading = false, failure: String?
                        for w in targets {
                            switch catalog.fetch(w) {
                            case .loading: loading = true
                            case .failed(let m): failure = failure ?? m
                            case .idle: break
                            }
                        }
                        guard !loading else { return }
                        token.observer.map(NotificationCenter.default.removeObserver)
                        token.observer = nil
                        done(failure.map(ActionResult.failed) ?? .ok(summary: "Fetched \(targets.count) workspace\(targets.count == 1 ? "" : "s")."))
                    }
                    if let workspace { catalog.refresh(workspace, force: true) } else { catalog.refreshAll(force: true) }
                }
            },
        ]
    }
}

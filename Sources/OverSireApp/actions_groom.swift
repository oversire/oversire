import Foundation
import OverSireAI
import OverSireAssistant
import OverSireCore

// The Groom writes. They run on the home, because the journal lives there (OVERSIRE-537).
struct GroomActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "groom.apply", title: "Apply Groom", help: "Writes the lines of a Groom review to the tracker, one item at a time. Returns {outcome, undoable}.",
                       kind: .change,
                       input: ActionSpec.args(["project": ItemActions.project, "lines": ("array", "The lines to write: [GroomResult.Proposal]."),
                                               "intake": ("object", "The intake item of each intake key: {KEY: IntakeItem}."),
                                               "begin": ("boolean", "True starts a new journal for Undo. False adds to the last one.")],
                                              required: ["project", "lines"], objects: ["lines"])) { a in
                await link.run { d, done in
                    let store = d.projectStore
                    guard let snap = store.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    let ref = snap.summary.ref, pk = ref.storeKey
                    guard store.has(.intake, in: snap), let tracker = store.tracker(of: ref) else { done(ActionLink.unsupported(snap, "intake")); return }
                    guard let v = a["lines"], let lines = try? MirrorCodec.value([GroomResult.Proposal].self, from: v) else { done(.notAllowed("Give the lines.")); return }
                    let intake = a["intake"].flatMap { try? MirrorCodec.value([String: IntakeItem].self, from: $0) } ?? [:]
                    let agent = d.groomAgent, journal = agent.journal, begin = a.bool("begin") ?? true, now = agent.now
                    let applier = GroomApplier(tracker: tracker, snapshot: snap, targets: GroomAgent.targets(snap, intake: intake, url: store.intakeURL(of: snap)),
                                               journal: journal, projectKey: pk)
                    Task {
                        if begin { await journal.begin(pk, project: ref, at: now()) }
                        let out = await applier.apply(lines)
                        let undoable = await journal.last(pk) != nil
                        await MainActor.run {
                            for p in lines where out.written.contains(p.id) { Self.row(p, in: snap, by: a.caller.actor, store) }
                            store.refreshAfterWrite(pk, priority: .background)
                            guard let body = try? MirrorCodec.body(out) else { done(.failed("OverSire cannot read the result of Groom.")); return }
                            done(.ok(summary: "Groom wrote \(out.written.count) of \(lines.count) lines in \(snap.summary.identifier).",
                                     data: .object(["outcome": body, "undoable": .bool(undoable)])))
                        }
                    }
                }
            },
            ActionSpec(id: "groom.undo", title: "Undo Groom", help: "Puts back the items that the last Groom of a project changed. The Groom comments stay. Returns {undone, left, failed}.",
                       kind: .change, input: ActionSpec.args(["project": ItemActions.project], required: ["project"])) { a in
                await link.run { d, done in
                    let store = d.projectStore
                    guard let snap = store.snapshot(a.string("project") ?? "") else {
                        done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                    }
                    let ref = snap.summary.ref, ident = snap.summary.identifier
                    guard let tracker = store.tracker(of: ref) else { done(ActionLink.unsupported(snap, "intake")); return }
                    let journal = d.groomAgent.journal
                    Task {
                        guard await journal.last(ref.storeKey) != nil else {
                            await MainActor.run { done(.notAllowed("No Groom to undo in \(ident).")) }
                            return
                        }
                        let out = await journal.undo(ref.storeKey, tracker: tracker)
                        await MainActor.run {
                            store.events.action(.groomUndone, item: nil, project: ident, verb: "groom",
                                                "Groom of \(ident) undone: \(out.undone.count) put back, \(out.left.count) left",
                                                payload: ["project": .string(ident), "undone": .int(out.undone.count), "left": .int(out.left.count)],
                                                actorType: a.caller.actor.type, actor: a.caller.actor.name, via: a.caller.actor.via)
                            store.refreshAfterWrite(ref.storeKey, priority: .background)
                            guard let body = try? MirrorCodec.body(out) else { done(.failed("OverSire cannot read the result of Undo.")); return }
                            done(.ok(summary: "Undo put back \(out.undone.count) item\(out.undone.count == 1 ? "" : "s") in \(ident).", data: body))
                        }
                    }
                }
            },
        ]
    }

    /// One `groom.applied` row for a written line. The agent is Groom, and the app of the caller is the channel.
    private static func row(_ p: GroomResult.Proposal, in snap: ProjectSnapshot, by caller: EventActor, _ store: ProjectStore) {
        let ident = snap.summary.identifier
        let item = (p.keep ?? p.keys.first)?.uppercased()
        var payload: [String: JSONValue] = ["kind": .string(p.kind.rawValue)]
        if let keep = p.keep { payload["keep"] = .string(keep) }
        if let parent = p.parent { payload["parent"] = .string(parent) }
        if let r = p.relation { payload["relation"] = .object(["kind": .string(r.kind), "key": .string(r.key)]) }
        if !p.evidence.isEmpty { payload["evidence"] = .array(p.evidence.prefix(6).map(JSONValue.string)) }
        let summary: String
        switch p.kind {
        case .merge: summary = "Merged into \(p.keep ?? item ?? ident)"
        case .done: summary = "Done: \(p.reason)"
        case .obsolete: summary = "Obsolete: \(p.reason)"
        case .fold: summary = "Folded under \(p.parent ?? ident)"
        default: summary = "Related to \(p.relation?.key ?? ident)"
        }
        store.events.action(.groomApplied, item: item, project: ident, verb: "groom-\(p.kind.rawValue)", String(summary.prefix(EventDraft.maxSummary)),
                            payload: payload, actorType: .agent, actor: "groom", via: caller.via)
    }
}

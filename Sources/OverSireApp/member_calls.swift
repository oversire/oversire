import Foundation
import OverSireAssistant
import OverSireCore

// The clicks of a client (app-call.json MemberCall). The home daemon sends each call on the WebSocket of the source app.
// The source app runs the action as the member, sends the data to the mirror, and then posts the result (OVERSIRE-528).

struct MemberCalls {
    /// Actions that run on the Mac where you click. A client never sends them.
    /// They change this Mac, read the mirror that this Mac holds, or read the daemons directly.
    static let local: Set<String> = [
        "page.current", "page.navigate", "machine.list", "machine.mode", "cloud.status",
        "session.list", "session.history", "session.tail", "session.reveal", "item.favorite", "item.markRead",
        "item.get", "item.list", "activity.list", "pr.get", "pr.list", "run.get", "run.list", "insights.summary",
    ]

    /// Runs the call. Then it sends the changes to the mirror, so the client finds them when it pulls.
    func handle(_ c: MemberCall, actions: any ActionCatalog, flush: () async -> Void) async -> AppCallResult {
        if Self.local.contains(c.action) {
            return AppCallResult(id: c.id, status: .notAllowed, summary: "\(c.action) runs only on the Mac where you click it.")
        }
        let caller = ActionCaller.member(machine: c.from.machine, name: c.from.name)
        let r = await actions.run(c.action, ActionArgs(c.args, caller: caller))
        let out: AppCallResult
        switch r {
        case .ok(let summary, let data, _): out = AppCallResult(id: c.id, status: .ok, summary: summary, data: data)
        case .failed(let m):
            let conflict = c.action == "settings.patch" && m.hasPrefix("Changed on ")
            out = AppCallResult(id: c.id, status: .failed, summary: m, data: conflict ? .object(["conflict": .bool(true)]) : nil)
        case .notAllowed(let m): out = AppCallResult(id: c.id, status: .notAllowed, summary: m)
        }
        if out.status == .notAllowed { log.info("member call refused id=\(c.id, privacy: .public) from=\(c.from.machine, privacy: .public)") }
        await flush()
        return out
    }
}

/// The body of an answer to `mirror.read`: one object with the rows.
struct MirrorRows<T: Codable & Sendable>: Codable, Sendable {
    var rows: T
}

/// The actions that only a client uses: its reads of a live tracker, and its refresh.
struct MemberActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "mirror.read", title: "Read from the tracker",
                       help: "Reads comments, the timeline, options, intake details, labels or links of the tracker, for a client app.", kind: .read,
                       input: ActionSpec.args(["what": ("string", "comments, timeline, options, intakeDetail, labels or links."),
                                               "project": ("string", "The store key of the project."), "item": ("string", "The key or id of the item."),
                                               "intake": ("object", "The intake item, for intakeDetail.")], required: ["what"])) { a in
                await link.main(.failed("The app is closing.")) { d, done in Self.read(a, d, done) }
            },
            ActionSpec(id: "app.refresh", title: "Refresh the app", help: "Loads all data again from the providers, for a client app.", kind: .change) { _ in
                await link.main(.failed("The app is closing.")) { d, done in
                    d.refresh(force: true) { done(.ok(summary: "Loaded again.")) }
                }
            },
        ]
    }

    private static func rows<T: Codable & Sendable>(_ r: Result<T, ProviderError>, _ done: (ActionResult) -> Void) {
        switch r {
        case .success(let v):
            guard let body = try? MirrorCodec.body(MirrorRows(rows: v)) else { done(.failed("Could not encode the answer.")); return }
            done(.ok(summary: "Read.", data: body))
        case .failure(let e): done(.failed(e.message))
        }
    }

    private static func read(_ a: ActionArgs, _ d: AppData, _ done: @escaping (ActionResult) -> Void) {
        let store = d.projectStore
        let project = a.string("project") ?? "", item = a.string("item") ?? ""
        switch a.string("what") {
        case "comments": store.comments(key: item) { rows($0, done) }
        case "timeline":
            guard let id = (store.item(item) ?? store.item(key: item))?.item.id else { done(.notAllowed("OverSire has no loaded item \(item).")); return }
            store.timelineRead(itemId: id) { rows($0, done) }
        case "options": store.options(projectKey: project) { rows(.success($0), done) }
        case "labels": store.labels(projectKey: project) { rows($0, done) }
        case "links":
            guard let id = (store.item(item) ?? store.item(key: item))?.item.id else { done(.notAllowed("OverSire has no loaded item \(item).")); return }
            store.links(itemId: id) { rows(.success($0), done) }
        case "intakeDetail":
            guard let v = a["intake"], let i = try? MirrorCodec.value(IntakeItem.self, from: v) else { done(.notAllowed("Give the intake item.")); return }
            store.intakeDetail(projectKey: project, item: i) { rows($0, done) }
        default: done(.notAllowed("mirror.read has no read \(a.string("what") ?? "")."))
        }
    }
}

import Cocoa
import OverSireCore
import OverSireAssistant

/// A status change from the UI. A close of a parent with open sub-items asks first (OVERSIRE-396).
struct CloseGuard {
    let actions: AppActionCatalog
    let store: ProjectStore

    enum Choice: Int { case closeSubItems, force, cancel }

    static func spec(key: String, state: String, open n: Int) -> AlertConfirm.Spec {
        AlertConfirm.Spec(title: "\(key) has \(n) open sub-item\(n == 1 ? "" : "s")",
                          info: "\(state) closes \(key). Close the open sub-item\(n == 1 ? "" : "s") too, or close \(key) anyway and keep \(n == 1 ? "it" : "them") open.",
                          buttons: ["Close sub-item\(n == 1 ? "" : "s") too", "Close anyway", "Cancel"], style: .warning)
    }

    /// Runs item.setStatus. `status` is a name or an id. Cancel gives `.ok`.
    func setStatus(key: String, status: String, in window: NSWindow?, done: @escaping (ActionResult) -> Void) {
        let args: [String: JSONValue] = ["key": .string(key), "status": .string(status)]
        guard let f = store.item(key: key), let o = f.snap.statusOptions.find(status) else {
            actions.run("item.setStatus", args, done: done); return
        }
        let n = f.snap.blockingSubItems(f.item, to: o.id)
        guard n > 0 else { actions.run("item.setStatus", args, done: done); return }
        let actions = actions
        AlertConfirm.show(Self.spec(key: f.item.key, state: o.name, open: n), in: window) { a in
            switch Choice(rawValue: a.button) ?? .cancel {
            case .closeSubItems:
                actions.run("item.closeSubItems", ["key": .string(key)]) { r in
                    guard case .ok = r else { done(r); return }
                    actions.run("item.setStatus", args, done: done)
                }
            case .force: actions.run("item.setStatus", args.merging(["force": .bool(true)]) { a, _ in a }, done: done)
            case .cancel: done(.ok(summary: "\(f.item.key) did not change."))
            }
        }
    }
}

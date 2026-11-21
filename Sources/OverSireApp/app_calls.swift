import Foundation
import OverSireCore
import OverSireAssistant

// The `oversire` commands that the app runs (app-call.json). The local daemon sends each call on its WebSocket.
// The app runs only the actions of `allowed`, with no confirm. The event rows name the agent as the actor.
// Some of them leave the Mac (ci.dispatch, ci.approve). The agent rights of CIOps guard them.
final class AppCalls: @unchecked Sendable {
    static let allowed: Set<String> = [
        "item.get", "item.list", "item.history", "item.markdown", "item.setEpic", "epic.list", "epic.show", "epic.plan", "epic.create", "epic.update", "epic.close", "epic.addItems", "epic.removeItems",
        "project.northStar", "project.setNorthStar",
        "item.setStatus", "item.setPriority", "item.update", "item.edit", "item.comment", "item.assignMe", "item.assign", "item.start", "item.reopen",
        "item.create", "item.relate", "item.link", "item.attach", "project.statuses", "project.labels", "project.people", "search.all",
        "ci.log", "ci.jobs", "ci.workflows", "ci.refresh", "ci.explain",
        "ci.rerun", "ci.rerunJob", "ci.cancel", "ci.dispatch", "ci.approve",
        "vendor.list", "vendor.run", "vendor.skill",
        "item.setLabels", "item.setAreas", "project.addLabel", "project.refresh", "intake.create", "intake.list", "intake.accept", "intake.decline", "intake.snooze", "intake.merge", "intake.edit", "people.list", "activity.list",
    ]

    private let catalog: any ActionCatalog
    private let vendor: VendorCalls?
    private let post: @Sendable (AppCallResult) async throws -> Void

    /// `post` sends the result to the daemon that sent the call. `vendor` runs the vendor CLI calls. Not in the catalog.
    init(catalog: any ActionCatalog, vendor: VendorCalls? = nil, post: @escaping @Sendable (AppCallResult) async throws -> Void) {
        self.catalog = catalog
        self.vendor = vendor
        self.post = post
    }

    /// A failed post is only logged: the daemon times out the call.
    func handle(_ call: AppCall) async {
        let r = await run(call)
        do { try await post(r) } catch { log.error("app call \(call.id, privacy: .public) \(call.action, privacy: .public): the result did not post: \(error.localizedDescription, privacy: .public)") }
    }

    func run(_ call: AppCall) async -> AppCallResult {
        guard Self.allowed.contains(call.action) else {
            return AppCallResult(id: call.id, status: .notAllowed, summary: "The app does not run \(call.action) from the CLI.")
        }
        if VendorCalls.actions.contains(call.action) {
            guard let vendor else { return AppCallResult(id: call.id, status: .notAllowed, summary: "The app does not run \(call.action) from the CLI.") }
            return await vendor.handle(call)
        }
        switch await catalog.run(call.action, ActionArgs(call.args, caller: .cli(agent: call.agent))) {
        case .ok(let summary, let data, _): return AppCallResult(id: call.id, status: .ok, summary: summary, data: data)
        case .failed(let m): return AppCallResult(id: call.id, status: .failed, summary: m)
        case .notAllowed(let m): return AppCallResult(id: call.id, status: .notAllowed, summary: m)
        }
    }
}

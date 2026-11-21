import Foundation
import GitHubKit
import OverSireCore

// The CI writes of the app. One path for the action catalog, the CLI and member calls.

enum CIOpError: Error, Equatable {
    /// The repo is not in REPOS.
    case untracked(String)
    case unsupported(ci: String, what: String)
    /// The agent setting is off.
    case agentRefused(String)
    /// Bad input, or the run state does not permit the action.
    case invalid(String)
    /// The text of a `ProviderError`.
    case vendor(String)

    var text: String {
        switch self {
        case .untracked(let repo): return "OverSire does not track \(repo). Add the repo in Settings › Code hosts."
        case .unsupported(let ci, let what): return "\(ci) has no \(what)."
        case .agentRefused(let m), .invalid(let m), .vendor(let m): return m
        }
    }
}

actor CIOps {
    static let rerunWindow: TimeInterval = 60
    static let dispatchWindow: TimeInterval = 30
    /// GitHub accepts at most 25 inputs for a workflow_dispatch.
    static let maxInputs = 25

    private let accounts: any RepoAccounts
    private let rights: @Sendable () -> AgentCIRights
    private let tracked: @Sendable () -> Set<String>
    private let desk: @Sendable () -> EventDesk?
    private let refresh: @Sendable (String) async -> Void
    private let now: @Sendable () -> Date
    private let ciName: @Sendable (any Provider) -> String

    private var flights: [String: Task<CIActionResult, Error>] = [:]
    private var reruns: [String: (at: Date, result: CIActionResult)] = [:]
    private var dispatches: [String: (at: Date, result: CIActionResult?)] = [:]

    init(accounts: any RepoAccounts,
         rights: @escaping @Sendable () -> AgentCIRights,
         tracked: @escaping @Sendable () -> Set<String>,
         desk: @escaping @Sendable () -> EventDesk?,
         refresh: @escaping @Sendable (String) async -> Void,
         now: @escaping @Sendable () -> Date = { Date() },
         ciName: @escaping @Sendable (any Provider) -> String = { ENV.descriptor($0.account)?.displayName ?? $0.account.provider.rawValue }) {
        self.accounts = accounts
        self.rights = rights
        self.tracked = tracked
        self.desk = desk
        self.refresh = refresh
        self.now = now
        self.ciName = ciName
    }

    // MARK: Rerun

    func rerun(repo: String, run: String, failedOnly: Bool, by: EventActor) async throws -> CIActionResult {
        let ci = try provider(repo)
        guard ci.capabilities.contains(.rerun) else { throw CIOpError.unsupported(ci: ciName(ci), what: "rerun") }
        return try await rerunOnce(repo, run, ci: ci, by: by, done: "Run \(run) runs again.",
                                   check: { before in
                                       if failedOnly, before.outcome == .success { throw CIOpError.invalid("Run \(run) has no failed jobs.") }
                                   },
                                   write: { ref in try await ci.perform(failedOnly ? .rerunFailed : .rerun, on: ref) })
    }

    func rerunJob(repo: String, run: String, job: String, by: EventActor) async throws -> CIActionResult {
        let ci = try provider(repo)
        guard ci.capabilities.contains(.rerunJob), let jr = ci as? any JobRerunning else {
            throw CIOpError.unsupported(ci: ciName(ci), what: "job rerun")
        }
        return try await rerunOnce(repo, run, ci: ci, by: by, done: "Job \(job) runs again.", check: { _ in },
                                   write: { ref in try await jr.rerun(JobRef(run: ref, id: job)) })
    }

    /// The rerun, and the de-dup that `rerun`, `rerun --failed` and `rerunJob` share.
    private func rerunOnce(_ repo: String, _ run: String, ci: any CIProvider, by: EventActor, done: String,
                           check: @escaping @Sendable (Run) throws -> Void,
                           write: @escaping @Sendable (RunRef) async throws -> Void) async throws -> CIActionResult {
        let key = "rerun|\(repo)|\(run)"
        if let flight = flights[key] {
            var r = try await flight.value
            r.noop = true
            r.summary = "Run \(run) is already rerun. No new rerun."
            return r
        }
        if let last = reruns[key], now().timeIntervalSince(last.at) < Self.rerunWindow {
            var r = last.result
            r.noop = true
            r.summary = "Run \(run) was rerun a moment ago. No new rerun."
            return r
        }
        let flight = Task { [self] () throws -> CIActionResult in
            let ref = RepoClient.runRef(ci, repo, id: run)
            let before = try await call { try await ci.run(ref) }
            let view = CIRunView(before)
            guard before.phase == .completed else {
                return CIActionResult(ok: true, noop: true, summary: "Run \(run) attempt \(view.attempt) is already running. No new rerun.",
                                      run: view, url: before.url)
            }
            try check(before)
            try await call { try await write(ref) }
            let result = CIActionResult(ok: true, noop: false, summary: done, run: view, url: before.url)
            reruns[key] = (now(), result)
            let desk = desk
            await MainActor.run { desk()?.ciRerunBy(repo: repo, run: run, attempt: view.attempt + 1, actor: by) }
            await refresh(repo)
            return result
        }
        flights[key] = flight
        defer { flights[key] = nil }
        return try await flight.value
    }

    // MARK: Cancel

    func cancel(repo: String, run: String, by: EventActor) async throws -> CIActionResult {
        let ci = try provider(repo)
        if by.type == .agent, !rights().cancel {
            throw CIOpError.agentRefused("Agents may not cancel runs. Turn it on in Settings › Agents › CI.")
        }
        guard ci.capabilities.contains(.cancel) else { throw CIOpError.unsupported(ci: ciName(ci), what: "cancel") }
        let ref = RepoClient.runRef(ci, repo, id: run)
        let before = try await call { try await ci.run(ref) }
        let view = CIRunView(before)
        guard before.phase != .completed else {
            return CIActionResult(ok: true, noop: true, summary: "Run \(run) is finished already. Nothing to cancel.", run: view, url: before.url)
        }
        try await call { try await ci.perform(.cancel, on: ref) }
        await refresh(repo)
        await record(.ciCancelled, verb: "cancelled", repo: repo, run: before, attempt: view.attempt, by: by, extra: [:])
        return CIActionResult(ok: true, noop: false, summary: "Run \(run) is cancelled.", run: view, url: before.url)
    }

    // MARK: Dispatch

    func dispatch(repo: String, workflow: String, ref: String, inputs: [String: String], by: EventActor) async throws -> CIActionResult {
        let ci = try provider(repo)
        guard ci.capabilities.contains(.dispatch), let dispatching = ci as? any Dispatching else {
            throw CIOpError.unsupported(ci: ciName(ci), what: "dispatch")
        }
        guard !ref.isEmpty else { throw CIOpError.invalid("Give the ref (a branch or a tag).") }
        guard inputs.count <= Self.maxInputs else { throw CIOpError.invalid("A workflow takes at most \(Self.maxInputs) inputs. This call has \(inputs.count).") }
        let repoRef = RepoClient.repoRef(ci, repo)
        let list = try await call { try await ci.pipelines(repoRef) }
        guard let pipeline = Self.find(workflow, in: list) else {
            throw CIOpError.invalid("\(repo) has no workflow \(workflow). Workflows: \(list.map(\.name).joined(separator: ", ")).")
        }
        let key = "dispatch|\(repo)|\(pipeline.id)|\(ref)|" + inputs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let last = dispatches[key], now().timeIntervalSince(last.at) < Self.dispatchWindow {
            var r = last.result ?? CIActionResult(ok: true, noop: true, summary: "")
            r.noop = true
            r.summary = "Workflow \(pipeline.name) was dispatched on \(ref) a moment ago. No new dispatch."
            return r
        }
        dispatches[key] = (now(), nil)
        let started: RunRef?
        do {
            started = try await call { try await dispatching.dispatch(repoRef, pipeline: pipeline.id, ref: ref, inputs: inputs) }
        } catch {
            dispatches[key] = nil
            throw error
        }
        var run: Run?
        if let started { run = try? await ci.run(started) }
        let view = run.map(CIRunView.init)
        var text = "Workflow \(pipeline.name) is dispatched on \(ref)."
        if let started { text += " Run \(started.id)." }
        let result = CIActionResult(ok: true, noop: false, summary: text, run: view, url: run?.url)
        dispatches[key] = (now(), result)
        await refresh(repo)
        await record(.ciDispatched, verb: "dispatched", repo: repo, run: run, attempt: view?.attempt ?? 1, by: by,
                     extra: ["workflow": .string(pipeline.name), "ref": .string(ref), "inputKeys": .array(inputs.keys.sorted().map(JSONValue.string))])
        return result
    }

    /// A workflow by id, name or file name.
    private static func find(_ name: String, in list: [Pipeline]) -> Pipeline? {
        let low = name.lowercased()
        return list.first { $0.id == name }
            ?? list.first { $0.name.lowercased() == low }
            ?? list.first { $0.path.lowercased() == low || ($0.path as NSString).lastPathComponent.lowercased() == low }
    }

    // MARK: Approve

    func approve(repo: String, run: String, environments: [String], comment: String?, by: EventActor) async throws -> CIActionResult {
        let ci = try provider(repo)
        if by.type == .agent, !rights().approve {
            throw CIOpError.agentRefused("Agents may not approve deployments. Turn it on in Settings › Agents › CI.")
        }
        guard ci.capabilities.contains(.gates), let gating = ci as? any GateApproving else {
            throw CIOpError.unsupported(ci: ciName(ci), what: "deployment approval")
        }
        let ref = RepoClient.runRef(ci, repo, id: run)
        let wanted = Set(environments.map { $0.lowercased() })
        let waiting = try await call { try await gating.gates(ref) }.filter { $0.canApprove && (wanted.isEmpty || wanted.contains($0.name.lowercased())) }
        let before = try await call { try await ci.run(ref) }
        let view = CIRunView(before)
        guard !waiting.isEmpty else {
            return CIActionResult(ok: true, noop: true, summary: "Run \(run) waits for no deployment that you can approve.", run: view, url: before.url)
        }
        let text = comment.flatMap { $0.isEmpty ? nil : $0 } ?? (by.type == .agent ? "Approved by \(by.name ?? "an agent") via OverSire" : "Approved from OverSire")
        do {
            try await gating.approve(ref, gates: waiting.map(\.id), comment: text)
        } catch ProviderError.forbidden {
            throw CIOpError.vendor("You are not a reviewer of \(waiting.map(\.name).joined(separator: ", ")).")
        } catch let e as ProviderError {
            throw CIOpError.vendor(GitHubClient.hint(e))
        }
        await refresh(repo)
        let names = waiting.map(\.name)
        await record(.ciApproved, verb: "approved:" + waiting.map(\.id).joined(separator: ","), repo: repo, run: before, attempt: view.attempt, by: by,
                     extra: ["environments": .array(names.map(JSONValue.string))])
        return CIActionResult(ok: true, noop: false, summary: "Run \(run) is approved for \(names.joined(separator: ", ")).", run: view, url: before.url)
    }

    // MARK: Shared

    private func provider(_ repo: String) throws -> any CIProvider {
        guard tracked().contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) else { throw CIOpError.untracked(repo) }
        guard let ci = accounts.ci(owner: repoOwner(repo)) else { throw CIOpError.invalid("OverSire has no CI account for \(repoOwner(repo)).") }
        return ci
    }

    /// A vendor call. A `ProviderError` becomes `.vendor`.
    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as ProviderError {
            throw CIOpError.vendor(GitHubClient.hint(e))
        }
    }

    private func record(_ kind: Event.Kind, verb: String, repo: String, run: Run?, attempt: Int, by: EventActor, extra: [String: JSONValue]) async {
        let desk = desk
        await MainActor.run { desk()?.ciActed(kind, verb: verb, repo: repo, run: run, attempt: attempt, actor: by, extra: extra) }
    }
}

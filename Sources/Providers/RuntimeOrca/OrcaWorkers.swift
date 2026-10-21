import Foundation
import OverSireCore

/// One supervised worker that OverSire started in the Run of its coordinator.
public struct OrcaWorker: Hashable, Sendable, Codable {
    public let dispatch: String
    public let task: String
    public let terminal: String?

    public init(dispatch: String, task: String, terminal: String?) {
        self.dispatch = dispatch
        self.task = task
        self.terminal = terminal
    }
}

public enum OrcaWorkerState: Equatable, Sendable {
    case running
    /// The worker sent `worker_done`. `body` is its text.
    case done(outcome: String, body: String)
    /// The worker stopped with no `worker_done`.
    case ended(String)
}

extension OrcaRuntime {
    /// Starts a worker in `path` with the spec as its task. Its `worker_done` goes to the coordinator Run.
    public func startWorker(spec: String, title: String, path: String, agent: String = "claude") async throws -> OrcaWorker {
        let coord = try await coordinator()
        let r = try await run(["orchestration", "worker-start", "--spec", spec, "--task-title", title, "--worktree", "path:" + path,
                               "--agent", agent, "--run", coord.run, "--from", coord.terminal], timeout: .seconds(180))
        guard let dispatch = Self.find("dispatchId", in: r) else { throw ProviderError.decoding("Orca started no worker") }
        return OrcaWorker(dispatch: dispatch, task: Self.find("taskId", in: r) ?? "",
                          terminal: Self.find("agentTerminalHandle", in: r) ?? Self.find("terminalHandle", in: r))
    }

    /// The inbox is read again after `worker-show`, because the worker can settle between the two calls.
    public func workerState(_ w: OrcaWorker) async throws -> OrcaWorkerState {
        if let done = try await doneMessage(w) { return done }
        let state = Self.find("workerState", in: try await run(["orchestration", "worker-show", "--dispatch", w.dispatch])) ?? ""
        guard ["failed", "stopped", "abandoned", "exited", "cancelled", "succeeded"].contains(state) else { return .running }
        return try await doneMessage(w) ?? .ended(state)
    }

    private func doneMessage(_ w: OrcaWorker) async throws -> OrcaWorkerState? {
        guard let m = try await inbox().first(where: { $0.type == "worker_done" && $0.payload["dispatchId"] == w.dispatch }) else { return nil }
        return .done(outcome: m.payload["outcome"] ?? "succeeded", body: m.body)
    }

    public func stopWorker(_ w: OrcaWorker) async throws {
        _ = try await run(["orchestration", "worker-stop", "--dispatch", w.dispatch])
    }

    /// Closes the terminal of a settled worker.
    public func releaseWorker(_ w: OrcaWorker) async throws {
        _ = try await run(["orchestration", "worker-release", "--dispatch", w.dispatch])
    }

    /// The first string value of the key, at any depth. The receipts nest the ids in different places.
    static func find(_ key: String, in v: Any) -> String? {
        if let d = v as? [String: Any] {
            if let s = d[key] as? String, !s.isEmpty { return s }
            for k in d.keys.sorted() { if let s = find(key, in: d[k]!) { return s } }
        } else if let a = v as? [Any] {
            for x in a { if let s = find(key, in: x) { return s } }
        }
        return nil
    }
}

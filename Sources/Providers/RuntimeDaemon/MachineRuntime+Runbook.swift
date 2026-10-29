import Foundation
import OverSireCore

/// The daemon of the machine runs the runbooks. Each change comes as a runbookRun frame on its WebSocket.
extension MachineRuntime: RunbookRunning {
    public func startRunbook(_ s: RunbookStart) async throws -> RunbookRun { try await client.startRunbook(s) }

    public func runbookRuns(item: String?, open: Bool) async throws -> [RunbookRun] {
        try await client.runbookRuns(item: item, open: open)
    }

    public func runbookRun(_ id: RunbookRunID) async throws -> RunbookRun { try await client.runbookRun(id) }

    public func act(_ a: RunbookAction, on id: RunbookRunID) async throws -> RunbookRun { try await client.act(a, on: id) }

    public func act(_ a: StepAction, step: String, on id: RunbookRunID) async throws -> RunbookRun {
        try await client.act(a, step: step, on: id)
    }
}

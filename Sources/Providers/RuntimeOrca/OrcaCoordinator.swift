import Foundation
import OverSireCore

/// The quiet terminal on one Orca server that receives the questions of the sessions, and the Run that it is bound to.
/// Sessions send to `run:<run>`. The Run mailbox stays when the terminal closes; a new terminal binds to the same Run.
public struct OrcaCoordinator: Hashable, Sendable {
    public static let title = "oversire-coordinator"
    public static let objective = "OverSire questions"

    public let terminal: String
    public let run: String

    /// The address that a session gives to `orchestration send --to`.
    public var address: String { "run:" + run }
}

/// The coordinator of one runtime. Two calls at the same time share one search.
final class CoordinatorSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<OrcaCoordinator, any Error>?

    func get(_ make: @escaping @Sendable () async throws -> OrcaCoordinator) async throws -> OrcaCoordinator {
        let t = lock.withLock {
            if let task { return task }
            let t = Task { try await make() }
            task = t
            return t
        }
        do { return try await t.value } catch {
            reset(t)
            throw error
        }
    }

    /// Forgets the coordinator, so that the next call finds or makes it again.
    func reset(_ only: Task<OrcaCoordinator, any Error>? = nil) {
        lock.withLock { if only == nil || task == only { task = nil } }
    }
}

extension OrcaRuntime {
    public func coordinator() async throws -> OrcaCoordinator {
        try await coordinatorSlot.get { [self] in try await findOrMakeCoordinator() }
    }

    /// The live terminal with the coordinator title, else a new one. Then its Run: the bound one,
    /// else the last OverSire Run on the server, else a new Run.
    func findOrMakeCoordinator() async throws -> OrcaCoordinator {
        let list = try await run(["terminal", "list"])["terminals"] as? [[String: Any]] ?? []
        let live = list.first { $0["title"] as? String == OrcaCoordinator.title && $0["orphaned"] as? Bool != true }
        let terminal: String
        if let h = live?["handle"] as? String {
            terminal = h
        } else {
            let made = try await run(["terminal", "create", "--title", OrcaCoordinator.title], timeout: .seconds(30))
            guard let h = (made["terminal"] as? [String: Any])?["handle"] as? String else {
                throw ProviderError.decoding("Orca made no coordinator terminal")
            }
            terminal = h
        }
        if let id = (try await run(["orchestration", "run-current", "--from", terminal])["run"] as? [String: Any])?["id"] as? String {
            return OrcaCoordinator(terminal: terminal, run: id)
        }
        let runs = try await run(["orchestration", "run-list"])["runs"] as? [[String: Any]] ?? []
        if let old = runs.filter({ $0["objective"] as? String == OrcaCoordinator.objective })
            .max(by: { ($0["created_at"] as? String ?? "") < ($1["created_at"] as? String ?? "") })?["id"] as? String,
           (try? await run(["orchestration", "run-use", "--id", old, "--from", terminal])) != nil {
            return OrcaCoordinator(terminal: terminal, run: old)
        }
        let made = try await run(["orchestration", "run-create", "--objective", OrcaCoordinator.objective, "--from", terminal])
        guard let id = (made["run"] as? [String: Any])?["id"] as? String else { throw ProviderError.decoding("Orca made no Run") }
        return OrcaCoordinator(terminal: terminal, run: id)
    }
}

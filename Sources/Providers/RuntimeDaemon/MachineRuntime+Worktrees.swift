import Foundation
import OverSireCore

extension MachineRuntime: WorktreeSource {
    public func worktrees(changed: Bool, dir: String?) async throws -> WorktreesPage {
        try await client.worktrees(changed: changed, dir: dir)
    }
}

import Foundation

/// The git worktrees of the machine of one daemon (`GET /v1/worktrees`).
public protocol WorktreeSource: Sendable {
    var machine: String { get }
    /// `changed`: only the worktrees with files not committed or commits not on the base. `dir`: only the worktrees in that folder.
    /// An old daemon throws `ProviderError.notFound`.
    func worktrees(changed: Bool, dir: String?) async throws -> WorktreesPage
}

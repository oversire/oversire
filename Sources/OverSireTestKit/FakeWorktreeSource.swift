import Foundation
import OverSireCore

/// The worktrees of one daemon, in memory. `failure` makes each read throw.
public final class FakeWorktreeSource: WorktreeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [WorktreeInfo]
    public let machine: String
    public var failure: Error?
    public var now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_793_000_000) }

    public init(machine: String, _ list: [WorktreeInfo] = []) {
        self.machine = machine
        self.list = list
    }

    public func seed(_ list: [WorktreeInfo]) { lock.withLock { self.list = list } }

    public func worktrees(changed: Bool, dir: String?) async throws -> WorktreesPage {
        if let failure { throw failure }
        let all = lock.withLock { list }
        let keep = all.filter { w in
            (!changed || w.changed) && (dir.map { w.path == $0 || w.path.hasPrefix($0 + "/") } ?? true)
        }
        return WorktreesPage(worktrees: keep, at: now())
    }
}

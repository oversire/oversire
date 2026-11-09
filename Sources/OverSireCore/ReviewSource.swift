import Foundation

/// The reviews of one machine (OVERSIRE-371). The daemon of the session machine keeps them.
/// A wrong state throws `ProviderError.vendor(code: "409", ...)`; an unknown key throws `.notFound`.
public protocol ReviewSource: Sendable {
    /// The machine of the daemon. Each call of a row goes to this machine.
    var machine: String { get }
    /// `kind` nil: code and plan.
    func reviews(kind: ReviewKind?) async throws -> ReviewsPage
    func review(_ key: String, kind: ReviewKind) async throws -> ReviewDetail
    /// `full`: ask for the whole file. The reply sets `full` only when the daemon sent it.
    func diff(_ key: String, repo: String, path: String, full: Bool) async throws -> FileDiff
    func addComment(_ key: String, _ d: CommentDraft) async throws -> ReviewComment
    /// 409: the comment is not pending.
    func editComment(_ key: String, id: String, _ e: CommentEdit) async throws
    func deleteComment(_ key: String, id: String, kind: ReviewKind) async throws
    func markViewed(_ key: String, _ m: ViewedMark) async throws
    /// All pending comments become one round.
    func submit(_ key: String, _ s: SubmitReview) async throws -> ReviewRound
    /// A conflict gives `merged` false. A failed check throws 409.
    func merge(_ key: String, _ r: MergeRequest) async throws -> MergeResult
    /// The agent rebases the group and fixes the conflict.
    func fix(_ key: String) async throws -> ReviewRound
}

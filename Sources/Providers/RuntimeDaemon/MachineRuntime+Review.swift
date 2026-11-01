import Foundation
import OverSireCore

/// The daemon of the machine keeps its reviews. Each change comes as a review frame on its WebSocket.
extension MachineRuntime: ReviewSource {
    public func reviews(kind: ReviewKind?) async throws -> ReviewsPage { try await client.reviews(kind: kind) }

    public func review(_ key: String, kind: ReviewKind) async throws -> ReviewDetail { try await client.review(key, kind: kind) }

    public func diff(_ key: String, repo: String, path: String) async throws -> FileDiff {
        try await client.diff(key, repo: repo, path: path)
    }

    public func addComment(_ key: String, _ d: CommentDraft) async throws -> ReviewComment { try await client.addComment(key, d) }

    public func editComment(_ key: String, id: String, _ e: CommentEdit) async throws { try await client.editComment(key, id: id, e) }

    public func deleteComment(_ key: String, id: String, kind: ReviewKind) async throws {
        try await client.deleteComment(key, id: id, kind: kind)
    }

    public func markViewed(_ key: String, _ m: ViewedMark) async throws { try await client.markViewed(key, m) }

    public func submit(_ key: String, _ s: SubmitReview) async throws -> ReviewRound { try await client.submit(key, s) }

    public func merge(_ key: String, _ r: MergeRequest) async throws -> MergeResult { try await client.merge(key, r) }

    public func fix(_ key: String) async throws -> ReviewRound { try await client.fix(key) }
}

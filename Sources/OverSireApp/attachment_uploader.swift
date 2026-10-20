import OverSireCore

/// Uploads files to a tracker item. A failed file gets up to `retries` more tries.
struct AttachmentUploader {
    var retries = 3

    /// Uploads in order. Returns the names that still failed.
    func upload(_ files: [AttachmentUpload], to item: ItemRef, with t: any AttachmentUploading) async -> [String] {
        var left = files
        for _ in 0...retries where !left.isEmpty {
            var failed: [AttachmentUpload] = []
            for f in left {
                do { _ = try await t.attach(f, to: item) } catch { failed.append(f) }
            }
            left = failed
        }
        return left.map(\.name)
    }
}

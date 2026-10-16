import Foundation
import OverSireCore
import TrackerPlane

// The Plane workspaces of the tracker accounts. The Providers page adds and removes them.
final class PlaneAccounts {
    static let noToken = "Add a token for this workspace in Settings › Providers."

    var workspaces: [PlaneWorkspace] { PROJECTS_CFG.workspaces }

    func workspace(_ slug: String) -> PlaneWorkspace? { workspaces.first { $0.slug == slug } }
    func hasToken(_ slug: String) -> Bool { !(ENV.secrets.secret("PLANE_TOKEN_\(slug)") ?? "").isEmpty }

    func client(for slug: String) -> PlaneTracker? { ENV.tracker(slug) as? PlaneTracker }
}

extension Result where Failure == ProviderError {
    /// Runs async work and waits for it. Use it only on a background queue. Item 15 removes it.
    init(blocking op: @escaping @Sendable () async throws -> Success) {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<Success>()
        Task.detached {
            do { box.value = .success(try await op()) }
            catch let e as ProviderError { box.value = .failure(e) }
            catch { box.value = .failure(.transport(error.localizedDescription)) }
            sem.signal()
        }
        sem.wait()
        self = box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, ProviderError>?
}

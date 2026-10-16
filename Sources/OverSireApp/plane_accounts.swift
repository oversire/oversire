import Foundation
import OverSireCore
import TrackerPlane

// Workspaces from the config and their tokens from the Keychain.
final class PlaneAccounts {
    static let changed = Notification.Name("PlaneAccountsChanged")
    static let noToken = "Add a token for this workspace in Settings → Projects."

    private let secrets: SecretStore
    private var clients: [String: PlaneTracker] = [:]

    init(secrets: SecretStore = SecretStore(service: "com.oversire.app.plane")) {
        self.secrets = secrets
    }

    var workspaces: [PlaneWorkspace] { PROJECTS_CFG.workspaces }

    func workspace(_ slug: String) -> PlaneWorkspace? { workspaces.first { $0.slug == slug } }
    func hasToken(_ slug: String) -> Bool { !(token(slug) ?? "").isEmpty }
    private func token(_ slug: String) -> String? { secrets.get("PLANE_TOKEN_\(slug)") }

    func client(for slug: String) -> PlaneTracker? {
        guard let w = workspace(slug), let t = token(slug), !t.isEmpty else { return nil }
        if let c = clients[slug], c.workspace == w { return c }
        let c = PlaneTracker(workspace: w, token: t, http: URLSessionTransport())
        clients[slug] = c
        return c
    }

    // Adds the workspace or changes its host and token.
    func save(_ w: PlaneWorkspace, token: String) {
        secrets.set("PLANE_TOKEN_\(w.slug)", token)
        clients[w.slug] = nil
        PROJECTS_CFG.workspaces.removeAll { $0.slug == w.slug }
        PROJECTS_CFG.workspaces.append(w)
        saveConfig()
        NotificationCenter.default.post(name: PlaneAccounts.changed, object: self)
    }

    func remove(_ slug: String) {
        secrets.delete("PLANE_TOKEN_\(slug)")
        clients[slug] = nil
        PROJECTS_CFG.workspaces.removeAll { $0.slug == slug }
        PROJECTS_CFG.allOf.removeAll { $0 == slug }
        PROJECTS_CFG.picked.removeAll { $0.hasPrefix(slug + "/") }
        saveConfig()
        NotificationCenter.default.post(name: PlaneAccounts.changed, object: self)
    }
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

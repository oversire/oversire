import Foundation
import OverSireCore

extension ProviderID {
    public static let plane: ProviderID = "plane"
}

extension PlaneTracker {
    public static let descriptor = ProviderDescriptor(
        id: .plane, layer: .tracker, displayName: "Plane", symbol: "paperplane",
        fields: [ConfigField(key: "workspace", label: "Workspace", kind: .text, help: "The slug in the Plane URL."),
                 ConfigField(key: "host", label: "Host", kind: .url, required: false, help: PlaneWorkspace.cloudHost),
                 ConfigField(key: "token", label: "API token", kind: .secret)],
        auth: [.token], docsURL: URL(string: "https://developers.plane.so/api-reference/introduction"),
        epicFields: [.goal, .startDate, .targetDate, .lead], epicNoun: "module",
        cli: VendorCLI(binary: "plane-cli", tokenEnv: "PLANE_API_KEY", hostEnv: "PLANE_HOST", hostField: "host",
                       defaultHost: PlaneWorkspace.cloudHost, accountEnv: "PLANE_WORKSPACE", projectEnv: "PLANE_PROJECT",
                       managedEnv: "PLANE_MANAGED_BY", lockedFlags: ["--api-key", "-k", "--host", "--workspace", "-w"],
                       deniedCommands: [["auth", "login"], ["auth", "logout"], ["auth", "workspace", "add"],
                                        ["auth", "workspace", "remove"], ["config", "set"], ["listen"], ["serve"]],
                       minVersion: "0.2.2", projectFlags: ["--project", "-p"], skillCommand: ["skill"],
                       release: .trebiCatalog(entry: "plane"))
    ) { config, env in
        let slug = config.values["workspace"] ?? config.account.id
        let host = config.values["host"].flatMap { $0.isEmpty ? nil : $0 } ?? PlaneWorkspace.cloudHost
        guard let token = env.secrets.secret(config.secretKeys.first ?? "PLANE_TOKEN_\(slug)"), !token.isEmpty else {
            throw ProviderError.unauthorized
        }
        return PlaneTracker(workspace: PlaneWorkspace(slug: slug, host: host), token: token, http: env.http)
    }
}

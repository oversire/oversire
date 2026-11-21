import Foundation
import OverSireCore

extension ProviderID {
    public static let bigtimer: ProviderID = "bigtimer"   // Do not change after release.
}

extension BigTimerTracker {
    public static let descriptor = ProviderDescriptor(
        id: .bigtimer, layer: .tracker, displayName: "Big Timer", symbol: "timer",
        fields: [ConfigField(key: "server", label: "Server URL", kind: .url, help: "The address of the Big Timer server."),
                 ConfigField(key: "token", label: "API token", kind: .secret, help: "A btk_ token with write scope.")],
        auth: [.token], epicFields: [.goal, .startDate, .targetDate, .lead], epicNoun: "epic",
        cli: VendorCLI(binary: "big-timer-cli", tokenEnv: "BIGTIMER_TOKEN", hostEnv: "BIGTIMER_SERVER", hostField: "server",
                       managedEnv: "BIGTIMER_MANAGED_BY", lockedFlags: ["--server", "-s", "--token", "-t"],
                       deniedCommands: [["auth", "login"], ["auth", "logout"], ["auth", "join"], ["auth", "rotate"],
                                        ["token", "create"], ["sync", "stream"]],
                       minVersion: "1.0.12", skillCommand: ["skill"])
    ) { config, env in
        guard let raw = config.values["server"]?.trimmingCharacters(in: .whitespaces),
              let id = BigTimerTracker.account(forServer: raw),
              let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let base = BigTimerTracker.baseURL(comps)
        else { throw ProviderError.vendor(code: "bad_server_url", message: "The server URL is not valid.") }
        if scheme == "http", !BigTimerTracker.isLocal(comps.host ?? "") {
            throw ProviderError.vendor(code: "bad_server_url", message: "A server that is not local needs an https URL.")
        }
        guard let token = env.secrets.secret(config.secretKeys.first ?? "BIGTIMER_TOKEN_\(id)"), !token.isEmpty else {
            throw ProviderError.unauthorized
        }
        return BigTimerTracker(server: base, account: AccountID(provider: .bigtimer, id: id), token: token, http: env.http, streaming: env.streaming, clock: env.clock)
    }

    /// The lowercased host, plus ":port" when the URL has a port. nil when the URL has no host.
    public static func account(forServer url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)), let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        return c.port.map { "\(host):\($0)" } ?? host
    }

    private static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h.hasSuffix(".local")
    }

    private static func baseURL(_ c: URLComponents) -> URL? {
        var b = c
        b.query = nil
        b.fragment = nil
        return b.url
    }
}

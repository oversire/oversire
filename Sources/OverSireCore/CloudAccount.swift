import Foundation

// ─── OverSire Cloud account and device pairing ──────────────────────────────
// The JSON form is in the $defs of Contract/schema/account.json.

/// A client shows the state. A runner does work orders.
public enum DeviceRole: String, Codable, Sendable, CaseIterable { case client, runner }

public struct OverSireAccount: Hashable, Codable, Sendable {
    public let id: String
    public let email: String
    public let createdAt: Date
    public let plan: String
    public let hookRoute: String
    public let stripeCustomer: String?

    public init(id: String, email: String, createdAt: Date, plan: String, hookRoute: String, stripeCustomer: String? = nil) {
        self.id = id
        self.email = email
        self.createdAt = createdAt
        self.plan = plan
        self.hookRoute = hookRoute
        self.stripeCustomer = stripeCustomer
    }
}

/// The answer to POST /pair. The token shows only once.
public struct PairResult: Hashable, Codable, Sendable {
    public let token: String
    public let deviceId: String
    public let role: DeviceRole
    public let account: String
    public let hookRoute: String

    public init(token: String, deviceId: String, role: DeviceRole, account: String, hookRoute: String) {
        self.token = token
        self.deviceId = deviceId
        self.role = role
        self.account = account
        self.hookRoute = hookRoute
    }
}

/// The answer to GET /v1/whoami. An old relay sends only `deviceId`.
public struct WhoAmI: Hashable, Codable, Sendable {
    public let deviceId: String
    public let role: DeviceRole?
    public let account: String?
    public let hookRoute: String?

    public init(deviceId: String, role: DeviceRole? = nil, account: String? = nil, hookRoute: String? = nil) {
        self.deviceId = deviceId
        self.role = role
        self.account = account
        self.hookRoute = hookRoute
    }
}

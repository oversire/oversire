import Foundation
import OverSireCore

// ─── Group joins ─────────────────────────────────────────────────────────────
// The frames that the local daemon sends on its WebSocket during a join, and the text of a failed join.

/// A machine asks to join the group of this daemon. The same shape is an item of GET /v1/group/requests.
public struct JoinRequestFrame: Codable, Hashable, Sendable, Identifiable {
    public var request: String
    public var machine: MachineName
    public var host: String
    public var kind: DeviceKind
    public var confirm: String
    public var expiresAt: Date

    public var id: String { request }

    public init(request: String, machine: MachineName, host: String, kind: DeviceKind = .daemon, confirm: String, expiresAt: Date) {
        self.request = request
        self.machine = machine
        self.host = host
        self.kind = kind
        self.confirm = confirm
        self.expiresAt = expiresAt
    }
}

/// The end of a join request that this daemon sent (POST /v1/group/ask).
public struct JoinResultFrame: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case approved, denied, expired, pending }

    public var host: String
    public var request: String
    public var status: Status
    public var error: String?

    public init(host: String, request: String, status: Status, error: String? = nil) {
        self.host = host
        self.request = request
        self.status = status
        self.error = error
    }
}

/// A typed frame of the local daemon. Other frames (poke, group, store) are not here.
public enum DaemonFrame: Hashable, Sendable {
    case joinRequest(JoinRequestFrame)
    case joinResult(JoinResultFrame)

    /// nil for a frame of another type.
    public static func parse(_ text: String) -> DaemonFrame? {
        struct Head: Decodable { let type: String }
        let data = Data(text.utf8)
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { return nil }
        switch head.type {
        case "joinRequest": return (try? DaemonClient.decode(data) as JoinRequestFrame).map(DaemonFrame.joinRequest)
        case "joinResult": return (try? DaemonClient.decode(data) as JoinResultFrame).map(DaemonFrame.joinResult)
        default: return nil
        }
    }
}

extension DaemonClient {
    /// The open join requests on this daemon.
    public func joinRequests() async throws -> [JoinRequestFrame] { try await get("/v1/group/requests") }

    @discardableResult
    public func setHome(_ machine: String) async throws -> HomeMove {
        try await post("/v1/group/home", ["machine": machine])
    }

    /// The text of an error of a group route: the "error" field of the body, without the "group: " prefix.
    public static func reason(_ error: Error) -> String {
        guard let e = error as? ProviderError else { return error.localizedDescription }
        switch e {
        case .forbidden: return "The code is not valid or was used."
        case .notFound: return "The daemon does not know this route. Update oversire."
        case .vendor(let code, let text):
            let clean = text.hasPrefix("group: ") ? String(text.dropFirst(7)) : text
            guard !clean.isEmpty else { return "The daemon answered \(code)." }
            let line = clean.prefix(1).uppercased() + clean.dropFirst()
            return ".!?".contains(line.last!) ? line : line + "."
        default: return e.message
        }
    }
}

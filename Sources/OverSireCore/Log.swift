import Foundation

// ─── Logs ────────────────────────────────────────────────────────────────────
// Each background job writes one LogEntry when it ends. The app keeps them on this Mac only.

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case ok, warn, error
}

/// Open set: an adapter can write its own area.
public struct LogArea: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let ai: LogArea = "ai"
    public static let sessions: LogArea = "sessions"
    public static let sync: LogArea = "sync"
    public static let runner: LogArea = "runner"
    public static let ui: LogArea = "ui"
    public static let net: LogArea = "net"
    public static let cmd: LogArea = "cmd"

    /// A record area keeps what happened, not the result of a job. Its lines open and clear no problem.
    public var isRecord: Bool { self == .net || self == .cmd || self == .ui }
}

public struct LogEntry: Codable, Hashable, Sendable {
    public var at: Date
    public var level: LogLevel
    public var area: LogArea
    /// The job name, for example "Status" or "Plane poll".
    public var job: String
    /// An item key, a repo or an account.
    public var subject: String?
    /// The machine or the runner, when it is not this Mac.
    public var host: String?
    public var message: String
    /// The time the job took, in milliseconds.
    public var ms: Int?

    // AI jobs.
    public var engine: String?
    public var model: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var stop: String?
    /// Why the job ran, for example "turn end".
    public var reason: String?
    public var input: String?
    public var output: String?

    // Commands.
    public var exit: Int?
    public var outputTail: String?

    /// A routine line, for example a poll. The log keeps it only in Debug detail. It still clears a problem.
    public var verbose: Bool?

    public init(at: Date = Date(), level: LogLevel, area: LogArea, job: String, subject: String? = nil, host: String? = nil,
                message: String, ms: Int? = nil) {
        self.at = at
        self.level = level
        self.area = area
        self.job = job
        self.subject = subject
        self.host = host
        self.message = message
        self.ms = ms
    }

    /// The problem key: the area, the job and the host or account.
    public var problemKey: String { [area.rawValue, job, host ?? ""].joined(separator: "|") }
}

/// Where adapters and jobs write their log lines. Defined small, so a target with no AppKit can write.
public protocol LogSink: Sendable {
    func write(_ e: LogEntry)
}

/// Drops each line. The default for targets and tests that do not log.
public struct NoLog: LogSink {
    public init() {}
    public func write(_ e: LogEntry) {}
}

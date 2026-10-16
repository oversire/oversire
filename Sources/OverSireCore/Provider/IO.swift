import Foundation

/// All HTTP of an adapter goes through this. Tests replay recorded answers.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// All child processes of an adapter go through this.
public protocol CommandRunner: Sendable {
    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput
}

public struct CommandOutput: Hashable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var ok: Bool { status == 0 }
}

public protocol SecretReader: Sendable {
    func secret(_ key: String) -> String?
}

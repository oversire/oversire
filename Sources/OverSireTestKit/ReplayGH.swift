import Foundation
import OverSireCore

/// Recorded `gh api -i` outputs for the GitHub adapters, keyed by "METHOD path". Each call is kept.
public final class ReplayGH: CommandRunner, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var answers: [String: [String]] = [:]
    public private(set) var calls: [(args: [String], stdin: Data?)] = []

    /// Answers in order. The last one repeats.
    public func on(_ method: String, _ path: String, _ outputs: String...) {
        lock.withLock { answers[method + " " + path] = outputs }
    }

    public func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        let key = args[3] + " " + args[4]   // api -i -X METHOD path
        return lock.withLock {
            calls.append((args, stdin))
            guard var list = answers[key], !list.isEmpty else {
                return CommandOutput(status: 1, stdout: Data(), stderr: "gh: no answer for \(key)")
            }
            let out = list.count > 1 ? list.removeFirst() : list[0]
            answers[key] = list
            return CommandOutput(status: out.hasPrefix("HTTP/2.0 2") ? 0 : 1, stdout: Data(out.utf8), stderr: "")
        }
    }

    public func body(_ n: Int = -1) -> [String: Any]? {
        let c = lock.withLock { n < 0 ? calls.last : calls[n] }
        return c?.stdin.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// One `gh api -i` output with the rate limit headers.
public func answer(_ status: String, _ body: String, etag: String? = nil, remaining: Int = 4900) -> String {
    var h = ["HTTP/2.0 \(status)", "Content-Type: application/json; charset=utf-8",
             "X-Ratelimit-Limit: 5000", "X-Ratelimit-Remaining: \(remaining)", "X-Ratelimit-Reset: 1792184456"]
    if let etag { h.append("Etag: \(etag)") }
    return h.joined(separator: "\r\n") + "\r\n\r\n" + body
}

public struct NoHTTP: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ProviderError.transport("no HTTP in this test") }
}

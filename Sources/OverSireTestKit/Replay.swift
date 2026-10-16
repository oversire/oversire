import CryptoKit
import Foundation
import OverSireCore

// ─── Replay I/O ──────────────────────────────────────────────────────────────
// Recorded vendor answers in Fixtures/<adapter>/. A test with no fixture for a call fails.
// With OVERSIRE_RECORD=1 and an upstream, a call goes to the vendor and the answer goes to a fixture without tokens.

/// The folder Fixtures/<adapter> next to the test file.
public func fixtureDir(_ adapter: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Fixtures/\(adapter)")
}

/// True when OVERSIRE_RECORD=1.
public var recordMode: Bool { ProcessInfo.processInfo.environment["OVERSIRE_RECORD"] == "1" }

func fixtureHash(_ parts: [Data]) -> String {
    var h = SHA256()
    for p in parts { h.update(data: p); h.update(data: Data([0])) }
    return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
}

/// Removes tokens from fixture text: token-like values and JSON fields with a secret name.
struct FixtureRedactor {
    static let patterns = [#"gh[pousr]_[A-Za-z0-9_]{20,}"#, #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, #"plane_api_[A-Za-z0-9]+"#,
                           #"sk-[A-Za-z0-9_-]{20,}"#]
    static let secretKey = try! NSRegularExpression(pattern: "(?i)token|secret|password|api_?key|authorization")

    static func text(_ s: String) -> String {
        if let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d),
           let out = try? JSONSerialization.data(withJSONObject: json(obj), options: [.sortedKeys, .withoutEscapingSlashes]) {
            return plain(String(decoding: out, as: UTF8.self))
        }
        return plain(s)
    }

    static func plain(_ s: String) -> String {
        patterns.reduce(s) { $0.replacingOccurrences(of: $1, with: "REDACTED", options: .regularExpression) }
    }

    static func json(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: d.map { k, v in (k, isSecret(k) && v is String ? "REDACTED" : json(v)) })
        }
        if let a = v as? [Any] { return a.map(json) }
        return v
    }

    static func isSecret(_ name: String) -> Bool {
        secretKey.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func headers(_ h: [String: String]) -> [String: String] {
        h.filter { !isSecret($0.key) && $0.key.lowercased() != "set-cookie" }
    }
}

public final class ReplayTransport: HTTPTransport, @unchecked Sendable {
    struct Fixture: Codable {
        var method: String
        var url: String
        var status: Int
        var headers: [String: String]
        var body: String
    }

    public let dir: URL
    let upstream: (any HTTPTransport)?
    let record: Bool
    private let lock = NSLock()
    private var misses: [String] = []

    public init(dir: URL, upstream: (any HTTPTransport)? = nil, record: Bool = recordMode) {
        self.dir = dir
        self.upstream = upstream
        self.record = record && upstream != nil
    }

    /// The calls with no fixture.
    public var missing: [String] { lock.withLock { misses } }

    /// "<METHOD>-<hash of the URL and the body>".
    public static func name(_ r: URLRequest) -> String {
        let method = r.httpMethod ?? "GET"
        return "\(method)-\(fixtureHash([Data(method.utf8), Data((r.url?.absoluteString ?? "").utf8), r.httpBody ?? Data()]))"
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let name = Self.name(request)
        let file = dir.appendingPathComponent(name + ".json")
        let url = request.url!
        if record, let upstream {
            let (data, resp) = try await upstream.send(request)
            let headers = (resp.allHeaderFields as? [String: String]) ?? [:]
            let f = Fixture(method: request.httpMethod ?? "GET", url: FixtureRedactor.plain(url.absoluteString), status: resp.statusCode,
                            headers: FixtureRedactor.headers(headers), body: FixtureRedactor.text(String(decoding: data, as: UTF8.self)))
            try writeFixture(f, to: file)
            return (data, resp)
        }
        guard let d = try? Data(contentsOf: file), let f = try? JSONDecoder().decode(Fixture.self, from: d) else {
            let miss = "\(name) for \(request.httpMethod ?? "GET") \(url.absoluteString)"
            lock.withLock { misses.append(miss) }
            throw ProviderError.transport("no fixture \(miss)")
        }
        return (Data(f.body.utf8), HTTPURLResponse(url: url, statusCode: f.status, httpVersion: "HTTP/1.1", headerFields: f.headers)!)
    }
}

public final class ReplayCommandRunner: CommandRunner, @unchecked Sendable {
    struct Fixture: Codable {
        var command: [String]
        var status: Int32
        var stdout: String
        var stderr: String
    }

    public let dir: URL
    let upstream: (any CommandRunner)?
    let record: Bool
    private let lock = NSLock()
    private var misses: [String] = []

    public init(dir: URL, upstream: (any CommandRunner)? = nil, record: Bool = recordMode) {
        self.dir = dir
        self.upstream = upstream
        self.record = record && upstream != nil
    }

    public var missing: [String] { lock.withLock { misses } }

    /// "cmd-<hash of the program name, the arguments and stdin>". The program folder does not count.
    public static func name(_ exe: String, _ args: [String], stdin: Data?) -> String {
        "cmd-" + fixtureHash([Data((exe as NSString).lastPathComponent.utf8)] + args.map { Data($0.utf8) } + [stdin ?? Data()])
    }

    public func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        let name = Self.name(exe, args, stdin: stdin)
        let file = dir.appendingPathComponent(name + ".json")
        let command = [(exe as NSString).lastPathComponent] + args
        if record, let upstream {
            let out = try await upstream.run(exe, args, stdin: stdin, timeout: timeout)
            let f = Fixture(command: command.map(FixtureRedactor.plain), status: out.status,
                            stdout: FixtureRedactor.text(String(decoding: out.stdout, as: UTF8.self)), stderr: FixtureRedactor.plain(out.stderr))
            try writeFixture(f, to: file)
            return out
        }
        guard let d = try? Data(contentsOf: file), let f = try? JSONDecoder().decode(Fixture.self, from: d) else {
            let miss = "\(name) for \(command.joined(separator: " "))"
            lock.withLock { misses.append(miss) }
            throw ProviderError.transport("no fixture \(miss)")
        }
        return CommandOutput(status: f.status, stdout: Data(f.stdout.utf8), stderr: f.stderr)
    }
}

func writeFixture<T: Encodable>(_ f: T, to file: URL) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try e.encode(f).write(to: file, options: .atomic)
}

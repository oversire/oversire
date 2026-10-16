import Foundation
import OverSireCore

/// Answers by method and URL. Each request is kept.
public final class RecordedHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (Int, [String: String], String)] = [:]
    private var sent: [URLRequest] = []

    public init() {}

    public var requests: [URLRequest] { lock.withLock { sent } }

    public func on(_ method: String, _ url: String, _ status: Int, headers: [String: String] = [:], _ body: String = "") {
        lock.withLock { answers[method + " " + url] = (status, headers, body) }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = (request.httpMethod ?? "GET") + " " + request.url!.absoluteString
        return try lock.withLock {
            sent.append(request)
            guard let (status, headers, body) = answers[key] else { throw ProviderError.transport("no answer for \(key)") }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }
}

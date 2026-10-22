import Foundation
import OverSireCore

/// An HTTP transport with a queue of replies, for streams whose request bodies change each turn.
/// Each request takes the next reply. A streamed body comes in small chunks, as from the network.
public final class ScriptedHTTP: HTTPTransport, HTTPStreaming, @unchecked Sendable {
    public struct Reply: Sendable {
        public var status: Int
        public var body: Data
        /// False: the stream stays open after the body.
        public var ends: Bool

        public init(status: Int = 200, body: Data, ends: Bool = true) {
            self.status = status
            self.body = body
            self.ends = ends
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [URLRequest] = []
    let seed: UInt64

    public init(_ replies: [Reply] = [], chunkSeed: UInt64 = 1) {
        self.replies = replies
        seed = chunkSeed
    }

    public var requests: [URLRequest] { lock.withLock { sent } }

    public func add(_ r: Reply) { lock.withLock { replies.append(r) } }

    /// The JSON body of request `i`.
    public func body(_ i: Int) -> [String: Any] {
        (requests[i].httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func next(_ request: URLRequest) throws -> (Reply, HTTPURLResponse) {
        let r: Reply? = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let r, let url = request.url else { throw ProviderError.transport("no scripted reply") }
        return (r, HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (r, resp) = try next(request)
        return (r.body, resp)
    }

    public func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (r, resp) = try next(request)
        let chunks = ReplayTransport.chunks(r.body, seed: seed)
        let stream = AsyncThrowingStream<Data, Error> { out in
            for c in chunks { out.yield(c) }
            if r.ends { out.finish() }
        }
        return (resp, stream)
    }
}

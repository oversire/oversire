import Foundation

// The mirror feed of the home daemon. Contract: mirror.json.

public enum MirrorKind: String, Codable, Hashable, Sendable, CaseIterable {
    case project, item, runs, prs, activity, settings, catalog
}

/// One doc of the feed. The source sets no `hash` and no `seq`: the daemon sets them.
public struct MirrorDoc: Codable, Hashable, Sendable {
    public var kind: MirrorKind
    public var id: String
    /// The version of the body type. A reader skips a higher v.
    public var v: Int
    public var hash: String
    public var seq: Int64
    public var at: Date
    public var deleted: Bool?
    public var body: JSONValue?

    public init(kind: MirrorKind, id: String, v: Int, hash: String = "", seq: Int64 = 0, at: Date,
                deleted: Bool? = nil, body: JSONValue? = nil) {
        self.kind = kind
        self.id = id
        self.v = v
        self.hash = hash
        self.seq = seq
        self.at = at
        self.deleted = deleted
        self.body = body
    }
}

/// The body of PUT /v1/mirror/docs.
public struct MirrorPut: Codable, Hashable, Sendable {
    public var epoch: String
    /// The app device of the sender. It holds the automations lease.
    public var source: String
    public var sourceName: String
    public var appVersion: String
    public var ready: Bool?
    public var docs: [MirrorDoc]

    public init(epoch: String, source: String, sourceName: String, appVersion: String, ready: Bool? = nil, docs: [MirrorDoc]) {
        self.epoch = epoch
        self.source = source
        self.sourceName = sourceName
        self.appVersion = appVersion
        self.ready = ready
        self.docs = docs
    }
}

public struct MirrorReader: Codable, Hashable, Sendable {
    public var machine: String
    public var name: String
    public var device: String?
    public var head: Int64
    public var seenAt: Date

    public init(machine: String, name: String, device: String? = nil, head: Int64, seenAt: Date) {
        self.machine = machine
        self.name = name
        self.device = device
        self.head = head
        self.seenAt = seenAt
    }
}

public struct MirrorHead: Codable, Hashable, Sendable {
    public var epoch: String
    public var head: Int64
    public var floor: Int64
    public var ready: Bool
    public var source: String?
    public var sourceName: String?
    public var sourceMachine: String?
    public var appVersion: String?
    public var publishedAt: Date?
    /// A WebSocket client of the source is connected. Absent means false.
    public var sourceOnline: Bool?
    public var readers: [MirrorReader]?

    public init(epoch: String, head: Int64, floor: Int64, ready: Bool, source: String? = nil, sourceName: String? = nil,
                sourceMachine: String? = nil, appVersion: String? = nil, publishedAt: Date? = nil,
                sourceOnline: Bool? = nil, readers: [MirrorReader]? = nil) {
        self.epoch = epoch
        self.head = head
        self.floor = floor
        self.ready = ready
        self.source = source
        self.sourceName = sourceName
        self.sourceMachine = sourceMachine
        self.appVersion = appVersion
        self.publishedAt = publishedAt
        self.sourceOnline = sourceOnline
        self.readers = readers
    }
}

public struct MirrorPutResult: Codable, Hashable, Sendable {
    public var head: MirrorHead
    public var applied: Int
    public var same: Int

    public init(head: MirrorHead, applied: Int, same: Int) {
        self.head = head
        self.applied = applied
        self.same = same
    }
}

public struct MirrorPage: Codable, Hashable, Sendable {
    public var epoch: String
    public var docs: [MirrorDoc]
    public var next: Int64
    public var more: Bool
    /// The reader drops its docs and reads again from 0.
    public var reset: Bool

    public init(epoch: String, docs: [MirrorDoc], next: Int64, more: Bool, reset: Bool) {
        self.epoch = epoch
        self.docs = docs
        self.next = next
        self.more = more
        self.reset = reset
    }
}

public struct MirrorIndex: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var kind: MirrorKind
        public var id: String
        public var hash: String

        public init(kind: MirrorKind, id: String, hash: String) {
            self.kind = kind
            self.id = id
            self.hash = hash
        }
    }

    public var epoch: String
    public var head: Int64
    public var docs: [Entry]

    public init(epoch: String, head: Int64, docs: [Entry]) {
        self.epoch = epoch
        self.head = head
        self.docs = docs
    }
}

/// The WebSocket frame {type: mirror}: the head moved.
public struct MirrorFrame: Codable, Hashable, Sendable {
    public var type: String
    public var head: Int64
    public var epoch: String

    public init(head: Int64, epoch: String) {
        type = "mirror"
        self.head = head
        self.epoch = epoch
    }
}

extension DaemonClient {
    /// Member route on the home daemon. Throws StoreNotHome for 409 with `home`.
    public func mirrorHead() async throws -> MirrorHead {
        try await mirrorCall(request("/v1/mirror"))
    }

    /// Member route. The docs with seq above `after`. A page can be large, so the call waits 30 s.
    public func mirrorPage(after: Int64, limit: Int, epoch: String?) async throws -> MirrorPage {
        var r = request("/v1/mirror/docs" + Self.query(["after": String(after), "limit": String(limit), "epoch": epoch]))
        r.timeoutInterval = 30
        return try await mirrorCall(r)
    }

    /// Member route, apps only. The kind, id and hash of each live doc.
    public func mirrorIndex() async throws -> MirrorIndex {
        try await mirrorCall(request("/v1/mirror/index"))
    }

    /// Member route, apps only. Only the holder of the automations lease can put.
    /// 409 with an epoch: the feed changed, send all docs again (vendor code "409"). 413: the batch is too large.
    public func mirrorPut(_ p: MirrorPut) async throws -> MirrorPutResult {
        var r = try json("PUT", "/v1/mirror/docs", p)
        r.timeoutInterval = 30
        return try await mirrorCall(r)
    }

    private struct NotHomeBody: Decodable { let error: String?; let home: String? }

    private func mirrorCall<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, resp) = try await exchange(r)
        if resp.statusCode == 409 {
            if let b = try? JSONDecoder().decode(NotHomeBody.self, from: data), let home = b.home {
                throw StoreNotHome(home: home, message: b.error ?? "This machine is not home")
            }
        }
        return try Self.decode(try Self.check(data, resp))
    }
}

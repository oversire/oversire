import Foundation
import OverSireCore

// The AI results that the Macs of the user share: item summaries, CI explanations, the digest and the session statuses.
// The owner app writes them. The other apps read them and do not run the same job (OVERSIRE-327).
final class AIOutputBook {
    static let changed = Notification.Name("AIOutputBookChanged")

    enum Kind: String {
        case itemSummary = "item-summary"
        case ciExplanation = "ci-explanation"
        case ciDigest = "ci-digest"
        case sessionStatus = "session-status"
        case enhanceWritten = "enhance-written"   // not an AI job: Enhance wrote the review of the subject
    }

    private let writes: StoreWrites
    private var byID: [String: AIOutput] = [:]
    private var observer: NSObjectProtocol?
    // Dates in a body keep the milliseconds, so a newer result of the same second still counts as newer.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let d = parseISO(s) else { throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not a date: \(s)")) }
            return d
        }
        return d
    }()

    init(writes: StoreWrites) {
        self.writes = writes
        reload()
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == AIOutput.collection else { return }
            self.reload()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func reload() { byID = Dictionary(writes.load(AIOutput.self).map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b }) }

    /// The records of one kind, with their body as T. A body that does not decode drops out.
    func all<T: Decodable>(_ kind: Kind, as: T.Type) -> [(subject: String, hash: String, at: Date, value: T)] {
        byID.values.filter { $0.kind == kind.rawValue }.compactMap { r in
            guard let d = try? JSONSerialization.data(withJSONObject: r.body.any),
                  let v = try? Self.decoder.decode(T.self, from: d) else { return nil }
            return (r.subject, r.hash, r.at, v)
        }
    }

    func contains(_ kind: Kind, _ subject: String) -> Bool { byID[AIOutput.id(kind.rawValue, subject)] != nil }

    func remove(_ kind: Kind, _ subject: String) {
        let id = AIOutput.id(kind.rawValue, subject)
        guard byID.removeValue(forKey: id) != nil else { return }
        writes.delete(AIOutput.self, id: id)
    }

    /// Writes the result and keeps the newest `keep` records of the kind.
    func put<T: Encodable>(_ kind: Kind, _ subject: String, hash: String, _ value: T, at: Date, keep: Int) {
        guard let d = try? Self.encoder.encode(value), let o = try? JSONSerialization.jsonObject(with: d) else { return }
        let r = AIOutput(kind: kind.rawValue, subject: subject, hash: hash, body: JSONValue(any: o), at: at)
        byID[r.id] = r
        writes.put(r)
        let old = byID.values.filter { $0.kind == kind.rawValue }.sorted { $0.at > $1.at }.dropFirst(keep)
        for o in old {
            byID[o.id] = nil
            writes.delete(AIOutput.self, id: o.id)
        }
    }
}

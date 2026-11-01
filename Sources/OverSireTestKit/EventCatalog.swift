import Foundation
import OverSireCore

/// Contract/schema/event-kinds.json. Tests check event rows against it.
public struct EventCatalog: Sendable {
    public struct Entry: Sendable {
        public let kind: String
        public let domain: String
        public let actorTypes: Set<ActorType>
        public let isPrivate: Bool
        public let properties: Set<String>
        public let required: Set<String>
    }

    public let kinds: [String: Entry]

    /// The catalog of this checkout.
    public static let repo: EventCatalog = {
        let contract = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Contract")
        return try! load(contract: contract)
    }()

    public static func load(contract: URL) throws -> EventCatalog {
        let data = try Data(contentsOf: contract.appendingPathComponent("schema/event-kinds.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = root["kinds"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var kinds: [String: Entry] = [:]
        for k in list {
            guard let kind = k["kind"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            let payload = k["payload"] as? [String: Any] ?? [:]
            kinds[kind] = Entry(kind: kind, domain: k["domain"] as? String ?? "",
                                actorTypes: Set((k["actorTypes"] as? [String] ?? []).compactMap(ActorType.init(rawValue:))),
                                isPrivate: k["private"] as? Bool ?? false,
                                properties: Set((payload["properties"] as? [String: Any] ?? [:]).keys),
                                required: Set(payload["required"] as? [String] ?? []))
        }
        return EventCatalog(kinds: kinds)
    }

    /// Why a row does not follow the catalog. Empty when it does.
    public func problems(_ d: EventDraft) -> [String] {
        guard let e = kinds[d.kind.rawValue] else { return ["kind \(d.kind) is not in event-kinds.json"] }
        var out: [String] = []
        if !e.actorTypes.contains(d.actorType) { out.append("\(d.kind): actor type \(d.actorType.rawValue)") }
        if e.isPrivate != d.isPrivate { out.append("\(d.kind): private must be \(e.isPrivate)") }
        let keys = Set(d.payload.map { Array($0.keys) } ?? [])
        if !keys.isSubset(of: e.properties) { out.append("\(d.kind): payload fields \(keys.subtracting(e.properties).sorted())") }
        if !e.required.isSubset(of: keys) { out.append("\(d.kind): payload needs \(e.required.subtracting(keys).sorted())") }
        if d.summary.unicodeScalars.count > EventDraft.maxSummary { out.append("\(d.kind): summary too long") }
        if !d.id.contains(":") { out.append("\(d.kind): id \(d.id) has no source") }
        return out
    }
}

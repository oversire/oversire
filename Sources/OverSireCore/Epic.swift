import Foundation

/// The id of an epic in its tracker (a Plane module id, a Jira epic id).
public struct EpicID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

public enum EpicState: String, Codable, Sendable, CaseIterable {
    case planned, active, paused, done, canceled

    public var isClosed: Bool { self == .done || self == .canceled }
}

/// A field that an epic of a vendor can have. Open set, like `Capability`.
public struct EpicField: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let goal: EpicField = "goal"
    public static let startDate: EpicField = "startDate"
    public static let targetDate: EpicField = "targetDate"
    public static let lead: EpicField = "lead"
    /// An epic can hold items of other projects.
    public static let crossProject: EpicField = "crossProject"
}

public struct Epic: Codable, Hashable, Sendable, Identifiable {
    public let id: EpicID
    public var key: String?            // vendor key (Jira PROJ-5); nil for a Plane module
    public var title: String
    public var goal: String?           // Markdown
    public var state: EpicState
    public var nativeState: String     // "in-progress", "cancelled", ...
    public var lead: String?           // person id, same ids as Item.assignees
    public var startDate: Date?
    public var targetDate: Date?
    public let url: String
    public let project: ProjectRef
    public var createdAt: Date?
    public var updatedAt: Date?
    /// Item id → the date the item joined. Nil when the vendor does not tell.
    public var linkedAt: [String: Date]?

    public init(id: EpicID, key: String? = nil, title: String, goal: String? = nil, state: EpicState, nativeState: String = "",
                lead: String? = nil, startDate: Date? = nil, targetDate: Date? = nil, url: String, project: ProjectRef,
                createdAt: Date? = nil, updatedAt: Date? = nil, linkedAt: [String: Date]? = nil) {
        self.id = id
        self.key = key
        self.title = title
        self.goal = goal
        self.state = state
        self.nativeState = nativeState
        self.lead = lead
        self.startDate = startDate
        self.targetDate = targetDate
        self.url = url
        self.project = project
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.linkedAt = linkedAt
    }

    /// The `item` of the event rows of the epic. It matches the Key pattern and has at most 60 characters.
    public var eventKey: String {
        if let key, !key.isEmpty { return key.uppercased() }
        return "EPIC-" + String(SHA256Digest.hex(of: project.storeKey + id.rawValue).prefix(12)).uppercased()
    }
}

public struct EpicDraft: Sendable, Hashable {
    public var title: String
    public var goal: String?
    public var state: EpicState
    public var lead: String?
    public var startDate: Date?
    public var targetDate: Date?

    public init(title: String, goal: String? = nil, state: EpicState = .planned, lead: String? = nil, startDate: Date? = nil,
                targetDate: Date? = nil) {
        self.title = title
        self.goal = goal
        self.state = state
        self.lead = lead
        self.startDate = startDate
        self.targetDate = targetDate
    }
}

/// A write to an epic. Nil fields stay as they are. `clear` removes a value, so no field needs a double optional.
public struct EpicPatch: Sendable, Hashable {
    public var title: String?
    public var goal: String?
    public var state: EpicState?
    public var lead: String?
    public var startDate: Date?
    public var targetDate: Date?
    public var clear: Set<EpicField>

    public init(title: String? = nil, goal: String? = nil, state: EpicState? = nil, lead: String? = nil, startDate: Date? = nil,
                targetDate: Date? = nil, clear: Set<EpicField> = []) {
        self.title = title
        self.goal = goal
        self.state = state
        self.lead = lead
        self.startDate = startDate
        self.targetDate = targetDate
        self.clear = clear
    }

    public var isEmpty: Bool { self == EpicPatch() }
}

/// The progress of an epic. Derived from the snapshot, never stored.
public struct EpicRollup: Hashable, Sendable {
    public let epic: Epic
    public let total: Int, done: Int, started: Int, open: Int
    /// Nil if the epic is not late. Late: the target date is before today, the epic is not closed and an item is open.
    public let lateDays: Int?
    /// The epic is open and all its items are closed.
    public let readyToClose: Bool
    /// Item ids in the order of `ProjectSnapshot.nextReady`.
    public let next: [String]
}

/// Scope and done over time, from the event rows of an epic.
public struct EpicBurnUp: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public let at: Date
        public let scope: Int
        public let done: Int
    }

    public let points: [Point]
    public let target: Date?

    /// `rows`: the `epic.*` rows of the epic and the `item.state_changed` rows of its items. A row of an item
    /// that is not a member at that time does not count. The last point is `current`, at `now`.
    public static func build(epicKey: String, rows: [Event], now: Date, current: EpicRollup) -> EpicBurnUp {
        var members: Set<String> = []
        var closed: Set<String> = []
        var points: [Point] = []
        for e in rows.sorted(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            guard let item = e.item?.uppercased() else { continue }
            switch e.kind {
            case .epicItemAdded where e.parentItem?.uppercased() == epicKey.uppercased():
                guard members.insert(item).inserted else { continue }
            case .epicItemRemoved where e.parentItem?.uppercased() == epicKey.uppercased():
                guard members.remove(item) != nil else { continue }
                closed.remove(item)
            case .itemStateChanged where members.contains(item):
                guard case .string(let group)? = e.payload?["group"] else { continue }
                let isClosed = group == "completed" || group == "cancelled" || group == "canceled"
                guard isClosed ? closed.insert(item).inserted : closed.remove(item) != nil else { continue }
            default: continue
            }
            points.append(Point(at: e.at, scope: members.count, done: closed.count))
        }
        points.append(Point(at: now, scope: current.total, done: current.done))
        return EpicBurnUp(points: points, target: current.epic.targetDate)
    }
}

/// A tracker that groups items in epics: a Plane module, a Jira epic.
public protocol EpicTracking: Tracker {
    /// All epics of the project, in all states.
    func epics(in p: ProjectRef) async throws -> [Epic]
    func createEpic(_ d: EpicDraft, in p: ProjectRef) async throws -> Epic
    func updateEpic(_ e: Epic, _ patch: EpicPatch) async throws -> Epic
    /// A nil epic removes the item from all epics. `ProviderError.unsupported(.epics)` when the epic is in another project
    /// and the vendor has no cross-project epics.
    func setEpic(_ epic: EpicID?, for item: ItemRef) async throws
}

extension ProjectSnapshot {
    public func epic(_ id: EpicID) -> Epic? { epics?.first { $0.id == id } }

    /// The epic of an item. The loaded item wins over the index.
    public func epicId(of itemId: String) -> EpicID? {
        if let i = items.first(where: { $0.id == itemId }) { return i.epicId }
        return index?.first { $0.id == itemId }?.epicId
    }

    /// The loaded and the index-only items of the epic, one row for each id.
    public func members(of id: EpicID) -> [(id: String, key: String?, state: String?)] {
        var out: [(id: String, key: String?, state: String?)] = []
        var seen = Set<String>()
        for i in items where seen.insert(i.id).inserted && i.epicId == id { out.append((i.id, i.key, i.statusOptionId)) }
        for s in index ?? [] where seen.insert(s.id).inserted && s.epicId == id { out.append((s.id, s.key, s.stateId)) }
        return out
    }

    public func rollup(_ epic: Epic, blocked: Set<String> = [], now: Date = Date()) -> EpicRollup {
        let m = members(of: epic.id)
        let done = m.filter { isClosed($0.state) }.count
        let started = m.filter { [.progress, .review].contains(option($0.state)?.category) }.count
        let open = m.count - done
        var late: Int?
        if let target = epic.targetDate, !epic.state.isClosed, open > 0 {
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: target), to: cal.startOfDay(for: now)).day ?? 0
            late = days > 0 ? days : nil
        }
        return EpicRollup(epic: epic, total: m.count, done: done, started: started, open: open, lateDays: late,
                          readyToClose: !epic.state.isClosed && !m.isEmpty && open == 0,
                          next: nextReady(in: epic.id, blocked: blocked).map(\.id))
    }

    /// Loaded items of the epic that can start: open, not in progress or review, not blocked. Priority first, then `sorted`.
    public func nextReady(in id: EpicID, blocked: Set<String> = []) -> [Item] {
        let ready = items.filter {
            guard $0.epicId == id, !blocked.contains($0.id) else { return false }
            return ![.progress, .review, .done].contains(option($0.statusOptionId)?.category)
        }
        let order = Dictionary(uniqueKeysWithValues: sorted(ready).enumerated().map { ($1.id, $0) })
        return ready.sorted { a, b in
            let (ra, rb) = (LaneOrder.rank(a.fields["Priority"]), LaneOrder.rank(b.fields["Priority"]))
            return ra != rb ? ra < rb : order[a.id]! < order[b.id]!
        }
    }

    /// Open epics first (target date, then title), then closed epics with items, then the items with no epic.
    public func epicGroups(_ list: [Item]) -> [(epic: Epic?, items: [Item])] {
        let known = Set((epics ?? []).map(\.id))
        let by = Dictionary(grouping: list.filter { $0.epicId.map(known.contains) ?? false }, by: { $0.epicId! })
        func order(_ a: Epic, _ b: Epic) -> Bool {
            switch (a.targetDate, b.targetDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        let all = epics ?? []
        var out: [(epic: Epic?, items: [Item])] = all.filter { !$0.state.isClosed }.sorted(by: order).map { ($0, by[$0.id] ?? []) }
        out += all.filter { $0.state.isClosed && by[$0.id] != nil }.sorted(by: order).map { ($0, by[$0.id] ?? []) }
        let none = list.filter { $0.epicId.map { !known.contains($0) } ?? true }
        if !none.isEmpty { out.append((nil, none)) }
        return out
    }
}

/// SHA-256 in plain Swift, so that Core stays Foundation only.
private enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(of text: String) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = Array(text.utf8)
        let bits = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        msg += (0..<8).map { UInt8(truncatingIfNeeded: bits >> UInt64(56 - 8 * $0)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for block in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(msg[block + 4 * i + $1]) }
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var v = h
            for i in 0..<64 {
                let s1 = rotr(v[4], 6) ^ rotr(v[4], 11) ^ rotr(v[4], 25)
                let ch = (v[4] & v[5]) ^ (~v[4] & v[6])
                let t1 = v[7] &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(v[0], 2) ^ rotr(v[0], 13) ^ rotr(v[0], 22)
                let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
                let t2 = s0 &+ maj
                v = [t1 &+ t2, v[0], v[1], v[2], v[3] &+ t1, v[4], v[5], v[6]]
            }
            for i in 0..<8 { h[i] = h[i] &+ v[i] }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}

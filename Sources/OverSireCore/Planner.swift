import Foundation

// ─── Planner (cloud) ─────────────────────────────────────────────────────────
// The Planner orders the items of a queue lane, so that two items do not change the same code area at the same time.
// It only suggests: a plan change is a Suggestion with a PlanDraft. The gate (claims, core areas, slots) is a rule, not AI.
// The JSON form is in Contract/schema/suggestion.json (PlanDraft) and store.json (the records).

/// Open set. An unknown kind acts as core, because that is the safe side.
public struct AreaKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    /// Shared code that many items use. Two items never hold a core area at the same time.
    public static let core: AreaKind = "core"
    /// One UI page, the docs. A project setting can let two items share it.
    public static let feature: AreaKind = "feature"

    public var isCore: Bool { self != .feature }
}

/// A change that made the Planner look again.
public struct PlannerTrigger: Hashable, Sendable, Codable {
    /// Open set.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        public var description: String { rawValue }

        public static let itemCreated: Kind = "itemCreated"
        public static let queued: Kind = "queued"
        public static let itemDone: Kind = "itemDone"
        public static let prMerged: Kind = "prMerged"
        public static let ciFailed: Kind = "ciFailed"
        public static let reopened: Kind = "reopened"
        public static let pathsChanged: Kind = "pathsChanged"
        public static let heldLong: Kind = "heldLong"
        public static let visionChanged: Kind = "visionChanged"
        public static let claimGrown: Kind = "claimGrown"
        public static let claimBlocked: Kind = "claimBlocked"
    }

    public var kind: Kind
    public var subject: SubjectRef
    public var at: Date

    public init(kind: Kind, subject: SubjectRef, at: Date) {
        self.kind = kind
        self.subject = subject
        self.at = at
    }
}

/// A plan change: the proposal of the Planner for one queue lane. The subject of the suggestion is the project.
public struct PlanDraft: Hashable, Sendable, Codable {
    public static let maxReason = 200

    /// Move one lane entry behind `after`. nil `after` is the top of the lane.
    public struct OrderLine: Hashable, Sendable, Codable {
        public var item: ItemRef
        public var lane: String
        public var after: ItemRef?
        public var reason: String

        public init(item: ItemRef, lane: String, after: ItemRef?, reason: String) {
            self.item = item
            self.lane = lane
            self.after = after
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey { case item, lane, after, reason }

        // JSON: after is required, null for the top.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            item = try c.decode(ItemRef.self, forKey: .item)
            lane = try c.decode(String.self, forKey: .lane)
            after = try c.decode(ItemRef?.self, forKey: .after)
            reason = try c.decode(String.self, forKey: .reason)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(item, forKey: .item)
            try c.encode(lane, forKey: .lane)
            try c.encode(after, forKey: .after)
            try c.encode(reason, forKey: .reason)
        }
    }

    public struct RelationLine: Hashable, Sendable, Codable {
        public var item: ItemRef
        public var add: [ItemRelation]
        public var remove: [ItemRelation]
        public var reason: String

        public init(item: ItemRef, add: [ItemRelation] = [], remove: [ItemRelation] = [], reason: String) {
            self.item = item
            self.add = add
            self.remove = remove
            self.reason = reason
        }
    }

    public struct AreaLine: Hashable, Sendable, Codable {
        public var item: ItemRef
        public var add: [String]
        public var remove: [String]
        public var reason: String

        public init(item: ItemRef, add: [String] = [], remove: [String] = [], reason: String) {
            self.item = item
            self.add = add
            self.remove = remove
            self.reason = reason
        }
    }

    public struct Overlaps: Hashable, Sendable, Codable {
        public var before: Int
        public var after: Int

        public init(before: Int, after: Int) {
            self.before = before
            self.after = after
        }
    }

    public var order: [OrderLine]
    public var relations: [RelationLine]
    public var areas: [AreaLine]
    public var triggers: [PlannerTrigger]
    public var overlaps: Overlaps?
    /// The kind of each new area in the areas lines.
    public var kinds: [String: AreaKind]?

    public init(order: [OrderLine] = [], relations: [RelationLine] = [], areas: [AreaLine] = [], triggers: [PlannerTrigger] = [],
                overlaps: Overlaps? = nil, kinds: [String: AreaKind]? = nil) {
        self.order = order
        self.relations = relations
        self.areas = areas
        self.triggers = triggers
        self.overlaps = overlaps
        self.kinds = kinds
    }

    public enum Line: Hashable, Sendable {
        case order(OrderLine), relation(RelationLine), area(AreaLine)

        public var reason: String {
            switch self {
            case .order(let l): return l.reason
            case .relation(let l): return l.reason
            case .area(let l): return l.reason
            }
        }
    }

    /// The lines that SuggestionEdit.drop counts: each order line, each relations line, then each areas line.
    public var lines: [Line] { order.map(Line.order) + relations.map(Line.relation) + areas.map(Line.area) }

    /// The lane order after the order lines. A line with an item or an `after` outside `keys` has no effect.
    public func order(_ keys: [String]) -> [String] {
        var out = keys
        for line in order {
            guard let at = out.firstIndex(of: line.item.key.uppercased()) else { continue }
            let key = out.remove(at: at)
            if let after = line.after {
                guard let j = out.firstIndex(of: after.key.uppercased()) else { out.insert(key, at: at); continue }
                out.insert(key, at: j + 1)
            } else {
                out.insert(key, at: 0)
            }
        }
        return out
    }

    /// The areas of an item after the areas lines.
    public func areas(of key: String, base: [String]) -> [String] {
        var out = base
        for line in areas where line.item.key.uppercased() == key.uppercased() {
            out.removeAll(where: line.remove.contains)
            out += line.add.filter { !out.contains($0) }
        }
        return out
    }

    public func dropping(_ indexes: Set<Int>) -> PlanDraft {
        var out = PlanDraft(triggers: triggers, overlaps: overlaps, kinds: kinds)
        for (i, line) in lines.enumerated() where !indexes.contains(i) {
            switch line {
            case .order(let l): out.order.append(l)
            case .relation(let l): out.relations.append(l)
            case .area(let l): out.areas.append(l)
            }
        }
        return out
    }
}

// MARK: Records

/// The Planner settings of one project. The cloud reads them; the app writes them.
public struct PlannerSettings: StoreRecord {
    public static let collection = "planner-settings"
    public static let defaultSlots = 3
    public static let defaultHoldLimit = 2 * 3600

    /// Open set. An unknown mode acts as hourly.
    public struct Mode: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        public var description: String { rawValue }

        public static let off: Mode = "off"
        public static let hourly: Mode = "hourly"
        public static let live: Mode = "live"
    }

    public enum SharedFeature: String, Codable, Sendable, CaseIterable { case serial, parallel }

    public let project: String          // ProjectRef.storeKey, the same as QueueLane.project
    public var mode: Mode
    public var holdLimit: Int           // seconds
    public var triggers: [PlannerTrigger.Kind]?
    public var sharedFeature: SharedFeature
    public var slots: Int
    public var updatedAt: Date

    public init(project: String, mode: Mode = .hourly, holdLimit: Int = defaultHoldLimit, triggers: [PlannerTrigger.Kind]? = nil,
                sharedFeature: SharedFeature = .serial, slots: Int = defaultSlots, updatedAt: Date) {
        self.project = project
        self.mode = mode
        self.holdLimit = holdLimit
        self.triggers = triggers
        self.sharedFeature = sharedFeature
        self.slots = slots
        self.updatedAt = updatedAt
    }

    public var id: String { project }
}

/// A path rule of an area. `*` is one path part (or a part of it), `**` is any number of parts.
public struct AreaRule: Hashable, Sendable, Codable {
    public enum Source: String, Codable, Sendable, CaseIterable { case user, learned, graph }

    public var glob: String
    public var source: Source

    public init(glob: String, source: Source) {
        self.glob = glob
        self.source = source
    }

    public func matches(_ path: String) -> Bool { Glob(glob).matches(path) }
}

public struct AreaDef: Hashable, Sendable, Codable {
    public var name: String
    public var kind: AreaKind
    public var rules: [AreaRule]
    /// The hub proposes the area from the import graph. The user accepts it in Settings.
    public var proposed: Bool

    public init(name: String, kind: AreaKind, rules: [AreaRule] = [], proposed: Bool = false) {
        self.name = name
        self.kind = kind
        self.rules = rules
        self.proposed = proposed
    }

    private enum CodingKeys: String, CodingKey { case name, kind, rules, proposed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AreaKind.self, forKey: .kind)
        rules = try c.decode([AreaRule].self, forKey: .rules)
        proposed = try c.decodeIfPresent(Bool.self, forKey: .proposed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(rules, forKey: .rules)
        if proposed { try c.encode(proposed, forKey: .proposed) }
    }
}

/// The code areas of one project.
public struct AreaCatalog: StoreRecord {
    public static let collection = "area-catalog"

    public let project: String
    public var areas: [AreaDef]
    public var updatedAt: Date

    public init(project: String, areas: [AreaDef] = [], updatedAt: Date) {
        self.project = project
        self.areas = areas
        self.updatedAt = updatedAt
    }

    public var id: String { project }

    /// The kind of an area. An area that the catalog does not have is core.
    public func kind(of area: String) -> AreaKind { areas.first { $0.name == area && !$0.proposed }?.kind ?? .core }

    /// The area of a path, or nil. A user rule wins over a learned rule, and a learned rule over a graph rule.
    /// Inside one source, the first match in the catalog order wins. A proposed area does not match.
    public func area(of path: String) -> AreaDef? {
        for source in AreaRule.Source.allCases {
            if let a = areas.first(where: { a in !a.proposed && a.rules.contains { $0.source == source && $0.matches(path) } }) { return a }
        }
        return nil
    }
}

public struct ClaimArea: Hashable, Sendable, Codable {
    public var area: String
    public var at: Date
    /// For a blocked area: the item that holds it.
    public var by: ItemRef?

    public init(area: String, at: Date, by: ItemRef? = nil) {
        self.area = area
        self.at = at
        self.by = by
    }
}

/// The areas that a running item holds. Only the gate writes it.
public struct AreaClaim: StoreRecord {
    public static let collection = "area-claims"

    public let id: String               // ItemAreas.id(of:)
    public let item: ItemRef
    public var areas: [String]
    public var at: Date
    public var grown: [ClaimArea]
    public var blocked: [ClaimArea]?

    public init(item: ItemRef, areas: [String], at: Date, grown: [ClaimArea] = [], blocked: [ClaimArea]? = nil) {
        id = ItemAreas.id(of: item)
        self.item = item
        self.areas = areas
        self.at = at
        self.grown = grown
        self.blocked = blocked
    }

    /// The claimed areas plus the grown areas.
    public var held: [String] { areas + grown.map(\.area).filter { !areas.contains($0) } }
}

/// Area candidates from the import graph of the repos of one project. Only paths, no code.
public struct AreaCandidates: StoreRecord {
    public static let collection = "area-candidates"

    public struct Hub: Hashable, Sendable, Codable {
        public var glob: String
        public var importers: Int

        public init(glob: String, importers: Int) {
            self.glob = glob
            self.importers = importers
        }
    }

    public struct Cluster: Hashable, Sendable, Codable {
        public var name: String
        public var globs: [String]

        public init(name: String, globs: [String]) {
            self.name = name
            self.globs = globs
        }
    }

    public let project: String
    public var at: Date
    public var hubs: [Hub]
    public var clusters: [Cluster]

    public init(project: String, at: Date, hubs: [Hub] = [], clusters: [Cluster] = []) {
        self.project = project
        self.at = at
        self.hubs = hubs
        self.clusters = clusters
    }

    public var id: String { project }
}

/// The paths that the running work of one subject changed. Only paths, never file text.
public struct ChangedPaths: StoreRecord {
    public static let collection = "changed-paths"
    public static let maxPaths = 500

    public let id: String
    public let subject: SubjectRef
    public var paths: [String]
    public var at: Date

    public init(id: String, subject: SubjectRef, paths: [String], at: Date) {
        self.id = id
        self.subject = subject
        self.paths = Array(paths.prefix(Self.maxPaths))
        self.at = at
    }

    /// The record of an item: the id is the ItemAreas id.
    public init(item: ItemRef, paths: [String], at: Date) {
        self.init(id: ItemAreas.id(of: item), subject: .item(item), paths: paths, at: at)
    }
}

// MARK: Board

/// The lane as a board: Now (the first `slots` items), Next (the next `slots`) and Later. Running items come first.
public struct PlanBoard: Hashable, Sendable {
    public enum Column: Int, CaseIterable, Sendable { case now, next, later }

    public struct Card: Hashable, Sendable {
        public var key: String
        public var areas: [String]
        public var running: Bool

        public init(key: String, areas: [String], running: Bool = false) {
            self.key = key
            self.areas = areas
            self.running = running
        }
    }

    public let slots: Int
    public let columns: [[Card]]

    /// `cards`: the running items, then the lane entries in their order.
    public init(cards: [Card], slots: Int) {
        let n = max(1, slots)
        self.slots = n
        let running = cards.filter(\.running), rest = cards.filter { !$0.running }
        let all = running + rest
        let nowCount = max(n, running.count)
        columns = [Array(all.prefix(nowCount)), Array(all.dropFirst(nowCount).prefix(n)), Array(all.dropFirst(nowCount + n))]
    }

    public func cards(_ c: Column) -> [Card] { columns[c.rawValue] }

    /// For each card in Now and Next that shares an area with another card of the same column: the key of the other card and the area.
    /// A shared core area wins over a shared feature area.
    public func clashes(kind: (String) -> AreaKind) -> [String: (other: String, area: String)] {
        var out: [String: (other: String, area: String)] = [:]
        for column in columns.prefix(2) {
            for a in column {
                var best: (other: String, area: String, core: Bool)?
                for b in column where b.key != a.key {
                    for area in a.areas where b.areas.contains(area) {
                        let core = kind(area).isCore
                        if best == nil || (core && !best!.core) { best = (b.key, area, core) }
                    }
                }
                if let best { out[a.key] = (best.other, best.area) }
            }
        }
        return out
    }

    /// The pairs of cards in Now and in Next that share an area. A pair with a shared core area counts 3, else 1.
    public func overlaps(kind: (String) -> AreaKind) -> Int {
        var total = 0
        for column in columns.prefix(2) {
            for (i, a) in column.enumerated() {
                for b in column.dropFirst(i + 1) {
                    let shared = a.areas.filter(b.areas.contains)
                    if shared.isEmpty { continue }
                    total += shared.contains { kind($0).isCore } ? 3 : 1
                }
            }
        }
        return total
    }
}

/// A path glob: `**` is any number of path parts, `*` is any text in one part, `?` is one character in one part.
public struct Glob: Hashable, Sendable {
    public let text: String
    private let regex: NSRegularExpression?

    public init(_ text: String) {
        self.text = text
        var out = "^"
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                let slash = i + 2 < chars.count && chars[i + 2] == "/"
                out += slash ? "(?:.*/)?" : ".*"
                i += slash ? 3 : 2
                continue
            }
            switch ch {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            default: out += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i += 1
        }
        regex = try? NSRegularExpression(pattern: out + "$")
    }

    public func matches(_ path: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    public static func == (a: Glob, b: Glob) -> Bool { a.text == b.text }
    public func hash(into h: inout Hasher) { h.combine(text) }
}

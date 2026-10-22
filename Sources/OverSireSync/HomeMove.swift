import Foundation

/// The answer of POST /v1/group/home: {"ok": true, "records": N, "offline": true}. records and offline are left out when zero or false.
public struct HomeMove: Decodable, Hashable, Sendable {
    public var records: Int
    public var offline: Bool

    public init(records: Int = 0, offline: Bool = false) {
        self.records = records
        self.offline = offline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decodeIfPresent(Int.self, forKey: .records) ?? 0
        offline = try c.decodeIfPresent(Bool.self, forKey: .offline) ?? false
    }

    private enum CodingKeys: String, CodingKey { case records, offline }

    /// The Settings text after a move from an offline home. nil: the new home has all records.
    public var warning: String? {
        offline ? "The old home was offline. The new home starts from the stores of the apps. "
            + "Open OverSire on each Mac once, so that it sends its records." : nil
    }
}

import Foundation

/// The start keys of LaunchRequest.key. The daemon gives the live session of a key back, so two apps start one session (OVERSIRE-320).
public enum StartKey {
    public static let workPrefix = "work:"
    public static let enhancePrefix = "enhance:"

    /// work:<ITEM-KEY>, for a queue start and the item Start.
    public static func work(_ item: String) -> String { workPrefix + item.uppercased() }
    /// enhance:<ITEM-KEY>. An intake item with no number uses its id.
    public static func enhance(_ item: String) -> String { enhancePrefix + item }

    /// The item key of a work key, else nil.
    public static func workItem(_ key: String?) -> String? {
        guard let key, key.hasPrefix(workPrefix) else { return nil }
        return String(key.dropFirst(workPrefix.count))
    }
}

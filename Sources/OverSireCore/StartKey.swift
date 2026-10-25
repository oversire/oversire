import Foundation

/// The start keys of LaunchRequest.key. The daemon gives the live session of a key back, so two apps start one session (OVERSIRE-320).
public enum StartKey {
    public static let workPrefix = "work:"
    public static let enhancePrefix = "enhance:"
    public static let refinePrefix = "refine:"
    public static let groomPrefix = "groom:"

    /// work:<ITEM-KEY>, for a queue start and the item Start.
    public static func work(_ item: String) -> String { workPrefix + item.uppercased() }
    /// enhance:<ITEM-KEY>. An intake item with no number uses its id.
    public static func enhance(_ item: String) -> String { enhancePrefix + item }
    /// refine:<ITEM-KEY>, for Refine on an intake item.
    public static func refine(_ item: String) -> String { refinePrefix + item.uppercased() }
    /// groom:<PROJECT>, one Groom session for each project.
    public static func groom(_ project: String) -> String { groomPrefix + project.uppercased() }

    /// The item key of a work key, else nil.
    public static func workItem(_ key: String?) -> String? {
        guard let key, key.hasPrefix(workPrefix) else { return nil }
        return String(key.dropFirst(workPrefix.count))
    }

    /// The item key of a refine key, else nil.
    public static func refineItem(_ key: String?) -> String? {
        guard let key, key.hasPrefix(refinePrefix) else { return nil }
        return String(key.dropFirst(refinePrefix.count))
    }
}

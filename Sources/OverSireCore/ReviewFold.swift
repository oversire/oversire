import Foundation

/// The fold of a code read (OVERSIRE-591): the daemon puts the groups of the sub-items into the row of their parent.
/// An older daemon ignores it and gives a row for each group.
public struct ReviewFold: Sendable, Equatable {
    public var on: Bool
    /// The key prefixes (projects) that do not fold, in upper case.
    public var except: [String]

    public init(on: Bool, except: [String] = []) {
        self.on = on
        self.except = except.map { $0.uppercased() }.sorted()
    }

    public static let off = ReviewFold(on: false)

    /// True when the group of key can fold into its parent.
    public func folds(_ key: String) -> Bool {
        guard on, let dash = key.lastIndex(of: "-"), dash > key.startIndex else { return false }
        return !except.contains(key[..<dash].uppercased())
    }

    /// The query values: `fold=1` and `nofold=A,B`. Nil values stay out of the query.
    public var fold: String? { on ? "1" : nil }
    public var nofold: String? { on && !except.isEmpty ? except.joined(separator: ",") : nil }
}

import Foundation
import OverSireCore

/// The turns of a chat view in seq order. A turn with a known seq replaces the old one:
/// the daemon sends a tool turn again when its state changes.
public struct TurnBook: Hashable, Sendable {
    public private(set) var turns: [SessionTurn] = []

    public init(_ turns: [SessionTurn] = []) { merge(turns) }

    /// Gives true when a turn is new or changed.
    @discardableResult
    public mutating func merge(_ new: [SessionTurn]) -> Bool {
        var changed = false
        for t in new {
            let i = turns.partitionIndex { $0.seq >= t.seq }
            if i < turns.count, turns[i].seq == t.seq {
                if turns[i] != t { turns[i] = t; changed = true }
            } else {
                turns.insert(t, at: i)
                changed = true
            }
        }
        return changed
    }
}

extension Array {
    /// The first index where `pred` is true. The array must be partitioned by `pred`.
    func partitionIndex(where pred: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pred(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

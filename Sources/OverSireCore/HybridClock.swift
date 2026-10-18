import Foundation

/// A hybrid logical clock for StoreOp.hlc: "<ms, 15 digits>-<counter, 6 digits>-<device>".
/// The text order is the time order. Each stamp is larger than all stamps that this clock made or saw.
public final class HybridClock: @unchecked Sendable {
    public let device: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var ms: Int64 = 0
    private var counter = 0

    public init(device: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.device = device
        self.now = now
    }

    /// A new stamp.
    public func next() -> String {
        lock.withLock {
            let wall = Self.millis(now())
            if wall > ms {
                ms = wall
                counter = 0
            } else {
                counter += 1
            }
            return Self.stamp(ms: ms, counter: counter, device: device)
        }
    }

    /// Moves the clock past a stamp from another device, so a later local stamp is larger.
    public func observe(_ hlc: String) {
        guard let (m, c) = Self.parse(hlc) else { return }
        lock.withLock {
            if m > ms || (m == ms && c > counter) {
                ms = m
                counter = c
            }
        }
    }

    public static func stamp(ms: Int64, counter: Int, device: String) -> String {
        let m = String(ms), c = String(counter)
        return String(repeating: "0", count: max(0, 15 - m.count)) + m + "-"
            + String(repeating: "0", count: max(0, 6 - c.count)) + c + "-" + device
    }

    /// The milliseconds and the counter of a stamp.
    public static func parse(_ hlc: String) -> (ms: Int64, counter: Int)? {
        let parts = hlc.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[0].count == 15, parts[1].count == 6,
              let m = Int64(parts[0]), let c = Int(parts[1]) else { return nil }
        return (m, c)
    }

    public static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded(.down)) }
}

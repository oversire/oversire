import Foundation

public enum Wait {
    /// Calls `ok` until it gives true or the timeout ends. Returns the last result.
    public static func until(
        timeout: Duration = .seconds(3), every: Duration = .milliseconds(5),
        isolation: isolated (any Actor)? = #isolation, _ ok: () async -> Bool
    ) async -> Bool {
        let end = ContinuousClock.now + timeout
        repeat {
            if await ok() { return true }
            try? await Task.sleep(for: every)
        } while ContinuousClock.now < end
        return await ok()
    }
}

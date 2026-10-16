import Foundation
import XCTest
import OverSireCore

let acme = AccountID(provider: "github-actions", id: "acme")

func event(_ id: String, account: AccountID = acme) -> ProviderEvent {
    let ref = RunRef(account: account, repo: nil, id: id)
    return ProviderEvent(id: id, provider: account.provider, account: account, kind: .run, action: "completed",
                         subject: .run(ref), at: Date(timeIntervalSince1970: 0))
}

/// Takes the next n elements, or fails after the timeout.
func take<T: Sendable>(_ n: Int, from stream: AsyncStream<T>, timeout: TimeInterval = 2, failOnTimeout: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) async -> [T] {
    let result = await withTaskGroup(of: [T]?.self) { g in
        g.addTask {
            var out: [T] = []
            for await e in stream {
                out.append(e)
                if out.count == n { break }
            }
            return out
        }
        g.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            return nil
        }
        let first = await g.next()!
        g.cancelAll()
        return first
    }
    guard let result else {
        if failOnTimeout { XCTFail("timeout: wanted \(n) elements", file: file, line: line) }
        return []
    }
    return result
}

/// Waits until a condition holds, or fails after about 2 s.
func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                _ ok: @Sendable () async -> Bool) async {
    for _ in 0..<2000 {
        if await ok() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timeout: \(what)", file: file, line: line)
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    @discardableResult
    func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

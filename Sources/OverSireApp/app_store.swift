import Foundation
import OverSireCore
import OverSireSync

// OverSire state lives in the store, one JSON file for each collection.
// The selftest writes to a temp folder.
let STORE_DIR = CommandLine.arguments.contains("--selftest")
    ? NSTemporaryDirectory() + "oversire-selftest-\(ProcessInfo.processInfo.processIdentifier)/store"
    : (CONFIG_DIR as NSString).appendingPathComponent("store")
let STORE_WRITES = StoreWrites(store: LocalStore(dir: URL(fileURLWithPath: STORE_DIR)))

/// The UI path to the store. Writes run in call order and the caller does not wait.
final class StoreWrites: @unchecked Sendable {
    let store: any Store
    private var last: Task<Void, Never>?   // main thread only

    init(store: any Store) { self.store = store }

    func put<R: StoreRecord>(_ r: R) { run(R.collection) { try await $0.put(r) } }

    func delete<R: StoreRecord>(_ type: R.Type, id: String) { run(R.collection) { try await $0.delete(type, id: id) } }

    /// Blocks until the earlier writes end. Use it only at start.
    func load<R: StoreRecord>(_ type: R.Type) -> [R] {
        let (store, prev) = (self.store, last)
        switch Result(blocking: { await prev?.value; return try await store.all(type) }) {
        case .success(let rows): return rows
        case .failure(let e):
            log.error("Store read \(R.collection, privacy: .public) failed: \(e.message, privacy: .public)")
            return []
        }
    }

    private func run(_ what: String, _ op: @escaping @Sendable (any Store) async throws -> Void) {
        let (store, prev) = (self.store, last)
        last = Task {
            await prev?.value
            do { try await op(store) } catch {
                log.error("Store write \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension StoreMigration {
    /// Moves the state of older versions into the store once. The old copies go after a success.
    static func runForApp(_ writes: StoreWrites) {
        let queueFile = FileManager.default.contents(atPath: QUEUE_PATH)
        let m = StoreMigration(defaults: UserDefaults.standard.dictionaryRepresentation(), queueFile: queueFile)
        guard m.hasWork else { return }
        let store = writes.store
        switch Result(blocking: { try await m.run(into: store) }) {
        case .success:
            UserDefaults.standard.removeObject(forKey: StoreMigration.ignoredKey)
            if queueFile != nil { try? FileManager.default.moveItem(atPath: QUEUE_PATH, toPath: QUEUE_PATH + ".migrated") }
            log.info("Moved the old queue and ignored failures into the store")
        case .failure(let e):
            log.error("Store migration failed: \(e.message, privacy: .public)")
        }
    }
}

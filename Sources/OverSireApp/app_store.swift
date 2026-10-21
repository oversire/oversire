import Foundation
import OverSireCore
import OverSireSync

// OverSire state lives in the store, one JSON file for each collection.
// The selftest writes to a temp folder.
let STORE_DIR = CommandLine.arguments.contains("--selftest")
    ? NSTemporaryDirectory() + "oversire-selftest-\(ProcessInfo.processInfo.processIdentifier)/store"
    : (CONFIG_DIR as NSString).appendingPathComponent("store")
let STORE_WRITES = StoreWrites(store: LocalStore(dir: URL(fileURLWithPath: STORE_DIR)))

/// A store that can read its records without waiting, at start.
protocol StartReading { func stored<R: StoreRecord>(_ type: R.Type) -> [R] }

extension LocalStore: StartReading {}

extension SyncedStore: StartReading {
    nonisolated func stored<R: StoreRecord>(_ type: R.Type) -> [R] { local.stored(type) }
}

/// The UI path to the store. Writes run in call order and the caller does not wait.
final class StoreWrites: @unchecked Sendable {
    /// Posted on the main thread for a record that came from the cloud. userInfo["collection"] is its collection.
    static let remoteChanged = Notification.Name("StoreRemoteChanged")

    private let lock = NSLock()
    private var current: any Store
    private let local: LocalStore?
    private var link: CloudLink?            // main thread only
    private var watch: Task<Void, Never>?   // main thread only
    private var last: Task<Void, Never>?   // main thread only

    var store: any Store { lock.withLock { current } }

    init(store: any Store) {
        current = store
        local = store as? LocalStore
    }

    /// Free mode (nil) keeps the LocalStore. A paired Mac syncs the same files with the cloud. Main thread only.
    func use(_ link: CloudLink?) {
        guard let local, link != self.link else { return }
        self.link = link
        watch?.cancel()
        if let old = store as? SyncedStore { Task { await old.stop() } }
        let next = ENV.store(local: local, link: link)
        lock.withLock { current = next }
        guard let synced = next as? SyncedStore else { return }
        watch = Task {
            for await c in await synced.remoteChanges() {
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.remoteChanged, object: self, userInfo: ["collection": c.collection])
                }
            }
        }
        syncNow()
    }

    /// Sends the outbox and reads the cloud ops now. Free mode does nothing.
    func syncNow() {
        if let synced = store as? SyncedStore { Task { await synced.sync() } }
    }

    func put<R: StoreRecord>(_ r: R) { run(R.collection) { try await $0.put(r) } }

    func delete<R: StoreRecord>(_ type: R.Type, id: String) { run(R.collection) { try await $0.delete(type, id: id) } }

    /// The records on disk. Use it only at start: it does not see writes that did not end.
    func load<R: StoreRecord>(_ type: R.Type) -> [R] { (store as? any StartReading)?.stored(type) ?? [] }

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
    static func runForApp(_ writes: StoreWrites) async {
        let queueFile = FileManager.default.contents(atPath: QUEUE_PATH)
        let m = StoreMigration(defaults: UserDefaults.standard.dictionaryRepresentation(), queueFile: queueFile)
        let store = writes.store
        switch await Result(awaiting: { try await m.run(into: store) }) {
        case .success:
            guard m.hasWork else { return }
            UserDefaults.standard.removeObject(forKey: StoreMigration.ignoredKey)
            if queueFile != nil { try? FileManager.default.moveItem(atPath: QUEUE_PATH, toPath: QUEUE_PATH + ".migrated") }
            log.info("Moved the old queue and ignored failures into the store")
        case .failure(let e):
            log.error("Store migration failed: \(e.message, privacy: .public)")
        }
    }
}

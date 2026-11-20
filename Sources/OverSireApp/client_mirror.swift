import AppKit
import Foundation
import OverSireCore
import OverSireSync

// ─── Client mirror ───────────────────────────────────────────────────────────
// A client pulls the mirror feed of the home daemon and gives each delta to the app (OVERSIRE-527).
// It pulls at the start, on each `mirror` frame and each minute. Main thread only.

/// What a client knows about its data. Ticket 7 adds the offline cases.
enum ClientLink: Equatable {
    /// The home has no data yet.
    case waiting
    case live(updated: Date, items: Int, repos: Int)
    /// A doc has a newer body version than this app reads.
    case needsUpdate(home: String, version: String)

    var isWaiting: Bool { if case .waiting = self { return true }; return false }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// The title of the live line.
    func title(_ name: String) -> String { isWaiting ? "Waiting for \(name)" : "From \(name)" }

    /// The dim text after the title.
    var detail: String? {
        switch self {
        case .waiting: return nil
        case .live(let d, _, _): return "updated \(Self.clock(d))"
        case .needsUpdate: return "update needed"
        }
    }

    func footer(_ name: String) -> String {
        switch self {
        case .waiting: return "Waiting for \(name)"
        case .live(let d, _, _): return "From \(name) · updated \(relativeTime(d))"
        case .needsUpdate: return "From \(name) · update OverSire"
        }
    }

    /// The note of the row "Data from <name>" in Settings › Machines.
    func note(_ name: String) -> String {
        switch self {
        case .waiting: return "Waiting for \(name) to send its data."
        case .live(let d, let items, let repos):
            return "Updated \(Self.clock(d)) · \(items.formatted()) item\(items == 1 ? "" : "s") · \(repos.formatted()) repo\(repos == 1 ? "" : "s")"
        case .needsUpdate(let home, let version): return "\(home) runs OverSire \(version). Update OverSire on this Mac."
        }
    }

    /// The banner of the needs-update state. Nil in the other states.
    @MainActor var banner: NSView? {
        guard case .needsUpdate(let home, let version) = self else { return nil }
        let check = ActionButton("Check for updates") { (NSApp.delegate as? GHActionsBar)?.updater.check(manual: true) }
        return Banner(.warning, title: "Update OverSire on this Mac", body: "\(home) runs OverSire \(version). This Mac cannot read all of its data.", actions: [check])
    }
}

@MainActor
final class ClientMirror {
    static let safetyInterval: TimeInterval = 60

    private let reader: MirrorReader
    private let apply: (MirrorDelta) -> Void
    /// The counts of the apply step, for the live status.
    var counts: () -> (items: Int, repos: Int) = { (0, 0) }
    /// The name of the home machine, until the feed names its source.
    var homeName: () -> String? = { nil }
    /// Reads the group again after a not-home answer.
    var rehome: (() async -> Void)?
    var onStatus: ((ClientLink) -> Void)?

    private(set) var status: ClientLink = .waiting {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    private(set) var sourceName: String?
    private var running = false
    private var inFlight = false
    private var again = false
    private var timer: Timer?

    init(reader: MirrorReader, apply: @escaping (MirrorDelta) -> Void) {
        self.reader = reader
        self.apply = apply
    }

    /// The name of the app that sends the data, else the name of the home machine.
    var name: String { sourceName ?? homeName() ?? "home" }

    func start() {
        guard !running else { return }
        running = true
        Task { [weak self] in
            guard let self else { return }
            let cached = await reader.cached()
            if !cached.isEmpty { apply(cached) }
            await refreshStatus(cached.needsUpdate)
            pull()
        }
        let t = Timer(timeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    /// Pulls now. A call during a pull makes one more pull after it.
    func pull() {
        guard running else { return }
        guard !inFlight else { again = true; return }
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            await run()
            inFlight = false
            if again {
                again = false
                pull()
            }
        }
    }

    private func run() async {
        var moved = false
        while true {
            do {
                let d = try await reader.pull()
                if !d.isEmpty { apply(d) }
                await refreshStatus(d.needsUpdate)
                return
            } catch let e as StoreNotHome {
                log.info("Mirror: \(e.message, privacy: .public)")
                guard !moved else { return }
                moved = true
                await rehome?()
            } catch {
                // Ticket 7 adds the offline states. The last data stays.
                log.error("Mirror pull failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
    }

    private func refreshStatus(_ needsUpdate: String?) async {
        if let n = await reader.head?.sourceName, !n.isEmpty { sourceName = n }
        if let v = needsUpdate {
            status = .needsUpdate(home: name, version: v)
        } else if await reader.hasData {
            let c = counts()
            status = .live(updated: await reader.updatedAt ?? Date(), items: c.items, repos: c.repos)
        } else {
            status = .waiting
        }
    }
}

/// The mirror fetch of the app: the home can move, so each call asks for the home daemon again.
struct HomeMirrorFetch: MirrorFetch {
    struct NoHome: LocalizedError { var errorDescription: String? { "The home daemon is not reachable." } }

    let home: @Sendable () async -> DaemonClient?

    func head() async throws -> MirrorHead {
        guard let c = await home() else { throw NoHome() }
        return try await c.head()
    }

    func page(after: Int64, limit: Int, epoch: String?) async throws -> MirrorPage {
        guard let c = await home() else { throw NoHome() }
        return try await c.page(after: after, limit: limit, epoch: epoch)
    }
}

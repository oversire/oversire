import AppKit
import Foundation
import OverSireCore
import OverSireSync

// ─── Client mirror ───────────────────────────────────────────────────────────
// A client pulls the mirror feed of the home daemon and gives each delta to the app (OVERSIRE-527).
// It pulls at the start, on each `mirror` frame and each minute. Main thread only.

/// What a client knows about its data. A client shows the last data in each state, and it changes nothing unless `canChange`.
enum ClientLink: Equatable {
    /// The home has no data yet.
    case waiting
    case live(updated: Date, items: Int, repos: Int)
    /// A doc has a newer body version than this app reads.
    case needsUpdate(home: String, version: String)
    /// The home daemon does not answer. `since`: when the loss began. `data`: the time of the last data.
    case homeOffline(home: String, since: Date, data: Date?)
    /// The home daemon answers, but the app that sends the data is not open.
    case appClosed(home: String, data: Date?)
    /// No Mac holds the automations, so no app sends data.
    case noSource(home: String)
    /// The home moved. The client reads from the new home and keeps the old data until the new feed is ready.
    case moving(to: String)

    var isWaiting: Bool { if case .waiting = self { return true }; return false }

    /// A click can reach the source app.
    var canChange: Bool {
        switch self {
        case .live, .needsUpdate: return true
        case .waiting, .homeOffline, .appClosed, .noSource, .moving: return false
        }
    }

    /// The name of the home that the state tells, or nil.
    var homeName: String? {
        switch self {
        case .homeOffline(let h, _, _), .appClosed(let h, _), .noSource(let h), .needsUpdate(let h, _): return h
        case .moving(let h): return h
        case .waiting, .live: return nil
        }
    }

    /// The time of the data that the client shows in an offline state.
    var dataTime: Date? {
        switch self {
        case .homeOffline(_, _, let d), .appClosed(_, let d): return d
        case .live(let d, _, _): return d
        default: return nil
        }
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// The title of the live line.
    func title(_ name: String) -> String {
        switch self {
        case .waiting: return "Waiting for \(name)"
        case .live, .needsUpdate: return "From \(name)"
        case .homeOffline(let h, _, _): return "\(h) is offline"
        case .appClosed(let h, _): return "OverSire is not open on \(h)"
        case .noSource: return "No Mac runs the automations"
        case .moving(let h): return "Moving to \(h)…"
        }
    }

    /// The dim text after the title.
    var detail: String? {
        switch self {
        case .live(let d, _, _): return "updated \(Self.clock(d))"
        case .needsUpdate: return "update needed"
        case .homeOffline(_, _, let d?): return "data from \(Self.clock(d))"
        default: return nil
        }
    }

    func footer(_ name: String) -> String {
        switch self {
        case .waiting: return "Waiting for \(name)"
        case .live(let d, _, _): return "From \(name) · updated \(relativeTime(d))"
        case .needsUpdate: return "From \(name) · update OverSire"
        case .homeOffline(let h, _, let d): return "\(h) offline" + (d.map { " · data from \(Self.clock($0))" } ?? "")
        case .appClosed(let h, let d): return "OverSire closed on \(h)" + (d.map { " · data from \(Self.clock($0))" } ?? "")
        case .noSource: return "No Mac runs the automations"
        case .moving(let h): return "Moving to \(h)…"
        }
    }

    /// The note of the row "Data from <name>" in Settings › Machines. `items` and `repos` count the data that the client holds.
    func note(_ name: String, items: Int = 0, repos: Int = 0) -> String {
        func counts(_ prefix: String) -> String {
            "\(prefix) · \(items.formatted()) item\(items == 1 ? "" : "s") · \(repos.formatted()) repo\(repos == 1 ? "" : "s")"
        }
        switch self {
        case .waiting, .noSource: return "Waiting for \(name) to send its data."
        case .live(let d, let i, let r):
            return "Updated \(Self.clock(d)) · \(i.formatted()) item\(i == 1 ? "" : "s") · \(r.formatted()) repo\(r == 1 ? "" : "s")"
        case .needsUpdate(let home, let version): return "\(home) runs OverSire \(version). Update OverSire on this Mac."
        case .homeOffline(_, _, let d), .appClosed(_, let d):
            guard let d else { return "This Mac has no data from \(name) yet." }
            return counts("Data from \(Self.clock(d))")
        case .moving(let h): return "Home moved to \(h). Reading the data from \(h)…"
        }
    }

    /// Why a change does not run now. nil: it runs. This text is the tooltip of an off control.
    func refusal(_ name: String) -> String? {
        switch self {
        case .live, .needsUpdate: return nil
        case .waiting: return "Waiting for \(name) to send its data."
        case .homeOffline(let h, _, _): return "\(h) is offline. Try again when it is back."
        case .appClosed(let h, _): return "The OverSire app on \(h) is not open."
        case .noSource: return "No Mac runs the automations."
        case .moving(let h): return "Moving to \(h). Try again in a moment."
        }
    }

    /// One log line for each change of the state.
    var logText: String {
        switch self {
        case .waiting: return "waiting"
        case .live: return "live"
        case .needsUpdate(_, let v): return "needsUpdate version=\(v)"
        case .homeOffline(_, let s, _): return "homeOffline since=\(ISO8601DateFormatter().string(from: s))"
        case .appClosed: return "appClosed"
        case .noSource: return "noSource"
        case .moving(let h): return "moving to=\(h)"
        }
    }

    /// The banner of a page. Nil in the states that need none.
    @MainActor var banner: NSView? {
        switch self {
        case .needsUpdate(let home, let version):
            let check = ActionButton("Check for updates") { (NSApp.delegate as? GHActionsBar)?.updater.check(manual: true) }
            return Banner(.warning, title: "Update OverSire on this Mac", body: "\(home) runs OverSire \(version). This Mac cannot read all of its data.", actions: [Spacer(), check])
        case .homeOffline(let h, _, let d):
            return Banner(.warning, title: "\(h) is offline", body: Self.shown(d) + " You cannot make changes until \(h) is back.", actions: [Spacer(), Self.tryAgain()])
        case .appClosed(let h, let d):
            return Banner(.warning, title: "OverSire is not open on \(h)", body: Self.shown(d) + " Open OverSire on \(h) to see new data and make changes.",
                          actions: [Spacer(), Self.tryAgain()])
        case .noSource:
            return Banner(.warning, title: "No Mac runs the automations", body: "Open OverSire on a Mac in Full mode, then use \"Run them here\" on it.",
                          actions: [Spacer(), Self.tryAgain()])
        case .waiting, .live, .moving: return nil
        }
    }

    /// The banner of a shared settings page while the client cannot change. Nil when it can.
    @MainActor var settingsBanner: NSView? {
        switch self {
        case .homeOffline(let h, _, _):
            return Banner(.warning, title: "\(h) is offline", body: "\(h) is offline. You cannot change these settings now.", actions: [Spacer(), Self.tryAgain()])
        case .moving(let h):
            return Banner(.idle, title: "Moving to \(h)…", body: "You cannot change these settings until the move ends.")
        case .waiting: return nil
        default: return banner
        }
    }

    private static func shown(_ d: Date?) -> String {
        d.map { "This Mac shows the data from \(clock($0))." } ?? "This Mac has no data from the home yet."
    }

    @MainActor private static func tryAgain() -> ActionButton {
        ActionButton("Try again") { (NSApp.delegate as? GHActionsBar)?.refresh(force: true, completion: nil) }
    }
}

extension NSView {
    /// Turns this control off for a client that cannot change now. `why` is the tooltip.
    func lock(_ why: String) {
        switch self {
        case let b as ActionButton: b.gate = why
        case let c as Chiplet: c.gate = why
        case let t as NSTextField where !t.isEditable: break
        case let c as NSControl:
            c.isEnabled = false
            c.toolTip = why
        default: break
        }
    }
}

/// The link state for any thread. The catalog reads it off the main thread.
final class ClientLinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var link: ClientLink?
    private var source: String?

    init(_ link: ClientLink? = .waiting) { self.link = link }

    var value: ClientLink? {
        get { lock.withLock { link } }
        set { lock.withLock { link = newValue } }
    }

    /// The last `ClientMirror.name`. A failed send off the main thread puts it in its text.
    var name: String? {
        get { lock.withLock { source } }
        set { lock.withLock { source = newValue } }
    }
}

/// The banner rows of a client page. Empty in Full mode and in a state that needs no banner.
enum ClientBanner {
    @MainActor static func rows() -> [PageRow] {
        guard let l = (NSApp?.delegate as? AppData)?.clientLink, l.banner != nil else { return [] }
        return [PageRow("client", "\(l)") { l.banner ?? NSView() }]
    }
}

@MainActor
final class ClientMirror {
    static let safetyInterval: TimeInterval = 60
    /// A short drop of the network does not change the state.
    static let grace: TimeInterval = 30

    private let reader: MirrorReader
    private let apply: (MirrorDelta) -> Void
    /// The counts of the apply step, for the live status.
    var counts: () -> (items: Int, repos: Int) = { (0, 0) }
    /// The name of the home machine, until the feed names its source.
    var homeName: () -> String? = { nil }
    /// Reads the group again after a not-home answer.
    var rehome: (() async -> Void)?
    /// True while the WebSocket to the home daemon is up.
    var socketUp: () -> Bool = { true }
    var now: () -> Date = Date.init
    /// Runs `body` after `seconds`. Tests keep the call and run it by hand.
    var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { s, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(body) }
    }
    var onStatus: ((ClientLink) -> Void)?
    /// The state for any thread.
    nonisolated let box = ClientLinkBox()

    private(set) var status: ClientLink = .waiting {
        didSet {
            box.value = status
            box.name = name
            guard status != oldValue else { return }
            log.info("client link \(self.status.logText, privacy: .public)")
            onStatus?(status)
        }
    }
    private(set) var sourceName: String? {
        didSet { box.name = name }
    }
    private var running = false
    private var inFlight = false
    private var again = false
    private var timer: Timer?
    /// The state of the last good pull.
    private var base: ClientLink = .waiting
    private var dataAt: Date?
    private var downSince: Date?
    private var failedSince: Date?
    /// When the socket was down and a pull failed, both at the same time.
    private var lostAt: Date?
    private var movingTo: String?

    init(reader: MirrorReader, apply: @escaping (MirrorDelta) -> Void) {
        self.reader = reader
        self.apply = apply
    }

    /// The name of the app that sends the data, else the name of the home machine.
    var name: String { sourceName ?? homeName() ?? "home" }

    func start() {
        guard !running else { return }
        running = true
        box.name = name
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

    /// The WebSocket to the home changed. A drop starts the grace. A return pulls at once.
    func socketChanged() {
        let up = socketUp()
        if up { downSince = nil } else if downSince == nil { downSince = now() }
        recompute()
        pull()
    }

    /// One pull with its state change. Tests call it.
    func run() async {
        var moved = false
        while true {
            do {
                let d = try await reader.pull()
                if !d.isEmpty { apply(d) }
                failedSince = nil
                await refreshStatus(d.needsUpdate)
                return
            } catch let e as StoreNotHome {
                log.info("Mirror: \(e.message, privacy: .public)")
                movingTo = e.home ?? homeName() ?? "home"
                recompute()
                guard !moved else { return }
                moved = true
                await rehome?()
            } catch {
                log.error("Mirror pull failed: \(String(describing: error), privacy: .public)")
                if failedSince == nil { failedSince = now() }
                recompute()
                return
            }
        }
    }

    private func refreshStatus(_ needsUpdate: String?) async {
        let head = await reader.head
        if let n = head?.sourceName, !n.isEmpty { sourceName = n }
        dataAt = await reader.updatedAt
        let hasData = await reader.hasData
        let pending = await reader.isPending
        if movingTo != nil, !pending { movingTo = nil }
        let home = homeName() ?? name
        if let h = head, (h.source ?? "").isEmpty {
            base = .noSource(home: home)
        } else if let h = head, h.sourceOnline != true {
            base = .appClosed(home: name, data: hasData ? dataAt : nil)
        } else if let v = needsUpdate {
            base = .needsUpdate(home: name, version: v)
        } else if hasData {
            let c = counts()
            base = .live(updated: dataAt ?? now(), items: c.items, repos: c.repos)
        } else {
            base = .waiting
        }
        recompute()
    }

    /// The state from the inputs. The offline state needs the socket down and a failed pull for the whole grace.
    func recompute() {
        let t = now()
        let lost = downSince != nil && failedSince != nil
        if lost, lostAt == nil {
            lostAt = t
            after(Self.grace) { [weak self] in self?.recompute() }
        } else if !lost {
            lostAt = nil
        }
        if let at = lostAt, t.timeIntervalSince(at) >= Self.grace {
            status = .homeOffline(home: homeName() ?? name, since: at, data: dataAt)
        } else if let to = movingTo {
            status = .moving(to: to)
        } else {
            status = base
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

import AppKit
import OverSireCore
import OverSireSync

// ─── Link open ───────────────────────────────────────────────────────────────
// A /go/ link or `oversire open` on a daemon pushes an openRoute frame to the app of the Mac of the click (link.json).

struct LinkOpen {
    let open: OpenRoute

    var target: Target? { Target(path: open.focus.map { open.path + "#" + $0 } ?? open.path) }

    var toast: (text: String, bad: Bool) {
        guard target != nil else { return ("This OverSire cannot open \(open.path). Update OverSire.", true) }
        switch open.source {
        case .cli: return ("Opened from the terminal on \(open.daemon)", false)
        case .web: return ("Opened from a link on \(open.daemon)", false)
        }
    }
}

/// Tells each linked daemon when the user last used this Mac, so that a link opens where the user is.
@MainActor
final class PresenceReporter {
    static let every: TimeInterval = 10
    static let gap: TimeInterval = 60

    private let links: () -> [MachineLink]
    private let idle: () -> TimeInterval
    private let now: () -> Date
    private let post: (MachineLink, AppPresence) async throws -> Void
    private var timer: Timer?
    private var busy = false
    private var known: Set<MachineLink> = []
    private var posted: [MachineLink: (at: Date, input: Date)] = [:]
    /// The links of an old daemon (no /v1/presence). They get no posts until the links change.
    private var old: Set<MachineLink> = []
    private var lastIdle: TimeInterval?

    init(links: @escaping () -> [MachineLink], idle: @escaping () -> TimeInterval = PresenceReporter.systemIdle,
         now: @escaping () -> Date = Date.init, post: @escaping (MachineLink, AppPresence) async throws -> Void) {
        self.links = links
        self.idle = idle
        self.now = now
        self.post = post
    }

    nonisolated static func systemIdle() -> TimeInterval {
        // kCGAnyInputEventType is a C macro (~0). It needs no permission.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let current = Set(links())
        if current != known {
            known = current
            old = []
            posted = posted.filter { current.contains($0.key) }
        }
        let t = now()
        let i = max(0, idle())
        let input = t.addingTimeInterval(-i)
        // The user comes back after a gap with no input: post at once, so a move to another Mac shows soon.
        let back = (lastIdle ?? 0) >= Self.gap && i < (lastIdle ?? 0)
        lastIdle = i
        for l in links() where !old.contains(l) {
            if let p = posted[l] {
                let fresh = input.timeIntervalSince(p.input) > 1
                guard fresh, back || t.timeIntervalSince(p.at) >= Self.gap else { continue }
            }
            do {
                try await post(l, AppPresence(idle: Int(i)))
                posted[l] = (t, input)
            } catch ProviderError.notFound {
                old.insert(l)
            } catch {
                log.debug("presence to \(l.machine, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

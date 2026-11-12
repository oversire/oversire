import Foundation
import OverSireCore

// ─── One read of one part of a page ──────────────────────────────────────────
// A part reads its own data. A failed read keeps the old value, tells its age, and tries again by itself
// after 5 s, 30 s and 2 min. Then it stops, and a click on Try again starts the plan again (OVERSIRE-462).

/// The state of one part, for the views and the toolbar menu.
enum ReadState: Hashable {
    case idle
    case busy(shows: Date?)
    case fresh(Date)
    case stale(Date, error: String)
    case failed(String)

    /// True when the last read failed.
    var didFail: Bool {
        switch self {
        case .stale, .failed: return true
        case .idle, .busy, .fresh: return false
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle.dashed"
        case .busy: return "arrow.clockwise"
        case .fresh: return "checkmark.circle"
        case .stale: return "exclamationmark.triangle"
        case .failed: return "xmark.circle"
        }
    }

    var word: String { word(now: Date(), zone: .current) }

    func word(now: Date, zone: TimeZone) -> String {
        switch self {
        case .idle: return "Not read yet"
        case .busy: return "Reading…"
        case .fresh(let d): return "Read " + Self.clock(d, now: now, zone: zone)
        case .stale(let d, _): return "Read failed · shows " + Self.clock(d, now: now, zone: zone)
        case .failed: return "Did not load"
        }
    }

    /// "14:06", or "Nov 11" for a day before today.
    static func clock(_ d: Date, now: Date, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        if cal.isDate(d, inSameDayAs: now) || d > now {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let c = cal.dateComponents([.month, .day], from: d)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[((c.month ?? 1) - 1) % 12]) \(c.day ?? 1)"
    }
}

/// The next automatic try of a failed read.
struct ReadRetry: Hashable {
    let at: Date
    let k: Int
    let of: Int
}

/// One read of one page part. It is a pure value and has no timer.
struct Read<T> {
    static var plan: [TimeInterval] { [5, 30, 120] }
    /// After the plan stops, a read that a caller starts runs again only after this time.
    static var rest: TimeInterval { 600 }

    private(set) var value: T?
    /// The time of the last good read.
    private(set) var at: Date?
    private(set) var error: String?
    private(set) var busy = false
    /// The failed reads since the last good or manual read.
    private(set) var tries = 0
    /// The time of the last end of a read.
    private(set) var endedAt: Date?

    /// For tests and `--uishots`.
    init(value: T? = nil, at: Date? = nil, error: String? = nil, tries: Int = 0) {
        self.value = value
        self.at = at ?? (value == nil ? nil : Date())
        self.error = error
        self.tries = tries
    }

    var state: ReadState {
        if busy { return .busy(shows: value == nil ? nil : at) }
        if let error {
            if value != nil, let at { return .stale(at, error: error) }
            return .failed(error)
        }
        if let at { return .fresh(at) }
        return .idle
    }

    var stopped: Bool { tries > Self.plan.count }

    func retry(now: Date) -> ReadRetry? {
        guard error != nil, !busy, !stopped, tries > 0 else { return nil }
        return ReadRetry(at: (endedAt ?? now).addingTimeInterval(Self.plan[tries - 1]), k: tries, of: Self.plan.count)
    }

    func wants(force: Bool, now: Date, maxAge: TimeInterval?) -> Bool {
        if busy { return false }
        if force { return true }
        if at == nil && error == nil { return true }
        if error != nil, !stopped { return false }
        if stopped { return now.timeIntervalSince(endedAt ?? .distantPast) >= Self.rest }
        guard let maxAge, let at else { return false }
        return now.timeIntervalSince(at) > maxAge
    }

    /// A manual read starts the plan again.
    mutating func begin(manual: Bool) {
        busy = true
        if manual { tries = 0 }
    }

    mutating func succeed(_ v: T, at t: Date) {
        value = v
        at = t
        endedAt = t
        error = nil
        busy = false
        tries = 0
    }

    /// Keeps `value` and `at`. `final` ends the plan.
    mutating func fail(_ message: String, at t: Date, final: Bool) {
        error = message
        endedAt = t
        busy = false
        tries = final ? Self.plan.count + 1 : tries + 1
    }

    /// A frame or a seed. It keeps the error state.
    mutating func set(_ v: T, at t: Date) {
        value = v
        at = t
    }
}

/// One row of the toolbar menu, and the input of the views.
struct PagePart {
    let id: String
    let title: String
    let state: ReadState
    let retry: ReadRetry?
    let refresh: () -> Void
    /// False when the part has no retry plan, for example Plane, which polls on its own timer.
    var auto = true
}

/// One read with its fetch, retries and change callback. Use it on the main thread.
final class PartReader<T> {
    private let fetch: () async throws -> T
    private let merge: (T?, T) -> T
    private let isFinal: (Error) -> Bool
    private let onRead: (T) -> Void
    private let maxAge: TimeInterval?
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let changed: () -> Void
    private var generation = 0
    private var task: Task<Void, Never>?

    private(set) var last = Read<T>()
    var value: T? { last.value }
    var state: ReadState { last.state }

    init(fetch: @escaping () async throws -> T,
         merge: @escaping (T?, T) -> T = { $1 },
         final: @escaping (Error) -> Bool = { _ in false },
         onRead: @escaping (T) -> Void = { _ in },
         maxAge: TimeInterval? = nil,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter,
         changed: @escaping () -> Void) {
        self.fetch = fetch
        self.merge = merge
        isFinal = final
        self.onRead = onRead
        self.maxAge = maxAge
        self.now = now
        self.schedule = schedule
        self.changed = changed
    }

    /// Reads when `Read.wants` says so. A forced read is manual: it starts the retry plan again.
    func load(force: Bool = false) async {
        let go = await MainActor.run { () -> Bool in
            guard last.wants(force: force, now: now(), maxAge: maxAge) else { return false }
            begin(manual: force)
            return true
        }
        if go { await run() }
    }

    /// For callers that use callbacks. On the main thread the state is busy when this call returns.
    func start(force: Bool = false) {
        guard Thread.isMainThread else { task = Task { await load(force: force) }; return }
        guard last.wants(force: force, now: now(), maxAge: maxAge) else { return }
        begin(manual: force)
        task = Task { await run() }
    }

    /// Waits for the read that `start` or a retry began. For tests.
    func settled() async { await task?.value }

    func set(_ v: T) {
        last.set(v, at: now())
        changed()
    }

    func update(_ f: (inout T) -> Void) {
        guard var v = last.value else { return }
        f(&v)
        set(v)
    }

    /// For tests and `--uishots`.
    func seed(_ r: Read<T>) {
        last = r
        generation += 1
    }

    func part(id: String, title: String) -> PagePart {
        PagePart(id: id, title: title, state: state, retry: last.retry(now: now()), refresh: { [weak self] in self?.start(force: true) })
    }

    private func begin(manual: Bool) {
        generation += 1
        last.begin(manual: manual)
        changed()
    }

    private func run() async {
        do {
            let v = try await fetch()
            await MainActor.run {
                let merged = merge(last.value, v)
                last.succeed(merged, at: now())
                onRead(merged)
                changed()
            }
        } catch {
            await MainActor.run { fail(error) }
        }
    }

    private func fail(_ e: Error) {
        last.fail((e as? ProviderError)?.message ?? e.localizedDescription, at: now(), final: isFinal(e))
        changed()
        guard let retry = last.retry(now: now()) else { return }
        let g = generation
        schedule(max(0, retry.at.timeIntervalSince(now()))) { [weak self] in
            guard let self else { return }
            task = Task { await self.again(g) }
        }
    }

    /// A scheduled try. A read that began after the schedule drops it.
    private func again(_ g: Int) async {
        let go = await MainActor.run { () -> Bool in
            guard g == generation, !last.busy else { return false }
            begin(manual: false)
            return true
        }
        if go { await run() }
    }
}

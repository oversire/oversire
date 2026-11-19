import Cocoa

// The last visit of each project, in UserDefaults on this Mac. "Since you were away" counts from it.
// A visit ends when the project page leaves or the app quits.
final class PlanVisits {
    static let shared = PlanVisits(defaults: .standard, persists: !UIShots.shooting)

    private let defaults: UserDefaults
    private let now: () -> Date
    private let persists: Bool
    /// Project → the stamp before the visit. Nil: the first visit.
    private var visits: [String: Date?] = [:]
    private var stamps: [String: Date] = [:]
    private var observer: NSObjectProtocol?

    /// `persists` false keeps the stamps in memory, for the shots.
    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init, persists: Bool = true) {
        self.defaults = defaults
        self.now = now
        self.persists = persists
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.leaveAll()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private static func key(_ project: String) -> String { "planVisit." + project.uppercased() }

    private func stamp(_ project: String) -> Date? {
        persists ? defaults.object(forKey: Self.key(project)) as? Date : stamps[project.uppercased()]
    }

    /// The last visit before this visit. Fixed during the visit.
    func since(_ project: String) -> Date? {
        visits[project.uppercased()] ?? nil
    }

    /// Starts a visit and returns true. A visit that is open already keeps its `since`.
    @discardableResult
    func enter(_ project: String) -> Bool {
        let p = project.uppercased()
        guard visits[p] == nil else { return false }
        visits[p] = .some(stamp(p))
        return true
    }

    /// Ends the visit and stores now.
    func leave(_ project: String) {
        let p = project.uppercased()
        guard visits.removeValue(forKey: p) != nil else { return }
        if persists { defaults.set(now(), forKey: Self.key(p)) } else { stamps[p] = now() }
    }

    func leaveAll() { visits.keys.forEach(leave) }

    /// For the shots: the stamp of the last visit, in memory.
    func seed(_ project: String, since: Date?) {
        let p = project.uppercased()
        visits[p] = nil
        stamps[p] = since
    }
}

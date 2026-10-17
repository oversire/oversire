import Cocoa
import OverSireCore

// Failed runs the user chose to ignore. They do not turn the menu bar icon red.
// The key holds the attempt, so a re-run that fails again shows red again.
final class IgnoredFailures {
    static let limit = 500
    private let writes: StoreWrites
    private var keys: [String: Date]

    init(writes: StoreWrites) {
        self.writes = writes
        keys = Dictionary(writes.load(IgnoredFailure.self).map { ($0.id, $0.at) }, uniquingKeysWith: max)
    }

    static func key(_ r: Run) -> String { "\(r.url)#\(r.attempt ?? 1)" }

    func contains(_ r: Run) -> Bool { keys[IgnoredFailures.key(r)] != nil }

    func set(_ runs: [Run], ignored: Bool) {
        let now = Date()
        for k in runs.map(IgnoredFailures.key) {
            if ignored {
                keys[k] = now
                writes.put(IgnoredFailure(id: k, at: now))
            } else if keys.removeValue(forKey: k) != nil {
                writes.delete(IgnoredFailure.self, id: k)
            }
        }
        for (k, _) in keys.sorted(by: { $0.value < $1.value }).dropLast(IgnoredFailures.limit) {
            keys[k] = nil
            writes.delete(IgnoredFailure.self, id: k)
        }
    }
}

let IGNORED = IgnoredFailures(writes: STORE_WRITES)

let isoFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
}()

let timestampFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
}()

func fmtTimestamp(_ iso: String) -> String {
    guard let d = parseISO(iso) else { return "" }
    return timestampFmt.string(from: d)
}

func fmtDuration(_ secs: TimeInterval) -> String {
    let s = Int(max(0, secs))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s/60)m \(s%60)s" }
    return "\(s/3600)h \(s/60%60)m"
}

func runDuration(_ r: Run) -> String {
    guard let s = parseISO(r.startedAt) ?? parseISO(r.createdAt),
          let e = parseISO(r.updatedAt) else { return "" }
    return fmtDuration(e.timeIntervalSince(s))
}

func runElapsed(_ r: Run) -> TimeInterval {
    guard let s = parseISO(r.startedAt) ?? parseISO(r.createdAt) else { return 0 }
    return -s.timeIntervalSinceNow
}

let startedFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
}()

// "Started 11:56 am" / "Started yesterday 3:04 pm" / "Started May 12, 9:01 am"
func fmtStartedAt(_ iso: String?) -> String {
    guard let d = parseISO(iso) else { return "" }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Started \(startedFmt.string(from: d))" }
    if cal.isDateInYesterday(d) { return "Started yesterday \(startedFmt.string(from: d))" }
    return "Started \(timestampFmt.string(from: d))"
}

// Colour-blind-safe status palette (Okabe-Ito). Hues separate on the blue–yellow
// axis so they stay distinguishable under deutan/protan/tritan vision; shape and
// text carry the state as well, colour is never the only signal.
let C_SUCCESS = NSColor(srgbRed: 0.00, green: 0.62, blue: 0.45, alpha: 1)  // bluish green
let C_FAILURE = NSColor(srgbRed: 0.84, green: 0.37, blue: 0.00, alpha: 1)  // vermillion
let C_RUNNING = NSColor(srgbRed: 0.34, green: 0.71, blue: 0.91, alpha: 1)  // sky blue
let C_QUEUED  = NSColor(srgbRed: 0.90, green: 0.62, blue: 0.00, alpha: 1)  // amber

extension Run {
    var statusText: String {
        switch status {
        case "in_progress": return "In progress"
        case "queued", "waiting", "pending": return "Queued"
        case "completed":
            switch conclusion ?? "" {
            case "success": return "Succeeded"
            case "failure": return "Failed"
            case "cancelled": return "Cancelled"
            case "skipped": return "Skipped"
            default: return "Completed"
            }
        default: return status
        }
    }

    var symbolName: String {
        switch status {
        case "in_progress": return "hourglass.circle.fill"
        case "queued", "waiting", "pending": return "clock.fill"
        case "completed":
            switch conclusion ?? "" {
            case "success": return "checkmark.circle.fill"
            case "failure": return "xmark.circle.fill"
            case "cancelled": return "minus.circle.fill"
            case "skipped": return "forward.fill"
            default: return "questionmark.circle"
            }
        default: return "questionmark.circle"
        }
    }

    var symbolColor: NSColor {
        switch status {
        case "in_progress": return C_RUNNING
        case "queued", "waiting", "pending": return C_QUEUED
        case "completed":
            switch conclusion ?? "" {
            case "success": return C_SUCCESS
            case "failure": return C_FAILURE
            default: return .systemGray
            }
        default: return .secondaryLabelColor
        }
    }
}

// Overall state for the menu bar: tint colour + badge glyph + readable label.
// The glyph shape carries the state so the icon works without colour perception.
func overallStatus(_ g: [(String, [Run])]) -> (color: NSColor, badge: String?, label: String) {
    let all = g.flatMap { $0.1 }
    if all.isEmpty { return (.secondaryLabelColor, nil, "No runs") }
    if all.contains(where: { $0.status == "in_progress" || $0.status == "queued" }) {
        return (C_RUNNING, "hourglass.circle.fill", "Run in progress")
    }
    if !failingRuns(g).isEmpty { return (C_FAILURE, "xmark.circle.fill", "Run failed") }
    return (C_SUCCESS, "checkmark.circle.fill", "All runs passing")
}

// The failures that count: the latest run of each workflow in each repo, over all branches, and not ignored.
// A newer run of the workflow on any branch replaces an older failure.
func failingRuns(_ g: [(String, [Run])]) -> [(repo: String, run: Run)] {
    g.flatMap { repo, runs in latestPerWorkflow(runs, acrossBranches: true).filter { $0.isFailure && !IGNORED.contains($0) }.map { (repo, $0) } }
}

func hasActive(_ g: [(String, [Run])]) -> Bool {
    g.flatMap { $0.1 }.contains { $0.status == "in_progress" || $0.status == "queued" }
}

// The rows the Actions list actually renders. The menu bar icon must agree with this,
// or it pulses for runs the user can't see (feature-branch runs under "Main/develop only").
func visibleRuns(_ runs: [Run]) -> [Run] {
    FILTER_DEFAULT_BRANCHES ? runs.filter { DEFAULT_BRANCHES.contains($0.headBranch) } : runs
}

// Every consumer of "is anything running" must go through this. The poll cadence
// included: a hidden feature-branch run polling every 10s behind an idle-looking
// icon is exactly the drain the render-server pulse rewrite set out to remove.
func visibleGrouped(_ g: [(String, [Run])]) -> [(String, [Run])] {
    g.map { ($0.0, visibleRuns($0.1)) }
}

// Repos with an active run come first, then by newest visible run. Repos without runs go last.
// A running or queued run is active now. A finished run was last active when it completed.
func lastActivity(_ r: Run) -> Date {
    if r.status != "completed" { return Date() }
    return parseISO(r.updatedAt) ?? parseISO(r.createdAt) ?? .distantPast
}

// Newest first. Active runs come first.
func newerActivity(_ a: Run, _ b: Run) -> Bool {
    let aActive = a.status != "completed", bActive = b.status != "completed"
    if aActive != bActive { return aActive }
    if aActive { return (parseISO(a.createdAt) ?? .distantPast) > (parseISO(b.createdAt) ?? .distantPast) }
    return lastActivity(a) > lastActivity(b)
}

func byLastActivity(_ runs: [Run]) -> [Run] { runs.sorted(by: newerActivity) }

// The newest run of each workflow on each branch, or over all branches. `runs` is newest first, as the API returns it.
func latestPerWorkflow(_ runs: [Run], acrossBranches: Bool = false) -> [Run] {
    var seen = Set<String>()
    return runs.filter { seen.insert(acrossBranches ? ($0.workflowName ?? $0.name) : "\($0.workflowName ?? $0.name)|\($0.headBranch)").inserted }
}

func sortedByRecent(_ g: [(String, [Run])]) -> [(String, [Run])] {
    func latest(_ runs: [Run]) -> Date { visibleRuns(runs).map(lastActivity).max() ?? .distantPast }
    let keyed = g.map { (repo: $0, active: hasActive([($0.0, visibleRuns($0.1))]), latest: latest($0.1)) }
    return keyed.sorted { a, b in
        if a.active != b.active { return a.active }
        return a.latest > b.latest
    }.map { $0.repo }
}

// Replaces the entries of the refreshed repos and keeps the order of `order`.
func mergeGrouped<T>(_ old: [(String, [T])], _ fresh: [(String, [T])], order: [String]) -> [(String, [T])] {
    var byRepo = Dictionary(old.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    for (repo, items) in fresh { byRepo[repo] = items }
    return order.map { ($0, byRepo[$0] ?? []) }
}


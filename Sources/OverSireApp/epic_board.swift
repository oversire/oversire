import Foundation
import OverSireCore

// The rows of Work › Epics: which epic goes in which section, and what its button does. No AppKit.
struct EpicBoard {
    enum Section: String, CaseIterable {
        case inProgress, readyToClose, planned, done

        var title: String {
            switch self {
            case .inProgress: return "In progress"
            case .readyToClose: return "Ready to close"
            case .planned: return "Planned"
            case .done: return "Done"
            }
        }
    }

    struct Filter: Hashable {
        /// The identifier of one project. Nil: all projects.
        var project: String?
        var mine = false
        var late = false
        var showDone = false
    }

    enum Action: Hashable {
        case open, close
        /// The key of the item to start.
        case startNext(String)
    }

    struct Row: Hashable {
        let project: String
        let projectTitle: String
        let rollup: EpicRollup
        /// Members with an open question or a session that waits for you, and members with a working session.
        let needsInput: Int
        let working: Int
        let action: Action

        var epic: Epic { rollup.epic }

        /// "6 of 8 done · 2 in progress", or "No items".
        var progressText: String {
            guard rollup.total > 0 else { return "No items" }
            return "\(rollup.done) of \(rollup.total) done" + (rollup.started > 0 ? " · \(rollup.started) in progress" : "")
        }

        /// "▲ 2 days late", "Due Nov 28" or "No target date".
        var dueText: String { EpicBoard.due(rollup) }

        /// "▲ 1 needs input", "● 2 working" or "No sessions".
        var sessionText: String {
            if needsInput > 0 { return "▲ \(needsInput) needs input" }
            return working > 0 ? "● \(working) working" : "No sessions"
        }
    }

    static func due(_ r: EpicRollup) -> String {
        if let late = r.lateDays { return "▲ \(late) day\(late == 1 ? "" : "s") late" }
        guard let t = r.epic.targetDate else { return "No target date" }
        return "Due " + day(t)
    }

    /// "Nov 28".
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: d)
    }

    /// The sections that have rows, in display order. Done shows only with `showDone`.
    /// `sessions` gets an item key. `blocked` gives the ids of the items that wait on another item.
    static func build(_ snaps: [ProjectSnapshot], filter: Filter, sessions: (String) -> (needsInput: Bool, working: Bool),
                      blocked: (ProjectSnapshot) -> Set<String> = { _ in [] }, now: Date) -> [(Section, [Row])] {
        var by: [Section: [Row]] = [:]
        for snap in snaps {
            let ident = snap.summary.identifier
            if let p = filter.project, p.caseInsensitiveCompare(ident) != .orderedSame { continue }
            let block = blocked(snap)
            for epic in snap.epics ?? [] {
                let r = snap.rollup(epic, blocked: block, now: now)
                if filter.late, r.lateDays == nil { continue }
                if filter.mine, !isMine(epic, snap) { continue }
                let section = section(r)
                if section == .done, !filter.showDone { continue }
                var asks = 0, busy = 0
                for m in snap.members(of: epic.id) {
                    guard let key = m.key else { continue }
                    let s = sessions(key)
                    if s.needsInput { asks += 1 } else if s.working { busy += 1 }
                }
                let next = r.next.first.flatMap { id in snap.items.first { $0.id == id }?.key }
                let action: Action = r.readyToClose ? .close : next.map(Action.startNext) ?? .open
                by[section, default: []].append(Row(project: ident, projectTitle: snap.summary.title, rollup: r, needsInput: asks, working: busy,
                                                    action: epic.state.isClosed ? .open : action))
            }
        }
        return Section.allCases.compactMap { s in by[s].map { (s, sorted($0)) } }
    }

    static func section(_ r: EpicRollup) -> Section {
        if r.readyToClose { return .readyToClose }
        switch r.epic.state {
        case .done, .canceled: return .done
        case .active, .paused: return .inProgress
        case .planned: return .planned
        }
    }

    /// Late first (most days first), then the nearest target date, then no date, then the title.
    private static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { a, b in
            switch (a.rollup.lateDays, b.rollup.lateDays) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            switch (a.epic.targetDate, b.epic.targetDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.epic.title.localizedCaseInsensitiveCompare(b.epic.title) == .orderedAscending
            }
        }
    }

    /// You lead the epic, or you are the assignee of a loaded member.
    static func isMine(_ epic: Epic, _ snap: ProjectSnapshot) -> Bool {
        if let lead = epic.lead, let me = snap.meId, lead == me { return true }
        return snap.items.contains { $0.epicId == epic.id && $0.isMine(snap.me) }
    }
}

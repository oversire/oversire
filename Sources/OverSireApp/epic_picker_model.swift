import Foundation
import OverSireCore

// The rows of the epic picker. No AppKit.
struct EpicPickerModel {
    enum Row: Hashable {
        case epic(EpicRollup, selected: Bool)
        case none(selected: Bool)
        case new

        var isSelected: Bool {
            switch self {
            case .epic(_, let s), .none(let s): return s
            case .new: return false
            }
        }

        var title: String {
            switch self {
            case .epic(let r, _): return r.epic.title
            case .none: return "No epic"
            case .new: return "New epic…"
            }
        }

        /// "6 of 8 done · ▲ 2 days late", "0 of 4 done · Planned". Nil for the two fixed rows.
        var detail: String? {
            guard case .epic(let r, _) = self else { return nil }
            var parts = [r.total == 0 ? "No items" : "\(r.done) of \(r.total) done"]
            if let late = r.lateDays {
                parts.append("▲ \(late) day\(late == 1 ? "" : "s") late")
            } else if let t = r.epic.targetDate, !r.epic.state.isClosed {
                parts.append("Due " + EpicBoard.day(t))
            } else if r.epic.state != .active {
                parts.append(EpicColor.word(r.epic.state))
            }
            return parts.joined(separator: " · ")
        }

        /// The spoken text of the row.
        var label: String {
            let text = [title, detail].compactMap { $0 }.joined(separator: ", ")
            return isSelected ? text + ", selected" : text
        }
    }

    let epics: [EpicRollup]
    let current: EpicID?

    /// Open epics first (target date, then title), then the closed epics by title. A query keeps the epics whose title
    /// has all its words. "No epic" and "New epic…" are always last.
    func rows(query: String) -> [Row] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let found = epics.filter { r in
            let t = r.epic.title.lowercased()
            return words.allSatisfy { t.contains($0) }
        }
        func byTitle(_ a: EpicRollup, _ b: EpicRollup) -> Bool { a.epic.title.localizedCaseInsensitiveCompare(b.epic.title) == .orderedAscending }
        let open = found.filter { !$0.epic.state.isClosed }.sorted { a, b in
            switch (a.epic.targetDate, b.epic.targetDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return byTitle(a, b)
            }
        }
        let closed = found.filter { $0.epic.state.isClosed }.sorted(by: byTitle)
        return (open + closed).map { .epic($0, selected: $0.epic.id == current) } + [.none(selected: current == nil), .new]
    }
}

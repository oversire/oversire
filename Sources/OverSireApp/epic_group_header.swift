import Cocoa
import OverSireCore

// The views of an epic group row on the project page: the mark before the title, and the progress, due line, lead and buttons after it.
enum EpicGroupHeader {
    static func lead(_ r: EpicRollup) -> [NSView] {
        [EpicGlyph(r.epic.state, late: r.lateDays != nil, size: 16)]
    }

    /// The lead as a name. Plane gives a user id: only your own id turns into your name.
    static func leadName(_ epic: Epic, snap: ProjectSnapshot) -> String? {
        guard let lead = epic.lead, !lead.isEmpty else { return nil }
        if lead == snap.meId { return snap.me ?? lead }
        return lead.count == 36 && lead.filter({ $0 == "-" }).count == 4 ? nil : lead
    }

    /// `close` is set when the epic is ready to close.
    static func trailing(_ r: EpicRollup, lead: String?, open: @escaping () -> Void, close: (() -> Void)?) -> [NSView] {
        let late = r.lateDays != nil
        var out: [NSView] = []
        if !r.epic.state.isClosed || r.total > 0 {
            out.append(EpicBar(done: r.done, started: r.started, total: r.total).fixedWidth(120))
            out.append(NSTextField.text(r.total == 0 ? "No items" : "\(r.done) of \(r.total) done", size: 12, color: Palette.dim).fixedWidth(76))
        }
        if !r.epic.state.isClosed {
            let due = EpicBoard.due(r)
            out.append(NSTextField.text(due, size: 12, weight: late ? .semibold : .regular, color: late ? Palette.bad : Palette.dim).fixedWidth(96))
        } else {
            out.append(NSTextField.text(EpicColor.word(r.epic.state), size: 12, color: Palette.dim).fixedWidth(96))
        }
        out.append(lead.map { Avatar($0) as NSView } ?? Spacer(20))
        let more = ActionButton("Open ›", style: .link) { open() }
        more.setAccessibilityLabel("Open epic \(r.epic.title)")
        out.append(more)
        if let close {
            let b = ActionButton("Close epic") { close() }
            b.setAccessibilityLabel("Close epic \(r.epic.title)")
            out.append(b)
        }
        return out
    }
}

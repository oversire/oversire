import Cocoa
import OverSireCore


// ─── Icon ────────────────────────────────────────────────────────────────────

// What the menu bar icon shows. Color and badge come from the runs; the dot shows an agent that waits or unread Plane activity.
struct MenuIconState: Equatable {
    let color: NSColor
    let badge: String?
    let label: String
    let active: Bool
    let dot: Bool
    /// The open OverSire problems. The ▲ shows only when the Logs settings keep the mark on.
    let problems: Int

    init(runs: [(String, [Run])], waitingAgents: Int, unread: Int, unreadDot: Bool, problems: Int = 0, questions: Int = 0) {
        let (c, b, l) = overallStatus(runs)
        color = c; badge = b
        active = hasActive(runs)
        dot = waitingAgents > 0 || questions > 0 || (unreadDot && unread > 0)
        self.problems = problems
        var text = waitingAgents > 0 ? "\(l) · \(waitingAgents) session\(waitingAgents == 1 ? "" : "s") wait\(waitingAgents == 1 ? "s" : "")" : l
        if questions > 0 { text += " · \(questions) question\(questions == 1 ? "" : "s")" }
        if problems > 0 { text += " · \(problems) problem\(problems == 1 ? "" : "s")" }
        label = text
    }
}

// The "Status lens" mark (brand/MenuBarIcon.svg): three arcs around one status light, in an 18 pt box.
enum Lens {
    static let size = NSSize(width: 18, height: 18)

    static func ring(in r: NSRect) -> NSBezierPath {
        let k = r.width / 18
        let c = NSPoint(x: r.midX, y: r.midY)
        let p = NSBezierPath()
        p.lineWidth = 2 * k
        // Three arcs of 101° with 19° gaps, clockwise from the top, as in the SVG.
        for i in 0..<3 {
            let start = 80 - CGFloat(i) * 120
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: 6.5 * k, startAngle: start, endAngle: start - 101, clockwise: true)
            p.append(arc)
        }
        return p
    }

    static func light(in r: NSRect) -> NSBezierPath {
        let k = r.width / 18, d = 5.2 * k
        return NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
    }
}

func loadGHIcon() -> NSImage? {
    let img = NSImage(size: Lens.size, flipped: false) { r in
        NSColor.black.set()
        Lens.ring(in: r).stroke()
        Lens.light(in: r).fill()
        return true
    }
    img.isTemplate = true
    return img
}

func tintedIcon(_ base: NSImage?, _ color: NSColor) -> NSImage {
    guard let base = base else { return NSImage() }
    let img = NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    img.isTemplate = false
    return img
}

// Menu bar icon: the ring with a status glyph (check / cross / hourglass) as its light.
// The shape conveys state independently of the tint colour. Without a glyph, a plain light shows.
func statusBadgedIcon(_ base: NSImage?, color: NSColor, badge: String?, dot: Bool = false, problem: Bool = false) -> NSImage {
    guard let base = base else { return NSImage() }
    let sz = base.size
    let img = NSImage(size: sz, flipped: false) { rect in
        // The ring follows the menu bar appearance; only the light takes the status color.
        NSColor.labelColor.setStroke()
        Lens.ring(in: rect).stroke()
        if let name = badge, let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let b = 9.4 * rect.width / 18
            let bRect = NSRect(x: rect.midX - b / 2, y: rect.midY - b / 2, width: b, height: b)
            let tinted = NSImage(size: bRect.size, flipped: false) { r in
                sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: bRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            color.setFill()
            Lens.light(in: rect).fill()
        }
        // A blue dot for unread project items. The CI color keeps priority; the dot only adds information.
        if dot {
            let d: CGFloat = 5
            let dRect = NSRect(x: sz.width - d - 0.5, y: sz.height - d - 0.5, width: d, height: d)
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                NSColor.black.set()
                NSBezierPath(ovalIn: dRect.insetBy(dx: -1.2, dy: -1.2)).fill()
                ctx.restoreGState()
            }
            C_RUNNING.setFill()
            NSBezierPath(ovalIn: dRect).fill()
        }
        // An amber ▲ at the lower corner for an OverSire problem. The light keeps the state of the work.
        if problem {
            let w: CGFloat = 7, h: CGFloat = 6
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: sz.width - w, y: 0))
            tri.line(to: NSPoint(x: sz.width, y: 0))
            tri.line(to: NSPoint(x: sz.width - w / 2, y: h))
            tri.close()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                NSColor.black.setStroke()
                tri.lineWidth = 2.4
                tri.stroke()
                ctx.restoreGState()
            }
            C_QUEUED.setFill()
            tri.fill()
        }
        return true
    }
    img.isTemplate = false
    return img
}

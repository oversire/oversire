import Cocoa


let GH_ICON_B64 = "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAeGVYSWZNTQAqAAAACAAEARoABQAAAAEAAAA+ARsABQAAAAEAAABGASgAAwAAAAEAAgAAh2kABAAAAAEAAABOAAAAAAAAAEgAAAABAAAASAAAAAEAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAJKADAAQAAAABAAAAJAAAAAAZgdfLAAAACXBIWXMAAAsTAAALEwEAmpwYAAAEkUlEQVRYCbWYTYyNVxjH5/pWE0NKqI9LlFawqCDtQiZWIsFOWSBIdWdj126mkerSx6IhkQjx0W5KSOxI2liw8LXoYDBhYoj4iJoxPovb3+/2vjfnnnnvuDPzzj/5zXve5zznOc8973nPOe/k6nqhQqEwGvdGWADzYDZMhQZQHdAOLdAMl+BsLpfr5JqdSCQPO6EFOuAVvIV38AESWdZmnT5dcB9sm+9XRgTIwXhognvwHOystzLJTjCGsYyZ61VyNBgGc+AEtENWMpYxjT2spqRwrIf5sAOeQdYyprHtoz5OalBowMGsZ8FKWA/JZKWYmYxpbPv4otRn9+BUDAKH0uwfQaJ/KbwAr33Vexo6B98EAezDvuyzYmCK2WF0sh2H8DEZ6DochSvg5DQxJ6ry6kTXlpDUYSrWmUgr7IHzJRuXouzLPsd3GyKMvgHxBHZkNiTOlFfBX/APmMBjuAx/BjykbJ2v/QVYFbRfwr1LQSj7bEp8ilcMefC1jOWv+yp05t5JP1FCe1hO6vWN7NOxOcqx7Lu4TiXPbisN0yZwAburb6gX3DwqEdrDsvUPQd9aZN/mUOdEdjtYDaM0RBrM/dehjW2gAB8ktIflUr1+/qBQU7hJWxRHYl9mLo5QI5hh7Pge2wNwX8pKbQQyprFD+cM/g0YTWghDINYrDKehLa7ox/0T2h6DlykxhmNbYEJzIZlLoZ+NTjLsz0Jjf8rEek3738CY8eN0lOaZiEcIb0Lp3AXnQmMWZZL6mziO1LsonjnMNqGpEI/QG2wPaJztOYagJTmP7CNUMRf/pL3uoeNAlJ8TNB4h+2mIR2YgOk+L6VKT9iIVH1W88BlgBExmXRio0fuS+BWruJ2iDkeoHdIWuU+wL4JMxY80prFjmUO7CbnwxQuVzq7c31rIWMuJl5aQObSY0FVIGyEXqsX8om+4ZiJiuQ0tBadELBNqNqGL4IIVy0k3E9YSaBrEW0vsX/XetjAZh3XgJ5Qn01gmdKkOx9Hg503yRfGa8lN4Ap5r1C6YAQ0wElLfkLAHfAbDCLCNx45tUE0e6jyC+Paxhv/foWcfdRZ+gI1wFZJE71L+BdbAXEgb9iSeiXwOy+FnaIaeZN+7io1LCYUHNE+DZ8DjgK/+FYjlsXZ7OUBUsA70qVXlA1o5FC09wlqhfFTXwKGWO+D5OtFBChUnyXIgCtbBAahF9tmUtA/nwl6M88EFywVxEmyCbbACNsM4aAOPJW6S1WTd3WqVgd1F+QLYd6XI0tNj+BnkRPO7XNsQGAufgi+BS0KPwucn6Empn0HlEWJnN4FWejkCZr4FJsAh+ANug5uik/kGXIO+6jENf4VT0GrfSaByQhqo8L8Wtyjq6GP7Dlw3PKt4aHe9Ggq/Q18T8sceBvu4aZ9cy6pISCsOfjc1U9wP02AhxBPY594X3afRRTC2I1ORjAFdqbtJR3AE1sJuMFAXxMdOTFWlr4/CFdhHbYx98D1cT0sGe21ixPKwE5zkfuj9+LGW+GwFv0rdBWyb/1gb63u1PxHUpV26+IUe1KsK3zFU1kMnvjUfhf8D2aXnxu16TasAAAAASUVORK5CYII="
// ─── Icon ────────────────────────────────────────────────────────────────────

// What the menu bar icon shows. Color and badge come from the runs; the dot shows an agent that waits or unread Plane activity.
struct MenuIconState: Equatable {
    let color: NSColor
    let badge: String?
    let label: String
    let active: Bool
    let dot: Bool

    init(runs: [(String, [Run])], waitingAgents: Int, unread: Int, unreadDot: Bool) {
        let (c, b, l) = overallStatus(runs)
        color = c; badge = b
        active = hasActive(runs)
        dot = waitingAgents > 0 || (unreadDot && unread > 0)
        label = waitingAgents > 0 ? "\(l) · \(waitingAgents) session\(waitingAgents == 1 ? "" : "s") wait\(waitingAgents == 1 ? "s" : "")" : l
    }
}

func loadGHIcon() -> NSImage? {
    guard let data = Data(base64Encoded: GH_ICON_B64), let img = NSImage(data: data) else { return nil }
    img.isTemplate = true
    img.size = NSSize(width: 18, height: 18)
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

// Menu bar icon with a small status glyph (check / cross / hourglass) punched into
// the bottom-right corner — the shape conveys state independently of the tint colour.
func statusBadgedIcon(_ base: NSImage?, color: NSColor, badge: String?, dot: Bool = false) -> NSImage {
    guard let base = base else { return NSImage() }
    let sz = base.size
    let img = NSImage(size: sz, flipped: false) { rect in
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
        if let name = badge, let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let b: CGFloat = 10
            let bRect = NSRect(x: sz.width - b, y: 0, width: b, height: b)
            // Punch a clear ring so the badge separates from the cat silhouette.
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                NSColor.black.set()
                NSBezierPath(ovalIn: bRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                ctx.restoreGState()
            }
            let tinted = NSImage(size: bRect.size, flipped: false) { r in
                sym.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: bRect, from: .zero, operation: .sourceOver, fraction: 1.0)
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
        return true
    }
    img.isTemplate = false
    return img
}

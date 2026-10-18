import Foundation

// ─── Snap Basket model ───────────────────────────────────────────────────────
// A basket holds the shots of one project. One basket becomes one intake item.
// All rects are in pixels of the original PNG, from the top-left corner.

struct SnapRect: Codable, Hashable {
    var x, y, w, h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    init(size: CGSize) { self.init(x: 0, y: 0, w: Double(size.width), h: Double(size.height)) }

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var area: Double { w * h }
    var isEmpty: Bool { w <= 0 || h <= 0 }

    func intersection(_ o: SnapRect) -> SnapRect? {
        let r = SnapRect(x: max(x, o.x), y: max(y, o.y), w: min(maxX, o.maxX) - max(x, o.x), h: min(maxY, o.maxY) - max(y, o.y))
        return r.isEmpty ? nil : r
    }

    /// The same size, moved so that it is inside `bounds` where it fits.
    func clamped(to bounds: SnapRect) -> SnapRect {
        var r = self
        r.x = min(max(r.x, bounds.x), max(bounds.x, bounds.maxX - r.w))
        r.y = min(max(r.y, bounds.y), max(bounds.y, bounds.maxY - r.h))
        return r
    }

    /// Relative to the origin of `crop`, rounded to whole pixels.
    func relative(to crop: SnapRect) -> SnapRect {
        SnapRect(x: (x - crop.x).rounded(), y: (y - crop.y).rounded(), w: w.rounded(), h: h.rounded())
    }
}

struct SnapMark: Codable, Hashable {
    var rect: SnapRect
    var note: String
}

/// The parts of a shot that undo and redo cover.
struct SnapEdit: Hashable {
    var marks: [SnapMark]
    var crop: SnapRect
}

struct SnapShot: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case window, area }

    var id: UUID
    var project: String          // project key
    var kind: Kind
    var app: String
    var windowTitle: String
    var pixelSize: CGSize
    var scale: Double
    var crop: SnapRect           // the whole image when not cropped
    var note: String
    var marks: [SnapMark]
    var takenAt: Date

    init(id: UUID = UUID(), project: String, kind: Kind, app: String, windowTitle: String, pixelSize: CGSize, scale: Double,
         crop: SnapRect? = nil, note: String = "", marks: [SnapMark] = [], takenAt: Date = Date()) {
        self.id = id
        self.project = project
        self.kind = kind
        self.app = app
        self.windowTitle = windowTitle
        self.pixelSize = pixelSize
        self.scale = scale
        self.crop = crop ?? SnapRect(size: pixelSize)
        self.note = note
        self.marks = marks
        self.takenAt = takenAt
    }

    var full: SnapRect { SnapRect(size: pixelSize) }
    var isCropped: Bool { crop != full }
    var isBlank: Bool { marks.isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var edit: SnapEdit {
        get { SnapEdit(marks: marks, crop: crop) }
        set { marks = newValue.marks; crop = newValue.crop }
    }

    /// Clips each mark to the crop. A mark that is fully outside goes.
    func apply(crop c: SnapRect) -> (SnapShot, removed: Int) {
        var out = self
        out.crop = c.intersection(full) ?? full
        out.marks = marks.compactMap { m in m.rect.intersection(out.crop).map { SnapMark(rect: $0, note: m.note) } }
        return (out, marks.count - out.marks.count)
    }

    /// Moves a mark and keeps it inside the crop.
    mutating func move(mark i: Int, by d: CGVector) {
        guard marks.indices.contains(i) else { return }
        var r = marks[i].rect
        r.x += Double(d.dx)
        r.y += Double(d.dy)
        marks[i].rect = r.clamped(to: crop)
    }
}

struct SnapBasket: Codable, Hashable, Identifiable {
    enum State: Codable, Hashable {
        case open
        case sent(key: String, session: String?)
        case partial(key: String, missing: [String])   // sent, but some files did not upload
        case copied
    }

    var id: String               // "2026-10-18-143205-sling-platform"
    var project: String
    var shots: [SnapShot]        // the order in the ticket
    var state: State
    var createdAt: Date

    init(project: String, at: Date = Date()) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let slug = project.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        id = f.string(from: at) + "-" + String(slug)
        self.project = project
        shots = []
        state = .open
        createdAt = at
    }

    var isOpen: Bool { state == .open }
    var markCount: Int { shots.reduce(0) { $0 + $1.marks.count } }

    mutating func reorder(_ from: Int, to: Int) {
        guard shots.indices.contains(from), shots.indices.contains(to), from != to else { return }
        shots.insert(shots.remove(at: from), at: to)
    }
}

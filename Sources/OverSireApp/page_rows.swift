import Cocoa
import OverSireCore

// ─── In-place updates ────────────────────────────────────────────────────────
// A page gives its rows with a stable id and a hash. The reconciler keeps the views of the
// rows that did not change, and changes only the others. No view swap, so no flicker.

/// One row of a page. `id` is stable for the same thing (run id, item key, PR repo#number).
struct PageRow {
    let id: String
    /// Changes when the row must update.
    let hash: Int
    let make: () -> NSView
    /// Updates the view in place. With nil, a changed row gets a new view at the same place.
    var update: ((NSView) -> Void)?
    /// The row fills the width of the stack.
    var full = true
    /// A group header of a sticky list. Its copy pins at the top of the list.
    var group = false
    /// The space after the row, when it is not the stack spacing.
    var spacingAfter: CGFloat?

    init(_ id: String, hash: Int, full: Bool = true, update: ((NSView) -> Void)? = nil, make: @escaping () -> NSView) {
        self.id = id
        self.hash = hash
        self.full = full
        self.update = update
        self.make = make
    }

    /// A row whose hash comes from the values that it shows.
    init(_ id: String, _ parts: AnyHashable..., full: Bool = true, update: ((NSView) -> Void)? = nil, make: @escaping () -> NSView) {
        self.init(id, hash: PageRow.hash(parts), full: full, update: update, make: make)
    }

    static func hash(_ parts: [AnyHashable]) -> Int {
        var h = Hasher()
        parts.forEach { h.combine($0) }
        return h.finalize()
    }

    /// The first rows of a long list, and a "Show more" row for the rest. Each row costs layout time.
    /// `reload` builds the page again after a click on "Show more".
    static func limited<T>(_ items: [T], more: MoreRows, reload: @escaping () -> Void, _ row: (T) -> PageRow) -> [PageRow] {
        var out = items.prefix(more.count).map(row)
        let shown = out.count, left = items.count - shown
        guard left > 0 else { return out }
        out.append(PageRow("more", left) {
            let b = ActionButton("Show \(min(left, MoreRows.step)) more", symbol: "chevron.down") {
                more.count = shown + MoreRows.step
                reload()
            }
            let r = NSStackView(h: [b, NSTextField.text("\(left) more in the list", size: 11.5, color: Palette.dim), Spacer()], spacing: 8)
            r.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
            return r
        })
        return out
    }

    /// A list card row: the card stays, and its rows reconcile inside it.
    static func list<C: NSView & RowList>(_ id: String, rows: [PageRow], card: @escaping () -> C) -> PageRow {
        var h = Hasher()
        for r in rows { h.combine(r.id); h.combine(r.hash) }
        return PageRow(id, hash: h.finalize(), update: { ($0 as? C)?.apply(rows) }) {
            let c = card()
            c.apply(rows, mark: false)
            return c
        }
    }
}

/// A part of a page with an optional header row.
struct PageSection {
    let id: String
    var header: PageRow?
    var rows: [PageRow]

    init(_ id: String, header: PageRow? = nil, rows: [PageRow]) {
        self.id = id
        self.header = header
        self.rows = rows
    }

    /// The rows of all sections in order, with the section id in front of each row id.
    static func flatten(_ sections: [PageSection]) -> [PageRow] {
        sections.flatMap { s -> [PageRow] in
            ((s.header.map { [$0] } ?? []) + s.rows).map { r in
                var r2 = PageRow(s.id + "/" + r.id, hash: r.hash, full: r.full, update: r.update, make: r.make)
                r2.group = r.group
                r2.spacingAfter = r.spacingAfter
                return r2
            }
        }
    }

    /// A hash of all ids and hashes. Equal for the same shown data.
    static func fingerprint(_ sections: [PageSection]) -> Int {
        var h = Hasher()
        for s in sections {
            h.combine(s.id)
            if let hd = s.header { h.combine(hd.id); h.combine(hd.hash) }
            for r in s.rows { h.combine(r.id); h.combine(r.hash) }
        }
        return h.finalize()
    }
}

/// Keeps the views of a vertical stack in step with a list of rows. Main thread only.
final class RowReconciler {
    struct Result: Equatable {
        var kept = 0, updated = 0, inserted = 0, removed = 0
        var changed: Int { updated + inserted + removed }
    }

    private unowned let stack: NSStackView
    private let separators: Bool
    private var views: [String: (view: NSView, hash: Int)] = [:]
    private var separatorViews: [String: NSView] = [:]
    private(set) var ids: [String] = []
    private(set) var applied = false
    /// The views of the group headers, in order. A sticky list pins their copies.
    private(set) var groups: [(id: String, view: NSView, hash: Int, make: () -> NSView)] = []

    init(_ stack: NSStackView, separators: Bool = false) {
        self.stack = stack
        self.separators = separators
    }

    func view(_ id: String) -> NSView? { views[id]?.view }

    /// Keeps the views with the same id, updates the rows whose hash changed, inserts and removes the others.
    /// `mark` tints the rows that changed, so the page shows what came in.
    @discardableResult
    func apply(_ input: [PageRow], mark: Bool = true) -> Result {
        let rows = RowReconciler.unique(input)
        let anchor = captureAnchor()
        var result = Result()
        var next: [String: (view: NSView, hash: Int)] = [:]
        var changed: [NSView] = []
        for r in rows {
            if let old = views[r.id] {
                if old.hash == r.hash { next[r.id] = old; result.kept += 1; continue }
                if let update = r.update {
                    update(old.view)
                    next[r.id] = (old.view, r.hash)
                } else {
                    next[r.id] = (r.make(), r.hash)
                }
                result.updated += 1
                changed.append(next[r.id]!.view)
            } else {
                next[r.id] = (r.make(), r.hash)
                result.inserted += 1
                if applied { changed.append(next[r.id]!.view) }
            }
        }
        result.removed = views.keys.filter { next[$0] == nil }.count

        var wanted: [NSView] = []
        var fullViews = Set<ObjectIdentifier>()
        var spacing: [(NSView, CGFloat)] = []
        var seps: [String: NSView] = [:]
        for (i, r) in rows.enumerated() {
            let v = next[r.id]!.view
            if separators && i > 0 {
                let s = separatorViews[r.id] ?? RowReconciler.separator()
                seps[r.id] = s
                wanted.append(s)
                fullViews.insert(ObjectIdentifier(s))
            }
            wanted.append(v)
            if r.full { fullViews.insert(ObjectIdentifier(v)) }
            if let a = r.spacingAfter { spacing.append((v, a)) }
        }
        arrange(wanted, full: fullViews)
        for (v, a) in spacing { stack.setCustomSpacing(a, after: v) }

        views = next
        separatorViews = seps
        ids = rows.map(\.id)
        groups = rows.filter(\.group).map { ($0.id, next[$0.id]!.view, $0.hash, $0.make) }
        applied = true
        restore(anchor)
        if mark, !changed.isEmpty { changed.forEach(RowReconciler.tint) }
        return result
    }

    // Moves the kept views into place, adds the new ones and removes the rest. A view in place stays untouched.
    private func arrange(_ wanted: [NSView], full: Set<ObjectIdentifier>) {
        let keep = Set(wanted.map(ObjectIdentifier.init))
        for v in stack.arrangedSubviews where !keep.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
        for (i, v) in wanted.enumerated() {
            let current = stack.arrangedSubviews
            if i < current.count, current[i] === v { continue }
            let isNew = v.superview !== stack
            stack.insertArrangedSubview(v, at: i)
            if isNew, full.contains(ObjectIdentifier(v)) {
                v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
            }
        }
    }

    // MARK: Anchor

    private struct Anchor { let view: NSView; let offset: CGFloat; let scroll: NSScrollView }

    // The first visible row and its distance from the top of the visible part.
    private func captureAnchor() -> Anchor? {
        guard applied, let scroll = stack.enclosingScrollView, let doc = scroll.documentView else { return nil }
        let top = scroll.contentView.bounds.minY
        guard top > 0 else { return nil }
        for v in stack.arrangedSubviews where !v.isHidden {
            let f = v.convert(v.bounds, to: doc)
            if f.maxY > top { return Anchor(view: v, offset: f.minY - top, scroll: scroll) }
        }
        return nil
    }

    private func restore(_ a: Anchor?) {
        guard let a, a.view.superview === stack, let doc = a.scroll.documentView else { return }
        a.scroll.layoutSubtreeIfNeeded()
        let f = a.view.convert(a.view.bounds, to: doc)
        let maxY = max(0, doc.frame.height - a.scroll.contentView.bounds.height)
        let y = min(max(0, f.minY - a.offset), maxY)
        guard abs(y - a.scroll.contentView.bounds.minY) > 0.5 else { return }
        a.scroll.contentView.scroll(to: NSPoint(x: a.scroll.contentView.bounds.minX, y: y))
        a.scroll.reflectScrolledClipView(a.scroll.contentView)
    }

    // MARK: Parts

    private static func unique(_ rows: [PageRow]) -> [PageRow] {
        var seen: [String: Int] = [:]
        return rows.map { r in
            let n = seen[r.id, default: 0]
            seen[r.id] = n + 1
            guard n > 0 else { return r }
            var r2 = PageRow(r.id + "#\(n)", hash: r.hash, full: r.full, update: r.update, make: r.make)
            r2.group = r.group
            r2.spacingAfter = r.spacingAfter
            return r2
        }
    }

    private static func separator() -> NSView {
        let s = Box(fill: Palette.line, border: nil, radius: 0)
        s.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return s
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A short accent tint that fades out. Not with Reduce Motion.
    static func tint(_ v: NSView) {
        guard !reduceMotion else { return }
        v.wantsLayer = true
        guard let layer = v.layer else { return }
        layer.sublayers?.filter { $0.name == "oversire.mark" }.forEach { $0.removeFromSuperlayer() }
        let mark = CALayer()
        mark.name = "oversire.mark"
        mark.frame = layer.bounds
        mark.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        mark.cornerRadius = layer.cornerRadius
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            mark.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        }
        mark.opacity = 0
        layer.addSublayer(mark)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 2.4
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock { mark.removeFromSuperlayer() }
        mark.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

extension RowList {
    /// Reconciles the rows of the list in place.
    @discardableResult
    func apply(_ rows: [PageRow], mark: Bool = true) -> RowReconciler.Result {
        let r = reconciler.apply(rows, mark: mark)
        didApply()
        return r
    }
}

// ─── Relative times ──────────────────────────────────────────────────────────

/// Keeps the "2m ago" texts current. One timer for all labels. It changes only their strings.
final class TimeTicker {
    static let shared = TimeTicker()

    private let labels = NSHashTable<RelativeTimeLabel>.weakObjects()
    private var timer: Timer?

    func add(_ l: RelativeTimeLabel) {
        labels.add(l)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() { labels.allObjects.forEach { $0.refresh() } }
}

/// A label with a text made from a date, for example "updated 2m ago". The ticker keeps it current.
final class RelativeTimeLabel: NSTextField {
    var date: () -> Date? { didSet { refresh() } }
    private let format: (String) -> String
    private let text: (Date) -> String

    /// `format` gets the relative time, for example "2m ago", and gives the full text.
    /// `text` makes the relative time. Use it for a duration, for example "12m".
    init(_ date: @escaping () -> Date?, size: CGFloat = 11.5, color: NSColor = Palette.dim, lines: Int = 1,
         text: @escaping (Date) -> String = { relativeTime($0) }, format: @escaping (String) -> String = { $0 }) {
        self.date = date
        self.format = format
        self.text = text
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: size)
        textColor = color
        maximumNumberOfLines = lines
        lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        cell?.truncatesLastVisibleLine = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if lines != 1 { preferredMaxLayoutWidth = 0 }
        refresh()
        TimeTicker.shared.add(self)
    }
    convenience init(_ date: Date?, size: CGFloat = 11.5, color: NSColor = Palette.dim, format: @escaping (String) -> String = { $0 }) {
        self.init({ date }, size: size, color: color, format: format)
    }

    /// The time since `start`, for example "12m".
    static func since(_ start: Date) -> RelativeTimeLabel {
        RelativeTimeLabel({ start }, text: { AgentSession.minutes(Date().timeIntervalSince($0)) })
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let s = format(date().map(text) ?? "—")
        if stringValue != s { stringValue = s }
    }
}

// ─── Held updates ────────────────────────────────────────────────────────────

/// Shows over the top of the page while an update waits because the person uses the page.
final class HeldUpdatesPill: Box {
    private let show: ActionButton
    var onShow: (() -> Void)?
    private var pending: DispatchWorkItem?

    init() {
        show = ActionButton("Show", style: .link) {}
        super.init(fill: Palette.raise, border: Palette.line, radius: 14)
        let label = NSTextField.text("New updates", size: 12, weight: .medium)
        let row = NSStackView(h: [Glyph("arrow.down.circle", color: Palette.mut, size: 12), label, show], spacing: 6)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        show.onClick = { [weak self] in self?.onShow?() }
        show.setAccessibilityLabel("Show new updates")
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the pill when the hold lasts more than 0.3 s. Hides it at once when the update applies.
    func set(held: Bool) {
        pending?.cancel()
        pending = nil
        if held {
            let w = DispatchWorkItem { [weak self] in self?.fade(in: true) }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        } else {
            fade(in: false)
        }
    }

    private func fade(in on: Bool) {
        guard on != !isHidden || alphaValue != (on ? 1 : 0) else { return }
        if on {
            isHidden = false
            NSAccessibility.post(element: show, notification: .announcementRequested,
                                 userInfo: [.announcement: "New updates", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        guard !RowReconciler.reduceMotion else { alphaValue = on ? 1 : 0; isHidden = !on; return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self] in
            if !on, self?.alphaValue == 0 { self?.isHidden = true }
        })
    }
}

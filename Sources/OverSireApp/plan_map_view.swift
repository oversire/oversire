import Cocoa
import OverSireCore

/// The Map segment of the Plan tab: the map, the legend and the selected item panel. It follows Map.dc.html.
final class PlanMapPane: NSView {
    /// For `--uishots`: the key whose tip stays open.
    static var preset: String?
    /// The scroll point of the map, by project identifier. A new build keeps it. A shot sets it.
    static var scrolls: [String: NSPoint] = [:]

    private let model: PlanModel
    private let controls: PlanControls
    private weak var host: PlanHost?
    private let geometry: PlanMapModel
    private let map: PlanMapView
    private let scroll = NSScrollView()
    private let panel = PlanItemPanel()
    private var tips: PlanTipPresenter!
    private var scrollWatch: NSObjectProtocol?
    private var restored = false

    init(_ model: PlanModel, controls: PlanControls, host: PlanHost) {
        self.model = model
        self.controls = controls
        self.host = host
        let ident = model.ident
        // A jump from another view: unfold the epic of the item, and show all epics when the item is not in the lanes.
        var target: (key: String?, epic: EpicID?)?
        if let f = controls.focus, f.segment == .map {
            let epic = f.epic ?? f.key.flatMap { model.graph.nodes[$0.uppercased()]?.epic }
            if let epic {
                controls.folded.remove(epic)
                let shown = PlanMap.lanes(model.graph, schedule: model.schedule, epics: model.graph.epics, mode: controls.mode)
                if !shown.contains(where: { $0.epic == epic }) { controls.mode = .all }
            }
            target = (f.key?.uppercased(), epic)
            if let k = f.key { PlanSelection.keys[ident] = k.uppercased() }
            controls.focus = nil
        }
        let lanes = PlanMap.lanes(model.graph, schedule: model.schedule, epics: model.graph.epics, mode: controls.mode)
        geometry = PlanMapModel.build(lanes: lanes, graph: model.graph, schedule: model.schedule, folded: controls.folded, showCritical: controls.critical)
        map = PlanMapView(geometry, plan: model)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .vertical)
        tips = PlanTipPresenter(container: self)

        map.selected = PlanSelection.keys[ident].flatMap { geometry.node($0) != nil ? $0 : nil }
        map.onSelect = { [weak self] k in self?.select(k) }
        map.onFold = { [weak self] id in self?.fold(id) }
        map.onHover = { [weak self] target, rect in self?.hover(target, rect) }

        let box = Box(fill: Palette.bg, border: Palette.line, radius: 10)
        box.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = map
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.setAccessibilityLabel("Dependency map")
        box.addSubview(scroll)
        let legend = Self.legend()
        panel.onJump = { [weak self] k in self?.jump(k) }
        panel.onOpen = { [weak self] k in self?.host?.go(.item(k, .overview)) }
        panel.show(key: map.selected, model: model, showCritical: controls.critical)
        for v in [box, legend, panel] as [NSView] { addSubview(v) }
        let panelFit = panel.heightAnchor.constraint(equalToConstant: 0)
        panelFit.priority = .init(200)
        let boxTall = box.heightAnchor.constraint(equalToConstant: geometry.size.height + 2)
        boxTall.priority = .init(150)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor), box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 260), boxTall,
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            legend.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10), legend.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            legend.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: legend.bottomAnchor, constant: 12), panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 150), panelFit,
        ])

        if let t = target {
            let rect = t.key.flatMap { geometry.node($0)?.frame } ?? geometry.lanes.first { $0.epic == t.epic }.map {
                CGRect(x: PlanMapModel.labelW, y: $0.y, width: 1, height: $0.height)
            }
            if let rect { Self.scrolls[ident] = NSPoint(x: max(0, rect.minX - 420), y: max(0, rect.minY - 170)) }
        }
        scrollWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.map.needsDisplay = true
            if self.restored { Self.scrolls[ident] = self.scroll.contentView.bounds.origin }
            if !self.tips.pinned { self.tips.hide() }
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { scrollWatch.map(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let clip = scroll.contentView.bounds.size
        map.frame.size = NSSize(width: max(geometry.size.width, clip.width), height: max(geometry.size.height, clip.height))
        guard !restored, clip.height > 0 else { return }
        restored = true
        if let p = Self.scrolls[model.ident] { scrollTo(p) }
        if let k = Self.preset, geometry.node(k) != nil {
            map.focusKey = k.uppercased()
            DispatchQueue.main.async { [weak self] in
                guard let self, let n = self.geometry.node(k) else { return }
                self.tips.pinned = true
                self.map.preset(.node(n.key))
            }
        }
    }

    private func scrollTo(_ p: NSPoint) {
        let doc = map.frame.size, clip = scroll.contentView.bounds.size
        let q = NSPoint(x: min(max(0, p.x), max(0, doc.width - clip.width)), y: min(max(0, p.y), max(0, doc.height - clip.height)))
        scroll.contentView.scroll(to: q)
        scroll.reflectScrolledClipView(scroll.contentView)
        Self.scrolls[model.ident] = q
    }

    /// Selects the item and scrolls to it.
    func focus(key: String) {
        let k = key.uppercased()
        guard let n = geometry.node(k) else {
            host?.show(plan: .map, focus: k, epic: nil)
            return
        }
        select(k)
        map.focusKey = k
        reveal(n.frame)
    }

    /// Scrolls to the lane of the epic.
    func focus(epic: EpicID) {
        guard let l = geometry.lanes.first(where: { $0.epic == epic }), !l.folded else {
            host?.show(plan: .map, focus: nil, epic: epic)
            return
        }
        reveal(CGRect(x: PlanMapModel.labelW, y: l.y, width: 1, height: l.height))
    }

    /// Scrolls when the rect is not in full view, past the sticky label column and header.
    private func reveal(_ r: CGRect) {
        let v = scroll.contentView.bounds
        let room = CGRect(x: v.minX + PlanMapModel.labelW, y: v.minY + PlanMapModel.headH, width: v.width - PlanMapModel.labelW,
                          height: v.height - PlanMapModel.headH)
        guard !room.contains(r) else { return }
        scrollTo(NSPoint(x: room.contains(CGPoint(x: r.minX, y: room.midY)) && r.maxX <= room.maxX ? v.minX : r.minX - 420, y: r.minY - 170))
    }

    private func jump(_ key: String) {
        tips.hide()
        focus(key: key)
    }

    private func select(_ key: String?) {
        PlanSelection.keys[model.ident] = key
        map.selected = key
        panel.show(key: key, model: model, showCritical: controls.critical)
    }

    private func fold(_ id: EpicID) {
        if controls.folded.contains(id) { controls.folded.remove(id) } else { controls.folded.insert(id) }
        host?.planChanged()
    }

    private func hover(_ target: PlanMapView.Target?, _ rect: CGRect) {
        guard let target else { tips.release(); return }
        let r = map.convert(rect, to: self)
        let content: PlanItemTip.Content
        switch target {
        case .node(let k): content = .item(k)
        case .pill(let id): content = doneTip(id)
        }
        tips.show(content, model: model, showCritical: controls.critical, near: r) { [weak self] k in self?.jump(k) }
    }

    /// The tip of the DONE pill: the done items of the epic and the last one.
    private func doneTip(_ id: EpicID) -> PlanItemTip.Content {
        let done = model.snap.items.filter { $0.epicId == id && model.snap.isFinished($0) }.sorted { $0.updatedAt > $1.updatedAt }
        let total = (geometry.lanes.first { $0.epic == id }).map { $0.doneCount + $0.open } ?? done.count
        var last = "—"
        if let d = done.first {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d.updatedAt),
                                                       to: Calendar.current.startOfDay(for: model.today)).day ?? 0
            last = d.title + ", " + (days <= 0 ? "today" : days == 1 ? "1 day ago" : "\(days) days ago")
        }
        return .group(epic: model.name(id), progress: "\(done.count) of \(total) done", title: "Done in this epic",
                      body: done.reversed().map(\.title).joined(separator: " · "), row: "Last done", value: last, valueColor: Palette.fg)
    }

    // MARK: Legend

    private static func legend() -> NSView {
        func part(_ kind: MapSwatch.Kind, _ word: String) -> NSView {
            let v = NSStackView(h: [MapSwatch(kind), NSTextField.text(word, size: 12, color: Palette.mut)], spacing: 6)
            v.setAccessibilityElement(true)
            v.setAccessibilityRole(.staticText)
            v.setAccessibilityLabel(word)
            return v
        }
        let note = NSTextField.text("Columns come from the links: an item sits one column after its last blocker.", size: 12, color: Palette.dim)
        return NSStackView(h: [part(.blocks, "blocks"), part(.crosses, "crosses epics"), part(.critical, "critical path"),
                               part(.planned, "planned epic"), note], spacing: 18)
    }
}

/// A small drawn sample for the Map legend.
private final class MapSwatch: NSView {
    enum Kind { case blocks, crosses, critical, planned }
    private let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let w: CGFloat = kind == .planned ? 16 : 26
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: w), heightAnchor.constraint(equalToConstant: 12)])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if kind == .planned {
                let p = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 14, height: 10), xRadius: 3, yRadius: 3)
                p.setLineDash([3, 2], count: 2, phase: 0)
                Palette.dim.setStroke()
                p.stroke()
                return
            }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: 6))
            p.line(to: NSPoint(x: 24, y: 6))
            p.lineWidth = kind == .critical ? 3 : 1.5
            if kind == .crosses { p.setLineDash([5, 3], count: 2, phase: 0) }
            (kind == .critical ? PlanColor.critical : PlanMapView.edgeColor).setStroke()
            p.stroke()
        }
    }
}

/// The drawn map. The label column and the column header stay in view when the map scrolls.
/// Hover or keyboard focus dims the items that are not linked and shows the tip. A click or Return selects.
final class PlanMapView: NSView {
    enum Target: Equatable {
        case node(String)
        case pill(EpicID)
    }

    static let edgeColor = NSColor(name: nil) { a in
        Palette.isDark(a) ? NSColor(srgbRed: 0x6F / 255.0, green: 0x73 / 255.0, blue: 0x7C / 255.0, alpha: 1)
                          : NSColor(srgbRed: 0x8A / 255.0, green: 0x8E / 255.0, blue: 0x96 / 255.0, alpha: 1)
    }

    var model: PlanMapModel { didSet { needsDisplay = true } }
    let plan: PlanModel
    var onSelect: (String?) -> Void = { _ in }
    var onFold: (EpicID) -> Void = { _ in }
    /// The target and its rect in view points. Nil when the pointer leaves the target.
    var onHover: (Target?, CGRect) -> Void = { _, _ in }
    var selected: String? { didSet { if selected != oldValue { needsDisplay = true } } }
    /// The keyboard place. It also dims like a hover.
    var focusKey: String? { didSet { if focusKey != oldValue { needsDisplay = true } } }

    private var hover: Target? { didSet { if hover != oldValue { needsDisplay = true } } }

    /// For `--uishots`: hover the target and show its tip.
    func preset(_ t: Target) {
        hover = t
        onHover(t, rect(t))
    }
    private var tracking: NSTrackingArea?

    init(_ model: PlanMapModel, plan: PlanModel) {
        self.model = model
        self.plan = plan
        super.init(frame: NSRect(origin: .zero, size: model.size))
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dependency map. Arrow keys move between items. Return selects.")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    private var view: CGRect { visibleRect }

    /// The key that dims the map: the hover, else the keyboard place when the map has focus.
    private var lit: String? {
        if case .node(let k)? = hover { return k }
        return window?.firstResponder === self ? focusKey : nil
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let lit = self.lit
            let related = lit.map(model.related) ?? []
            drawLanes()
            drawEdges(lit: lit)
            for (i, l) in model.lanes.enumerated() {
                if let p = l.pill { drawPill(p, lane: l, dim: lit != nil, hot: hover == .pill(l.epic)) }
                if l.folded, let t = l.foldText {
                    Self.text(t, size: 12, color: Palette.dim).draw(at: NSPoint(x: PlanMapModel.labelW + 14, y: l.y + 14))
                }
                _ = i
            }
            for n in model.nodes { drawNode(n, dim: lit != nil && !related.contains(n.key)) }
            drawLabels()
            drawHeader()
        }
    }

    private func drawLanes() {
        for (i, l) in model.lanes.enumerated() {
            let r = NSRect(x: 0, y: l.y, width: bounds.width, height: l.height)
            (i % 2 == 0 ? Palette.fg.withAlphaComponent(0.018) : NSColor.clear).setFill()
            r.fill()
            Palette.line.withAlphaComponent(0.8).setFill()
            NSRect(x: 0, y: l.y + l.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    private func drawEdges(lit: String?) {
        // Plain edges first, so a lit or critical edge draws on top.
        let sorted = model.edges.sorted { rank($0, lit) < rank($1, lit) }
        for e in sorted {
            let near = lit != nil && (e.from == lit || e.to == lit)
            let picked = selected != nil && (e.from == selected || e.to == selected)
            var color = Self.edgeColor, width: CGFloat = 1.5
            if near { color = Palette.acc; width = 2.5 }
            else if e.critical { color = PlanColor.critical; width = 3 }
            else if picked && lit == nil { color = Palette.acc; width = 2 }
            let alpha: CGFloat = lit != nil && !near ? 0.15 : 1
            let p = NSBezierPath()
            p.move(to: e.path[0])
            p.curve(to: e.path[3], controlPoint1: e.path[1], controlPoint2: e.path[2])
            p.lineWidth = width
            if e.crossEpic { p.setLineDash([5, 3], count: 2, phase: 0) }
            color.withAlphaComponent(alpha).setStroke()
            p.stroke()
            let tip = NSPoint(x: e.path[3].x + 6, y: e.path[3].y)
            let head = NSBezierPath()
            head.move(to: NSPoint(x: tip.x - 8, y: tip.y - 4.5))
            head.line(to: tip)
            head.line(to: NSPoint(x: tip.x - 8, y: tip.y + 4.5))
            head.close()
            color.withAlphaComponent(alpha).setFill()
            head.fill()
        }
    }

    private func rank(_ e: PlanMapModel.Edge, _ lit: String?) -> Int {
        if lit != nil && (e.from == lit || e.to == lit) { return 3 }
        if e.critical { return 2 }
        return selected != nil && (e.from == selected || e.to == selected) ? 1 : 0
    }

    private func drawNode(_ n: PlanMapModel.Node, dim: Bool) {
        let alpha: CGFloat = dim ? 0.35 : 1
        let sel = n.key == selected
        let hot = hover == .node(n.key)
        let r = n.frame
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: sel ? 1 : 0.5, dy: sel ? 1 : 0.5), xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        (sel ? Palette.acc.blended(withFraction: 0.88, of: Palette.panel) ?? Palette.panel : Palette.panel).setFill()
        shape.fill()
        if n.critical {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            PlanColor.critical.setFill()
            NSRect(x: r.minX, y: r.minY, width: 4, height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        shape.lineWidth = sel ? 2 : 1
        if n.dashed && !sel { shape.setLineDash([4, 3], count: 2, phase: 0) }
        (sel ? Palette.acc : hot ? Palette.dim : Palette.line).setStroke()
        shape.stroke()
        if n.key == focusKey, window?.firstResponder === self {
            Palette.acc.setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            ring.stroke()
        }
        let x = r.minX + (n.critical ? 10 : 9), w = r.width - (n.critical ? 19 : 18)
        let line = NSMutableAttributedString(string: plan.short(n.key) + " ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: Palette.dim])
        line.append(NSAttributedString(string: n.text, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Palette.fg]))
        line.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: line.length))
        line.draw(with: NSRect(x: x, y: r.minY + 7, width: w, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let (state, color) = plan.state(n.key)
        Self.text(state, size: 11, color: color).draw(with: NSRect(x: x, y: r.minY + 26, width: w, height: 15),
                                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPill(_ r: CGRect, lane: PlanMapModel.Lane, dim: Bool, hot: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(dim ? 0.35 : 1)
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        shape.setLineDash([4, 3], count: 2, phase: 0)
        (hot ? Palette.dim : Palette.line).setStroke()
        shape.stroke()
        Self.text("✓ \(lane.doneCount) done", size: 12.5, weight: .semibold, color: Palette.mut).draw(at: NSPoint(x: r.minX + 9, y: r.minY + 7))
        Self.text("hover for the list", size: 11, color: Palette.dim).draw(at: NSPoint(x: r.minX + 9, y: r.minY + 26))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The sticky label column.
    private func drawLabels() {
        let x0 = view.minX, w = PlanMapModel.labelW
        for (i, l) in model.lanes.enumerated() {
            let r = NSRect(x: x0, y: l.y, width: w, height: l.height)
            Palette.bg.setFill()
            r.fill()
            if i % 2 == 0 {
                Palette.fg.withAlphaComponent(0.018).setFill()
                r.fill()
            }
            Palette.line.withAlphaComponent(0.8).setFill()
            NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
            NSRect(x: r.minX, y: r.maxY - 1, width: w, height: 1).fill()

            let chev = chevron(l)
            Palette.sel.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: chev, xRadius: 4, yRadius: 4).fill()
            let c = Self.text(l.folded ? "▸" : "▾", size: 11, color: Palette.mut)
            let cs = c.size()
            c.draw(at: NSPoint(x: chev.midX - cs.width / 2, y: chev.midY - cs.height / 2))

            let epic = plan.epic(l.epic)
            let readyToClose = l.open == 0 && l.doneCount > 0
            drawGlyph(epic?.state ?? .planned, ready: readyToClose, in: NSRect(x: chev.maxX + 6, y: chev.midY - 6.5, width: 13, height: 13))
            Self.text(plan.name(l.epic), size: 13, weight: .bold, color: Palette.fg)
                .draw(with: NSRect(x: chev.maxX + 25, y: chev.minY + 1, width: r.maxX - chev.maxX - 35, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let (prog, color) = progress(l, epic: epic)
            Self.text(prog, size: 11, color: color).draw(with: NSRect(x: x0 + 32, y: chev.maxY + (l.folded ? 1 : 4), width: w - 42, height: 15),
                                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !l.folded, let why = plan.status(l.epic) {
                let top = chev.maxY + 22
                let t = Self.text("Why: " + why, size: 11.5, color: Palette.mut, wrap: true)
                t.draw(with: NSRect(x: x0 + 32, y: top, width: w - 42, height: max(0, l.y + l.height - top - 6)),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    /// "6/10 · ▲ 3d late · planned" and its color.
    private func progress(_ l: PlanMapModel.Lane, epic: Epic?) -> (String, NSColor) {
        let total = l.doneCount + l.open
        guard total > 0 else { return ("No items yet", Palette.mut) }
        let late = epic.map { plan.schedule.forecast($0, in: plan.graph, today: plan.today).lateBy ?? 0 } ?? 0
        var s = "\(l.doneCount)/\(total)"
        if late > 0 { s += " · ▲ \(late)d late" }
        if epic?.state == .planned { s += " · planned" }
        if epic?.state == .paused { s += " · paused" }
        if l.open == 0 { s += " · ready to close" }
        return (s, late > 0 ? Palette.bad : l.open == 0 ? Palette.ok : Palette.mut)
    }

    private func drawGlyph(_ state: EpicState, ready: Bool, in r: NSRect) {
        let c = EpicColor.accent
        if ready {
            Palette.ok.setFill()
            NSBezierPath(ovalIn: r).fill()
            let t = NSBezierPath()
            t.move(to: NSPoint(x: r.minX + 3.8, y: r.midY + 0.2))
            t.line(to: NSPoint(x: r.minX + 5.7, y: r.midY + 2.2))
            t.line(to: NSPoint(x: r.maxX - 3.4, y: r.midY - 2.2))
            t.lineWidth = 1.6
            Palette.bg.setStroke()
            t.stroke()
            return
        }
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1.4
        if state == .planned { ring.setLineDash([2.2, 1.8], count: 2, phase: 0) }
        c.setStroke()
        ring.stroke()
        c.setFill()
        if state == .active { NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).fill() }
        if state == .paused {
            NSRect(x: r.midX - 2.4, y: r.midY - 2.5, width: 1.6, height: 5).fill()
            NSRect(x: r.midX + 0.8, y: r.midY - 2.5, width: 1.6, height: 5).fill()
        }
    }

    /// The sticky column header.
    private func drawHeader() {
        let r = NSRect(x: view.minX, y: view.minY, width: max(bounds.width, view.width), height: PlanMapModel.headH)
        Palette.side.setFill()
        r.fill()
        Palette.line.setFill()
        NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        let corner = Self.text("EPIC · WHY", size: 11, weight: .semibold, color: Palette.dim, kern: 0.44)
        for (i, name) in PlanMapModel.columns.enumerated() {
            let t = Self.text(name, size: 11, weight: .semibold, color: i == 1 ? Palette.fg : Palette.dim, kern: 0.44)
            let x = PlanMapModel.labelW + CGFloat(i) * PlanMapModel.colW + (PlanMapModel.colW - t.size().width) / 2
            if x + t.size().width > view.minX + PlanMapModel.labelW { t.draw(at: NSPoint(x: x, y: r.minY + 8)) }
        }
        Palette.side.setFill()
        NSRect(x: r.minX, y: r.minY, width: PlanMapModel.labelW, height: PlanMapModel.headH - 1).fill()
        corner.draw(at: NSPoint(x: r.minX + 14, y: r.minY + 8))
    }

    private func chevron(_ l: PlanMapModel.Lane) -> NSRect {
        NSRect(x: view.minX + 8, y: l.y + (l.folded ? 5 : 10), width: 18, height: 18)
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private static let wrapping: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 1
        return p
    }()

    private static func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, kern: CGFloat = 0,
                             wrap: Bool = false) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
                                                   .paragraphStyle: wrap ? wrapping : truncating])
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func inSticky(_ p: NSPoint) -> Bool { p.x < view.minX + PlanMapModel.labelW || p.y < view.minY + PlanMapModel.headH }

    private func hit(_ p: NSPoint) -> Target? {
        guard !inSticky(p) else { return nil }
        if let n = model.nodes.first(where: { $0.frame.contains(p) }) { return .node(n.key) }
        if let l = model.lanes.first(where: { $0.pill?.contains(p) == true }) { return .pill(l.epic) }
        return nil
    }

    private func rect(_ t: Target) -> CGRect {
        switch t {
        case .node(let k): return model.node(k)?.frame ?? .zero
        case .pill(let id): return model.lanes.first { $0.epic == id }?.pill ?? .zero
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard PlanMapPane.preset == nil else { return }
        let h = hit(convert(event.locationInWindow, from: nil))
        guard h != hover else { return }
        hover = h
        onHover(h, h.map(rect) ?? .zero)
    }

    override func mouseExited(with event: NSEvent) {
        guard PlanMapPane.preset == nil, hover != nil else { return }
        hover = nil
        onHover(nil, .zero)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let l = model.lanes.first(where: { chevron($0).insetBy(dx: -3, dy: -3).contains(p) }) {
            onFold(l.epic)
            return
        }
        window?.makeFirstResponder(self)
        if case .node(let k)? = hit(p) {
            focusKey = k
            onSelect(k)
        }
    }

    override func resetCursorRects() {
        for l in model.lanes { addCursorRect(chevron(l), cursor: .pointingHand) }
    }

    // MARK: Keys

    override func becomeFirstResponder() -> Bool {
        if focusKey == nil || model.node(focusKey!) == nil { focusKey = selected ?? model.order.first }
        showFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        if PlanMapPane.preset == nil, hover == nil { onHover(nil, .zero) }
        return true
    }

    private func move(to key: String?) {
        guard let key, let n = model.node(key) else { return }
        focusKey = key
        scrollToVisible(n.frame.insetBy(dx: -PlanMapModel.labelW / 2 - 20, dy: -PlanMapModel.headH - 12))
        showFocus()
    }

    private func showFocus() {
        needsDisplay = true
        guard let k = focusKey, let n = model.node(k) else { return }
        onHover(.node(k), n.frame)
    }

    override func keyDown(with event: NSEvent) {
        let order = model.order
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: move(to: focusKey.flatMap { model.next(from: $0, .left) })
        case 124: move(to: focusKey.flatMap { model.next(from: $0, .right) })
        case 125: move(to: focusKey.flatMap { model.next(from: $0, .down) })
        case 126: move(to: focusKey.flatMap { model.next(from: $0, .up) })
        case 48:
            // Tab and Shift-Tab go through the items, then leave the map.
            let i = focusKey.flatMap { order.firstIndex(of: $0) }
            let j = i.map { $0 + (shift ? -1 : 1) } ?? 0
            if order.indices.contains(j) { move(to: order[j]) }
            else if shift { window?.selectPreviousKeyView(nil) } else { window?.selectNextKeyView(nil) }
        case 36, 76, 49: if let k = focusKey { onSelect(k) }
        case 53: onHover(nil, .zero)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        var out: [Any] = []
        for l in model.lanes {
            let name = plan.name(l.epic)
            out.append(MapElement(role: .button, label: (l.folded ? "Unfold " : "Fold ") + name, frame: chevron(l), parent: self) { [weak self] in
                self?.onFold(l.epic)
            })
            if let p = l.pill {
                out.append(MapElement(role: .staticText, label: "\(l.doneCount) done in \(name)", frame: p, parent: self, press: nil))
            }
            for n in model.nodes where model.lanes.indices.contains(n.lane) && model.lanes[n.lane].epic == l.epic {
                out.append(MapElement(role: .button, label: n.label, frame: n.frame, parent: self) { [weak self] in self?.onSelect(n.key) })
            }
        }
        return out
    }
}

/// One node, pill or fold button of the map for VoiceOver.
private final class MapElement: NSAccessibilityElement {
    private let press: (() -> Void)?

    init(role: NSAccessibility.Role, label: String, frame: CGRect, parent: NSView, press: (() -> Void)?) {
        self.press = press
        super.init()
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        let r = parent.window.map { $0.convertToScreen(parent.convert(frame, to: nil)) } ?? frame
        setAccessibilityFrame(r)
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}

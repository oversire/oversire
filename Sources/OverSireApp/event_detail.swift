import Cocoa
import OverSireCore

// The rows of the Timeline tab open in place (OVERSIRE-398): the fields of the event, the payload as a JSON tree,
// and the text of a comment from the tracker.

/// The Type column: a word for the kind of an event, and a color. The word is the signal.
struct EventTag: Equatable {
    let word: String
    let color: NSColor

    init(_ k: Event.Kind) {
        switch k.rawValue {
        case "comment.created": self.init("comment", Palette.acc)
        case "item.state_changed": self.init("status", Palette.acc)
        case "item.created": self.init("created", Palette.acc)
        case "item.updated": self.init("edited", Palette.acc)
        case "item.shipped": self.init("shipped", Palette.ok)
        case "item.viewed": self.init("viewed", Palette.dim)
        case "item.favorited", "item.unfavorited": self.init("favorite", Palette.dim)
        case "question.answered": self.init("answer", Palette.intake)
        case "pr.opened", "pr.updated", "pr.merged", "pr.closed": self.init("PR", Palette.ok)
        case "ci.queued", "ci.started", "ci.completed", "ci.rerun": self.init("CI", Palette.warn)
        default:
            switch k.domain {
            case "git", "worktree", "release", "review": self.init(k.domain, Palette.ok)
            case "intake": self.init("intake", Palette.acc)
            case "prompt", "turn", "session", "wait", "context", "subagent", "plan": self.init(k.domain, Palette.intake)
            default: self.init(k.domain, Palette.dim)
            }
        }
    }

    private init(_ word: String, _ color: NSColor) {
        self.word = word
        self.color = color
    }

    func view() -> NSView {
        let c = Chiplet(word, color: color)
        c.border = color
        c.keyFocus = false
        return c
    }
}

extension Event {
    /// The summary with no Markdown heading marks: "## Root cause" shows as "Root cause".
    var headline: String {
        let s = self.summary.drop { $0 == "#" }
        return s.count < self.summary.count && s.first == " " ? String(s.dropFirst()) : self.summary
    }

    /// The id of the tracker comment of a comment.created row.
    var commentID: String? {
        guard self.kind == .commentCreated, case .string(let id)? = self.payload?["comment"] else { return nil }
        return id
    }
}

/// A JSON value as lines with roles for the colors. Objects and arrays from foldDepth down, and long strings, start folded.
struct JSONTree {
    enum Role { case key, string, number, literal, punct, note }
    struct Part: Equatable {
        let text: String
        let role: Role
    }
    struct Line: Equatable {
        let depth: Int
        let parts: [Part]
        /// The path of a value that folds, for example "$/failed/0". Nil for a line that does not fold.
        let fold: String?
        let open: Bool
    }

    static let foldDepth = 2
    static let longString = 80
    static let head = 72

    /// The paths that differ from the default.
    private(set) var flipped: Set<String> = []
    /// Fold all or unfold all. Nil: the default of each value.
    private(set) var all: Bool?

    mutating func flip(_ path: String) {
        if flipped.remove(path) == nil { flipped.insert(path) }
    }

    mutating func setAll(open: Bool) {
        all = open
        flipped = []
    }

    private func isOpen(_ path: String, byDefault: Bool) -> Bool { (all ?? byDefault) != flipped.contains(path) }

    func lines(_ v: JSONValue) -> [Line] {
        var out: [Line] = []
        walk(nil, v, "$", 0, last: true, &out)
        return out
    }

    private func walk(_ key: String?, _ v: JSONValue, _ path: String, _ depth: Int, last: Bool, _ out: inout [Line]) {
        var head = key.map { [Part(text: Self.quote($0), role: .key), Part(text: ": ", role: .punct)] } ?? []
        let comma = last ? [] : [Part(text: ",", role: .punct)]
        func leaf(_ text: String, _ role: Role) { out.append(Line(depth: depth, parts: head + [Part(text: text, role: role)] + comma, fold: nil, open: true)) }
        switch v {
        case .object(let o):
            nest(head, comma, o.keys.sorted().map { ($0, o[$0]!) }, array: false, path, depth, &out)
        case .array(let a):
            nest(head, comma, a.map { (nil, $0) }, array: true, path, depth, &out)
        case .string(let s):
            let long = s.count > Self.longString
            let open = !long || isOpen(path, byDefault: false)
            if open {
                head.append(Part(text: Self.quote(s), role: .string))
            } else {
                head.append(Part(text: Self.quote(String(s.prefix(Self.head))).dropLast() + "…\"", role: .string))
                head.append(Part(text: "  +\(s.count - Self.head) chars", role: .note))
            }
            out.append(Line(depth: depth, parts: head + comma, fold: long ? path : nil, open: open))
        case .int(let i): leaf(String(i), .number)
        case .double(let d): leaf(String(d), .number)
        case .bool(let b): leaf(b ? "true" : "false", .literal)
        case .null: leaf("null", .literal)
        }
    }

    private func nest(_ head: [Part], _ comma: [Part], _ items: [(String?, JSONValue)], array: Bool, _ path: String, _ depth: Int,
                      _ out: inout [Line]) {
        let (o, c) = array ? ("[", "]") : ("{", "}")
        if items.isEmpty {
            out.append(Line(depth: depth, parts: head + [Part(text: o + c, role: .punct)] + comma, fold: nil, open: true))
            return
        }
        let fold = depth == 0 ? nil : path
        guard depth == 0 || isOpen(path, byDefault: depth < Self.foldDepth) else {
            let n = items.count, word = array ? (n == 1 ? "item" : "items") : (n == 1 ? "key" : "keys")
            out.append(Line(depth: depth, parts: head + [Part(text: o + " … " + c, role: .punct), Part(text: "  \(n) \(word)", role: .note)] + comma,
                            fold: fold, open: false))
            return
        }
        out.append(Line(depth: depth, parts: head + [Part(text: o, role: .punct)], fold: fold, open: true))
        for (i, (k, v)) in items.enumerated() {
            walk(k, v, path + "/" + (k ?? String(i)), depth + 1, last: i == items.count - 1, &out)
        }
        out.append(Line(depth: depth, parts: [Part(text: c, role: .punct)] + comma, fold: nil, open: true))
    }

    static func quote(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return d.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(s)\""
    }

    /// The whole value, for Copy.
    static func pretty(_ v: JSONValue) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// A scroll view as tall as its content, up to cap. A long payload or comment scrolls inside.
final class CappedScroll: NSScrollView {
    private let cap: CGFloat
    private lazy var height = heightAnchor.constraint(equalToConstant: 20)

    init(cap: CGFloat = 260) {
        self.cap = cap
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        verticalScrollElasticity = .none
        height.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func fit(_ content: CGFloat) { height.constant = min(cap, max(16, ceil(content))) }

    /// Shows the start of the content. A document view that is not flipped starts at its bottom.
    func top() {
        guard let d = documentView else { return }
        superview?.layoutSubtreeIfNeeded()
        contentView.scroll(to: NSPoint(x: 0, y: d.isFlipped ? 0 : max(0, d.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }

    // Content that fits gives the wheel to the page.
    override func scrollWheel(with event: NSEvent) {
        let fits = (documentView?.frame.height ?? 0) <= contentView.bounds.height + 1
        if fits || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// A JSON value with syntax colors. ▸ and ▾ fold a value. Fold all and Unfold all are the keyboard way.
final class JSONTreeView: Box, NSTextViewDelegate {
    private let value: JSONValue
    private var tree = JSONTree()
    private let scroll = CappedScroll()
    private let text = NSTextView()
    private let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private var width: CGFloat = 0

    init(_ value: JSONValue) {
        self.value = value
        super.init(fill: Palette.term, border: Palette.line, radius: 6)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        text.setAccessibilityLabel("Payload")
        scroll.documentView = text
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setAll(open: Bool) {
        tree.setAll(open: open)
        render()
    }

    override func layout() {
        super.layout()
        if abs(scroll.contentView.bounds.width - width) > 0.5 { width = scroll.contentView.bounds.width; measure() }
    }

    private func color(_ r: JSONTree.Role) -> NSColor {
        switch r {
        case .key: return Palette.acc
        case .string: return Palette.ok
        case .number: return Palette.warn
        case .literal: return Palette.intake
        case .punct, .note: return Palette.dim
        }
    }

    private func render() {
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        let s = NSMutableAttributedString()
        for (i, l) in tree.lines(value).enumerated() {
            let p = NSMutableParagraphStyle()
            p.headIndent = CGFloat(l.depth * 2 + 2) * cell
            p.lineSpacing = 2
            let line = NSMutableAttributedString(string: String(repeating: "  ", count: l.depth), attributes: [.font: font])
            if let path = l.fold {
                line.append(NSAttributedString(string: l.open ? "▾ " : "▸ ", attributes: [.font: font, .foregroundColor: Palette.mut, .link: path as NSString,
                                                                                          .toolTip: l.open ? "Fold" : "Unfold"]))
            } else {
                line.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            for part in l.parts {
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(part.role)]
                if part.role == .note { a[.obliqueness] = 0.15 }
                if l.fold != nil, part.role == .note { a[.link] = l.fold! as NSString }
                line.append(NSAttributedString(string: part.text, attributes: a))
            }
            if i > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            line.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: line.length))
            s.append(line)
        }
        text.textStorage?.setAttributedString(s)
        measure()
    }

    private func measure() {
        guard let lm = text.layoutManager, let tc = text.textContainer else { return }
        let w = max(100, scroll.contentView.bounds.width)
        text.frame.size.width = w
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + text.textContainerInset.height * 2
        text.frame.size.height = h
        scroll.fit(h)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let path = link as? String else { return false }
        tree.flip(path)
        render()
        return true
    }
}

/// The comments of items, from the tracker, by item key. Use it on the main thread.
final class CommentBook {
    enum Body: Hashable { case loading, text(String), missing, failed(String) }
    typealias Fetch = (_ key: String, _ done: @escaping (Result<[Comment], ProviderError>) -> Void) -> Void

    /// For `--uishots`: these lists take the place of the tracker.
    static var preset: [String: [Comment]]?
    static let retry: TimeInterval = 60

    private let fetch: Fetch
    private var lists: [String: [Comment]] = [:]
    private var loading: Set<String> = []
    private var failed: [String: (message: String, at: Date)] = [:]
    /// Each comment id starts at most one fetch. A comment that is not in the new list is gone.
    private var asked: Set<String> = []

    init(fetch: @escaping Fetch) { self.fetch = fetch }

    /// The text of comment `id` on item `key`. A comment that is not in the list starts a fetch, and `done` runs after it.
    func body(key: String, id: String, now: Date = Date(), done: @escaping () -> Void) -> Body {
        let k = key.uppercased()
        if let list = Self.preset?[k] ?? lists[k], let c = list.first(where: { $0.id == id }) { return .text(c.body ?? "") }
        if loading.contains(k) { return .loading }
        if let f = failed[k], now.timeIntervalSince(f.at) < Self.retry { return .failed(f.message) }
        if asked.contains(k + "|" + id), failed[k] == nil { return .missing }
        asked.insert(k + "|" + id)
        loading.insert(k)
        failed[k] = nil
        fetch(k) { [weak self] r in
            guard let self else { return }
            self.loading.remove(k)
            switch r {
            case .success(let list): self.lists[k] = list
            case .failure(let e):
                self.failed[k] = (e.message, Date())
                self.asked.remove(k + "|" + id)
            }
            done()
        }
        return .loading
    }
}

/// A Timeline row. Esc closes the open row. The up and down arrows go to the row above or below.
final class EventRow: Row {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53 where onEscape != nil: onEscape?()
        case 125, 126: step(event.keyCode == 125 ? 1 : -1)
        default: super.keyDown(with: event)
        }
    }

    private func step(_ by: Int) {
        let rows = superview?.subviews.compactMap { $0 as? EventRow } ?? []
        guard let i = rows.firstIndex(where: { $0 === self }), rows.indices.contains(i + by) else { return }
        window?.makeFirstResponder(rows[i + by])
    }
}

/// The open Timeline row: a title with the actions, the fields of the event, and the payload.
final class EventDetailCard: Box {
    enum Mode: Int, CaseIterable {
        case payload, raw, rendered
        var title: String { ["Payload", "Raw", "Rendered"][rawValue] }
    }

    private let onClose: () -> Void
    private let onMode: (Mode) -> Void
    private var tree: JSONTreeView?

    /// body: the comment text of a comment.created row, else nil. markdown: the page's view for Raw and Rendered.
    init(_ e: Event, pageKey: String, body: CommentBook.Body?, mode: Mode, markdown: MarkdownView, now: Date = Date(),
         go: @escaping (Route) -> Void, onMode: @escaping (Mode) -> Void, onClose: @escaping () -> Void, onSized: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onMode = onMode
        super.init(fill: Palette.raise, border: Palette.line, radius: 8)
        let tag = EventTag(e.kind)
        let who = TimelineGraphView.who(e)
        var head: [NSView] = [NSTextField.text("\(tag.word.prefix(1).uppercased() + tag.word.dropFirst()) by \(who) · \(dayTime(e.at, now: now))",
                                               size: 13, weight: .semibold), Spacer()]
        if case .string(let s)? = e.payload?["url"], let url = URL(string: s) {
            let where_ = e.provider == "plane" || e.kind == .commentCreated ? "Open in Plane" : e.kind.domain == "ci" ? "Open run" : "Open"
            head.append(ActionButton(where_, symbol: "arrow.up.right.square", style: .ghost) { NSWorkspace.shared.open(url) })
        }
        if let k = e.item, k.uppercased() != pageKey.uppercased() {
            head.append(ActionButton("Open \(k)", style: .ghost) { go(.item(k, .activity)) })
        }
        let shown = body != nil ? mode : .payload
        head.append(ActionButton("Copy", symbol: "doc.on.doc", style: .ghost) {
            if shown != .payload, case .text(let t)? = body { RowActions.copy(t) } else { RowActions.copy(JSONTree.pretty(.object(e.payload ?? [:]))) }
        })
        head.append(ActionButton("Close", style: .ghost) { onClose() })
        let col = NSStackView(v: [NSStackView(h: head, spacing: 6), Self.fields(e, now: now)], spacing: 12)

        var bar: [NSView] = [NSTextField.text("PAYLOAD", size: 10.5, weight: .semibold, color: Palette.dim), Spacer()]
        if body != nil {
            let seg = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
            seg.controlSize = .small
            seg.selectedSegment = mode.rawValue
            seg.setAccessibilityLabel("Payload view")
            seg.target = self
            seg.action = #selector(modeChanged(_:))
            bar.append(seg)
        }
        let content: NSView
        switch (shown, body) {
        case (.payload, _):
            if let p = e.payload, !p.isEmpty {
                let t = JSONTreeView(.object(p))
                tree = t
                bar += [ActionButton("Unfold all", style: .link) { [weak t] in t?.setAll(open: true) },
                        ActionButton("Fold all", style: .link) { [weak t] in t?.setAll(open: false) }]
                content = t
            } else {
                content = NSTextField.text("No payload.", size: 12, color: Palette.dim)
            }
        case (_, .text(let t)?):
            content = Self.markdownBox(markdown, text: t, mode: shown == .raw ? .code : .rendered, sized: onSized)
        case (_, .failed(let m)?):
            content = NSTextField.text("The comment did not load: \(m). It loads again in a minute.", size: 12, color: Palette.bad, lines: 2)
        case (_, .missing?):
            content = NSTextField.text("The tracker has no comment with this id. Someone deleted it.", size: 12, color: Palette.dim, lines: 2)
        default:
            content = LoadingNote("Loading the comment", height: 60, compact: true)
        }
        col.addFull(NSStackView(v: [NSStackView(h: bar, spacing: 8), content].map { $0 }, spacing: 6))
        for v in col.arrangedSubviews { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        if let s = (col.arrangedSubviews.last as? NSStackView) { for v in s.arrangedSubviews { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true } }
        addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 12), col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Details of the event")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose(); return }
        super.keyDown(with: event)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) { onMode(Mode(rawValue: sender.selectedSegment) ?? .rendered) }

    /// Two columns of name and value. Empty fields do not show.
    private static func fields(_ e: Event, now: Date) -> NSView {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM yyyy, HH:mm:ss"
        let all: [(String, String?)] = [
            ("Kind", e.kind.rawValue), ("Actor", "\(e.actor) (\(e.actorType.rawValue))"), ("On behalf", e.onBehalf), ("Via", e.via),
            ("Provider", e.provider), ("Project", e.project), ("Repo", e.repo), ("Machine", e.machine), ("Session", e.session),
            ("Item", e.item), ("Parent", e.parentItem), ("At", f.string(from: e.at)), ("Seen", f.string(from: e.seenAt)),
            ("Private", e.isPrivate ? "yes, the text stays on your Macs" : nil), ("Event id", e.id),
        ]
        let rows: [NSView] = all.compactMap { k, v in
            guard let v, !v.isEmpty else { return nil }
            let key = NSTextField.text(k, size: 12, color: Palette.dim)
            key.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let val = NSTextField.text(v, size: 11.5, mono: true)
            val.lineBreakMode = .byTruncatingMiddle
            val.isSelectable = true
            val.toolTip = v
            return NSStackView(h: [key, val], spacing: 8, align: .firstBaseline)
        }
        let half = (rows.count + 1) / 2
        let left = NSStackView(v: Array(rows.prefix(half)), spacing: 5), right = NSStackView(v: Array(rows.dropFirst(half)), spacing: 5)
        let grid = NSStackView(h: [left, right], spacing: 24, align: .top)
        grid.distribution = .fillEqually
        return grid
    }

    /// The Markdown view in a box of at most 260 pt that scrolls.
    private static func markdownBox(_ m: MarkdownView, text: String, mode: MarkdownView.Mode, sized: (() -> Void)?) -> NSView {
        let box = Box(fill: Palette.panel, border: Palette.line, radius: 6)
        let scroll = CappedScroll()
        m.removeFromSuperview()
        m.autoresizingMask = [.width]
        m.frame = NSRect(x: 0, y: 0, width: 600, height: max(20, m.contentHeight))
        scroll.documentView = m
        scroll.fit(m.contentHeight)
        m.onHeight = { [weak m, weak scroll] h in
            m?.frame.size.height = h
            scroll?.fit(h)
            DispatchQueue.main.async {
                scroll?.top()
                sized?()
            }
        }
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        m.show(text, mode: mode)
        return box
    }
}

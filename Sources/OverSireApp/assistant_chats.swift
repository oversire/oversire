import Cocoa
import OverSireCore
import OverSireAI

// ─── Assistant chats ─────────────────────────────────────────────────────────
// The chat list of the assistant panel: a search, the pinned chats, then the chats by day.

final class AssistantChats: NSView, NSSearchFieldDelegate {
    var onOpen: ((String) -> Void)?
    var onPin: ((String, Bool) -> Void)?
    var onDelete: ((String) -> Void)?

    let search = NSSearchField()
    private let scroll = PageScroll(maxWidth: 4000)
    private var threads: [AssistantThread] = []
    private var current: String?
    private var running: (String) -> Bool = { _ in false }
    private var label: (EngineID) -> String = { $0.rawValue }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search chats"
        search.setAccessibilityLabel("Search chats")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        scroll.column.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 14, right: 10)
        scroll.column.spacing = 2
        let note = NSTextField.text("Chats stay on this Mac. With the daemon on, they can sync to your home store.", size: 11, color: Palette.dim, lines: 0)
        addSubview(search)
        addSubview(scroll)
        addSubview(note)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ threads: [AssistantThread], current: String?, running: @escaping (String) -> Bool, label: @escaping (EngineID) -> String) {
        self.threads = threads
        self.current = current
        self.running = running
        self.label = label
        build()
    }

    func controlTextDidChange(_ obj: Notification) { build() }

    /// The groups of the list: Pinned, Today, Yesterday, Earlier. A search matches the title.
    static func groups(_ threads: [AssistantThread], query: String, now: Date, calendar: Calendar = .current) -> [(String, [AssistantThread])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = threads.filter { q.isEmpty || $0.title.lowercased().contains(q) }.sorted { $0.updatedAt > $1.updatedAt }
        var out: [(String, [AssistantThread])] = []
        func add(_ title: String, _ list: [AssistantThread]) { if !list.isEmpty { out.append((title, list)) } }
        add("Pinned", shown.filter(\.pinned))
        let rest = shown.filter { !$0.pinned }
        add("Today", rest.filter { calendar.isDate($0.updatedAt, inSameDayAs: now) })
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        add("Yesterday", rest.filter { calendar.isDate($0.updatedAt, inSameDayAs: yesterday) })
        add("Earlier", rest.filter { !calendar.isDate($0.updatedAt, inSameDayAs: now) && !calendar.isDate($0.updatedAt, inSameDayAs: yesterday) })
        return out
    }

    private func build() {
        let groups = Self.groups(threads, query: search.stringValue, now: Date())
        scroll.rebuild { col in
            if groups.isEmpty {
                col.addFull(EmptyNote(search.stringValue.isEmpty ? "No chats yet." : "No chat matches.", symbol: "bubble.left.and.bubble.right"))
            }
            for (title, list) in groups {
                let head = NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim)
                let pad = NSStackView(h: [head], spacing: 0)
                pad.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 4, right: 6)
                col.addFull(pad)
                for t in list { col.addFull(row(t)) }
            }
        }
    }

    private func row(_ t: AssistantThread) -> NSView {
        let title = NSTextField.text(t.title, size: 12.5, weight: .medium)
        var small: [NSView] = []
        if let key = t.subjects.lazy.compactMap(Self.label).first {
            small.append(Chiplet(key, symbol: "smallcircle.filled.circle", color: AI_COLOR))
        }
        small.append(NSTextField.text(label(t.engine), size: 11, color: Palette.dim))
        if let m = t.machines, !m.isEmpty { small.append(NSTextField.text("· " + m.joined(separator: ", "), size: 11, color: Palette.dim)) }
        let lines = NSStackView(v: [title, NSStackView(h: small, spacing: 6)], spacing: 3)
        var trail: [NSView] = []
        if running(t.id) { trail.append(Glyph(.running, size: 11)) }
        if t.pinned { trail.append(Glyph("pin.fill", color: Palette.dim, size: 10, label: "Pinned")) }
        trail.append(NSTextField.text(relativeTime(t.updatedAt), size: 11, color: Palette.dim))
        let r = Row([lines, Spacer()] + trail, height: 46, inset: 8, label: "\(t.title), \(relativeTime(t.updatedAt))") { [weak self] in self?.onOpen?(t.id) }
        r.selected = t.id == current
        r.menuItems = { [weak self] in
            [SnapMenuItem(title: t.pinned ? "Unpin" : "Pin") { self?.onPin?(t.id, !t.pinned) },
             SnapMenuItem(title: "Delete…") {
                 AlertConfirm.ask("Delete this chat?", info: "“\(t.title)” and its files go away from this Mac.", button: "Delete", critical: true, in: self?.window) {
                     self?.onDelete?(t.id)
                 }
             }]
        }
        return r
    }

    static func label(_ s: SubjectRef) -> String? {
        switch s {
        case .item(let r): return r.key
        case .change(let r): return "#\(r.number)"
        case .repo(let r): return r.path
        default: return nil
        }
    }
}

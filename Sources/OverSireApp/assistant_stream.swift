import Cocoa
import OverSireCore
import OverSireAI
import OverSireAssistant

// ─── Assistant stream ────────────────────────────────────────────────────────
// The messages of the open chat. ReplyItem.make turns the parts of an answer into blocks.
// The views keep their place over updates, so the Markdown views do not load again.

/// The color of the assistant.
let AI_COLOR = Palette.intake

/// One tool call of an answer, as a row of the tool group.
struct ToolChip: Equatable {
    enum State: Equatable { case running, waits, asks, ok, failed, denied, skipped }

    let id: String
    var state: State
    let source: String
    let line: String
    let time: String?
    let input: String
    let output: String?

    static func seconds(_ s: TimeInterval) -> String {
        s < 10 ? String(format: "%.1f s", max(0, s)) : "\(Int(s.rounded())) s"
    }
}

extension ToolChip.State {
    var symbol: String {
        switch self {
        case .running: return "circle.dashed"
        case .waits: return "clock"
        case .asks: return "hand.raised.fill"
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .denied: return "nosign"
        case .skipped: return "pause.circle"
        }
    }

    var word: String {
        switch self {
        case .running: return "Running"
        case .waits: return "Waits"
        case .asks: return "Asks you"
        case .ok: return "Done"
        case .failed: return "Failed"
        case .denied: return "Denied"
        case .skipped: return "Skipped"
        }
    }

    var color: NSColor {
        switch self {
        case .running: return Palette.run
        case .waits, .skipped, .denied: return Palette.dim
        case .asks: return Palette.warn
        case .ok: return Palette.ok
        case .failed: return Palette.bad
        }
    }

    var tone: Tone { Tone(symbol: symbol, color: color, word: word, spins: self == .running) }
}

/// The data source of a tool, for the chip: the machine of the call, or the provider of the action.
enum ToolSource {
    static func name(_ tool: String, args: JSONValue) -> String {
        if let m = args["machine"]?.string, !m.isEmpty { return m }
        switch tool.split(separator: "_").first.map(String.init) ?? tool {
        case "item", "intake", "project", "plan", "work": return "Plane"
        case "pr", "repo": return "GitHub"
        case "run": return "Actions"
        case "session", "worktree": return "Orca"
        case "queue": return "Queue"
        case "question": return "Daemon"
        case "machine", "group": return "Group"
        default: return "OverSire"
        }
    }

    static func symbol(_ source: String) -> String {
        switch source {
        case "Plane": return "checklist"
        case "GitHub": return "arrow.triangle.pull"
        case "Actions": return "play.circle"
        case "Orca": return "terminal"
        case "Queue": return "list.number"
        case "Daemon": return "server.rack"
        case "OverSire": return "sparkles"
        // The tools of a session chat.
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "MultiEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        default: return "desktopcomputer"
        }
    }
}

/// One block of an answer.
enum ReplyItem: Equatable {
    case thought(String, seconds: Int?)
    case tools([ToolChip])
    case text(String)
    case navigation(route: String, focus: String?, from: String?)
    case notice(code: String, text: String)
    case ask(AssistantController.Ask, title: String)
    case status(String)
    case replies([String])

    /// `live` is set while the answer runs. `last`: the last answer of the chat, which gets the quick replies.
    static func make(_ parts: [AssistantPart], live: AssistantController.Live?, titles: [String: String], last: Bool) -> [ReplyItem] {
        var results: [String: ToolResult] = [:]
        var approvals: [String: Approval] = [:]
        for p in parts {
            if case .toolResult(let r) = p { results[r.call] = r }
            if case .approval(let a) = p { approvals[a.call] = a }
        }
        let asking = Set(live?.asks.map(\.call.id) ?? [])
        var firstOpen = true
        var out: [ReplyItem] = []
        for p in parts {
            switch p {
            case .text(let t):
                if case .text(let old)? = out.last { out[out.count - 1] = .text(old + t) } else { out.append(.text(t)) }
            case .thought(let t, _):
                let secs = live.flatMap { l in l.thoughtStart.map { Int(((l.thoughtEnd ?? Date()).timeIntervalSince($0)).rounded()) } }
                out.append(.thought(t, seconds: secs))
            case .toolCall(let c):
                var state: ToolChip.State
                if let r = results[c.id] {
                    switch r.status {
                    case .ok: state = .ok
                    case .failed: state = .failed
                    case .denied: state = .denied
                    case .skipped: state = .skipped
                    }
                } else if asking.contains(c.id) {
                    state = .asks
                } else if live != nil {
                    state = firstOpen ? .running : .waits
                    firstOpen = false
                } else {
                    state = .skipped
                }
                let chip = ToolChip(id: c.id, state: state, source: ToolSource.name(c.tool, args: c.args),
                                    line: results[c.id]?.summary ?? line(c, titles), time: time(c.id, live, approvals[c.id]),
                                    input: "→ \(c.tool)(\(c.args.text))", output: results[c.id].map(output))
                if case .tools(var chips)? = out.last { chips.append(chip); out[out.count - 1] = .tools(chips) } else { out.append(.tools([chip])) }
            case .navigation(let r, let f, let from): out.append(.navigation(route: r, focus: f, from: from))
            case .notice(let code, let text): out.append(.notice(code: code, text: text))
            case .toolResult, .approval, .image, .file, .mention: continue
            }
        }
        if let live {
            for a in live.asks { out.append(.ask(a, title: titles[a.call.tool] ?? a.call.tool)) }
            if live.asks.isEmpty, let s = status(out) { out.append(.status(s)) }
        } else if last, case .text(let t)? = out.last {
            let (body, replies) = QuickReplies.split(t)
            if !replies.isEmpty {
                out[out.count - 1] = .text(body)
                out.append(.replies(replies))
            }
        }
        return out
    }

    private static func line(_ c: ToolCall, _ titles: [String: String]) -> String {
        let title = titles[c.tool] ?? c.tool.replacingOccurrences(of: "_", with: " ")
        let arg = ["key", "item", "pr", "run", "session", "id", "repo"].lazy.compactMap { k -> String? in
            guard let v = c.args[k] else { return nil }
            return v.string ?? v.int.map(String.init)
        }.first
        return arg.map { "\(title) · \($0)" } ?? title
    }

    private static func time(_ id: String, _ live: AssistantController.Live?, _ a: Approval?) -> String? {
        if let by = a?.by, by.hasPrefix("chat:") { return "Your rule" }
        if let s = live?.started[id], let e = live?.ended[id] { return ToolChip.seconds(e.timeIntervalSince(s)) }
        if a?.decision == .approved { return "Approved" }
        return nil
    }

    private static func output(_ r: ToolResult) -> String {
        var s = "← " + r.summary
        if let d = r.data?.text, !d.isEmpty { s += "\n" + (d.count > 600 ? String(d.prefix(600)) + "…" : d) }
        return s
    }

    private static func status(_ items: [ReplyItem]) -> String? {
        for case .tools(let chips) in items.reversed() {
            if let c = chips.first(where: { $0.state == .running }) { return c.line + "…" }
        }
        switch items.last {
        case nil, .thought?: return "Thinking…"
        case .tools?: return "Writing…"
        default: return nil
        }
    }
}

/// The quick replies of an answer: a last line "Replies: a | b | c". The system prompt asks for it.
enum QuickReplies {
    static func split(_ text: String) -> (String, [String]) {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), last.lowercased().hasPrefix("replies:") else { return (text, []) }
        let replies = last.dropFirst("replies:".count).split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lines.removeLast()
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), Array(replies.prefix(4)))
    }
}

/// The handlers and the shared view state of the stream.
final class StreamContext {
    var answer: (String, ApprovalAnswer) -> Void = { _, _ in }
    var goBack: (String) -> Void = { _ in }
    var stopFollow: () -> Void = {}
    var reply: (String) -> Void = { _ in }
    var retry: () -> Void = {}
    var openSettings: () -> Void = {}
    var blob: (String) async -> Data? = { _ in nil }
    var follows = true
    /// Open tool groups, tool rows and thoughts.
    var open: Set<String> = []
    /// A block changed its height.
    var resized: () -> Void = {}
}

// MARK: - The stream view

final class AssistantStream: NSView {
    let ctx = StreamContext()
    private let scroll = PageScroll(maxWidth: 4000)
    private var views: [String: NSView] = [:]
    private var pinned = true

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scroll.column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        scroll.column.spacing = 14
        scroll.setAccessibilityLabel("Chat")
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        ctx.resized = { [weak self] in self?.keepEnd() }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() {
        guard let doc = scroll.documentView else { return }
        pinned = scroll.contentView.bounds.maxY >= doc.frame.height - 40
    }

    private func keepEnd() {
        guard pinned else { return }
        layoutSubtreeIfNeeded()
        scroll.toEnd()
    }

    func toEnd() {
        pinned = true
        keepEnd()
    }

    /// The approval cards that show now.
    var askCards: [ApprovalCard] { views.values.compactMap { $0 as? ReplyView }.flatMap(\.askCards) }

    /// Shows the chat of the controller. `hello` shows when the chat is empty.
    func show(_ c: AssistantController, hello: @escaping () -> NSView) {
        ctx.follows = c.follows
        var keys: [(String, () -> NSView)] = []
        let msgs = c.messages
        let live = c.live
        if msgs.isEmpty && live == nil && c.problem == nil { keys.append(("hello", hello)) }
        let lastAnswer = msgs.last { $0.role == .assistant }?.id
        for m in msgs {
            if m.role == .user {
                keys.append((m.id, { [ctx] in UserBubble(m.parts, caption: nil, ctx: ctx) }))
            } else {
                let items = ReplyItem.make(m.parts, live: nil, titles: c.toolTitles, last: m.id == lastAnswer && live == nil)
                // The move shows before the answer, as in the run.
                if let moved = c.moves[m.id] { keys.append(("move:" + m.id, { NoticeCard(code: "moved", text: moved) })) }
                keys.append((m.id, { [ctx] in ReplyView(id: m.id, engine: c.label(m.engine), ctx: ctx) }))
                update[m.id] = items
                engines[m.id] = c.label(m.engine)
            }
        }
        if let live {
            keys.append(("pending-user", { [ctx] in UserBubble(live.user.parts, caption: nil, ctx: ctx) }))
            if let moved = live.moved { keys.append(("move-live", { NoticeCard(code: "moved", text: moved) })) }
            let id = live.answer?.id ?? "live"
            let engine = c.label(live.answer?.engine ?? c.currentEngine)
            keys.append((id, { [ctx] in ReplyView(id: id, engine: engine, ctx: ctx) }))
            engines[id] = engine
            update[id] = ReplyItem.make(live.answer?.parts ?? [], live: live, titles: c.toolTitles, last: true)
        }
        if let q = c.waiting {
            let parts: [AssistantPart] = [.text(q.text)]
            keys.append(("queued:\(q.text.hashValue)", { [ctx] in UserBubble(parts, caption: "Sends after this step", ctx: ctx) }))
        }
        if let p = c.problem {
            keys.append(("problem:\(p.code):\(p.message)", { [ctx] in ProblemCard(p, ctx: ctx) }))
        }
        apply(keys)
        update = [:]
        engines = [:]
        keepEnd()
    }

    private var update: [String: [ReplyItem]] = [:]
    private var engines: [String: String] = [:]

    private func apply(_ keys: [(String, () -> NSView)]) {
        var next: [String: NSView] = [:]
        var order: [NSView] = []
        for (k, make) in keys {
            // A stored message takes the view of the run, so the text does not load again.
            let v = views[k] ?? (k.hasPrefix("move") || k.hasPrefix("queued") || k.hasPrefix("problem") || k == "hello" ? nil : adopt(k)) ?? make()
            if let r = v as? ReplyView, let items = update[k] {
                r.update(items)
                if let e = engines[k] { r.engine = e }
            }
            next[k] = v
            order.append(v)
        }
        views = next
        let col = scroll.column
        let now = col.arrangedSubviews
        var same = 0
        while same < min(now.count, order.count), now[same] === order[same] { same += 1 }
        for v in now[same...] { v.removeFromSuperview() }
        for v in order[same...] { col.addFull(v) }
    }

    private func adopt(_ key: String) -> NSView? {
        if let v = views["live"] as? ReplyView, update[key] != nil { views["live"] = nil; return v }
        if update[key] == nil, let v = views["pending-user"] as? UserBubble, key != "pending-user" { views["pending-user"] = nil; return v }
        return nil
    }
}

// MARK: - User bubble

final class UserBubble: NSView {
    init(_ parts: [AssistantPart], caption: String?, ctx: StreamContext) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let bubble = Box(fill: Palette.raise, border: Palette.line, radius: 12)
        let stack = NSStackView(v: [], spacing: 6, align: .trailing)
        var chips: [NSView] = []
        var text = ""
        for p in parts {
            switch p {
            case .text(let t): text += t
            case .image(let blob, _, _, _): chips.append(BlobThumb(blob, ctx: ctx))
            case .file(_, let name, _, let bytes):
                chips.append(Chiplet("\(name) \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))", symbol: "doc"))
            case .mention(_, let label): chips.append(Chiplet(label ?? "Item", symbol: "smallcircle.filled.circle", color: AI_COLOR))
            default: break
            }
        }
        if !chips.isEmpty { stack.addArrangedSubview(NSStackView(h: chips, spacing: 6)) }
        if !text.isEmpty {
            let l = NSTextField.text(text, size: 13, lines: 0)
            l.isSelectable = true
            stack.addArrangedSubview(l)
        }
        bubble.addSubview(stack)
        addSubview(bubble)
        var c = [
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11),
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.88),
        ]
        if let caption {
            bubble.border = Palette.dim
            let cap = NSStackView(h: [Glyph("clock", color: Palette.dim, size: 10), NSTextField.text(caption, size: 11, color: Palette.dim)], spacing: 4)
            addSubview(cap)
            c += [cap.trailingAnchor.constraint(equalTo: trailingAnchor), cap.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 4),
                  cap.bottomAnchor.constraint(equalTo: bottomAnchor)]
        } else {
            c.append(bubble.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(c)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("You: " + text)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An image of a message, loaded from the blob store.
final class BlobThumb: NSImageView {
    init(_ blob: String, ctx: StreamContext) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 64), heightAnchor.constraint(equalToConstant: 44)])
        setAccessibilityLabel("Image")
        Task { [weak self] in
            guard let d = await ctx.blob(blob) else { return }
            self?.image = NSImage(data: d)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Answer

final class ReplyView: NSStackView {
    let id: String
    private let ctx: StreamContext
    private var items: [ReplyItem] = []
    private var itemViews: [NSView] = []
    private let head: NSView
    private let engineLabel: NSTextField
    /// A run can move to another engine.
    var engine: String {
        get { String(engineLabel.stringValue.dropFirst(2)) }
        set { if newValue != engine { engineLabel.stringValue = "· " + newValue } }
    }

    init(id: String, engine: String, ctx: StreamContext) {
        self.id = id
        self.ctx = ctx
        engineLabel = NSTextField.text("· " + engine, size: 12, color: Palette.dim)
        head = NSStackView(h: [Glyph("sparkles", color: AI_COLOR, size: 11), NSTextField.text("Assistant", size: 12, weight: .semibold, color: AI_COLOR),
                               engineLabel], spacing: 5)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(head)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Assistant answer")
    }
    required init?(coder: NSCoder) { fatalError() }

    var askCards: [ApprovalCard] { itemViews.compactMap { $0 as? ApprovalCard } }

    func update(_ new: [ReplyItem]) {
        var next: [NSView] = []
        for (i, it) in new.enumerated() {
            if i < items.count, items[i] == it { next.append(itemViews[i]); continue }
            if i < items.count, case .text = items[i], case .text(let t) = it, let b = itemViews[i] as? MarkdownBlock {
                b.show(t)
                next.append(b)
                continue
            }
            next.append(make(it, index: i))
        }
        let now = Array(arrangedSubviews.dropFirst())
        var same = 0
        while same < min(now.count, next.count), now[same] === next[same] { same += 1 }
        for v in now[same...] { v.removeFromSuperview() }
        for v in next[same...] { addFull(v) }
        items = new
        itemViews = next
    }

    private func make(_ it: ReplyItem, index: Int) -> NSView {
        switch it {
        case .text(let t):
            let b = MarkdownBlock(ctx: ctx)
            b.show(t)
            return b
        case .thought(let t, let secs): return ThoughtView(t, seconds: secs, key: "\(id):thought:\(index)", ctx: ctx)
        case .tools(let chips): return ToolGroupView(chips, ctx: ctx)
        case .navigation(let r, let f, let from): return NavigationCard(route: r, focus: f, from: from, ctx: ctx)
        case .notice(let code, let text): return NoticeCard(code: code, text: text)
        case .ask(let a, let title):
            let card = ApprovalCard(a.call, title: title, note: a.note) { [ctx] answer in ctx.answer(a.call.id, answer) }
            return card
        case .status(let s):
            return NSStackView(h: [Glyph(.running, size: 12), NSTextField.text(s, size: 12, color: Palette.mut)], spacing: 6)
        case .replies(let rs):
            return Wrap(rs.map { r in
                let c = Chiplet(r, symbol: "arrowshape.turn.up.left", color: Palette.fg, fill: Palette.panel) { [ctx] in ctx.reply(r) }
                c.radius = 11
                c.setAccessibilityLabel("Reply: " + r)
                return c
            })
        }
    }
}

/// Markdown text that grows to its content.
final class MarkdownBlock: NSView {
    private let md = MarkdownView(width: 360)
    private var height: NSLayoutConstraint!

    init(ctx: StreamContext) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(md)
        md.autoresizingMask = [.width, .height]
        md.frame = bounds
        height = heightAnchor.constraint(equalToConstant: 18)
        height.isActive = true
        md.onHeight = { [weak self] h in
            self?.height.constant = max(18, h)
            ctx.resized()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) { md.show(text, mode: .rendered) }
}

/// The thought of the model, closed by default.
final class ThoughtView: NSStackView {
    init(_ text: String, seconds: Int?, key: String, ctx: StreamContext) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        let open = ctx.open.contains(key)
        let title = seconds.map { "Thought for \(max(1, $0)) s" } ?? "Thought"
        let body = NSTextField.text(text, size: 12, color: Palette.mut, lines: 0)
        body.isSelectable = true
        body.isHidden = !open
        let button = ActionButton(title, symbol: open ? "chevron.down" : "chevron.right", style: .link)
        button.contentTintColor = Palette.mut
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Palette.mut, .font: NSFont.systemFont(ofSize: 12)])
        button.setAccessibilityLabel(title + (open ? ", open" : ", closed"))
        button.onClick = { [weak button, weak body] in
            let on = !ctx.open.contains(key)
            if on { ctx.open.insert(key) } else { ctx.open.remove(key) }
            body?.isHidden = !on
            button?.image = NSImage(systemSymbolName: on ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            button?.setAccessibilityLabel(title + (on ? ", open" : ", closed"))
            ctx.resized()
        }
        addArrangedSubview(button)
        addFull(body)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Tool group

final class ToolGroupView: Box {
    /// `canRetry`: a failed step shows a Retry button.
    init(_ chips: [ToolChip], ctx: StreamContext, canRetry: Bool = true) {
        super.init(fill: Palette.panel, border: Palette.line, radius: 8)
        let key = "group:" + (chips.first?.id ?? "")
        let failed = chips.filter { $0.state == .failed }.count
        let done = chips.filter { ![.running, .waits, .asks].contains($0.state) }.count
        let busy = done < chips.count
        let open = busy || failed > 0 || chips.contains { $0.state != .ok } ? !ctx.open.contains(key + ":shut") : ctx.open.contains(key)
        let tone: Tone
        let title: String
        if busy {
            tone = .running
            title = "Working · \(done) of \(chips.count)"
        } else if failed > 0 {
            tone = ToolChip.State.failed.tone
            title = failed == 1 ? "1 step failed" : "\(failed) steps failed"
        } else {
            tone = ToolChip.State.ok.tone
            title = chips.count == 1 ? "1 step done" : "\(chips.count) steps done"
        }
        let rows = NSStackView(v: [], spacing: 0)
        rows.isHidden = !open
        let chevron = Glyph(open ? "chevron.down" : "chevron.right", color: Palette.dim, size: 10)
        var headViews: [NSView] = [Glyph(tone, size: 12), NSTextField.text(title, size: 12, weight: .medium, color: Palette.fg), Spacer()]
        if failed > 0, canRetry { headViews.append(ActionButton("Retry", symbol: "arrow.clockwise", style: .link) { ctx.retry() }) }
        headViews.append(chevron)
        let head = Row(headViews, height: 26, inset: 8, label: "\(title). \(open ? "Open" : "Closed")")
        head.onClick = { [weak rows, weak head] in
            guard let rows else { return }
            let on = rows.isHidden
            rows.isHidden = !on
            if busy || failed > 0 || chips.contains(where: { $0.state != .ok }) {
                if on { ctx.open.remove(key + ":shut") } else { ctx.open.insert(key + ":shut") }
            } else if on { ctx.open.insert(key) } else { ctx.open.remove(key) }
            chevron.image = NSImage(systemSymbolName: on ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            head?.setAccessibilityLabel("\(title). \(on ? "Open" : "Closed")")
            ctx.resized()
        }
        head.setAccessibilityRole(.button)
        for c in chips { rows.addFull(ToolChipRow(c, ctx: ctx)) }
        let stack = NSStackView(v: [head, rows], spacing: 2)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor), rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tool steps")
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One tool call: state, source, line and time. A click shows the input and the output.
final class ToolChipRow: NSStackView {
    init(_ c: ToolChip, ctx: StreamContext) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        let key = "chip:" + c.id
        // The word never cuts: color is not the only signal. The summary cuts first.
        let word = NSTextField.text(c.state.word, size: 11, weight: .medium, color: c.state.color)
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        let state = NSStackView(h: [Glyph(c.state.tone, size: 11), word], spacing: 3)
        state.setHuggingPriority(.required, for: .horizontal)
        state.setClippingResistancePriority(.required, for: .horizontal)
        let line = NSTextField.text(c.line, size: 12, color: Palette.fg)
        line.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        line.toolTip = c.line
        var views: [NSView] = [state, Chiplet(c.source, symbol: ToolSource.symbol(c.source), fill: Palette.raise), line, Spacer()]
        if let t = c.time { views.append(NSTextField.text(t, size: 11, color: Palette.dim, mono: !t.contains(" rule") && t.hasSuffix(" s"))) }
        let detail = NSTextField.text(c.input + (c.output.map { "\n" + $0 } ?? ""), size: 11, color: Palette.mut, lines: 0, mono: true)
        detail.isSelectable = true
        let box = Box(fill: Palette.bg, border: Palette.line, radius: 6)
        box.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), detail.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), detail.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        box.isHidden = !ctx.open.contains(key)
        let label = "\(c.state.word), \(c.source), \(c.line)" + (c.time.map { ", " + $0 } ?? "")
        let row = Row(views, height: 26, inset: 6, label: label)
        addFull(row)
        let pad = NSStackView(v: [], spacing: 0)
        pad.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 4, right: 6)
        pad.addFull(box)
        addFull(pad)
        pad.isHidden = box.isHidden
        row.onClick = { [weak box, weak pad] in
            guard let box else { return }
            box.isHidden.toggle()
            pad?.isHidden = box.isHidden
            if box.isHidden { ctx.open.remove(key) } else { ctx.open.insert(key) }
            ctx.resized()
        }
        row.setAccessibilityRole(.button)
        if c.state == .running, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { flash(row) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // A new running row lights up once. Reduce motion turns it off.
    private func flash(_ row: Row) {
        row.restFill = AI_COLOR.withAlphaComponent(0.16)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak row] in row?.restFill = nil }
    }
}

// MARK: - Cards

/// The panel opened a page. Go back opens the page before.
final class NavigationCard: Box {
    init(route: String, focus: String?, from: String?, ctx: StreamContext) {
        super.init(fill: AI_COLOR.withAlphaComponent(0.07), border: AI_COLOR, radius: 10)
        let r = Route(path: route)
        let name = r.map { ($0.crumbs.dropFirst() + [$0.title]).joined(separator: " › ") } ?? route
        var lines: [NSView] = [NSStackView(h: [Glyph("arrow.up.right.square", color: AI_COLOR, size: 12, label: "Opened"),
                                               NSTextField.text("Opened " + name, size: 12.5, weight: .semibold)], spacing: 6)]
        if let focus { lines.append(NSTextField.text("The marked row: " + focus, size: 12, color: Palette.mut, lines: 2)) }
        var buttons: [NSView] = []
        if let from, let back = Route(path: from) {
            buttons.append(ActionButton("Go back to " + back.title, symbol: "arrow.left", style: .link) { ctx.goBack(from) })
        }
        if ctx.follows { buttons.append(ActionButton("Stop following", symbol: "eye.slash", style: .link) { ctx.stopFollow() }) }
        if !buttons.isEmpty { lines.append(NSStackView(h: buttons + [Spacer()], spacing: 14)) }
        let s = NSStackView(v: lines, spacing: 6)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 10), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Opened " + name)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The assistant asks before an action. ⌘↵ approves the focused card.
final class ApprovalCard: Box {
    let call: ToolCall
    private let onAnswer: (ApprovalAnswer) -> Void
    private(set) var answered: ApprovalAnswer?
    let approveButton: ActionButton
    let denyButton: ActionButton
    /// Shows for a change action only: it allows the action for the rest of the chat.
    let allowBox: NSButton?

    init(_ call: ToolCall, title: String, note: String?, onAnswer: @escaping (ApprovalAnswer) -> Void) {
        self.call = call
        self.onAnswer = onAnswer
        approveButton = ActionButton("Approve", symbol: "checkmark", style: .primary)
        denyButton = ActionButton("Deny", symbol: "xmark")
        allowBox = call.kind == .change ? NSButton(checkboxWithTitle: "Allow \(title.lowercased()) in this chat", target: nil, action: nil) : nil
        super.init(fill: Palette.warn.withAlphaComponent(0.08), border: Palette.warn, radius: 10)
        approveButton.toolTip = "Approve (⌘↵)"
        approveButton.onClick = { [weak self] in self?.approve() }
        denyButton.onClick = { [weak self] in self?.deny() }
        var lines: [NSView] = [NSStackView(h: [Glyph("hand.raised.fill", color: Palette.warn, size: 13, label: "Asks first"),
                                               NSTextField.text(title + "?", size: 13, weight: .semibold, lines: 2)], spacing: 6)]
        var args: [(String, String)] = [("Action", call.tool)]
        for (k, v) in (call.args.object ?? [:]).sorted(by: { $0.key < $1.key }).prefix(6) {
            args.append((k.prefix(1).uppercased() + k.dropFirst(), v.string ?? v.text))
        }
        let grid = NSStackView(v: args.map { k, v in
            let key = NSTextField.text(k, size: 11.5, color: Palette.dim)
            key.widthAnchor.constraint(equalToConstant: 64).isActive = true
            return NSStackView(h: [key, NSTextField.text(v, size: 11.5, color: Palette.fg, lines: 2, mono: true)], spacing: 8, align: .firstBaseline)
        }, spacing: 3)
        lines.append(grid)
        if let note {
            let n = NSStackView(h: [Glyph("exclamationmark.triangle.fill", color: Palette.warn, size: 11, label: "Warning"),
                                    NSTextField.text(note, size: 12, color: Palette.fg, lines: 3)], spacing: 6, align: .top)
            lines.append(n)
        }
        lines.append(NSStackView(h: [approveButton, denyButton, Spacer()], spacing: 8))
        if let allowBox {
            allowBox.font = .systemFont(ofSize: 12)
            lines.append(allowBox)
        }
        let s = NSStackView(v: lines, spacing: 8)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 10), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            grid.widthAnchor.constraint(equalTo: s.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Asks first: \(title)" + (note.map { ". " + $0 } ?? ""))
    }
    required init?(coder: NSCoder) { fatalError() }

    func approve() { give(allowBox?.state == .on ? .approveForChat : .approve) }
    func deny() { give(.deny) }

    private func give(_ a: ApprovalAnswer) {
        guard answered == nil else { return }
        answered = a
        approveButton.isEnabled = false
        denyButton.isEnabled = false
        onAnswer(a)
    }

    /// True when the key focus is in the card.
    var hasFocus: Bool {
        guard let r = window?.firstResponder as? NSView else { return false }
        return r.isDescendant(of: self)
    }
}

/// A notice of the loop or the router, for example a cut result or an engine move.
final class NoticeCard: Box {
    init(code: String, text: String) {
        super.init(fill: Palette.acc.withAlphaComponent(0.07), border: Palette.line, radius: 8)
        let symbol: String
        switch code {
        case "moved": symbol = "arrow.triangle.2.circlepath"
        case "cut": symbol = "scissors"
        default: symbol = "info.circle"
        }
        let s = NSStackView(h: [Glyph(symbol, color: Palette.acc, size: 12, label: "Note"), NSTextField.text(text, size: 12, color: Palette.fg, lines: 0)],
                            spacing: 6, align: .top)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 7), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An error of a run: no AI source, an offline machine or a failed turn.
final class ProblemCard: Box {
    init(_ p: AssistantController.Problem, ctx: StreamContext) {
        let setup = ["notConfigured", "unavailable", "setup"].contains(p.code)
        let offline = p.code == "offline"
        super.init(fill: (offline ? Palette.dim : Palette.bad).withAlphaComponent(0.08), border: offline ? Palette.line : Palette.bad, radius: 10)
        let title: String
        let body: String
        switch p.code {
        case "notConfigured", "setup":
            title = "No AI source is ready"
            body = "Set up Claude Code, another agent CLI or an API key. Then press Test."
        case "unavailable":
            title = "The AI source is not available"
            body = p.message
        case "offline":
            title = p.message
            body = "Start OverSire on that Mac, or ask about another machine."
        default:
            title = "The assistant stopped"
            body = p.message
        }
        let symbol = offline ? "wifi.slash" : "xmark.octagon.fill"
        let color = offline ? Palette.dim : Palette.bad
        var lines: [NSView] = [
            NSStackView(h: [Glyph(symbol, color: color, size: 13, label: offline ? "Offline" : "Error"),
                            NSTextField.text(title, size: 13, weight: .semibold, lines: 2)], spacing: 6),
            NSTextField.text(body, size: 12, color: Palette.mut, lines: 0),
        ]
        if setup { lines.append(ActionButton("Open Settings › AI", symbol: "gearshape") { ctx.openSettings() }) }
        else if !offline { lines.append(ActionButton("Try again", symbol: "arrow.clockwise") { ctx.retry() }) }
        let s = NSStackView(v: lines, spacing: 6)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 10), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(body)")
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - New chat

/// The empty chat: what the assistant can do, what it sees, and some first questions.
final class AssistantHello: NSStackView {
    struct Suggestion: Equatable {
        let text: String
        let note: String?
    }

    static func suggestions(_ page: PageContext?) -> [Suggestion] {
        var out = [Suggestion(text: "What needs me today?", note: nil)]
        let parts = page?.route.split(separator: "/").map(String.init) ?? []
        switch parts.first {
        case "item" where parts.count > 1:
            out.append(Suggestion(text: "What is pending for \(parts[1])?", note: nil))
            out.append(Suggestion(text: "Sum up \(parts[1]) and its sub-items", note: nil))
        case "run" where parts.count > 2:
            out.append(Suggestion(text: "Why did this run fail?", note: nil))
        case "prs":
            out.append(Suggestion(text: "Which pull requests wait on me?", note: nil))
        default:
            out.append(Suggestion(text: "Why did the last failed run fail?", note: nil))
        }
        out.append(Suggestion(text: "Start the next item in the queue", note: "Asks first. Uses a free slot on this Mac."))
        return out
    }

    init(page: PageContext?, pick: @escaping (String) -> Void) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
        edgeInsets = NSEdgeInsets(top: 12, left: 4, bottom: 0, right: 4)
        addArrangedSubview(Glyph("sparkles", color: AI_COLOR, size: 22, label: nil))
        addFull(NSTextField.text("What do you want to know or do?", size: 15, weight: .semibold, lines: 2))
        addFull(NSTextField.text("I can read your items, PRs, runs, sessions and machines. I can use the same buttons as you. I ask before I change something.",
                                 size: 12.5, color: Palette.mut, lines: 0))
        if let page {
            addArrangedSubview(NSStackView(h: [NSTextField.text("Sees", size: 11.5, color: Palette.dim),
                                               Chiplet(page.title, symbol: "smallcircle.filled.circle", color: AI_COLOR)], spacing: 6))
        }
        setCustomSpacing(16, after: arrangedSubviews.last!)
        for s in Self.suggestions(page) {
            let text = TwoLine(s.text, s.note, titleSize: 12.5, weight: .regular)
            let row = Row([Glyph("sparkles", color: AI_COLOR, size: 11), text, Spacer()], height: 34, inset: 10, label: s.text) { pick(s.text) }
            row.restBorder = Palette.line
            row.restFill = Palette.panel
            addFull(row)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

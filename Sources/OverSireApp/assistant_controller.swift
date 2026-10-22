import Cocoa
import UniformTypeIdentifiers
import OverSireCore
import OverSireAI
import OverSireAssistant

// ─── Assistant controller ────────────────────────────────────────────────────
// The state of the assistant panel: the open chat, the runs and the chat list.
// It sends through one AssistantLoop and gives the approval answers back to it. All work is on the main thread.

/// An AI source that the composer can pick.
struct AssistantEngine: Equatable {
    let id: EngineID
    /// For example "Claude Code · this Mac".
    let label: String
}

/// One attachment of the composer.
struct AssistantAttachment: Equatable {
    enum Kind: Equatable {
        case image(Data)
        case file(name: String, data: Data)
        case mention(SubjectRef, key: String)
    }
    let id = UUID()
    let kind: Kind
}

@MainActor
final class AssistantController {
    /// A run that goes on.
    struct Live {
        let thread: String
        /// The user message, before the store has it.
        let user: AssistantMessage
        /// The answer so far, from the loop.
        var answer: AssistantMessage?
        var asks: [Ask] = []
        var started: [String: Date] = [:]
        var ended: [String: Date] = [:]
        var thoughtStart: Date?
        var thoughtEnd: Date?
        var moved: String?
        /// The navigation parts that the panel followed.
        var followed = 0
    }

    struct Ask: Equatable {
        let call: ToolCall
        let note: String?
    }

    struct Problem: Equatable {
        let code: String
        let message: String
    }

    struct Queued {
        var text: String
        var attachments: [AssistantAttachment]
    }

    let loop: AssistantLoop
    let engines: [AssistantEngine]
    private let pageContext: () -> PageContext?
    private let now: () -> Date

    /// The views read the state again.
    var onChange: (() -> Void)?
    /// Opens a route path of a navigation part. The second value is the row to mark.
    var onNavigate: ((String, String?) -> Void)?

    private(set) var thread: AssistantThread?
    private(set) var messages: [AssistantMessage] = []
    private(set) var threads: [AssistantThread] = []
    private(set) var lives: [String: Live] = [:]
    private(set) var problems: [String: Problem] = [:]
    private(set) var queued: [String: Queued] = [:]
    /// The engine moves, by the id of the answer that had them.
    private(set) var moves: [String: String] = [:]
    /// Tool name to title, for the chips.
    private(set) var toolTitles: [String: String] = [:]
    /// The engine of a new chat.
    private(set) var engine: EngineID
    private var renderQueued = false

    init(loop: AssistantLoop, engines: [AssistantEngine], page: @escaping () -> PageContext? = { nil },
         now: @escaping () -> Date = Date.init) {
        self.loop = loop
        self.engines = engines
        pageContext = page
        self.now = now
        engine = engines.first?.id ?? .apiKey
        Task { [weak self] in
            await self?.reloadThreads()
            await self?.loadTools()
        }
    }

    // MARK: State for the views

    var live: Live? { thread.flatMap { lives[$0.id] } }
    var isRunning: Bool { live != nil }
    var problem: Problem? { thread.flatMap { problems[$0.id] } ?? problems[""] }
    var waiting: Queued? { thread.flatMap { queued[$0.id] } }
    var page: PageContext? { pageContext() }
    /// Nil on a chat: the default is on.
    var follows: Bool { thread?.follow ?? true }
    var currentEngine: EngineID { thread?.engine ?? engine }

    func label(_ id: EngineID?) -> String {
        guard let id else { return "Assistant" }
        return engines.first { $0.id == id }?.label ?? id.rawValue
    }

    func runs(_ thread: String) -> Bool { lives[thread] != nil }

    // MARK: Chats

    func newChat() {
        thread = nil
        messages = []
        problems[""] = nil
        changed()
    }

    func open(_ id: String) {
        Task {
            guard let t = try? await loop.store.thread(id) else { return }
            thread = t
            messages = (try? await loop.store.messages(id)) ?? []
            changed()
        }
    }

    func pin(_ id: String, _ on: Bool) {
        Task {
            guard var t = try? await loop.store.thread(id) else { return }
            t.pinned = on
            try? await loop.store.save(t)
            if thread?.id == id { thread?.pinned = on }
            await reloadThreads()
            changed()
        }
    }

    func delete(_ id: String) {
        Task {
            await loop.cancel(id)
            try? await loop.store.delete(thread: id)
            if thread?.id == id { newChat() }
            await reloadThreads()
            changed()
        }
    }

    func setFollow(_ on: Bool) {
        if thread == nil { thread = AssistantThread(title: ThreadStore.newTitle, createdAt: now(), engine: engine) }
        thread?.follow = on
        if let t = thread, !messages.isEmpty { Task { try? await loop.store.save(t) } }
        changed()
    }

    func setEngine(_ id: EngineID) {
        engine = id
        thread?.engine = id
        if let t = thread, !messages.isEmpty { Task { try? await loop.store.save(t) } }
        changed()
    }

    // MARK: Runs

    /// Sends a message. While the chat runs, the text waits for the end of the run.
    func send(_ text: String, _ attachments: [AssistantAttachment] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if let t = thread, lives[t.id] != nil {
            var q = queued[t.id] ?? Queued(text: "", attachments: [])
            q.text = q.text.isEmpty ? text : q.text + "\n\n" + text
            q.attachments += attachments
            queued[t.id] = q
            changed()
            return
        }
        let t = thread ?? AssistantThread(title: ThreadStore.newTitle, createdAt: now(), engine: engine)
        thread = t
        problems[t.id] = nil
        problems[""] = nil
        Task { await run(t, text, attachments) }
    }

    /// Stops the run of the open chat. The text that waits is dropped.
    func stop() {
        guard let t = thread else { return }
        queued[t.id] = nil
        Task { await loop.cancel(t.id) }
        changed()
    }

    func answer(_ call: String, _ a: ApprovalAnswer) {
        for (id, var l) in lives where l.asks.contains(where: { $0.call.id == call }) {
            l.asks.removeAll { $0.call.id == call }
            lives[id] = l
        }
        Task { await loop.answer(call, a) }
        changed()
    }

    /// A problem with no chat, for example no AI source.
    func report(_ p: Problem) {
        problems[thread?.id ?? ""] = p
        changed()
    }

    private func run(_ t: AssistantThread, _ text: String, _ attachments: [AssistantAttachment]) async {
        let parts = await self.parts(text, attachments)
        lives[t.id] = Live(thread: t.id, user: AssistantMessage(thread: t.id, role: .user, at: now(), parts: parts))
        changed()
        let stream = await loop.send(parts, in: t)
        for await ev in stream {
            if case .end = ev { await finish(t.id) } else { take(ev, t.id) }
        }
    }

    private func parts(_ text: String, _ attachments: [AssistantAttachment]) async -> [AssistantPart] {
        var out: [AssistantPart] = text.isEmpty ? [] : [.text(text)]
        for a in attachments {
            switch a.kind {
            case .image(let d):
                guard let blob = try? await loop.store.put(blob: d) else { continue }
                let size = NSImage(data: d).flatMap { $0.representations.first }.map { ($0.pixelsWide, $0.pixelsHigh) }
                out.append(.image(blob: blob, mime: "image/png", width: size?.0, height: size?.1))
            case .file(let name, let d):
                guard let blob = try? await loop.store.put(blob: d) else { continue }
                let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                out.append(.file(blob: blob, name: name, mime: mime, bytes: d.count))
            case .mention(let ref, let key):
                out.append(.mention(ref, label: key))
            }
        }
        return out
    }

    private func take(_ ev: ChatEvent, _ id: String) {
        guard var l = lives[id] else { return }
        let t = now()
        if case .thoughtDelta = ev {
            if l.thoughtStart == nil { l.thoughtStart = t }
        } else if l.thoughtStart != nil, l.thoughtEnd == nil {
            l.thoughtEnd = t
        }
        switch ev {
        case .toolCall(let c): l.started[c.id] = t
        case .toolResult(let r):
            l.ended[r.call] = t
            l.asks.removeAll { $0.call.id == r.call }
        case .approvalNeeded(let c, let note): l.asks.append(Ask(call: c, note: note))
        case .engineChanged(_, let to, let reason):
            l.moved = "Moved to \(label(to))." + (reason.map { " " + $0 } ?? "")
        case .error(let code, let message): problems[id] = Problem(code: code, message: message)
        case .textDelta, .thoughtDelta, .usage, .end: break
        }
        lives[id] = l
        // An approval card shows at once. The text shows at most 10 times a second.
        if case .approvalNeeded = ev { Task { await sync() } } else { renderSoon() }
    }

    private func renderSoon() {
        guard !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            Task { await self?.sync() }
        }
    }

    // Reads the answers from the loop. They hold the parts that come with no event.
    private func sync() async {
        renderQueued = false
        for id in lives.keys {
            guard let m = await loop.liveMessage(id), lives[id] != nil else { continue }
            // The loop names a new chat after the first message.
            if thread?.id == id, thread?.title == ThreadStore.newTitle, let t = try? await loop.store.thread(id) { thread?.title = t.title }
            lives[id]?.answer = m
            follow(id, m.parts)
        }
        changed()
    }

    private func follow(_ id: String, _ parts: [AssistantPart]) {
        guard let l = lives[id] else { return }
        let navs = parts.compactMap { p -> (String, String?)? in
            if case .navigation(let r, let f, _) = p { return (r, f) }
            return nil
        }
        guard navs.count > l.followed else { return }
        lives[id]?.followed = navs.count
        if thread?.id == id, follows, let last = navs.last { onNavigate?(last.0, last.1) }
    }

    private func finish(_ id: String) async {
        let msgs = (try? await loop.store.messages(id)) ?? []
        if let last = msgs.last, last.role == .assistant {
            follow(id, last.parts)
            if let moved = lives[id]?.moved { moves[last.id] = moved }
        }
        lives[id] = nil
        if thread?.id == id {
            messages = msgs
            if let t = try? await loop.store.thread(id) { thread = t }
        }
        await reloadThreads()
        changed()
        if thread?.id == id, let q = queued.removeValue(forKey: id) { send(q.text, q.attachments) }
    }

    // MARK: Store

    func reloadThreads() async {
        threads = (try? await loop.store.threads()) ?? []
    }

    func loadTools() async {
        toolTitles = Dictionary(await loop.tools().map { ($0.name, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    func blob(_ id: String) async -> Data? { await loop.store.blob(id) }

    private func changed() { onChange?() }
}

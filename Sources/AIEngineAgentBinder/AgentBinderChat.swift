import Foundation
import OverSireCore
import OverSireAI
import AgentBinder

// ─── Chat through the local CLI ──────────────────────────────────────────────
// One AgentBinder session for each thread. It stays open between turns.
// The CLI calls the OverSire tools through the MCP server of the app (AssistantLoop.runTool).
// The engine denies each tool that is not an OverSire tool: no shell, no files.

/// The MCP endpoint of the app for one thread. The app owns the listener.
public protocol ChatToolHost: Sendable {
    /// The token goes in a header. AgentBinder writes it to a config file or the env, never to argv.
    func endpoint(thread: String) async throws -> (url: URL, token: String)
    func closed(thread: String) async
}

public struct AgentBinderChat: ChatEngine {
    public static let server = "oversire"
    public static let toolPrefix = "mcp__\(server)__"
    public static let deny = "OverSire chats use only the OverSire tools."

    public let id = EngineID.localCLI
    public var runsTools: Bool { true }
    let links: ChatLinks

    /// `features` nil reads the table of the runtime once.
    public init(config: LocalCLIConfig, runtime: Runtime, limits: PlanLimits, tools: (any ChatToolHost)?, workRoot: URL,
                idle: TimeInterval = 30 * 60, features: (@Sendable (Harness) async -> Features)? = nil) {
        links = ChatLinks(config: config, runtime: runtime, limits: limits, tools: tools, workRoot: workRoot, idle: idle,
                          features: features ?? { await runtime.detect($0).features })
    }

    /// A CLI without MCP cannot call the tools, so it cannot chat.
    public func available() async -> Bool { await links.usable() }

    public func turn(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let links = self.links
        return AsyncThrowingStream { out in
            let task = Task {
                do {
                    let (link, fresh, resumed) = try await links.link(for: request)
                    let prompt = await links.prompt(request, history: fresh && !resumed)
                    try await link.begin(prompt, out: out, known: request.session, onSession: request.onSession)
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { Task { await links.interrupt(request.thread) } }
            }
        }
    }

    public func close(thread: String) async { await links.close(thread) }

    /// Closes the sessions with no turn in the idle time. The app calls it from a timer.
    public func closeIdle() async { await links.closeIdle() }
}

actor ChatLinks {
    let config: LocalCLIConfig
    let runtime: Runtime
    let limits: PlanLimits
    let tools: (any ChatToolHost)?
    let workRoot: URL
    let idle: TimeInterval
    let readFeatures: @Sendable (Harness) async -> Features
    private var cached: Features?
    private var open: [String: ChatLink] = [:]

    init(config: LocalCLIConfig, runtime: Runtime, limits: PlanLimits, tools: (any ChatToolHost)?, workRoot: URL,
         idle: TimeInterval, features: @escaping @Sendable (Harness) async -> Features) {
        self.config = config
        self.runtime = runtime
        self.limits = limits
        self.tools = tools
        self.workRoot = workRoot
        self.idle = idle
        readFeatures = features
    }

    var harness: Harness { Harness(config.harness) }

    func features() async -> Features {
        if let cached { return cached }
        let f = await readFeatures(harness)
        cached = f
        return f
    }

    func usable() async -> Bool {
        guard !config.harness.isEmpty else { return false }
        return await features().mcpInject != .none
    }

    /// The open session of the thread, else a resumed one, else a new one.
    func link(for r: ChatRequest) async throws -> (ChatLink, fresh: Bool, resumed: Bool) {
        let h = harness
        if let why = await limits.pause(above: config.limitPause) { throw AIError.unavailable(why) }
        await closeIdle()
        if let l = open[r.thread] {
            if await l.ready() { return (l, false, false) }
            await close(r.thread)
        }
        let fm = FileManager.default
        let dir = workRoot.appendingPathComponent(r.thread, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var servers: [MCPServer] = []
        if let tools {
            let (url, token) = try await tools.endpoint(thread: r.thread)
            servers = [.http(name: AgentBinderChat.server, url: url, headers: ["Authorization": "Bearer \(token)"])]
        }
        var req = StartRequest(harness: h, workingDirectory: dir,
                               model: config.model.isEmpty ? nil : config.model,
                               effort: config.effort.isEmpty ? nil : Effort(rawValue: config.effort),
                               instructions: r.system + "\n\nUse only the oversire tools. You have no shell and no file tools.",
                               permissions: PermissionPolicy(mode: .ask, allowTools: [AgentBinderChat.toolPrefix + "*"]),
                               mcpServers: servers)
        req.raw["sandbox"] = .string("read-only")
        var session: (any Session)?
        if let id = r.session, (await features()).resume {
            req.sessionID = id
            session = try? await runtime.resume(req)
        }
        let resumed = session != nil
        if session == nil {
            req.sessionID = nil
            do { session = try await runtime.start(req) } catch {
                throw AIError.unavailable("\(h) did not start: \(error)")
            }
        }
        guard let session else { throw AIError.unavailable("\(h) did not start.") }
        let link = ChatLink(session: session, limits: limits)
        open[r.thread] = link
        let thread = r.thread
        Task {
            await link.pump()
            await self.ended(thread, link)
        }
        return (link, true, resumed)
    }

    private func ended(_ thread: String, _ link: ChatLink) async {
        guard open[thread] === link else { return }
        open[thread] = nil
        await tools?.closed(thread: thread)
    }

    func interrupt(_ thread: String) async { await open[thread]?.interrupt() }

    func close(_ thread: String) async {
        guard let l = open.removeValue(forKey: thread) else { return }
        await l.close()
        await tools?.closed(thread: thread)
    }

    func closeIdle() async {
        let t = Date()
        for (thread, l) in open where await l.idle(since: t) > idle { await close(thread) }
    }

    /// The text and the images of the last user message. A new session that did not resume gets the earlier
    /// text of the chat too, since the CLI does not know it.
    func prompt(_ r: ChatRequest, history: Bool) async -> Prompt {
        guard let i = r.messages.lastIndex(where: { $0.role == .user }) else { return Prompt("") }
        let images = await features().attachments
        var lines: [String] = []
        var files: [PromptAttachment] = []
        for p in r.messages[i].parts {
            switch p {
            case .text(let t): lines.append(t)
            case .mention(let s, let label): lines.append(ChatWire.mentionText(s, label))
            case .file(let blob, let name, let mime, let bytes):
                lines.append(ChatWire.fileText(name, mime, bytes, await r.blobs?.blob(blob)))
            case .image(let blob, let mime, _, _):
                if !images { lines.append("[An image. \(harness) cannot read images.]") }
                else if let data = await r.blobs?.blob(blob) { files.append(.data(data, mime: mime)) }
                else { lines.append("[An image that is no longer on this Mac.]") }
            default: break
            }
        }
        var text = lines.joined(separator: "\n")
        if history, i > 0 {
            var earlier = r.messages[..<i].suffix(20).compactMap { m -> String? in
                let t = m.parts.compactMap { p -> String? in
                    switch p {
                    case .text(let t): return t
                    case .mention(let s, let label): return ChatWire.mentionText(s, label)
                    case .toolResult(let res): return "(tool: \(res.summary))"
                    default: return nil
                    }
                }.joined(separator: " ")
                return t.isEmpty ? nil : "\(m.role == .user ? "Developer" : "You"): \(t)"
            }.joined(separator: "\n")
            if earlier.count > 8_000 { earlier = "…" + earlier.suffix(8_000) }
            text = "Earlier in this chat:\n\(earlier)\n\nNow:\n\(text)"
        }
        return Prompt(text, kind: "chat", attachments: files)
    }
}

/// One live CLI session. The pump reads its events for the life of the session and feeds the open turn.
actor ChatLink {
    let session: any Session
    let limits: PlanLimits
    private var out: AsyncThrowingStream<ChatEvent, Error>.Continuation?
    private var onSession: (@Sendable (String) -> Void)?
    private var known: String?
    private var last = Date()
    private var alive = true
    /// After an interrupt, until the result of the stopped turn.
    private var draining = false
    private var current = ""
    private var said = false
    private var sawUsage = false
    private var lastError: WireError?

    init(session: any Session, limits: PlanLimits) {
        self.session = session
        self.limits = limits
    }

    /// True when a new turn can start. It waits a short time for the end of a stopped turn.
    func ready() async -> Bool {
        for _ in 0..<40 where alive && draining { try? await Task.sleep(for: .milliseconds(50)) }
        return alive && !draining && out == nil
    }

    func idle(since t: Date) -> TimeInterval { out == nil ? t.timeIntervalSince(last) : 0 }

    func begin(_ p: Prompt, out: AsyncThrowingStream<ChatEvent, Error>.Continuation, known: String?,
               onSession: (@Sendable (String) -> Void)?) async throws {
        self.out = out
        self.known = known
        self.onSession = onSession
        current = ""
        said = false
        sawUsage = false
        lastError = nil
        last = Date()
        do { try await session.prompt(p) } catch {
            self.out = nil
            throw AIError.unavailable("\(session.harness) did not take the prompt: \(error)")
        }
    }

    func pump() async {
        for await ev in session.events { await handle(ev) }
        alive = false
        finish(throwing: AIError.unavailable("\(session.harness) stopped before the end of the turn."))
    }

    func interrupt() async {
        guard out != nil else { return }
        out = nil
        draining = true
        try? await session.interrupt()
    }

    func close() async {
        alive = false
        finish(throwing: CancellationError())
        await session.close()
    }

    private func finish(throwing e: Error? = nil) {
        guard let o = out else { return }
        out = nil
        last = Date()
        if let e { o.finish(throwing: e) } else {
            o.yield(.end(.done))
            o.finish()
        }
    }

    private func report(_ id: String?) {
        guard let id, !id.isEmpty, id != known else { return }
        known = id
        onSession?(id)
    }

    private func text(_ t: String, delta: Bool) {
        if delta {
            if current.isEmpty && said { out?.yield(.textDelta("\n\n")) }
            current += t
            said = true
            out?.yield(.textDelta(t))
            return
        }
        // A whole message: send only the part that the deltas did not send.
        if !current.isEmpty, t.hasPrefix(current) {
            let rest = String(t.dropFirst(current.count))
            if !rest.isEmpty { out?.yield(.textDelta(rest)) }
        } else if !t.isEmpty {
            out?.yield(.textDelta(said ? "\n\n" + t : t))
            said = true
        }
        current = ""
    }

    func handle(_ ev: Event) async {
        report(ev.sessionID)
        // Permissions get an answer also when no turn reads the events.
        if case .permission(let q) = ev.kind {
            let ours = q.tool.hasPrefix(AgentBinderChat.toolPrefix)
            try? await session.answer(q.id, ours ? .allow() : .deny(AgentBinderChat.deny))
            return
        }
        if case .limits(let l) = ev.kind { await limits.set(l) }
        if draining {
            if case .result = ev.kind { draining = false }
            return
        }
        guard out != nil else { return }
        switch ev.kind {
        case .assistant(let t, let delta): text(t, delta: delta)
        case .thought(let t, _): out?.yield(.thoughtDelta(t, signature: nil))
        case .tool(let t):
            // Chips only: the loop runs the tool when the MCP server gets the call.
            guard t.name.hasPrefix(AgentBinderChat.toolPrefix) else { return }
            let name = String(t.name.dropFirst(AgentBinderChat.toolPrefix.count))
            switch t.status {
            case .started: out?.yield(.toolCall(ToolCall(id: t.id, tool: name, args: ChatWire.json(t.input))))
            case .completed: out?.yield(.toolResult(ToolResult(call: t.id, status: .ok, summary: String(t.output.prefix(200)))))
            case .failed, .cancelled:
                out?.yield(.toolResult(ToolResult(call: t.id, status: .failed, summary: String(t.output.prefix(200)))))
            }
        case .usage(let u):
            sawUsage = true
            out?.yield(.usage(Self.usage(u)))
        case .error(let e): lastError = e
        case .result(let r):
            report(r.sessionID ?? session.id)
            if r.isError {
                let reason = r.endReason ?? lastError?.endReason
                finish(throwing: await AgentBinderEngine.fail(session.harness, reason, r.text.isEmpty ? r.subtype : r.text, limits))
                return
            }
            if !sawUsage, r.usage.input + r.usage.output > 0 { out?.yield(.usage(Self.usage(r.usage))) }
            if !said, !r.text.isEmpty { out?.yield(.textDelta(r.text)) }
            finish()
        case .exit(_, let error, _):
            alive = false
            let e = await AgentBinderEngine.fail(session.harness, lastError?.endReason,
                                                 error ?? lastError?.message ?? "the process stopped", limits)
            finish(throwing: e)
        default: break
        }
    }

    static func usage(_ u: Usage) -> AIUsage {
        AIUsage(input: Int(u.input), output: Int(u.output), cached: u.cacheRead > 0 ? Int(u.cacheRead) : nil,
                costUSD: u.costUSD > 0 ? u.costUSD : nil)
    }
}

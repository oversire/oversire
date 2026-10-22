import Foundation
import OverSireCore
import OverSireAI

/// One line of the AI log for each tool call. The args are redacted.
public struct ToolLogLine: Sendable, Equatable {
    public var thread: String
    public var engine: EngineID
    public var action: String
    public var kind: ActionKind?
    public var decision: Approval.Decision?
    public var args: String
    public var status: ToolResult.Status
    public var bytes: Int
    public var ms: Int

    /// The line of Settings › Logs.
    public var entry: LogEntry {
        let level: LogLevel = status == .failed ? .error : .ok
        let who = decision.map { " · \($0.rawValue)" } ?? ""
        var e = LogEntry(level: level, area: .ai, job: "Assistant tool", subject: action, host: engine.rawValue,
                         message: "\(kind?.rawValue ?? "tool")\(who) · \(status.rawValue) · \(bytes) B", ms: ms)
        e.engine = engine.rawValue
        e.reason = thread
        e.input = String(args.prefix(4000))
        return e
    }
}

/// One line of the AI log for each send: the tokens of all the model turns.
public struct TurnLogLine: Sendable, Equatable {
    public var thread: String
    public var engine: EngineID
    public var end: ChatEvent.EndReason
    public var usage: AIUsage?
    public var tools: Int
    public var ms: Int

    public var entry: LogEntry {
        let level: LogLevel = end == .error ? .error : .ok
        var e = LogEntry(level: level, area: .ai, job: "Assistant", subject: thread, host: engine.rawValue,
                         message: "\(end.rawValue) · \(tools) tool call\(tools == 1 ? "" : "s")", ms: ms)
        e.engine = engine.rawValue
        e.tokensIn = usage?.input
        e.tokensOut = usage?.output
        e.stop = end.rawValue
        return e
    }
}

/// Runs the chats. A send stores the user message, runs turns until the model stops calling tools,
/// asks ConfirmPolicy before each call, runs the call through the catalog and stores the answer.
/// It gives the events to the UI. One run for each thread at a time.
public actor AssistantLoop {
    public struct Settings: Sendable {
        public var maxTurns: Int
        /// A larger tool result is cut, with a notice.
        public var maxResultBytes: Int
        public var maxTokens: Int?

        public init(maxTurns: Int = 24, maxResultBytes: Int = 24_000, maxTokens: Int? = nil) {
            self.maxTurns = maxTurns
            self.maxResultBytes = maxResultBytes
            self.maxTokens = maxTokens
        }
    }

    final class Run {
        let messageID = UUID().uuidString
        let started: Date
        var thread: AssistantThread
        let out: AsyncStream<ChatEvent>.Continuation
        var parts: [AssistantPart] = []
        var usage: AIUsage?
        var userText = ""
        var task: Task<Void, Never>?
        var asking: Set<String> = []

        init(thread: AssistantThread, out: AsyncStream<ChatEvent>.Continuation, started: Date) {
            self.thread = thread
            self.out = out
            self.started = started
        }

        var sawResult: Bool { parts.contains { if case .toolResult = $0 { return true }; return false } }
    }

    let router: ChatRouter
    let catalog: any ActionCatalog
    let policy: any ConfirmPolicy
    public nonisolated let store: ThreadStore
    let system: @Sendable (AssistantThread, PageContext?) async -> String
    let page: @Sendable () async -> PageContext?
    let redactor: @Sendable () -> Redactor
    let log: @Sendable (ToolLogLine) -> Void
    let turnLog: @Sendable (TurnLogLine) -> Void
    let now: @Sendable () -> Date
    let settings: Settings

    private var runs: [String: Run] = [:]
    private var asks: [String: CheckedContinuation<ApprovalAnswer, Never>] = [:]

    public init(router: ChatRouter, catalog: any ActionCatalog, policy: any ConfirmPolicy, store: ThreadStore,
                system: @escaping @Sendable (AssistantThread, PageContext?) async -> String,
                page: @escaping @Sendable () async -> PageContext? = { nil },
                redactor: @escaping @Sendable () -> Redactor = { Redactor() },
                log: @escaping @Sendable (ToolLogLine) -> Void = { _ in },
                turnLog: @escaping @Sendable (TurnLogLine) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = Date.init, settings: Settings = Settings()) {
        self.router = router
        self.catalog = catalog
        self.policy = policy
        self.store = store
        self.system = system
        self.page = page
        self.redactor = redactor
        self.log = log
        self.turnLog = turnLog
        self.now = now
        self.settings = settings
    }

    public func isRunning(_ thread: String) -> Bool { runs[thread] != nil }

    /// The tools that apply now, for the MCP server.
    public func tools() async -> [ToolSpec] { ToolRegistry(await catalog.specs(for: await page())).tools }

    /// Sends a user message. A run of the same thread stops first.
    public func send(_ parts: [AssistantPart], in thread: AssistantThread) async -> AsyncStream<ChatEvent> {
        if let old = runs[thread.id] { await finish(old, .cancelled) }
        let (stream, out) = AsyncStream.makeStream(of: ChatEvent.self)
        let run = Run(thread: thread, out: out, started: now())
        runs[thread.id] = run
        let token = ObjectIdentifier(run)
        run.task = Task { await self.drive(thread.id, token, user: parts) }
        return stream
    }

    /// The answer to an approvalNeeded event.
    public func answer(_ call: String, _ answer: ApprovalAnswer) {
        asks.removeValue(forKey: call)?.resume(returning: answer)
    }

    /// Stops the run of the thread: the engine, an open approval and the running tool.
    public func cancel(_ thread: String) async {
        if let run = runs[thread] { await finish(run, .cancelled) }
    }

    /// A tool call of an engine that runs the tools itself, from the MCP server.
    public func runTool(_ call: ToolCall, thread: String) async -> ToolResult {
        guard let run = runs[thread] else { return ToolResult(call: call.id, status: .denied, summary: "This chat does not run now.") }
        let registry = ToolRegistry(await catalog.specs(for: await page()))
        guard live(run) else { return ToolResult(call: call.id, status: .skipped, summary: "Stopped.") }
        var c = call
        c.kind = registry.spec(c.tool)?.kind
        run.parts.append(.toolCall(c))
        run.out.yield(.toolCall(c))
        return await execute(c, run: run, registry: registry)
    }

    // ─── The run ─────────────────────────────────────────────────────────────

    private func live(_ run: Run) -> Bool { runs[run.thread.id] === run }

    private func run(_ thread: String, _ token: ObjectIdentifier) -> Run? {
        guard let r = runs[thread], ObjectIdentifier(r) == token else { return nil }
        return r
    }

    private func drive(_ id: String, _ token: ObjectIdentifier, user: [AssistantPart]) async {
        guard let run = run(id, token) else { return }
        let msg = AssistantMessage(thread: id, role: .user, at: run.started, parts: user)
        run.userText = msg.text
        if run.thread.title.isEmpty || run.thread.title == ThreadStore.newTitle { run.thread.title = Self.title(msg.text) }
        for case .mention(let s, _) in user where !run.thread.subjects.contains(s) { run.thread.subjects.append(s) }
        run.thread.updatedAt = run.started
        try? await store.save(msg)
        try? await store.save(run.thread)
        let history = ((try? await store.messages(id)) ?? []).map(ChatMessage.init)

        for _ in 0..<settings.maxTurns {
            guard live(run) else { return }
            let pageNow = await page()
            let registry = ToolRegistry(await catalog.specs(for: pageNow))
            let prompt = await system(run.thread, pageNow)
            guard live(run) else { return }
            let req = ChatRequest(thread: id, system: prompt, messages: history + (run.parts.isEmpty ? [] : [ChatMessage(role: .assistant, parts: run.parts)]),
                                  tools: registry.tools, maxTokens: settings.maxTokens, blobs: store, session: run.thread.engineSession,
                                  onSession: { s in Task { await self.setSession(id, token, s) } })
            var engine = router.engine(run.thread.engine)
            var calls: [ToolCall] = []
            do {
                for try await ev in router.turn(req, prefer: run.thread.engine) {
                    guard live(run) else { return }
                    switch ev {
                    case .textDelta(let t):
                        if case .text(let old)? = run.parts.last { run.parts[run.parts.count - 1] = .text(old + t) } else { run.parts.append(.text(t)) }
                    case .thoughtDelta(let t, let sig):
                        if case .thought(let old, let oldSig)? = run.parts.last { run.parts[run.parts.count - 1] = .thought(old + t, signature: sig ?? oldSig) }
                        else { run.parts.append(.thought(t, signature: sig)) }
                    case .toolCall(var c):
                        // An engine that runs the tools sends them through runTool.
                        if engine?.runsTools == true { continue }
                        c.kind = registry.spec(c.tool)?.kind
                        run.parts.append(.toolCall(c))
                        calls.append(c)
                        run.out.yield(.toolCall(c))
                        continue
                    case .toolResult, .approvalNeeded, .end:
                        continue
                    case .usage(let u):
                        run.usage = run.usage.map { $0 + u } ?? u
                    case .engineChanged(_, let to, _):
                        run.thread.engine = to
                        engine = router.engine(to)
                    case .error:
                        run.out.yield(ev)
                        await finish(run, .error)
                        return
                    }
                    run.out.yield(ev)
                }
            } catch {
                guard live(run) else { return }
                let e = error as? AIError
                run.out.yield(.error(code: e.map(Self.code) ?? "error", message: e?.message ?? error.localizedDescription))
                await finish(run, .error)
                return
            }
            if calls.isEmpty {
                await finish(run, .done)
                return
            }
            for c in calls {
                guard live(run) else { return }
                _ = await execute(c, run: run, registry: registry)
            }
        }
        await finish(run, .maxTurns)
    }

    private func execute(_ c: ToolCall, run: Run, registry: ToolRegistry) async -> ToolResult {
        let start = now()
        let id = run.thread.id
        guard let spec = registry.spec(c.tool) else {
            return record(ToolResult(call: c.id, status: .failed, summary: "No tool \(c.tool)."), call: c, action: c.tool, decision: nil, run: run, start: start)
        }
        let token = ObjectIdentifier(run)
        let decision = await policy.decide(c, action: spec.id, kind: spec.kind, thread: run.thread, note: injectionNote(c, spec, run, registry)) { call, note, once in
            await self.ask(id, token, call, note, once)
        }
        guard live(run) else { return ToolResult(call: c.id, status: .skipped, summary: "Stopped.") }
        if decision.approval.by != "kind:read" { run.parts.append(.approval(decision.approval)) }
        if decision.allowForChat, !run.thread.allow.contains(spec.id) {
            run.thread.allow.append(spec.id)
            try? await store.save(run.thread)
        }
        guard decision.runs else {
            let why = spec.kind == .settings
                ? "Settings change only by the developer. Tell the developer where the setting is."
                : "The developer said no to \(spec.title). Do not try it in another way."
            return record(ToolResult(call: c.id, status: .denied, summary: why), call: c, action: spec.id, decision: decision.approval.decision, run: run, start: start)
        }
        let result = await catalog.run(spec.id, ActionArgs(c.args, caller: .assistant(thread: id)))
        var r: ToolResult
        var extra: [AssistantPart] = []
        switch result {
        case .ok(let summary, let data, let parts):
            r = ToolResult(call: c.id, status: .ok, summary: summary, data: data.map(redactor().redact))
            extra = parts
        case .failed(let why), .notAllowed(let why):
            r = ToolResult(call: c.id, status: .failed, summary: why)
        }
        if let text = r.data?.text, text.utf8.count > settings.maxResultBytes {
            r.data = .string(String(decoding: Data(text.utf8).prefix(settings.maxResultBytes), as: UTF8.self))
            extra.append(.notice(code: "cut", text: "The result of \(spec.title) was cut to \(settings.maxResultBytes / 1000) KB."))
        }
        guard live(run) else { return r }
        return record(r, call: c, action: spec.id, decision: decision.approval.decision, run: run, start: start, extra: extra)
    }

    private func record(_ r: ToolResult, call: ToolCall, action: String, decision: Approval.Decision?, run: Run, start: Date,
                        extra: [AssistantPart] = []) -> ToolResult {
        guard live(run) else { return r }
        run.parts.append(.toolResult(r))
        run.parts += extra
        run.out.yield(.toolResult(r))
        log(ToolLogLine(thread: run.thread.id, engine: run.thread.engine, action: action, kind: call.kind, decision: decision,
                        args: redactor().redact(call.args.text), status: r.status, bytes: r.data?.text.utf8.count ?? 0,
                        ms: Int(now().timeIntervalSince(start) * 1000)))
        return r
    }

    private func ask(_ thread: String, _ token: ObjectIdentifier, _ call: ToolCall, _ note: String?, _ once: Bool) async -> ApprovalAnswer {
        guard let run = run(thread, token) else { return .deny }
        run.asking.insert(call.id)
        run.out.yield(.approvalNeeded(call, note: note))
        let answer = await withCheckedContinuation { asks[call.id] = $0 }
        run.asking.remove(call.id)
        return once || answer != .approveForChat ? answer : .approve
    }

    private func setSession(_ thread: String, _ token: ObjectIdentifier, _ session: String) async {
        guard let run = run(thread, token), run.thread.engineSession != session else { return }
        run.thread.engineSession = session
        try? await store.save(run.thread)
    }

    /// Ends the run: skipped results for the open calls, a denial for the open approvals, the store.
    private func finish(_ run: Run, _ reason: ChatEvent.EndReason) async {
        guard live(run) else { return }
        runs[run.thread.id] = nil
        for id in run.asking { asks.removeValue(forKey: id)?.resume(returning: .deny) }
        let done = Set(run.parts.compactMap { if case .toolResult(let r) = $0 { return r.call }; return nil })
        for case .toolCall(let c) in run.parts where !done.contains(c.id) {
            let r = ToolResult(call: c.id, status: .skipped, summary: "Stopped.")
            run.parts.append(.toolResult(r))
            run.out.yield(.toolResult(r))
        }
        if reason == .cancelled { run.task?.cancel() }
        run.thread.updatedAt = now()
        if !run.parts.isEmpty || run.usage != nil {
            // After the user message, also with a fixed clock.
            let at = max(now(), run.started.addingTimeInterval(0.001))
            try? await store.save(AssistantMessage(id: run.messageID, thread: run.thread.id, role: .assistant, at: at,
                                                   parts: run.parts, engine: run.thread.engine, usage: run.usage))
        }
        try? await store.save(run.thread)
        let tools = run.parts.reduce(0) { n, p in if case .toolResult = p { return n + 1 }; return n }
        turnLog(TurnLogLine(thread: run.thread.id, engine: run.thread.engine, end: reason, usage: run.usage, tools: tools,
                            ms: Int(now().timeIntervalSince(run.started) * 1000)))
        // The end comes after the store, so a new send reads this run.
        run.out.yield(.end(reason))
        run.out.finish()
    }

    /// A flag for an outward or settings call after a tool result, when the developer did not ask for it.
    private func injectionNote(_ c: ToolCall, _ spec: ActionSpec, _ run: Run, _ registry: ToolRegistry) -> String? {
        guard spec.kind == .outward || spec.kind == .settings, run.sawResult else { return nil }
        let name = spec.id.split(separator: ".").last.map(String.init) ?? spec.id
        let verb = String(name.prefix { !$0.isUppercase }).lowercased()
        guard !verb.isEmpty, !run.userText.lowercased().contains(verb) else { return nil }
        let last = run.parts.reversed().lazy.compactMap { p -> String? in if case .toolResult(let r) = p { return r.call }; return nil }.first
        let source = run.parts.lazy.compactMap { p -> String? in
            if case .toolCall(let t) = p, t.id == last { return registry.spec(t.tool)?.title }
            return nil
        }.first
        return "You did not ask for this. It came after \(source ?? "a tool result"), and text there can ask for it."
    }

    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if line.isEmpty { return ThreadStore.newTitle }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    static func code(_ e: AIError) -> String {
        switch e {
        case .notConfigured: return "notConfigured"
        case .unavailable: return "unavailable"
        case .unsupported: return "unsupported"
        case .http: return "http"
        case .timeout: return "timeout"
        case .network: return "network"
        case .badReply: return "badReply"
        }
    }
}

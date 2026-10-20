import Foundation
import OverSireCore
import OverSireAI
import AgentBinder

// Runs AI tasks through the coding agent CLI of the user (AgentBinder).
// It starts the user's own binary with its own login. OverSire reads no token.
// Each task runs in a new empty folder, and the engine denies each tool request.

public struct LocalCLIConfig: Hashable, Sendable {
    public var harness: String
    /// Empty uses the default of the CLI.
    public var model: String
    /// Empty uses the default of the CLI.
    public var effort: String
    /// Tasks pause when a plan window is above this use, in percent.
    public var limitPause: Double
    public var timeout: Duration

    public init(harness: String, model: String = "", effort: String = "", limitPause: Double = 90, timeout: Duration = .seconds(90)) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.limitPause = limitPause
        self.timeout = timeout
    }
}

/// The plan limits from the last call. The app keeps one for the life of the process.
public actor PlanLimits {
    public private(set) var last: Limits?
    public private(set) var at: Date?
    let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func set(_ l: Limits) {
        last = l
        at = now()
    }

    /// Why tasks pause now, or nil.
    public func pause(above: Double) -> String? {
        guard let l = last else { return nil }
        let t = now()
        if l.rejected, let at, t.timeIntervalSince(at) < 15 * 60 { return "The CLI refused the last call on a plan limit." }
        let full = l.windows.filter { $0.usedPercent >= above && ($0.resetsAt ?? .distantFuture) > t }
        guard let w = full.max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
        return "The \(Self.name(w)) plan window is at \(Int(w.usedPercent))%. Jobs pause above \(Int(above))%."
    }

    public static func name(_ w: LimitWindow) -> String {
        switch w.key {
        case .fiveHour: return "5 h"
        case .daily: return "day"
        case .weekly: return "week"
        case .monthly: return "month"
        case .custom: return w.minutes > 0 ? "\(w.minutes) min" : (w.scope ?? "other")
        }
    }
}

public struct AgentBinderEngine: AIEngine {
    public let id = EngineID.localCLI
    public let config: LocalCLIConfig
    let runtime: Runtime
    let limits: PlanLimits

    public init(config: LocalCLIConfig, runtime: Runtime, limits: PlanLimits) {
        self.config = config
        self.runtime = runtime
        self.limits = limits
    }

    public func available() async -> Bool { !config.harness.isEmpty }

    public func run(_ task: AITask) async throws -> String {
        try await send(task.kind.prompt(task.input))
    }

    /// Each failure of the CLI is AIError.unavailable, so the router can try the next engine.
    public func send(_ p: AIPrompt) async throws -> String {
        let h = Harness(config.harness)
        if let why = await limits.pause(above: config.limitPause) { throw AIError.unavailable(why) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("oversire-ai-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        var r = StartRequest(harness: h, workingDirectory: dir,
                             model: config.model.isEmpty ? nil : config.model,
                             effort: config.effort.isEmpty ? nil : Effort(rawValue: config.effort),
                             instructions: p.system + "\n\nAnswer in text only. You have no tools.",
                             permissions: PermissionPolicy(mode: .ask))
        r.raw["sandbox"] = .string("read-only")
        let s: any Session
        do { s = try await runtime.start(r) } catch {
            throw AIError.unavailable("\(h) did not start: \(error)")
        }
        let limits = self.limits
        let reply = try await withThrowingTaskGroup(of: String?.self) { g in
            g.addTask { try await Self.turn(s, p.user, limits: limits) }
            g.addTask {
                try await Task.sleep(for: config.timeout)
                return nil
            }
            defer { g.cancelAll() }
            return try await g.next() ?? nil
        }
        guard let reply else {
            await s.kill()
            throw AIError.unavailable("\(h) did not reply in \(config.timeout.components.seconds) s.")
        }
        await s.close()
        return reply
    }

    static func turn(_ s: any Session, _ text: String, limits: PlanLimits) async throws -> String {
        let h = s.harness
        try await s.prompt(Prompt(text))
        var out = ""
        var lastError: WireError?
        for await ev in s.events {
            switch ev.kind {
            case .assistant(let t, let delta): out = delta ? out + t : t
            case .permission(let q): try? await s.answer(q.id, .deny("OverSire jobs run with no tools."))
            case .limits(let l): await limits.set(l)
            case .error(let e): lastError = e
            case .result(let r):
                if r.isError { throw await fail(h, r.endReason ?? lastError?.endReason, r.text.isEmpty ? r.subtype : r.text, limits) }
                let reply = (r.text.isEmpty ? out : r.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if reply.isEmpty { throw AIError.unavailable("\(h) gave an empty reply.") }
                return reply
            case .exit(_, let error, _):
                throw await fail(h, lastError?.endReason, error ?? lastError?.message ?? "the process stopped", limits)
            default: break
            }
        }
        throw AIError.unavailable("\(h) stopped before the end of the turn.")
    }

    static func fail(_ h: Harness, _ reason: EndReason?, _ text: String, _ limits: PlanLimits) async -> AIError {
        switch reason {
        case .auth: return .unavailable("\(h) is not logged in. Run \(h.binaryName) once in a terminal.")
        case .limit:
            var l = await limits.last ?? Limits()
            l.rejected = true
            await limits.set(l)
            return .unavailable("\(h) refused the call on a plan limit.")
        default: return .unavailable("\(h): \(text.prefix(200))")
        }
    }
}

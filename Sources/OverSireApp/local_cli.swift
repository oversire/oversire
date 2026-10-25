import Foundation
import OverSireAI
import AIEngineAgentBinder
import AgentBinder

// What LocalCLI needs from the AgentBinder runtime to find the CLIs.
protocol CLIProber: Sendable {
    func detect(_ h: Harness) async -> Detection
    func planLimits(_ h: Harness) async throws -> Limits
    func invalidateDetect(_ h: Harness) async
}

extension Runtime: CLIProber {
    func planLimits(_ h: Harness) async throws -> Limits { try await limits(h) }
}

// The local CLI engine of the app: one AgentBinder runtime, the CLIs on this Mac, their models and plan limits.
// The state changes on the main queue only.
final class LocalCLI {
    static let shared = LocalCLI()
    static let changed = Notification.Name("LocalCLI.changed")

    let runtime: Runtime
    let limits = PlanLimits()
    private let prober: CLIProber
    private let harnesses: [Harness]
    // The CLIs found so far, in the order of `harnesses`. Nil before the first detection.
    private(set) var detections: [Detection]?
    private(set) var detecting = false
    // The CLIs that have no result yet in this detection.
    private(set) var pending: [Harness] = []
    private(set) var plans: [String: Limits] = [:]
    private(set) var models: [String: [ModelInfo]] = [:]
    // The plan limits from the last call, for the bars in Settings › AI.
    private(set) var lastLimits: Limits?

    init(runtime: Runtime? = nil, prober: CLIProber? = nil, harnesses: [Harness] = Harness.allBuiltIn.filter { $0 != .fake && $0 != .native }) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.runtime = runtime ?? Runtime(options: .init(clientName: "oversire", clientVersion: version,
                                                         ledger: URL(fileURLWithPath: CONFIG_DIR + "/agent-binder-ledger.json")))
        self.prober = prober ?? self.runtime
        self.harnesses = harnesses
        if runtime == nil, prober == nil { Task { await self.runtime.reconcile() } }
    }

    // Done and total of the running detection.
    var progress: (done: Int, total: Int) {
        let done = detections?.count ?? 0
        return (done, done + pending.count)
    }

    func engine(_ cfg: AIConfig) -> AgentBinderEngine {
        AgentBinderEngine(config: cfg.localCLI, runtime: runtime, limits: limits)
    }

    /// UI shots set the table with no probe.
    func seed(_ d: [Detection], plans: [String: Limits] = [:], models: [String: [ModelInfo]] = [:], limits: Limits? = nil, pending: [Harness] = []) {
        detections = d
        self.pending = pending
        detecting = !pending.isEmpty
        self.plans = plans
        self.models = models
        lastLimits = limits
    }

    // Probes each CLI in parallel. Each result posts a change when it arrives. Then it reads the plan of each ready CLI.
    func detect(again: Bool = false) {
        guard !detecting, again || detections == nil else { return }
        detecting = true
        pending = harnesses
        if again { detections = [] }
        post()
        let probe = prober, all = harnesses
        Task {
            if again { for h in all { await probe.invalidateDetect(h) } }
            let ready = await withTaskGroup(of: Detection.self) { g -> [Harness] in
                for h in all { g.addTask { await probe.detect(h) } }
                var ready: [Harness] = []
                for await d in g {
                    if d.ready { ready.append(d.harness) }
                    await MainActor.run { self.found(d) }
                }
                return ready
            }
            for h in all where ready.contains(h) {
                guard let l = try? await probe.planLimits(h) else { continue }
                await MainActor.run {
                    self.plans[h.rawValue] = l
                    self.post()
                }
            }
            await MainActor.run {
                self.detecting = false
                self.post()
            }
        }
    }

    private func found(_ d: Detection) {
        pending.removeAll { $0 == d.harness }
        var list = (detections ?? []).filter { $0.harness != d.harness } + [d]
        list.sort { (harnesses.firstIndex(of: $0.harness) ?? 0) < (harnesses.firstIndex(of: $1.harness) ?? 0) }
        detections = list
        post()
    }

    func loadModels(_ harness: String) {
        guard !harness.isEmpty, models[harness] == nil else { return }
        models[harness] = []
        let rt = runtime
        Task {
            let list = (try? await rt.models(Harness(harness))) ?? []
            await MainActor.run {
                self.models[harness] = list
                self.post()
            }
        }
    }

    // Copies the limits of the last call to the main queue.
    func refreshLimits() {
        Task {
            let l = await limits.last
            await MainActor.run {
                self.lastLimits = l
                self.post()
            }
        }
    }

    func detection(_ harness: String) -> Detection? { detections?.first { $0.harness.rawValue == harness } }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

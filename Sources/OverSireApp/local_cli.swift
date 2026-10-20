import Foundation
import OverSireAI
import AIEngineAgentBinder
import AgentBinder

// The local CLI engine of the app: one AgentBinder runtime, the CLIs on this Mac, their models and plan limits.
// The state changes on the main queue only.
final class LocalCLI {
    static let shared = LocalCLI()
    static let changed = Notification.Name("LocalCLI.changed")

    let runtime: Runtime
    let limits = PlanLimits()
    private(set) var detections: [Detection]?
    private(set) var detecting = false
    private(set) var plans: [String: Limits] = [:]
    private(set) var models: [String: [ModelInfo]] = [:]
    // The plan limits from the last call, for the bars in Settings › AI.
    private(set) var lastLimits: Limits?

    init(runtime: Runtime? = nil) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.runtime = runtime ?? Runtime(options: .init(clientName: "oversire", clientVersion: version,
                                                         ledger: URL(fileURLWithPath: CONFIG_DIR + "/agent-binder-ledger.json")))
        if runtime == nil { Task { await self.runtime.reconcile() } }
    }

    func engine(_ cfg: AIConfig) -> AgentBinderEngine {
        AgentBinderEngine(config: cfg.localCLI, runtime: runtime, limits: limits)
    }

    /// UI shots set the table with no probe.
    func seed(_ d: [Detection], plans: [String: Limits] = [:], models: [String: [ModelInfo]] = [:], limits: Limits? = nil) {
        detections = d
        self.plans = plans
        self.models = models
        lastLimits = limits
    }

    // Probes each CLI, then reads the plan of each ready one.
    func detect(again: Bool = false) {
        guard !detecting, again || detections == nil else { return }
        detecting = true
        post()
        let rt = runtime
        Task {
            if again { for h in Harness.allBuiltIn { await rt.invalidateDetect(h) } }
            let all = await rt.detectAll()
            var found: [String: Limits] = [:]
            for d in all where d.ready {
                if let l = try? await rt.limits(d.harness) { found[d.harness.rawValue] = l }
            }
            let plans = found
            await MainActor.run {
                self.detections = all
                self.plans = plans
                self.detecting = false
                self.post()
            }
        }
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

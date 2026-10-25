import AppKit
import OverSireCore
import OverSireSync
@testable import OverSireApp

/// A manual clock for the bus and the gate. `run()` fires the due calls.
final class ManualSchedule {
    private var calls: [(at: TimeInterval, f: () -> Void)] = []
    private(set) var now: TimeInterval = 0

    func schedule(_ t: TimeInterval, _ f: @escaping () -> Void) { calls.append((now + t, f)) }

    func advance(_ t: TimeInterval) {
        now += t
        while let i = calls.firstIndex(where: { $0.at <= now }) { calls.remove(at: i).f() }
    }
}

/// App data for page tests. Files go to a fresh temporary folder.
final class TestAppData: AppData {
    var grouped: [(String, [Run])] = []
    var prGrouped: [(String, [ChangeRequest])] = []
    var lastUpdate = Date()
    var firstLoad = false
    let clock = ManualSchedule()
    lazy var bus = ChangeBus(schedule: clock.schedule)
    let tmp = NSTemporaryDirectory() + "oversire-tests-" + UUID().uuidString
    lazy var writes = StoreWrites(store: LocalStore(dir: URL(fileURLWithPath: tmp + "/store")))
    lazy var projectStore = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                         statePath: tmp + "/state.json", activityPath: tmp + "/activity.jsonl")
    lazy var agentIndex = AgentIndex(writes: writes)
    let workstreams = WorkstreamIndex()
    let cleaner = Cleaner(defaults: UserDefaults(suiteName: "oversire-tests")!)
    lazy var queue = WorkQueue(writes: writes, store: projectStore, agents: agentIndex)
    lazy var memory = ProjectMemory(writes: writes)
    lazy var updater = Updater()
    lazy var cloudSetup = CloudSetup()
    lazy var repoCatalog = RepoCatalog(path: tmp + "/repo-cache.json")
    lazy var projectCatalog = ProjectCatalog(trackers: ENV, path: tmp + "/plane-cache.json")
    lazy var areas = ItemAreaBook(writes: writes)
    lazy var suggestions = SuggestionBook(writes: writes)
    lazy var planner = PlannerBook(writes: writes)
    lazy var enhanceAgent = EnhanceAgent(store: projectStore, memory: memory, questions: questions, agents: agentIndex)
    lazy var attachments = MainActor.assumeIsolated { AttachmentBook(store: projectStore) }
    lazy var sessions = SessionNotes(path: tmp + "/sessions.json", agents: agentIndex, store: projectStore,
                                     writeBack: PlaneWriteBack(path: tmp + "/wb.json", store: projectStore, trackers: ENV))
    let busy = BusyTracker()
    lazy var ciAssist = CIAssist(path: tmp + "/ci.json")
    lazy var questions = QuestionHub(agents: agentIndex, writes: writes)
    lazy var stats = WorkStats(path: tmp + "/work-stats.json") { _ in nil }
    lazy var itemSummaries = ItemSummaries(path: tmp + "/summaries.json", ai: { nil })
    lazy var statusJob = StatusJob(path: tmp + "/session-status.json", agents: agentIndex, queue: queue)
    let relay = LiveSync(secrets: SecretStore(service: "com.oversire.app.tests"), cursors: CursorStore(url: nil))
    var logs: LogStore? { nil }
    var caps: Set<Capability> = []
    lazy var actions = AppActionCatalog(data: self)
    var assistant: AssistantController? { nil }

    init() { try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(atPath: tmp) }

    func has(_ c: Capability) -> Bool { caps.contains(c) }
    func rerun(repo: String, runs: [Run], failedOnly: Bool) {}
    func setIgnored(_ runs: [Run], ignored: Bool) {}
    func refresh(force: Bool, completion: (() -> Void)?) { completion?() }

    /// Posts a change and lets the burst end.
    func post(_ c: DataChange) {
        bus.post(c)
        clock.advance(1)
    }
}

extension Run {
    static func sample(_ id: Int, status: String = "completed", conclusion: String? = "success", updated: String = "2026-10-20T10:00:00Z") -> Run {
        Run(id: "\(id)", name: "CI", displayTitle: "Run \(id)", status: status, conclusion: conclusion, headBranch: "main", headSha: "abc\(id)",
            event: "push", url: "https://github.com/o/r/actions/runs/\(id)", updatedAt: updated, createdAt: "2026-10-20T09:00:00Z",
            startedAt: "2026-10-20T09:00:00Z", number: id, workflowName: "CI", actorLogin: nil)
    }
}

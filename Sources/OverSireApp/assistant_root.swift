import Cocoa
import os
import OverSireCore
import OverSireAI
import OverSireAssistant
import AIEngineAgentBinder
import AgentBinder

extension MCPListener: ChatToolHost {}

// ─── Assistant root ──────────────────────────────────────────────────────────
// The parts of the assistant: the MCP socket, the chat engines, the loop and the panel state.
// A change of the source or the API key makes the engines again. The chats stay in the store. Main thread only.
final class AssistantRoot {
    let store = ThreadStore(store: STORE_WRITES.store, blobDir: URL(fileURLWithPath: CONFIG_DIR + "/assistant/blobs"))
    let mcp = MCPListener(server: MCPServer())
    private let permissions = OSAllocatedUnfairLock(initialState: AI_CFG.assistant.permissions)
    private let secrets = OSAllocatedUnfairLock(initialState: [String]())
    private unowned let app: GHActionsBar
    private var cli: AgentBinderChat?
    private var built: AssistantController?
    private var builtFor: Fingerprint?
    private var idle: Timer?

    private struct Fingerprint: Equatable {
        let source: EngineID
        let harness: String
        let model: String
        let key: Bool
        let api: String
    }

    init(app: GHActionsBar) {
        self.app = app
        idle = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            guard let cli = self?.cli else { return }
            Task { await cli.closeIdle() }
        }
        let store = store
        let keep = AI_CFG.assistant.retention
        Task.detached { try? await store.prune(keep) }
    }

    /// Nil when no engine can chat. The panel then links to Settings › AI.
    var controller: AssistantController? {
        let key = AIClient.keyStore.get(AIClient.keyName) ?? ""
        let cfg = AI_CFG
        let f = Fingerprint(source: cfg.assistant.engine(jobs: cfg.engine), harness: cfg.cliHarness, model: cfg.cliModel,
                            key: cfg.keyVerified(key), api: cfg.apiKey.model + cfg.apiKey.baseURL)
        if f == builtFor { return built }
        builtFor = f
        built = make(cfg, key: key, prefer: f.source)
        return built
    }

    /// Settings › AI calls it after each change of the assistant section.
    func configChanged() {
        permissions.withLock { $0 = AI_CFG.assistant.permissions }
        let old = built
        if controller !== old { app.appWindow.resetAssistant() }
    }

    private func make(_ cfg: AIConfig, key: String, prefer: EngineID) -> AssistantController? {
        var engines: [(any ChatEngine, AssistantEngine)] = []
        cli = nil
        if !cfg.cliHarness.isEmpty, SettingsPage.cliChatNote(cfg.cliHarness) == nil {
            let c = AgentBinderChat(config: cfg.localCLI, runtime: LocalCLI.shared.runtime, limits: LocalCLI.shared.limits, tools: mcp,
                                    workRoot: URL(fileURLWithPath: CONFIG_DIR + "/assistant/work"))
            cli = c
            let name = Harness(cfg.cliHarness).binaryName
            engines.append((c, AssistantEngine(id: .localCLI, label: (cfg.cliModel.isEmpty ? name : "\(name) · \(cfg.cliModel)") + " · this Mac")))
        }
        if cfg.keyVerified(key) {
            let e = APIKeyEngine(config: cfg.apiKey, key: key, http: URLSessionTransport())
            engines.append((e, AssistantEngine(id: .apiKey, label: "API key · \(cfg.apiKey.model)")))
        }
        guard !engines.isEmpty else { return nil }
        engines = engines.filter { $0.1.id == prefer } + engines.filter { $0.1.id != prefer }

        secrets.withLock { $0 = Self.readSecrets(key) }
        let perms = permissions, secrets = secrets, store = store
        let actions = app.actions
        actions.link.follows = { id in
            let t = try? await store.thread(id)
            if let f = t?.follow { return f }
            return await MainActor.run { AI_CFG.assistant.follow }
        }
        let loop = AssistantLoop(
            router: ChatRouter(engines: engines.map(\.0)), catalog: actions, policy: RuleConfirmPolicy { perms.withLock { $0 } }, store: store,
            system: { thread, page in await MainActor.run { Self.system(thread, page) } },
            page: { [weak app] in await MainActor.run { app?.appWindow.pageContext } },
            redactor: { Redactor(secrets: secrets.withLock { $0 }) },
            log: { APP_LOG.write($0.entry) }, turnLog: { APP_LOG.write($0.entry) })
        let server = mcp.server
        Task { await server.attach(loop) }
        let list = engines.map(\.1)
        return MainActor.assumeIsolated { AssistantController(loop: loop, engines: list, page: { [weak app] in app?.appWindow.pageContext }) }
    }

    /// The Keychain secrets that a tool result must not show: the AI key and the account tokens.
    private static func readSecrets(_ key: String) -> [String] {
        let keychain = KeychainSecrets()
        return ([key] + ACCOUNTS.flatMap(\.secretKeys).compactMap(keychain.secret)).filter { $0.count >= 8 }
    }

    static func system(_ thread: AssistantThread, _ page: PageContext?) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE yyyy-MM-dd"
        let snap = MachinesController.shared.snapshot
        let me = snap.info?.machine.rawValue
        var ctx: [String: String] = [
            "today": df.string(from: Date()),
            "sources": ACCOUNTS.map { "\($0.account.provider.rawValue) \($0.account.id)" }.joined(separator: ", "),
            "machines": snap.peers.map(\.machine.rawValue).filter { $0 != me }.joined(separator: ", "),
            "extra": AI_CFG.extraContext,
        ]
        if thread.follow ?? AI_CFG.assistant.follow { ctx["follow"] = "on" }
        if let page {
            var p = "\(page.title) (\(page.route))."
            if !page.rows.isEmpty { p += " Rows: " + page.rows.prefix(20).map { "\($0.id): \($0.text)" }.joined(separator: "; ") + "." }
            if !page.selection.isEmpty { p += " Selected: " + page.selection.joined(separator: ", ") + "." }
            ctx["page"] = p
        }
        return (try? AITaskKind.assistant.prompt(AIInput(text: "", context: ctx)).system) ?? ""
    }
}

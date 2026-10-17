import Foundation
import OverSireCore
import OverSireAI
import TrackerPlane
import CryptoKit
import os

// ─── Configuration ───────────────────────────────────────────────────────────

struct AppConfig: Codable {
    var repos: [String]
    var orgs: [String]?
    var pollInterval: TimeInterval?
    var pollActiveInterval: TimeInterval?
    var runsPerRepo: Int?
    var filterDefaultBranches: Bool?
    var sortByRecent: Bool?
    var oneRowPerWorkflow: Bool?
    var latestAcrossBranches: Bool?
    var repoColors: [String: Int]?
    var autoUpdate: Bool?
    var relay: RelayConfig?
    var notifications: NotificationSettings?
    var tabs: TabVisibility?
    var projects: ProjectsConfig?
    var ai: AIConfig?
    var general: GeneralConfig?
    var linking: LinkRules?
    var agents: AgentsConfig?
    var accounts: [AccountConfig]?   // one entry for each connected vendor account
}

// How much the AI checks may do. Auto acts only on "looks done". "Looks stuck" always asks.
enum AIMode: String, Codable, CaseIterable {
    case off, ask, auto
    var label: String { self == .off ? "Off" : self == .ask ? "Ask me" : "Auto" }
}

// The queue, the AI checks of agents, the intake agent and the write-back to Plane.
struct AgentsConfig: Codable, Equatable {
    var autoStart = true                // the queue starts the next item when its condition holds
    var slots: [String: Int] = [:]      // project ref key → agents at the same time
    var startLabel = "agent"            // a Plane label that adds the item to the queue
    var botUser = ""                    // a Plane assignee that adds the item to the queue
    var aiMode = AIMode.ask
    var quietMinutes = 10.0             // an agent with no output this long gets a check
    var intakePrompt = AgentsConfig.defaultIntakePrompt
    var intakeScratch = false           // the intake agent works in a scratch worktree, not in main
    var writeBack = WriteBackConfig()

    static let defaultIntakePrompt = """
    You check a new intake ticket. Do not change files. Read the code in this folder to understand the ticket.
    If it is a bug, find the steps to reproduce it, and reproduce it with read-only commands if you can.
    If the ticket is too vague, list the facts that are missing.
    End with one JSON object on one line and nothing after it:
    {"verdict":"clear|vague|reproduced|not_reproduced|duplicate","findings":["..."],"block":"markdown to add to the ticket","priority":"urgent|high|medium|low|none","labels":["..."]}

    Ticket {KEY}: {title}
    {url}

    {body}
    """

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        slots = try c.decodeIfPresent([String: Int].self, forKey: .slots) ?? [:]
        startLabel = try c.decodeIfPresent(String.self, forKey: .startLabel) ?? "agent"
        botUser = try c.decodeIfPresent(String.self, forKey: .botUser) ?? ""
        aiMode = try c.decodeIfPresent(AIMode.self, forKey: .aiMode) ?? .ask
        quietMinutes = try c.decodeIfPresent(Double.self, forKey: .quietMinutes) ?? 10
        intakePrompt = try c.decodeIfPresent(String.self, forKey: .intakePrompt) ?? AgentsConfig.defaultIntakePrompt
        intakeScratch = try c.decodeIfPresent(Bool.self, forKey: .intakeScratch) ?? false
        writeBack = try c.decodeIfPresent(WriteBackConfig.self, forKey: .writeBack) ?? WriteBackConfig()
    }

    func slots(_ projectKey: String) -> Int { max(1, slots[projectKey] ?? 1) }
}

// What OverSire may add to Plane. It never changes text of other people.
struct WriteBackConfig: Codable, Equatable {
    var enabled = true
    var links = true                    // add the ChangeRequest, run and worktree links once
    var labels = true                   // agent:working, agent:needs-input, agent:done
    var block = true                    // the OverSire block at the end of the body, between markers
    var sessionComment = true           // one comment with the summary when the session ends
    var moveToReview = false            // set In review when the PR opens

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        links = try c.decodeIfPresent(Bool.self, forKey: .links) ?? true
        labels = try c.decodeIfPresent(Bool.self, forKey: .labels) ?? true
        block = try c.decodeIfPresent(Bool.self, forKey: .block) ?? true
        sessionComment = try c.decodeIfPresent(Bool.self, forKey: .sessionComment) ?? true
        moveToReview = try c.decodeIfPresent(Bool.self, forKey: .moveToReview) ?? false
    }
}

enum Theme: String, Codable, CaseIterable { case system, dark, light }

// Where the app shows: the menu bar icon, the Dock icon, or both.
enum ShowIn: String, Codable, CaseIterable {
    case menu, dock, both
    var dock: Bool { self != .menu }
    var menuBar: Bool { self != .dock }
}

struct GeneralConfig: Codable, Equatable {
    var theme = Theme.dark
    var showIn = ShowIn.both
    var windowKey = KeyShortcut(keyCode: 8, modifiers: 0x1800)   // ⌃⌥C
    var openWindowAtLaunch = false
    var sidebarCollapsed = false
    var smallPopover = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .dark
        showIn = try c.decodeIfPresent(ShowIn.self, forKey: .showIn) ?? .both
        windowKey = try c.decodeIfPresent(KeyShortcut.self, forKey: .windowKey) ?? KeyShortcut(keyCode: 8, modifiers: 0x1800)
        openWindowAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .openWindowAtLaunch) ?? false
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
        smallPopover = try c.decodeIfPresent(Bool.self, forKey: .smallPopover) ?? true
    }
}

// Which transition events create macOS notifications. Omitted legacy config
// fields keep the previous behavior: notify for every start and completion.
struct NotificationSettings: Codable {
    var started = true
    var succeeded = true
    var failed = true
    var cancelled = true
    var other = true

    init() {}

    // Hand-written config files may omit individual switches.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        started = try c.decodeIfPresent(Bool.self, forKey: .started) ?? true
        succeeded = try c.decodeIfPresent(Bool.self, forKey: .succeeded) ?? true
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? true
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? true
        other = try c.decodeIfPresent(Bool.self, forKey: .other) ?? true
    }
}

// One column of the project notification matrix. Omitted switches keep the defaults.
struct NotifyScope: Codable, Equatable {
    var any: Bool
    var mine: Bool
}

struct ProjectNotificationSettings: Codable, Equatable {
    var mention = true
    var comment = NotifyScope(any: false, mine: true)
    var status = NotifyScope(any: false, mine: true)
    var added = NotifyScope(any: true, mine: true)
    var assigned = true
    var closed = NotifyScope(any: false, mine: true)
    var otherFields = NotifyScope(any: false, mine: false)
    var intake = true
    var agentWaiting = true
    var agentDone = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mention = try c.decodeIfPresent(Bool.self, forKey: .mention) ?? true
        comment = try c.decodeIfPresent(NotifyScope.self, forKey: .comment) ?? NotifyScope(any: false, mine: true)
        status = try c.decodeIfPresent(NotifyScope.self, forKey: .status) ?? NotifyScope(any: false, mine: true)
        added = try c.decodeIfPresent(NotifyScope.self, forKey: .added) ?? NotifyScope(any: true, mine: true)
        assigned = try c.decodeIfPresent(Bool.self, forKey: .assigned) ?? true
        closed = try c.decodeIfPresent(NotifyScope.self, forKey: .closed) ?? NotifyScope(any: false, mine: true)
        otherFields = try c.decodeIfPresent(NotifyScope.self, forKey: .otherFields) ?? NotifyScope(any: false, mine: false)
        intake = try c.decodeIfPresent(Bool.self, forKey: .intake) ?? true
        agentWaiting = try c.decodeIfPresent(Bool.self, forKey: .agentWaiting) ?? true
        agentDone = try c.decodeIfPresent(Bool.self, forKey: .agentDone) ?? true
    }
}

enum ProjectView: String, Codable { case board, activity }

struct ProjectsConfig: Codable {
    var workspaces: [PlaneWorkspace] = []   // tokens are in the Keychain
    var picked: [String] = []         // project keys "slug/uuid"
    var allOf: [String] = []          // workspace slugs
    var pollMinutes = 5
    var itemsPerProject = 10          // 0 = all
    var hideDoneAfterDays = 1         // 0 = never hide, -1 = always hide
    var showSubItems = false          // also list sub-items as rows. An open item always shows its sub-items
    var defaultView = ProjectView.board
    var menuDot = true
    var showTab = true
    var notifications = ProjectNotificationSettings()
    var order: [String] = []          // project keys, top to bottom
    var folded: [String] = []         // project keys that show only the header
    var capture = CaptureConfig()
    var orca = OrcaConfig()
    var settings: [String: ProjectLocalSettings] = [:]   // by project key ("OVERSIRE")

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decodeIfPresent([PlaneWorkspace].self, forKey: .workspaces) ?? []
        // Keys of GitHub projects ("owner/3") and of removed workspaces are stale.
        let slugs = Set(workspaces.map(\.slug))
        picked = (try c.decodeIfPresent([String].self, forKey: .picked) ?? []).filter { k in
            let parts = k.split(separator: "/")
            return parts.count == 2 && slugs.contains(String(parts[0])) && parts[1].count == 36
        }
        allOf = (try c.decodeIfPresent([String].self, forKey: .allOf) ?? []).filter { slugs.contains($0) }
        pollMinutes = min(30, max(2, try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 5))
        itemsPerProject = try c.decodeIfPresent(Int.self, forKey: .itemsPerProject) ?? 10
        hideDoneAfterDays = try c.decodeIfPresent(Int.self, forKey: .hideDoneAfterDays) ?? 1
        showSubItems = try c.decodeIfPresent(Bool.self, forKey: .showSubItems) ?? false
        defaultView = try c.decodeIfPresent(ProjectView.self, forKey: .defaultView) ?? .board
        menuDot = try c.decodeIfPresent(Bool.self, forKey: .menuDot) ?? true
        showTab = try c.decodeIfPresent(Bool.self, forKey: .showTab) ?? true
        notifications = try c.decodeIfPresent(ProjectNotificationSettings.self, forKey: .notifications) ?? ProjectNotificationSettings()
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        folded = try c.decodeIfPresent([String].self, forKey: .folded) ?? []
        capture = try c.decodeIfPresent(CaptureConfig.self, forKey: .capture) ?? CaptureConfig()
        orca = try c.decodeIfPresent(OrcaConfig.self, forKey: .orca) ?? OrcaConfig()
        settings = try c.decodeIfPresent([String: ProjectLocalSettings].self, forKey: .settings) ?? [:]
    }

    func local(_ key: String) -> ProjectLocalSettings { settings[key.uppercased()] ?? ProjectLocalSettings() }

    mutating func setLocal(_ key: String, _ s: ProjectLocalSettings) { settings[key.uppercased()] = s }

    // The notification settings of a project. Nil when the project is muted.
    func notifications(for key: String) -> ProjectNotificationSettings? {
        let l = local(key)
        return l.muted ? nil : (l.notifications ?? notifications)
    }

    // The agent and the prompt for an item. The project settings come first, then the app defaults.
    func launch(for item: Item) -> (agent: String, prompt: String) {
        let l = local(item.key.split(separator: "-").dropLast().joined(separator: "-"))
        var o = orca
        if let a = l.agent, !a.isEmpty { o.agent = a }
        if let p = l.prompt, !p.isEmpty { o.prompt = p }
        return (o.agent, o.prompt(for: item))
    }

    // The Orca root of a project. `orca.roots` (by "slug/uuid") stays a mirror, because older code reads it.
    func orcaRoot(_ p: ProjectSummary) -> String? {
        orca.roots[p.ref.storeKey].flatMap { $0.isEmpty ? nil : $0 } ?? local(p.identifier).orcaRoot
    }

    mutating func setOrcaRoot(_ p: ProjectSummary, _ path: String?) {
        var l = local(p.identifier)
        l.orcaRoot = path
        setLocal(p.identifier, l)
        orca.roots[p.ref.storeKey] = path
    }

    // Copies each `orca.roots` entry into the settings of its project.
    mutating func migrateRoots(_ projects: [ProjectSummary]) {
        for p in projects {
            guard let root = orca.roots[p.ref.storeKey], !root.isEmpty, local(p.identifier).orcaRoot == nil else { continue }
            var l = local(p.identifier)
            l.orcaRoot = root
            setLocal(p.identifier, l)
        }
    }

    // A local category wins over the category of the tracker status.
    func category(_ o: StatusOption, project key: String) -> StatusCategory {
        settings[key.uppercased()]?.categories[o.id] ?? o.autoCategory
    }

    // Keys in `order` come first. Projects not in it follow by workspace, then title.
    func sorted(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        var rank: [String: Int] = [:]
        for (i, k) in order.enumerated() where rank[k.lowercased()] == nil { rank[k.lowercased()] = i }
        return projects.sorted { a, b in
            let ra = rank[a.ref.storeKey.lowercased()] ?? .max, rb = rank[b.ref.storeKey.lowercased()] ?? .max
            if ra != rb { return ra < rb }
            if a.ref.workspace != b.ref.workspace { return a.ref.workspace < b.ref.workspace }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func isFolded(_ key: String) -> Bool { folded.contains { $0.caseInsensitiveCompare(key) == .orderedSame } }

    mutating func setFolded(_ key: String, _ on: Bool) {
        folded.removeAll { $0.caseInsensitiveCompare(key) == .orderedSame }
        if on { folded.append(key) }
    }
}

// Where the icon of a project comes from. Auto takes the first source that exists: tracker, repo, org, letter.
enum IconChoice: Codable, Hashable {
    case auto, upload, tracker, repo(String), org(String), letter

    var raw: String {
        switch self {
        case .auto: return "auto"
        case .upload: return "upload"
        case .tracker: return "tracker"
        case .repo(let r): return "repo:" + r
        case .org(let o): return "org:" + o
        case .letter: return "letter"
        }
    }

    init(raw: String) {
        if raw.hasPrefix("repo:") { self = .repo(String(raw.dropFirst(5))); return }
        if raw.hasPrefix("org:") { self = .org(String(raw.dropFirst(4))); return }
        switch raw {
        case "upload": self = .upload
        case "tracker": self = .tracker
        case "letter": self = .letter
        default: self = .auto
        }
    }

    init(from decoder: Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

// Project settings that stay on this Mac. They work the same for each tracker.
struct ProjectLocalSettings: Codable, Equatable {
    var icon = IconChoice.auto
    var color: String?
    var github: [String] = []         // "org" or "owner/repo"
    var orcaRoot: String?
    var branchTemplate: String?       // {key}, {KEY}, {slug}, {title}
    var agent: String?
    var prompt: String?
    var notifications: ProjectNotificationSettings?   // nil uses the app default
    var categories: [String: StatusCategory] = [:]   // status id → category
    var hidden = false
    var muted = false

    static let defaultBranch = "{key}/{slug}"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icon = try c.decodeIfPresent(IconChoice.self, forKey: .icon) ?? .auto
        color = try c.decodeIfPresent(String.self, forKey: .color)
        github = try c.decodeIfPresent([String].self, forKey: .github) ?? []
        orcaRoot = try c.decodeIfPresent(String.self, forKey: .orcaRoot)
        branchTemplate = try c.decodeIfPresent(String.self, forKey: .branchTemplate)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        notifications = try c.decodeIfPresent(ProjectNotificationSettings.self, forKey: .notifications)
        categories = try c.decodeIfPresent([String: StatusCategory].self, forKey: .categories) ?? [:]
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }

    // The branch name of an item: {key} lowercase, {KEY}, {slug} from the title, {title}.
    func branch(for item: Item) -> String {
        let slug = item.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .split(separator: "-", omittingEmptySubsequences: true).prefix(6).joined(separator: "-")
        return (branchTemplate?.isEmpty == false ? branchTemplate! : ProjectLocalSettings.defaultBranch)
            .replacingOccurrences(of: "{KEY}", with: item.key)
            .replacingOccurrences(of: "{key}", with: item.key.lowercased())
            .replacingOccurrences(of: "{slug}", with: String(slug))
            .replacingOccurrences(of: "{title}", with: item.title)
    }
}

// Global shortcut that opens the New item sheet. Carbon key code and modifier flags.
struct CaptureConfig: Codable, Equatable {
    var enabled = true
    var keyCode: UInt32 = 45            // N
    var modifiers: UInt32 = 0x1800      // control + option
    var pasteClipboard = true
    var aiTitle = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keyCode = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 45
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? 0x1800
        pasteClipboard = try c.decodeIfPresent(Bool.self, forKey: .pasteClipboard) ?? true
        aiTitle = try c.decodeIfPresent(Bool.self, forKey: .aiTitle) ?? true
    }
}

// ▶ starts a Plane item in an Orca terminal. `roots` maps a project key ("slug/uuid")
// to the Orca workspace folder. The environment is per Mac: nil runs on this Mac.
struct OrcaConfig: Codable, Equatable {
    static let defaultPrompt = "work on {url} in worktree group .wt/{key}"

    var enabled = true
    var cli = ""   // the runtime account sets it
    var environment: String?
    var agent = "claude"
    var prompt = OrcaConfig.defaultPrompt
    var roots: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cli = try c.decodeIfPresent(String.self, forKey: .cli) ?? ""
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? OrcaConfig.defaultPrompt
        roots = try c.decodeIfPresent([String: String].self, forKey: .roots) ?? [:]
    }

    // {url}, {key} (lowercase), {KEY} and {title}.
    func prompt(for item: Item) -> String {
        (prompt.isEmpty ? OrcaConfig.defaultPrompt : prompt)
            .replacingOccurrences(of: "{url}", with: item.url)
            .replacingOccurrences(of: "{KEY}", with: item.key)
            .replacingOccurrences(of: "{key}", with: item.key.lowercased())
            .replacingOccurrences(of: "{title}", with: item.title)
    }


    // The Orca workspace whose name matches the project: "towertail-workspace" for TOWERTAIL.
    static func guess(_ p: ProjectSummary, _ repos: [RuntimeRepo]) -> String? {
        let names = [p.identifier, p.title].map { $0.lowercased() }.flatMap { [$0 + "-workspace", $0] }
        for n in names { if let r = repos.first(where: { $0.name.lowercased() == n }) { return r.path } }
        return nil
    }
}

// The API key is in the Keychain, not here.
struct AIConfig: Codable, Equatable {
    var format = AIFormat.openai
    var baseURL = ""
    var model = ""
    var effort = "low"                  // OpenAI only. "none" leaves out the field.
    var maxTokens = 1024                // Anthropic only
    var extraContext = ""
    var enabled = false
    var verified = ""                   // fingerprint of the last passed test
    var titleAndFields = true
    var tidy = true
    var pickProject = true
    // Features for agents and CI. Each is a switch in Settings › AI.
    var agentChecks = true              // "looks done" and "looks stuck"
    var queueOrder = true
    var intakeAgent = true
    var sessionSummary = true
    var ciExplain = true                // a short cause of a failed run that no agent watches
    var flaky = true                    // mark a run that failed, then passed on the same commit
    var digest = false                  // morning digest on Home
    var digestHour = 8

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(AIFormat.self, forKey: .format) ?? .openai
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? "low"
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 1024
        extraContext = try c.decodeIfPresent(String.self, forKey: .extraContext) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        verified = try c.decodeIfPresent(String.self, forKey: .verified) ?? ""
        titleAndFields = try c.decodeIfPresent(Bool.self, forKey: .titleAndFields) ?? true
        tidy = try c.decodeIfPresent(Bool.self, forKey: .tidy) ?? true
        pickProject = try c.decodeIfPresent(Bool.self, forKey: .pickProject) ?? true
        agentChecks = try c.decodeIfPresent(Bool.self, forKey: .agentChecks) ?? true
        queueOrder = try c.decodeIfPresent(Bool.self, forKey: .queueOrder) ?? true
        intakeAgent = try c.decodeIfPresent(Bool.self, forKey: .intakeAgent) ?? true
        sessionSummary = try c.decodeIfPresent(Bool.self, forKey: .sessionSummary) ?? true
        ciExplain = try c.decodeIfPresent(Bool.self, forKey: .ciExplain) ?? true
        flaky = try c.decodeIfPresent(Bool.self, forKey: .flaky) ?? true
        digest = try c.decodeIfPresent(Bool.self, forKey: .digest) ?? false
        digestHour = try c.decodeIfPresent(Int.self, forKey: .digestHour) ?? 8
    }

    var apiKey: APIKeyConfig { APIKeyConfig(format: format, baseURL: baseURL, model: model, effort: effort, maxTokens: maxTokens) }

    func fingerprint(key: String) -> String {
        let raw = "\(format.rawValue)|\(baseURL)|\(model)|\(key)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isOn(key: String?) -> Bool {
        guard enabled, let key, !key.isEmpty, !verified.isEmpty else { return false }
        return verified == fingerprint(key: key)
    }
}

// Which main tabs are shown. Projects uses ProjectsConfig.showTab.
struct TabVisibility: Codable {
    var actions = true
    var prs = true
    var insights = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actions = try c.decodeIfPresent(Bool.self, forKey: .actions) ?? true
        prs = try c.decodeIfPresent(Bool.self, forKey: .prs) ?? true
        insights = try c.decodeIfPresent(Bool.self, forKey: .insights) ?? true
    }
}

let CONFIG_DIR  = NSString(string: "~/.config/oversire").expandingTildeInPath
let CONFIG_PATH = (CONFIG_DIR as NSString).appendingPathComponent("config.json")
let REPO_CACHE_PATH = (CONFIG_DIR as NSString).appendingPathComponent("repo-cache.json")
let PROJECT_CACHE_PATH = (CONFIG_DIR as NSString).appendingPathComponent("plane-cache.json")
let PROJECT_STATE_PATH = (CONFIG_DIR as NSString).appendingPathComponent("plane-state.json")
let QUEUE_PATH = (CONFIG_DIR as NSString).appendingPathComponent("queue.json")
let WRITEBACK_PATH = (CONFIG_DIR as NSString).appendingPathComponent("writeback.json")
let CHECKS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("agent-checks.json")
let SESSIONS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("sessions.json")
let CI_ASSIST_PATH = (CONFIG_DIR as NSString).appendingPathComponent("ci-assist.json")
let PROJECT_ACTIVITY_PATH = (CONFIG_DIR as NSString).appendingPathComponent("plane-activity.jsonl")

// REPOS is what the app tracks: PICKED_REPOS plus every repo of PICKED_ORGS.
var REPOS: [String] = []
var PICKED_REPOS: [String] = []
var PICKED_ORGS: [String] = []
var POLL_NORMAL: TimeInterval = 30
var POLL_ACTIVE: TimeInterval = 10
var RUNS_PER_REPO: Int = 10
var FILTER_DEFAULT_BRANCHES: Bool = false
var SORT_BY_RECENT: Bool = true
var ONE_ROW_PER_WORKFLOW: Bool = true
// With ONE_ROW_PER_WORKFLOW, keep only the latest run of each workflow over all branches.
var LATEST_ACROSS_BRANCHES: Bool = false
var REPO_COLORS: [String: Int] = [:]
var AUTO_UPDATE: Bool = true
var NOTIFICATIONS = NotificationSettings()
var TABS = TabVisibility()
var PROJECTS_CFG = ProjectsConfig()
var AI_CFG = AIConfig()
var GENERAL = GeneralConfig()
var LINKING = LinkRules()
var AGENTS = AgentsConfig()
var ACCOUNTS: [AccountConfig] = []
let DEFAULT_BRANCHES: Set<String> = ["main", "develop"]

let repoPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$")

let log = Logger(subsystem: "com.oversire.app", category: "app")

func isValidRepo(_ s: String) -> Bool {
    repoPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// saveConfig writes only after loadConfig read the file or found no file.
/// A process that did not read the config (a test) or could not decode it must not overwrite it.
private(set) var CONFIG_READ = false

func loadConfig() {
    guard let data = FileManager.default.contents(atPath: CONFIG_PATH) else { CONFIG_READ = true; return }
    guard let c = try? JSONDecoder().decode(AppConfig.self, from: data) else {
        log.error("Cannot decode \(CONFIG_PATH, privacy: .public). OverSire does not save the config.")
        return
    }
    CONFIG_READ = true
    PICKED_REPOS = c.repos.filter { isValidRepo($0) }
    PICKED_ORGS = c.orgs ?? []
    REPOS = PICKED_REPOS
    POLL_NORMAL = max(5, c.pollInterval ?? 30)
    POLL_ACTIVE = max(5, c.pollActiveInterval ?? 10)
    RUNS_PER_REPO = min(max(1, c.runsPerRepo ?? 10), 100)
    FILTER_DEFAULT_BRANCHES = c.filterDefaultBranches ?? false
    SORT_BY_RECENT = c.sortByRecent ?? true
    ONE_ROW_PER_WORKFLOW = c.oneRowPerWorkflow ?? true
    LATEST_ACROSS_BRANCHES = c.latestAcrossBranches ?? false
    REPO_COLORS = c.repoColors ?? [:]
    AUTO_UPDATE = c.autoUpdate ?? true
    if let n = c.notifications { NOTIFICATIONS = n }
    if let r = c.relay { RELAY = r }
    if let t = c.tabs { TABS = t }
    if let p = c.projects { PROJECTS_CFG = p }
    if let a = c.ai { AI_CFG = a }
    if let g = c.general { GENERAL = g }
    if let l = c.linking { LINKING = l }
    if let a = c.agents { AGENTS = a }
    ACCOUNTS = AppEnvironment.accounts(from: c)
    AppEnvironment.applyLegacyFields(ACCOUNTS, to: &PROJECTS_CFG)
    ENV.load(ACCOUNTS)
}

func saveConfig() {
    guard CONFIG_READ else { return }
    try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
    ACCOUNTS = ACCOUNTS.filter { !AppEnvironment.repoProviders.contains($0.account.provider) }
        + AppEnvironment.repoAccounts(repos: PICKED_REPOS.filter(isValidRepo), orgs: PICKED_ORGS)
    AppEnvironment.applyLegacyFields(ACCOUNTS, to: &PROJECTS_CFG)
    ENV.load(ACCOUNTS)
    var c = AppConfig(repos: PICKED_REPOS.filter { isValidRepo($0) },
                      orgs: PICKED_ORGS.isEmpty ? nil : PICKED_ORGS, pollInterval: POLL_NORMAL,
                      pollActiveInterval: POLL_ACTIVE, runsPerRepo: RUNS_PER_REPO,
                      filterDefaultBranches: FILTER_DEFAULT_BRANCHES, sortByRecent: SORT_BY_RECENT,
                      oneRowPerWorkflow: ONE_ROW_PER_WORKFLOW, latestAcrossBranches: LATEST_ACROSS_BRANCHES,
                      repoColors: REPO_COLORS.isEmpty ? nil : REPO_COLORS, autoUpdate: AUTO_UPDATE,
                      relay: RELAY, notifications: NOTIFICATIONS, tabs: TABS, projects: PROJECTS_CFG, ai: AI_CFG, general: GENERAL, linking: LINKING, agents: AGENTS)
    c.accounts = ACCOUNTS
    if let data = try? JSONEncoder().encode(c) {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let pretty = try? JSONSerialization.data(withJSONObject: json as Any, options: .prettyPrinted) {
            try? pretty.write(to: URL(fileURLWithPath: CONFIG_PATH))
        }
    }
}

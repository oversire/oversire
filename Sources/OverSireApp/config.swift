import Foundation
import AgentBinder
import OverSireCore
import OverSireAI
import OverSireAssistant
import OverSireSync
import AIEngineAgentBinder
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
    var logs: LogConfig?
    var accounts: [AccountConfig]?   // one entry for each connected vendor account
    var machines: MachinesConfig?
}

// How much the AI checks may do. Auto acts only on "looks done". "Looks stuck" always asks.
enum AIMode: String, Codable, CaseIterable {
    case off, ask, auto
    var label: String { self == .off ? "Off" : self == .ask ? "Ask me" : "Auto" }
}

// When a question of a session gets a macOS notification.
enum QuestionNotice: String, Codable, CaseIterable {
    case now, later, never
    var label: String { self == .now ? "At once" : self == .later ? "After 30 min" : "Never" }
    var delay: TimeInterval? { self == .now ? 0 : self == .later ? 1800 : nil }
}

// The queue, the AI checks of agents, the intake agent and the write-back to Plane.
struct AgentsConfig: Codable, Equatable {
    var autoStart = true                // the queue starts the next item when its condition holds
    var slots: [String: Int] = [:]      // project ref key → agents at the same time
    var startLabel = "agent"            // a Plane label that adds the item to the queue
    var botUser = ""                    // a Plane assignee that adds the item to the queue
    var aiMode = AIMode.ask
    var quietMinutes = 10.0             // an agent with no output this long gets a check
    var questionNotice = QuestionNotice.later
    var intakePrompt = AgentsConfig.defaultIntakePrompt
    var intakeScratch = false           // Enhance works in a scratch worktree, not in main
    var enhanceVague = true             // start Enhance for a new intake item with a short note
    var writeBack = WriteBackConfig()
    var cleanup = CleanupConfig()

    /// The user template of Contract/prompts/enhance.md.
    static var defaultIntakePrompt: String { EnhancePrompt.template }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        slots = try c.decodeIfPresent([String: Int].self, forKey: .slots) ?? [:]
        startLabel = try c.decodeIfPresent(String.self, forKey: .startLabel) ?? "agent"
        botUser = try c.decodeIfPresent(String.self, forKey: .botUser) ?? ""
        aiMode = try c.decodeIfPresent(AIMode.self, forKey: .aiMode) ?? .ask
        quietMinutes = try c.decodeIfPresent(Double.self, forKey: .quietMinutes) ?? 10
        questionNotice = try c.decodeIfPresent(QuestionNotice.self, forKey: .questionNotice) ?? .later
        // A prompt of the old screen check has {KEY} fields. Enhance needs its own.
        intakePrompt = try c.decodeIfPresent(String.self, forKey: .intakePrompt).flatMap { $0.contains("{KEY}") ? nil : EnhancePrompt.migrate($0) }
            ?? AgentsConfig.defaultIntakePrompt
        intakeScratch = try c.decodeIfPresent(Bool.self, forKey: .intakeScratch) ?? false
        enhanceVague = try c.decodeIfPresent(Bool.self, forKey: .enhanceVague) ?? true
        writeBack = try c.decodeIfPresent(WriteBackConfig.self, forKey: .writeBack) ?? WriteBackConfig()
        cleanup = try c.decodeIfPresent(CleanupConfig.self, forKey: .cleanup) ?? CleanupConfig()
    }

    func slots(_ projectKey: String) -> Int { max(1, slots[projectKey] ?? PlannerSettings.defaultSlots) }
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
    var problems = false                // a notification when an OverSire problem opens

    init() {}

    // Hand-written config files may omit individual switches.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        problems = try c.decodeIfPresent(Bool.self, forKey: .problems) ?? false
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

    // The number of switches that differ from other.
    func changes(from other: Self) -> Int {
        let scopes: [KeyPath<Self, NotifyScope>] = [\.comment, \.status, \.added, \.closed, \.otherFields]
        let flags: [KeyPath<Self, Bool>] = [\.mention, \.assigned, \.intake, \.agentWaiting, \.agentDone]
        return scopes.reduce(0) { n, p in n + (self[keyPath: p].any != other[keyPath: p].any ? 1 : 0) + (self[keyPath: p].mine != other[keyPath: p].mine ? 1 : 0) }
            + flags.filter { self[keyPath: $0] != other[keyPath: $0] }.count
    }
}

// A project that does not use the app notification defaults.
struct NotificationOverride: Equatable {
    enum Kind: Equatable { case muted, custom(changes: Int) }
    let key: String
    let kind: Kind
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
    var workFolded: Set<String> = ["done"]   // Work › Items section ids that show only the header
    var capture = CaptureConfig()
    var runtime = RuntimeConfig()
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
        workFolded = try c.decodeIfPresent(Set<String>.self, forKey: .workFolded) ?? ["done"]
        capture = try c.decodeIfPresent(CaptureConfig.self, forKey: .capture) ?? CaptureConfig()
        orca = try c.decodeIfPresent(OrcaConfig.self, forKey: .orca) ?? OrcaConfig()
        if let r = try c.decodeIfPresent(RuntimeConfig.self, forKey: .runtime) {
            runtime = r
        } else if let old = try? c.decodeIfPresent(RuntimeConfig.self, forKey: .orca) {
            runtime = old   // before Settings › Runtime, orca held agent and prompt
        }
        settings = try c.decodeIfPresent([String: ProjectLocalSettings].self, forKey: .settings) ?? [:]
    }

    func local(_ key: String) -> ProjectLocalSettings { settings[key.uppercased()] ?? ProjectLocalSettings() }

    mutating func setLocal(_ key: String, _ s: ProjectLocalSettings) { settings[key.uppercased()] = s }

    // The notification settings of a project. Nil when the project is muted.
    func notifications(for key: String) -> ProjectNotificationSettings? {
        let l = local(key)
        return l.muted ? nil : (l.notifications ?? notifications)
    }

    // The projects that do not use the app notification defaults, by key.
    var notificationOverrides: [NotificationOverride] {
        settings.keys.sorted().compactMap { key in
            let l = settings[key]!
            if l.muted { return NotificationOverride(key: key, kind: .muted) }
            guard let n = l.notifications else { return nil }
            return NotificationOverride(key: key, kind: .custom(changes: n.changes(from: notifications)))
        }
    }

    // The agent, the prompt and the resolved start command for an item. The project settings come first, then the app defaults.
    /// `agent` starts this one time with another agent. The default does not change.
    func launch(for item: Item, agent: String? = nil) -> (agent: String, prompt: String, command: String?) {
        let l = local(item.key.split(separator: "-").dropLast().joined(separator: "-"))
        var r = runtime
        if let a = l.agent, !a.isEmpty { r.agent = a }
        if let agent { r.agent = agent }
        if let p = l.prompt, !p.isEmpty { r.prompt = p }
        let command = try? r.command(for: r.agent).resolve(name: item.key, key: item.key, title: item.title)
        return (r.agent, SessionPrompt.withSubItemsRule(r.prompt(for: item)), command)
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
    var snap = SnapConfig()
    var session = SessionConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keyCode = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 45
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? 0x1800
        pasteClipboard = try c.decodeIfPresent(Bool.self, forKey: .pasteClipboard) ?? true
        aiTitle = try c.decodeIfPresent(Bool.self, forKey: .aiTitle) ?? true
        snap = try c.decodeIfPresent(SnapConfig.self, forKey: .snap) ?? SnapConfig()
        session = try c.decodeIfPresent(SessionConfig.self, forKey: .session) ?? SessionConfig()
    }
}

// The New panel (session, intake or item). The shortcut defaults to ⌃⌥⌘N.
struct SessionConfig: Codable, Equatable {
    var enabled = true
    var keyCode: UInt32 = 45            // N
    var modifiers: UInt32 = 0x1900      // control + option + command
    var intake = true                   // the last value of the check box
    var mode = NewSessionModel.Mode.session  // the last mode of the panel
    var lastProject: String?            // ProjectRef.storeKey
    var maxBytes = 10 * 1024 * 1024     // the total file size of the direct route

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keyCode = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 45
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? 0x1900
        intake = try c.decodeIfPresent(Bool.self, forKey: .intake) ?? true
        mode = (try? c.decodeIfPresent(NewSessionModel.Mode.self, forKey: .mode)) ?? .session
        lastProject = try c.decodeIfPresent(String.self, forKey: .lastProject)
        maxBytes = max(1024 * 1024, try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 10 * 1024 * 1024)
    }
}

// Snap Basket. The shortcuts default to ⌃⌥⌘S (snap) and ⌃⌥⌘B (basket panel).
struct SnapConfig: Codable, Equatable {
    enum SendMode: String, Codable, CaseIterable {
        case agent, plane, markdown

        var label: String {
            switch self {
            case .agent: return "Draft ticket with agent"
            case .plane: return "Create item in Plane"
            case .markdown: return "Copy as Markdown"
            }
        }
    }

    var enabled = true
    var keyCode: UInt32 = 1             // S
    var modifiers: UInt32 = 0x1900      // control + option + command
    var basketKeyCode: UInt32 = 11      // B
    var basketModifiers: UInt32 = 0x1900
    var voice = true
    var keepDays = 30
    var sendMode = SendMode.agent
    var lastProject: String?
    var panelOrigins: [String: CGPoint] = [:]   // the basket panel place, for each screen

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keyCode = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? 1
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? 0x1900
        basketKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .basketKeyCode) ?? 11
        basketModifiers = try c.decodeIfPresent(UInt32.self, forKey: .basketModifiers) ?? 0x1900
        voice = try c.decodeIfPresent(Bool.self, forKey: .voice) ?? true
        keepDays = max(1, try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? 30)
        sendMode = (try? c.decodeIfPresent(SendMode.self, forKey: .sendMode)) ?? .agent
        lastProject = try c.decodeIfPresent(String.self, forKey: .lastProject)
        panelOrigins = try c.decodeIfPresent([String: CGPoint].self, forKey: .panelOrigins) ?? [:]
    }
}

// The agent settings of each runtime. `commands` holds only the changed start commands:
// key "intake" for the intake agent, else an agent name.
struct RuntimeConfig: Codable, Equatable {
    static let defaultPrompt = "work on {url} in worktree group .wt/{key}"
    static let intakeKey = "intake"
    static let knownAgents = ["claude", "codex", "opencode"]

    var agent = "claude"
    var prompt = RuntimeConfig.defaultPrompt
    var commands: [String: String] = [:]
    var snapPrompt = SnapTicket.defaultPrompt   // the prompt of a sent snap basket
    var sessionIntakePrompt = SessionPrompt.intakeDefault
    var sessionFilesPrompt = SessionPrompt.filesDefault

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? RuntimeConfig.defaultPrompt
        commands = try c.decodeIfPresent([String: String].self, forKey: .commands) ?? [:]
        snapPrompt = try c.decodeIfPresent(String.self, forKey: .snapPrompt) ?? SnapTicket.defaultPrompt
        sessionIntakePrompt = SessionPrompt.migrate(intake: try c.decodeIfPresent(String.self, forKey: .sessionIntakePrompt) ?? SessionPrompt.intakeDefault)
        sessionFilesPrompt = try c.decodeIfPresent(String.self, forKey: .sessionFilesPrompt) ?? SessionPrompt.filesDefault
    }

    func command(for agent: String) -> LaunchCommand { saved(agent) ?? .defaultFor(AgentName(rawValue: agent)) }

    var intakeCommand: LaunchCommand { saved(Self.intakeKey) ?? .intakeDefault }

    func defaultCommand(_ key: String) -> LaunchCommand {
        key == Self.intakeKey ? .intakeDefault : .defaultFor(AgentName(rawValue: key))
    }

    // Saves a template. A template at its default removes the entry, except for an added agent: its entry is the agent.
    mutating func setCommand(_ key: String, _ template: String) {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = !Self.knownAgents.contains(key) && key != Self.intakeKey
        commands[key] = t == defaultCommand(key).template && !added ? nil : t
    }

    /// The agents of the Start and New menus: the CLIs of AgentBinder, then the added agents.
    var startAgents: [String] {
        var out = Harness.allBuiltIn.filter { ![.opencode2, .fake, .native].contains($0) }.map(\.rawValue)
        for a in agents where !out.contains(a) { out.append(a) }
        return out
    }

    // The known agents, then the added agents and the default agent.
    var agents: [String] {
        var out = Self.knownAgents
        for k in (Array(commands.keys) + [agent]).sorted() where k != Self.intakeKey && !out.contains(k) { out.append(k) }
        return out
    }

    // A hand-edited bad template falls back to the default.
    private func saved(_ key: String) -> LaunchCommand? {
        guard let t = commands[key] else { return nil }
        let c = LaunchCommand(t)
        do { try c.validate() } catch {
            log.error("runtime.commands.\(key, privacy: .public) is not valid (\(String(describing: error), privacy: .public)). OverSire uses the default.")
            return nil
        }
        return c
    }

    // {url}, {key} (lowercase), {KEY} and {title}.
    func prompt(for item: Item) -> String {
        (prompt.isEmpty ? RuntimeConfig.defaultPrompt : prompt)
            .replacingOccurrences(of: "{url}", with: item.url)
            .replacingOccurrences(of: "{KEY}", with: item.key)
            .replacingOccurrences(of: "{key}", with: item.key.lowercased())
            .replacingOccurrences(of: "{title}", with: item.title)
    }
}

// ▶ starts a Plane item in an Orca terminal. `roots` maps a project key ("slug/uuid")
// to the Orca workspace folder. The environment is per Mac: nil runs on this Mac.
struct OrcaConfig: Codable, Equatable {
    var roots: [String: String] = [:]
    /// The old "Run sessions on" Orca environment. The migration reads it; the config does not save it.
    private(set) var legacyEnvironment: String?

    private enum CodingKeys: String, CodingKey { case roots, environment }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([String: String].self, forKey: .roots) ?? [:]
        legacyEnvironment = try c.decodeIfPresent(String.self, forKey: .environment)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(roots, forKey: .roots)
    }

    // The Orca workspace whose name matches the project: "towertail-workspace" for TOWERTAIL.
    static func guess(_ p: ProjectSummary, _ repos: [RuntimeRepo]) -> String? {
        let names = [p.identifier, p.title].map { $0.lowercased() }.flatMap { [$0 + "-workspace", $0] }
        for n in names { if let r = repos.first(where: { $0.name.lowercased() == n }) { return r.path } }
        return nil
    }
}

enum AIEngineChoice: String, Codable { case apiKey, localCLI }

// What a job does when the local CLI fails. Each fallback goes to the log.
enum AIFallback: String, Codable { case apiKey, wait, skip }

// The API key is in the Keychain, not here.
struct AIConfig: Codable, Equatable {
    var engine = AIEngineChoice.apiKey
    // The local CLI engine (AgentBinder). Empty model or effort uses the default of the CLI.
    var cliHarness = ""
    var cliModel = ""
    var cliEffort = ""
    var cliLimitPause = 90              // jobs pause above this use of a plan window, in percent
    var fallback = AIFallback.apiKey
    var cliVerified = ""                // fingerprint of the last passed test of the CLI
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
    var itemSummary = true              // summarize the long descriptions of open items
    var ciExplain = true                // a short cause of a failed run that no agent watches
    var flaky = true                    // mark a run that failed, then passed on the same commit
    var digest = false                  // morning digest on Home
    var digestHour = 8
    var assistant = AssistantConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(AIEngineChoice.self, forKey: .engine) ?? .apiKey
        cliHarness = try c.decodeIfPresent(String.self, forKey: .cliHarness) ?? ""
        cliModel = try c.decodeIfPresent(String.self, forKey: .cliModel) ?? ""
        cliEffort = try c.decodeIfPresent(String.self, forKey: .cliEffort) ?? ""
        cliLimitPause = try c.decodeIfPresent(Int.self, forKey: .cliLimitPause) ?? 90
        fallback = try c.decodeIfPresent(AIFallback.self, forKey: .fallback) ?? .apiKey
        cliVerified = try c.decodeIfPresent(String.self, forKey: .cliVerified) ?? ""
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
        itemSummary = try c.decodeIfPresent(Bool.self, forKey: .itemSummary) ?? true
        ciExplain = try c.decodeIfPresent(Bool.self, forKey: .ciExplain) ?? true
        flaky = try c.decodeIfPresent(Bool.self, forKey: .flaky) ?? true
        digest = try c.decodeIfPresent(Bool.self, forKey: .digest) ?? false
        digestHour = try c.decodeIfPresent(Int.self, forKey: .digestHour) ?? 8
        assistant = try c.decodeIfPresent(AssistantConfig.self, forKey: .assistant) ?? AssistantConfig()
    }

    var apiKey: APIKeyConfig { APIKeyConfig(format: format, baseURL: baseURL, model: model, effort: effort, maxTokens: maxTokens) }

    var localCLI: LocalCLIConfig {
        LocalCLIConfig(harness: cliHarness, model: cliModel, effort: cliEffort, limitPause: Double(cliLimitPause))
    }

    func fingerprint(key: String) -> String { Self.hash("\(format.rawValue)|\(baseURL)|\(model)|\(key)") }

    var cliFingerprint: String { Self.hash("\(EngineID.localCLI)|\(cliHarness)") }

    private static func hash(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // True when Test passed for the current key settings.
    func keyVerified(_ key: String?) -> Bool {
        guard let key, !key.isEmpty, !verified.isEmpty else { return false }
        return verified == fingerprint(key: key)
    }

    var cliVerifiedNow: Bool { !cliHarness.isEmpty && cliVerified == cliFingerprint }

    // True when Test passed for the chosen engine.
    func engineVerified(key: String?) -> Bool { engine == .localCLI ? cliVerifiedNow : keyVerified(key) }

    func isOn(key: String?) -> Bool { enabled && engineVerified(key: key) }
}

// Settings › AI › Assistant. The chat panel uses the same engines as the AI jobs.
struct AssistantConfig: Codable, Equatable {
    enum Source: String, Codable, CaseIterable { case jobs, localCLI = "local-cli", apiKey = "api-key" }

    var source = Source.jobs
    /// outward always asks and settings never runs (decision D).
    var permissions = AssistantPermissions()
    /// A new chat moves the window to the pages that it talks about.
    var follow = true
    /// Opens the panel from any app. No modifiers: no shortcut.
    var hotkey = KeyShortcut(keyCode: 38, modifiers: 0)
    /// Chats with no change for this time go away. Pinned chats stay.
    var retention = ChatRetention.days30

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .jobs
        permissions = try c.decodeIfPresent(AssistantPermissions.self, forKey: .permissions) ?? AssistantPermissions()
        follow = try c.decodeIfPresent(Bool.self, forKey: .follow) ?? true
        hotkey = try c.decodeIfPresent(KeyShortcut.self, forKey: .hotkey) ?? KeyShortcut(keyCode: 38, modifiers: 0)
        retention = try c.decodeIfPresent(ChatRetention.self, forKey: .retention) ?? .days30
    }

    /// The engine that a new chat tries first.
    func engine(jobs: AIEngineChoice) -> EngineID {
        switch source {
        case .jobs: return jobs == .localCLI ? .localCLI : .apiKey
        case .localCLI: return .localCLI
        case .apiKey: return .apiKey
        }
    }
}

// Settings › Logs.
struct LogConfig: Codable, Equatable {
    var keepDays = 7
    var keepAIText = true               // the input and the output of AI jobs
    var debug = false                   // also each poll and each screen read
    var menuMark = true                 // a ▲ on the menu bar light while a problem is open

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? 7
        keepAIText = try c.decodeIfPresent(Bool.self, forKey: .keepAIText) ?? true
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        menuMark = try c.decodeIfPresent(Bool.self, forKey: .menuMark) ?? true
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
let STATUS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("session-status.json")
let SESSIONS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("sessions.json")
let CI_ASSIST_PATH = (CONFIG_DIR as NSString).appendingPathComponent("ci-assist.json")
let ITEM_SUMMARIES_PATH = (CONFIG_DIR as NSString).appendingPathComponent("summaries.json")
let WORK_STATS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("work-stats.json")
let LOGS_DIR = (CONFIG_DIR as NSString).appendingPathComponent("logs")
let PROBLEMS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("problems.json")
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
var LOGS_CFG = LogConfig()
var MACHINES = MachinesConfig()
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

/// `save: false` (`--uishots`): the migrations change only the memory, not the file.
func loadConfig(save: Bool = true) {
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
    if let l = c.logs { LOGS_CFG = l }
    if let m = c.machines { MACHINES = m }
    ACCOUNTS = AppEnvironment.accounts(from: c)
    let moved = LegacyMigration.moveOrca(&ACCOUNTS, machines: &MACHINES, environment: PROJECTS_CFG.orca.legacyEnvironment)
    AppEnvironment.applyLegacyFields(ACCOUNTS, to: &PROJECTS_CFG)
    ENV.load(ACCOUNTS)
    if moved {
        log.notice("Removed the Orca runtime account. The daemon runs Orca now. Sessions run on \(MACHINES.sessions ?? "this Mac", privacy: .public).")
        if save { saveConfig() }
    }
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
                      relay: RELAY, notifications: NOTIFICATIONS, tabs: TABS, projects: PROJECTS_CFG, ai: AI_CFG, general: GENERAL, linking: LINKING, agents: AGENTS, logs: LOGS_CFG)
    c.accounts = ACCOUNTS
    c.machines = MACHINES == MachinesConfig() ? nil : MACHINES
    if let data = try? JSONEncoder().encode(c) {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let pretty = try? JSONSerialization.data(withJSONObject: json as Any, options: .prettyPrinted) {
            try? pretty.write(to: URL(fileURLWithPath: CONFIG_PATH))
        }
    }
}

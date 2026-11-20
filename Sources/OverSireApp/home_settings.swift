import Foundation
import OverSireCore
import OverSireSync

// ─── Home settings ───────────────────────────────────────────────────────────
// The settings that live only in config.json and that a client shares with its home (OVERSIRE-529).
// The source app publishes them as the mirror doc settings/home. A client lays them over its own config.
// The body is opaque to the daemon and is not in the contract (epic decision 10).

enum SettingsSection: String, Codable, CaseIterable {
    case repos, ci, projects, linking, agents, aiJobs, sessions

    /// The words of the event row, for example "Agents settings changed from mba".
    var title: String {
        switch self {
        case .repos: return "Repos"
        case .ci: return "CI"
        case .projects: return "Projects"
        case .linking: return "Linking"
        case .agents: return "Agents"
        case .aiJobs: return "AI jobs"
        case .sessions: return "Sessions"
        }
    }
}

/// One connected service of the home, with no token and no secret.
struct AccountSummary: Codable, Equatable {
    /// The layer: tracker, codeHost or ci.
    var kind: String
    var provider: String
    var displayName: String
    /// The account ids, for example "ocral, big-time-data".
    var detail: String
    /// "ok", or the text of the error.
    var status: String
    /// The capabilities of the accounts, as raw values.
    var features: [String]
}

/// The switches of Settings › AI › Use AI for. The engine and the keys stay on each Mac.
struct AIJobs: Codable, Equatable {
    var agentChecks: Bool
    var queueOrder: Bool
    var intakeAgent: Bool
    var sessionSummary: Bool
    var itemSummary: Bool
    var ciExplain: Bool
    var flaky: Bool
    var digest: Bool
    var digestHour: Int
    var titleAndFields: Bool
    var tidy: Bool
    var pickProject: Bool

    init(_ c: AIConfig) {
        agentChecks = c.agentChecks
        queueOrder = c.queueOrder
        intakeAgent = c.intakeAgent
        sessionSummary = c.sessionSummary
        itemSummary = c.itemSummary
        ciExplain = c.ciExplain
        flaky = c.flaky
        digest = c.digest
        digestHour = c.digestHour
        titleAndFields = c.titleAndFields
        tidy = c.tidy
        pickProject = c.pickProject
    }

    func apply(to c: inout AIConfig) {
        c.agentChecks = agentChecks
        c.queueOrder = queueOrder
        c.intakeAgent = intakeAgent
        c.sessionSummary = sessionSummary
        c.itemSummary = itemSummary
        c.ciExplain = ciExplain
        c.flaky = flaky
        c.digest = digest
        c.digestHour = digestHour
        c.titleAndFields = titleAndFields
        c.tidy = tidy
        c.pickProject = pickProject
    }
}

/// The body of the mirror doc `settings/home`.
struct HomeSettings: Codable, Equatable {
    static let version = 1

    var v = HomeSettings.version
    var repos: [String]
    var orgs: [String]
    var runsPerRepo: Int
    var filterDefaultBranches: Bool
    var sortByRecent: Bool
    var oneRowPerWorkflow: Bool
    var latestAcrossBranches: Bool
    var repoColors: [String: Int]
    var projects: ProjectsShared
    var linking: LinkRules
    var agents: AgentsConfig
    var aiJobs: AIJobs
    /// `machines.sessions`: the machine that runs the sessions. nil: the home itself.
    var sessions: String?
    var accounts: [AccountSummary]
    /// The hash of each section, by raw value of SettingsSection.
    var hashes: [String: String]

    private struct RepoPicks: Codable {
        var repos: [String]
        var orgs: [String]
        var repoColors: [String: Int]
    }

    private struct CIFilters: Codable {
        var runsPerRepo: Int
        var filterDefaultBranches: Bool
        var sortByRecent: Bool
        var oneRowPerWorkflow: Bool
        var latestAcrossBranches: Bool
    }

    private struct SessionsPick: Codable {
        var sessions: String?
    }

    init(from c: AppConfig, accounts: [AccountSummary] = []) {
        repos = c.repos
        orgs = c.orgs ?? []
        runsPerRepo = c.runsPerRepo ?? 10
        filterDefaultBranches = c.filterDefaultBranches ?? false
        sortByRecent = c.sortByRecent ?? true
        oneRowPerWorkflow = c.oneRowPerWorkflow ?? true
        latestAcrossBranches = c.latestAcrossBranches ?? false
        repoColors = c.repoColors ?? [:]
        projects = (c.projects ?? ProjectsConfig()).shared
        linking = c.linking ?? LinkRules()
        agents = c.agents ?? AgentsConfig()
        aiJobs = AIJobs(c.ai ?? AIConfig())
        sessions = c.machines?.sessions
        self.accounts = accounts
        hashes = [:]
        rehash()
    }

    /// The body of one section. The same bytes give the hash of the section.
    func value(_ s: SettingsSection) -> JSONValue {
        let body: JSONValue?
        switch s {
        case .repos: body = try? MirrorCodec.body(RepoPicks(repos: repos, orgs: orgs, repoColors: repoColors))
        case .ci:
            body = try? MirrorCodec.body(CIFilters(runsPerRepo: runsPerRepo, filterDefaultBranches: filterDefaultBranches, sortByRecent: sortByRecent,
                                                   oneRowPerWorkflow: oneRowPerWorkflow, latestAcrossBranches: latestAcrossBranches))
        case .projects: body = try? MirrorCodec.body(projects)
        case .linking: body = try? MirrorCodec.body(linking)
        case .agents: body = try? MirrorCodec.body(agents)
        case .aiJobs: body = try? MirrorCodec.body(aiJobs)
        case .sessions: body = try? MirrorCodec.body(SessionsPick(sessions: sessions))
        }
        return body ?? .object([:])
    }

    /// Sets one section from a body, and its hash. Throws when the body does not decode.
    mutating func set(_ s: SettingsSection, from v: JSONValue) throws {
        switch s {
        case .repos:
            let r = try MirrorCodec.value(RepoPicks.self, from: v)
            repos = r.repos; orgs = r.orgs; repoColors = r.repoColors
        case .ci:
            let r = try MirrorCodec.value(CIFilters.self, from: v)
            runsPerRepo = r.runsPerRepo; filterDefaultBranches = r.filterDefaultBranches; sortByRecent = r.sortByRecent
            oneRowPerWorkflow = r.oneRowPerWorkflow; latestAcrossBranches = r.latestAcrossBranches
        case .projects: projects = try MirrorCodec.value(ProjectsShared.self, from: v)
        case .linking: linking = try MirrorCodec.value(LinkRules.self, from: v)
        case .agents: agents = try MirrorCodec.value(AgentsConfig.self, from: v)
        case .aiJobs: aiJobs = try MirrorCodec.value(AIJobs.self, from: v)
        case .sessions: sessions = try MirrorCodec.value(SessionsPick.self, from: v).sessions
        }
        hashes[s.rawValue] = Self.hash(value(s))
    }

    /// This value with one section of another value.
    func adopting(_ s: SettingsSection, from other: HomeSettings) -> HomeSettings {
        var h = self
        try? h.set(s, from: other.value(s))
        return h
    }

    private mutating func rehash() {
        hashes = Dictionary(uniqueKeysWithValues: SettingsSection.allCases.map { ($0.rawValue, Self.hash(value($0))) })
    }

    static func hash(_ body: JSONValue) -> String { MirrorHash.hex(MirrorCodec.bytes(body)) }

    /// The sections whose hash differs from `last`.
    func changed(since last: HomeSettings) -> [SettingsSection] {
        SettingsSection.allCases.filter { hashes[$0.rawValue] != last.hashes[$0.rawValue] }
    }

    /// The keys of the section body that differ from `old`, sorted.
    func keys(of s: SettingsSection, since old: HomeSettings) -> [String] {
        let a = value(s).object ?? [:], b = old.value(s).object ?? [:]
        return Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }
}

/// The settings of a config, for the source side. `accounts` come from the environment, not from the config.
func homeSettings(from c: AppConfig, accounts: [AccountSummary] = []) -> HomeSettings {
    HomeSettings(from: c, accounts: accounts)
}

/// The client side: lays the shared sections over a config. The local sections stay as they are.
func apply(_ h: HomeSettings, to c: inout AppConfig) {
    c.repos = h.repos
    c.orgs = h.orgs.isEmpty ? nil : h.orgs
    c.runsPerRepo = h.runsPerRepo
    c.filterDefaultBranches = h.filterDefaultBranches
    c.sortByRecent = h.sortByRecent
    c.oneRowPerWorkflow = h.oneRowPerWorkflow
    c.latestAcrossBranches = h.latestAcrossBranches
    c.repoColors = h.repoColors.isEmpty ? nil : h.repoColors
    var p = c.projects ?? ProjectsConfig()
    p.shared = h.projects
    c.projects = p
    c.linking = h.linking
    c.agents = h.agents
    var ai = c.ai ?? AIConfig()
    h.aiJobs.apply(to: &ai)
    c.ai = ai
    var m = c.machines ?? MachinesConfig()
    m.sessions = h.sessions
    c.machines = m == MachinesConfig() ? nil : m
}

extension AppConfig {
    /// The file of a client: the local sections of this config, and the other keys of `file` as they are.
    /// `self` is the config in memory. It holds the values of home for the shared sections, and the file does not.
    func clientMerge(file: AppConfig) -> AppConfig {
        var out = file
        out.general = general
        out.notifications = notifications
        out.tabs = tabs
        out.logs = logs
        out.relay = relay
        out.autoUpdate = autoUpdate
        out.email = email
        out.mode = mode
        if file.projects != nil || projects != nil {
            var p = file.projects ?? ProjectsConfig()
            let mine = projects ?? ProjectsConfig()
            p.defaultView = mine.defaultView
            p.menuDot = mine.menuDot
            p.showTab = mine.showTab
            p.notifications = mine.notifications
            p.order = mine.order
            p.folded = mine.folded
            p.workFolded = mine.workFolded
            out.projects = p
        }
        var m = file.machines ?? MachinesConfig()
        let mine = machines ?? MachinesConfig()
        m.enabled = mine.enabled
        m.muted = mine.muted
        m.hooksConsent = mine.hooksConsent
        out.machines = m == MachinesConfig() ? nil : m
        if ai != nil || file.ai != nil {
            var a = ai ?? AIConfig()
            AIJobs(file.ai ?? AIConfig()).apply(to: &a)
            out.ai = a
        }
        return out
    }
}

extension AccountSummary {
    /// One summary for each provider of the accounts: the service cards of Settings › Accounts and sync.
    static func list(_ env: AppEnvironment) -> [AccountSummary] {
        [Layer.tracker, .codeHost, .ci].flatMap { layer in
            env.registry.descriptors(layer).compactMap { d -> AccountSummary? in
                let list = env.accounts(layer).filter { $0.account.provider == d.id }
                guard !list.isEmpty else { return nil }
                let errors = list.compactMap { a in env.error(a.account).map { "\(a.account.id): \($0)" } }
                let caps = list.compactMap { env.provider($0.account)?.capabilities }.reduce(into: Set<Capability>()) { $0.formUnion($1) }
                return AccountSummary(kind: layer.rawValue, provider: d.id.rawValue, displayName: d.displayName,
                                      detail: list.map(\.account.id).joined(separator: ", "), status: errors.isEmpty ? "ok" : errors.joined(separator: " · "),
                                      features: caps.map(\.rawValue).sorted())
            }
        }
    }
}

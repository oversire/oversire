import Foundation
import OverSireCore

// One place in the window. The path is the deep link: oversire://<path>.
enum Route: Equatable {
    enum RunFilter: String, CaseIterable { case all, running, failed, linked, unlinked }
    // Lanes is the board of the queue lanes. It has no tab: the Up next group links to it.
    enum WorkTab: String, CaseIterable { case items, worktrees, lanes }
    enum ItemTab: String, CaseIterable { case overview, session, subitems, activity }
    enum SettingsPage: String, CaseIterable {
        case general, accounts, projects, agents, ai, notifications, logs

        var title: String {
            switch self {
            case .general: return "General"
            case .accounts: return "Accounts and sync"
            case .projects: return "Projects and repos"
            case .agents: return "Agents and queue"
            case .ai: return "AI"
            case .notifications: return "Notifications"
            case .logs: return "Logs"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .accounts: return "square.stack.3d.up"
            case .projects: return "folder"
            case .agents: return "terminal"
            case .ai: return "sparkles"
            case .notifications: return "bell"
            case .logs: return "list.bullet.rectangle"
            }
        }

        // The slugs of the old pages, mapped to their new home. "accounts" was once Projects. It now names its own page.
        static let redirects: [String: (SettingsPage, SettingsTab?, String?)] = [
            "providers": (.accounts, nil, nil), "live": (.accounts, nil, "live"),
            "repos": (.projects, .repos, nil),
            "linking": (.projects, .linking, nil), "writeback": (.projects, .linking, "writeback"),
            "runtime": (.agents, nil, nil), "orca": (.agents, nil, nil),
            "queue": (.agents, nil, "queue"), "planner": (.agents, nil, "planner"),
            "menubar": (.general, nil, "menubar"), "shortcuts": (.general, nil, "shortcuts"),
        ]
    }
    // The tabs of the Projects and repos page.
    enum SettingsTab: String, CaseIterable {
        case projects, repos, linking

        var title: String {
            switch self {
            case .projects: return "Projects"
            case .repos: return "Repos"
            case .linking: return "Linking and write-back"
            }
        }
    }

    case home
    case intake(String?)            // project identifier, nil for all
    case activity
    case work(WorkTab)
    case runs(RunFilter)
    case run(repo: String, id: String)
    case prs
    case insights
    case settings(SettingsPage, tab: SettingsTab? = nil, anchor: String? = nil)
    case project(String)            // project identifier, for example FRITZ
    case projectSettings(String, ProjectSettingsSection)
    case item(String, ItemTab)      // item key, for example FRITZ-17

    var path: String {
        switch self {
        case .home: return "home"
        case .intake(let p): return p.map { "intake/\($0)" } ?? "intake"
        case .activity: return "activity"
        case .work(let t): return t == .items ? "work" : "work/\(t.rawValue)"
        case .runs(let f): return f == .all ? "runs" : "runs/\(f.rawValue)"
        case .run(let repo, let id): return "run/\(repo)/\(id)"
        case .prs: return "prs"
        case .insights: return "insights"
        case .settings(let p, let t, let a):
            return (["settings", p.rawValue] + [t?.rawValue, a].compactMap { $0 }).joined(separator: "/")
        case .project(let k): return "project/\(k)"
        case .projectSettings(let k, let s): return "project/\(k)/settings/\(s.rawValue)"
        case .item(let k, let t): return t == .overview ? "item/\(k)" : "item/\(k)/\(t.rawValue)"
        }
    }

    var url: URL { URL(string: "oversire://" + path)! }

    // Accepts oversire://item/FRITZ-17, oversire:item/FRITZ-17 and oversire:///item/FRITZ-17.
    init?(url: URL) {
        // cateye is the scheme of the old app. Links to it stay in Plane.
        guard ["oversire", "cateye"].contains(url.scheme?.lowercased()) else { return nil }
        var parts: [String] = []
        if let host = url.host, !host.isEmpty { parts.append(host) }
        parts += url.path.split(separator: "/").map(String.init)
        if parts.isEmpty, let rest = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path {
            parts = rest.split(separator: "/").map(String.init)
        }
        // settings/agents#queue is the same as settings/agents/queue.
        if let f = url.fragment, !f.isEmpty { parts.append(f) }
        self.init(parts: parts.compactMap { $0.removingPercentEncoding })
    }

    init?(path: String) { self.init(parts: path.split(separator: "/").map(String.init)) }

    private init?(parts: [String]) {
        guard let head = parts.first?.lowercased() else { return nil }
        let rest = Array(parts.dropFirst())
        switch head {
        case "home": self = .home
        // The Inbox is now Intake, Activity and the Needs you list of Home.
        case "inbox": self = rest.first?.lowercased() == "intake" ? .intake(nil) : .home
        case "intake": self = .intake(rest.first?.uppercased())
        case "activity": self = .activity
        case "work": self = .work(rest.first.flatMap { WorkTab(rawValue: $0.lowercased()) } ?? .items)
        // Old links: My items, Sessions and the Queue (and its Plan page) are tabs of Work now.
        case "mine": self = .work(.items)
        case "sessions", "agents": self = .work(.worktrees)
        case "queue", "plan": self = .work(.lanes)
        case "runs": self = .runs(rest.first.flatMap { RunFilter(rawValue: $0.lowercased()) } ?? .all)
        case "run":
            guard rest.count == 3, Int(rest[2]) != nil else { return nil }
            self = .run(repo: rest[0] + "/" + rest[1], id: rest[2])
        case "prs": self = .prs
        case "insights": self = .insights
        case "settings": self = Route.settings(Array(rest.map { $0.lowercased() }))
        case "project":
            guard let k = rest.first, !k.isEmpty else { return nil }
            if rest.count > 1, rest[1].lowercased() == "settings" {
                self = .projectSettings(k.uppercased(), rest.count > 2 ? ProjectSettingsSection(rawValue: rest[2].lowercased()) ?? .appearance : .appearance)
            } else {
                self = .project(k.uppercased())
            }
        case "item":
            guard let k = rest.first, k.contains("-") else { return nil }
            self = .item(k.uppercased(), rest.count > 1 ? ItemTab(rawValue: rest[1].lowercased()) ?? .overview : .overview)
        default: return nil
        }
    }

    // settings/<page>[/<tab>][/<anchor>]. An old slug opens its new home. An unknown page opens General.
    private static func settings(_ rest: [String]) -> Route {
        guard let head = rest.first else { return .settings(.general) }
        var more = rest.dropFirst()
        if let (p, t, a) = SettingsPage.redirects[head] { return .settings(p, tab: t, anchor: more.first ?? a) }
        guard let p = SettingsPage(rawValue: head) else { return .settings(.general) }
        var tab: SettingsTab?
        if p == .projects, let t = more.first.flatMap(SettingsTab.init(rawValue:)) { tab = t; more = more.dropFirst() }
        return .settings(p, tab: tab, anchor: more.first)
    }

    // The sidebar entry that shows as selected for this route.
    var sidebarKey: String {
        switch self {
        case .intake: return "intake"
        case .work: return "work"
        case .runs(let f): return f == .failed ? "runs/failed" : f == .unlinked ? "runs/unlinked" : "runs"
        case .run: return "runs"
        case .settings: return "settings"
        case .item(let k, _): return "project/" + (k.split(separator: "-").first.map(String.init) ?? k)
        case .projectSettings(let k, _): return "project/" + k
        default: return path
        }
    }

    // Same page, other tab or filter: the window updates the page in place.
    func samePage(_ other: Route) -> Bool {
        switch (self, other) {
        case (.intake, .intake), (.runs, .runs), (.settings, .settings): return true
        case (.item(let a, _), .item(let b, _)): return a == b
        case (.run(let a, let x), .run(let b, let y)): return a == b && x == y
        case (.project(let a), .project(let b)): return a == b
        case (.projectSettings(let a, _), .projectSettings(let b, _)): return a == b
        default: return self == other
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .intake: return "Intake"
        case .activity: return "Activity"
        case .work: return "Work"
        case .runs: return "Runs"
        case .run(_, let id): return "Run \(id)"
        case .prs: return "Pull requests"
        case .insights: return "Insights"
        case .settings(let p, _, _): return p.title
        case .project(let k): return k
        case .projectSettings: return "Project settings"
        case .item(let k, _): return k
        }
    }

    /// The places above this one, for the title bar.
    var crumbs: [String] {
        switch self {
        case .run(let repo, _): return ["Runs", repo]
        case .settings: return ["Settings"]
        case .project: return ["Projects"]
        case .projectSettings(let k, _): return ["Projects", k]
        case .item(let k, _):
            guard let dash = k.lastIndex(of: "-") else { return ["Projects"] }
            return ["Projects", String(k[..<dash])]
        default: return []
        }
    }

    // Every route kind once, for the selftest and the palette.
    static let samples: [Route] = [
        .home, .intake(nil), .intake("SLING"), .activity, .work(.items), .work(.worktrees), .work(.lanes), .runs(.all), .runs(.unlinked),
        .run(repo: "oversire/oversire", id: "123"), .prs, .insights, .settings(.ai), .settings(.general), .settings(.accounts), .settings(.agents),
        .settings(.projects, tab: .repos), .settings(.agents, anchor: "queue"),
        .project("FRITZ"), .projectSettings("FRITZ", .appearance), .item("FRITZ-17", .overview), .item("FRITZ-17", .session),
    ]
}

// Back and forward history of the window, like a browser.
final class Router {
    private(set) var current: Route = .home
    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    var onChange: ((Route) -> Void)?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func go(_ r: Route) {
        guard r != current else { onChange?(r); return }
        // A tab change on the same page replaces the entry, so Back leaves the page.
        if r.samePage(current) { current = r; onChange?(r); return }
        backStack.append(current)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack = []
        current = r
        onChange?(r)
    }

    func back() {
        guard let r = backStack.popLast() else { return }
        forwardStack.append(current)
        current = r
        onChange?(r)
    }

    func forward() {
        guard let r = forwardStack.popLast() else { return }
        backStack.append(current)
        current = r
        onChange?(r)
    }
}

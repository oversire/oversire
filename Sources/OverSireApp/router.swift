import Foundation

// One place in the window. The path is the deep link: oversire://<path>.
enum Route: Equatable {
    enum InboxTab: String, CaseIterable { case all, mentions, runs, agents, intake }
    enum RunFilter: String, CaseIterable { case all, running, failed, linked, unlinked }
    enum ItemTab: String, CaseIterable { case overview, session, subitems, activity }
    enum SettingsPage: String, CaseIterable {
        case general, accounts, repos, linking, writeback, live, orca, queue, ai, notifications, menubar, shortcuts

        var title: String {
            switch self {
            case .general: return "General"
            case .accounts: return "Accounts"
            case .repos: return "Repos"
            case .linking: return "Linking"
            case .writeback: return "Write back to Plane"
            case .live: return "Cloud (beta)"
            case .orca: return "Orca"
            case .queue: return "Sessions and queue"
            case .ai: return "AI"
            case .notifications: return "Notifications"
            case .menubar: return "Menu bar"
            case .shortcuts: return "Shortcuts"
            }
        }
    }

    case home
    case inbox(InboxTab)
    case mine
    case agents
    case queue
    case runs(RunFilter)
    case run(repo: String, id: Int)
    case prs
    case insights
    case settings(SettingsPage)
    case project(String)            // project identifier, for example FRITZ
    case item(String, ItemTab)      // item key, for example FRITZ-17

    var path: String {
        switch self {
        case .home: return "home"
        case .inbox(let t): return t == .all ? "inbox" : "inbox/\(t.rawValue)"
        case .mine: return "mine"
        case .agents: return "sessions"
        case .queue: return "queue"
        case .runs(let f): return f == .all ? "runs" : "runs/\(f.rawValue)"
        case .run(let repo, let id): return "run/\(repo)/\(id)"
        case .prs: return "prs"
        case .insights: return "insights"
        case .settings(let p): return "settings/\(p.rawValue)"
        case .project(let k): return "project/\(k)"
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
        self.init(parts: parts.compactMap { $0.removingPercentEncoding })
    }

    init?(path: String) { self.init(parts: path.split(separator: "/").map(String.init)) }

    private init?(parts: [String]) {
        guard let head = parts.first?.lowercased() else { return nil }
        let rest = Array(parts.dropFirst())
        switch head {
        case "home": self = .home
        case "inbox": self = .inbox(rest.first.flatMap { InboxTab(rawValue: $0.lowercased()) } ?? .all)
        case "mine": self = .mine
        case "sessions", "agents": self = .agents
        case "queue": self = .queue
        case "runs": self = .runs(rest.first.flatMap { RunFilter(rawValue: $0.lowercased()) } ?? .all)
        case "run":
            guard rest.count == 3, let id = Int(rest[2]) else { return nil }
            self = .run(repo: rest[0] + "/" + rest[1], id: id)
        case "prs": self = .prs
        case "insights": self = .insights
        case "settings": self = .settings(rest.first.flatMap { SettingsPage(rawValue: $0.lowercased()) } ?? .general)
        case "project":
            guard let k = rest.first, !k.isEmpty else { return nil }
            self = .project(k.uppercased())
        case "item":
            guard let k = rest.first, k.contains("-") else { return nil }
            self = .item(k.uppercased(), rest.count > 1 ? ItemTab(rawValue: rest[1].lowercased()) ?? .overview : .overview)
        default: return nil
        }
    }

    // The sidebar entry that shows as selected for this route.
    var sidebarKey: String {
        switch self {
        case .inbox: return "inbox"
        case .runs(let f): return f == .failed ? "runs/failed" : f == .unlinked ? "runs/unlinked" : "runs"
        case .run: return "runs"
        case .settings: return "settings"
        case .item(let k, _): return "project/" + (k.split(separator: "-").first.map(String.init) ?? k)
        default: return path
        }
    }

    // Same page, other tab or filter: the window updates the page in place.
    func samePage(_ other: Route) -> Bool {
        switch (self, other) {
        case (.inbox, .inbox), (.runs, .runs), (.settings, .settings): return true
        case (.item(let a, _), .item(let b, _)): return a == b
        case (.run(let a, let x), .run(let b, let y)): return a == b && x == y
        case (.project(let a), .project(let b)): return a == b
        default: return self == other
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .inbox: return "Inbox"
        case .mine: return "My items"
        case .agents: return "Sessions"
        case .queue: return "Queue"
        case .runs: return "Runs"
        case .run(let repo, let id): return "Run \(id) · \(repo)"
        case .prs: return "Pull requests"
        case .insights: return "Insights"
        case .settings: return "Settings"
        case .project(let k): return k
        case .item(let k, _): return k
        }
    }

    // Every route kind once, for the selftest and the palette.
    static let samples: [Route] = [
        .home, .inbox(.all), .inbox(.intake), .mine, .agents, .queue, .runs(.all), .runs(.unlinked),
        .run(repo: "oversire/oversire", id: 123), .prs, .insights, .settings(.ai), .settings(.general),
        .project("FRITZ"), .item("FRITZ-17", .overview), .item("FRITZ-17", .session),
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

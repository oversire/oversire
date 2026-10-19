import Cocoa

// The sections of the settings pages. A route anchor and the search scroll to them.
enum SettingsAnchor: String, CaseIterable {
    case appearance, menubar, runs, capture, startup, shortcuts
    case services, live
    case projects, refresh, repos, linking, writeback
    case sessions, queue, planner
    case engine, use, cloudAI = "cloud-ai"
    case ci, tracker, mentions, overrides

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .menubar: return "Menu bar popover"
        case .runs: return "Runs and items"
        case .capture: return "Quick capture and snap"
        case .startup: return "Startup and updates"
        case .shortcuts: return "Keyboard shortcuts"
        case .services: return "Services"
        case .live: return "Live updates"
        case .projects: return "Projects"
        case .refresh: return "Refresh"
        case .repos: return "Repos"
        case .linking: return "Link an item to code when"
        case .writeback: return "Write back to Plane"
        case .sessions: return "New sessions"
        case .queue: return "Queue"
        case .planner: return "Intake and planner"
        case .engine: return "Engine"
        case .use: return "Use AI for"
        case .cloudAI: return "Cloud AI"
        case .ci: return "CI runs"
        case .tracker: return "Tracker items"
        case .mentions: return "Agents and mentions"
        case .overrides: return "Project overrides"
        }
    }

    var page: Route.SettingsPage {
        switch self {
        case .appearance, .menubar, .runs, .capture, .startup, .shortcuts: return .general
        case .services, .live: return .accounts
        case .projects, .refresh, .repos, .linking, .writeback: return .projects
        case .sessions, .queue, .planner: return .agents
        case .engine, .use, .cloudAI: return .ai
        case .ci, .tracker, .mentions, .overrides: return .notifications
        }
    }

    var tab: Route.SettingsTab? {
        switch self {
        case .projects, .refresh: return .projects
        case .repos: return .repos
        case .linking, .writeback: return .linking
        default: return nil
        }
    }

    var route: Route { .settings(page, tab: tab, anchor: rawValue) }
    var id: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("anchor-" + rawValue) }
    // "Page › Tab › Section", without the section when it has the tab name.
    var path: String { ([page.title, tab?.title].compactMap { $0 } + (tab?.title == title ? [] : [title])).joined(separator: " › ") }
}

// One row on the settings pages, for the search.
struct SettingsIndex {
    struct Entry: Equatable {
        let title: String
        let anchor: SettingsAnchor
        let keywords: [String]
        init(_ title: String, _ anchor: SettingsAnchor, _ keywords: String = "") {
            self.title = title
            self.anchor = anchor
            self.keywords = keywords.split(separator: " ").map(String.init)
        }
    }

    // A section entry for each anchor, then the rows. Add an entry when you add a row.
    static let entries: [Entry] = SettingsAnchor.allCases.map { Entry($0.title, $0) } + [
        Entry("Theme", .appearance, "dark light system color"),
        Entry("Show OverSire in", .appearance, "dock menu bar icon"),
        Entry("Small popover", .menubar, "compact size"),
        Entry("Tabs", .menubar, "runs pull requests projects insights"),
        Entry("Blue dot on the menu bar icon", .menubar, "badge unread"),
        Entry("One row per workflow", .runs, "actions group"),
        Entry("Project view", .runs, "board activity"),
        Entry("Items per project", .runs, "limit count"),
        Entry("Hide Done items", .runs, "closed completed"),
        Entry("List sub-items as rows", .runs, "children"),
        Entry("New item from any app", .capture, "quick capture hotkey"),
        Entry("New item shortcut", .capture, "hotkey key"),
        Entry("Put the clipboard text in the description", .capture, "paste"),
        Entry("Write the title with AI at once", .capture, "ai"),
        Entry("Snap shortcuts", .capture, "screenshot hotkey"),
        Entry("Take a snap", .capture, "screenshot"),
        Entry("Show the basket", .capture, "screenshot"),
        Entry("Speak notes", .capture, "voice dictation"),
        Entry("Send the basket with", .capture, "screenshot agent"),
        Entry("Keep history", .capture, "screenshot days"),
        Entry("Open the window at launch", .startup, "login start"),
        Entry("Install updates automatically", .startup, "update release version"),
        Entry("Open the window", .shortcuts, "hotkey global"),
        Entry("New item (quick capture)", .shortcuts, "hotkey"),
        Entry("Add a service", .services, "account tracker plane github orca token login"),
        Entry("GitHub login", .services, "gh auth"),
        Entry("Cloud URL", .live, "server worker"),
        Entry("Pairing code", .live, "connect device"),
        Entry("Poll every", .live, "polling interval refresh"),
        Entry("Poll a run in progress every", .live, "polling interval"),
        Entry("Plane webhooks", .live, "webhook hooks"),
        Entry("GitHub webhooks", .repos, "webhook hooks fix problems"),
        Entry("Keep events for", .live, "log retention"),
        Entry("Reconcile poll while live", .live, "polling webhook"),
        Entry("Track a project", .projects, "workspace add pick"),
        Entry("Check trackers every", .refresh, "poll polling interval"),
        Entry("Track a repo", .repos, "add owner org filter"),
        Entry("Test a name", .linking, "branch worktree folder"),
        Entry("Branch starts with the key", .linking, "prefix"),
        Entry("PR names the key", .linking, "pull request"),
        Entry("Commit title names the key", .linking, "trailer"),
        Entry("Write back", .writeback, "plane read only labels links block comment review"),
        Entry("Default agent", .sessions, "claude codex harness"),
        Entry("Prompt", .sessions, "template"),
        Entry("Agent commands", .sessions, "command line start"),
        Entry("Auto start", .queue, "next item"),
        Entry("AI checks on quiet sessions", .queue, "done stuck"),
        Entry("Quiet after", .queue, "idle minutes"),
        Entry("Add to the queue by", .queue, "label bot"),
        Entry("Intake agent in a scratch worktree", .planner, "triage intake prompt"),
        Entry("Planner", .planner, "order mode project"),
        Entry("Feature areas", .planner, "areas code"),
        Entry("Format", .engine, "openai anthropic"),
        Entry("Endpoint", .engine, "url base"),
        Entry("Model", .engine, "gpt claude"),
        Entry("API key", .engine, "token secret keychain"),
        Entry("Reasoning effort", .engine, "openai"),
        Entry("Max tokens", .engine, "anthropic"),
        Entry("Test", .engine, "verify"),
        Entry("Use AI", .engine, "off on"),
        Entry("Extra context", .engine, "prompt"),
        Entry("Done and stuck checks", .use, "sessions quiet"),
        Entry("Queue order", .use, "lanes"),
        Entry("Intake agent", .use, "triage"),
        Entry("Session summary", .use, "summarize"),
        Entry("Explain failures", .use, "ci cause"),
        Entry("Flaky workflows", .use, "rerun re-run"),
        Entry("Morning digest", .use, "daily summary"),
        Entry("Digest time", .use, "hour"),
        Entry("Title and fields", .use, "new item size priority"),
        Entry("Tidy the text", .use, "rewrite description"),
        Entry("Pick the project", .use, "new item"),
        Entry("Credits", .cloudAI, "usage cloud"),
        Entry("Started", .ci, "run alert"),
        Entry("Passed", .ci, "run success alert"),
        Entry("Failed", .ci, "run failure alert flaky"),
        Entry("Cancelled", .ci, "run alert"),
        Entry("Other endings", .ci, "run alert"),
        Entry("New comment", .tracker, "alert"),
        Entry("Status changes", .tracker, "alert state"),
        Entry("Item is added", .tracker, "alert new"),
        Entry("Item is closed or Done", .tracker, "alert"),
        Entry("Other fields change", .tracker, "alert"),
        Entry("Someone mentions me", .mentions, "alert mention"),
        Entry("Assigned to me", .mentions, "alert assignee"),
        Entry("New intake item", .mentions, "alert"),
        Entry("Session needs input", .mentions, "alert waiting agent"),
        Entry("Session is done", .mentions, "alert agent"),
        Entry("Mute a project", .overrides, "unmute muted silence"),
    ]

    static let limit = 12

    // Title prefix first, then a word prefix, then any match. Case and accents do not count.
    static func search(_ query: String, in entries: [Entry] = entries) -> [Entry] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        let ranked: [(Int, Int, Entry)] = entries.enumerated().compactMap { i, e in
            let title = fold(e.title)
            let words = (title + " " + fold(e.anchor.title)).split(separator: " ") + e.keywords.map { Substring(fold($0)) }
            let rank: Int
            if title.hasPrefix(q) { rank = 0 }
            else if words.contains(where: { $0.hasPrefix(q) }) { rank = 1 }
            else if title.contains(q) || words.contains(where: { $0.contains(q) }) { rank = 2 }
            else { return nil }
            return (rank, i, e)
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }
}

// The search field at the top of the settings list. Arrow keys move, Return opens, Esc clears.
final class SettingsSearchField: NSSearchField, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onMove: ((Int) -> Void)?
    var onOpen: (() -> Void)?

    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        placeholderString = "Search settings  ⌘F"
        setAccessibilityLabel("Search settings")
        sendsSearchStringImmediately = true
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ n: Notification) { onChange?(stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(moveDown(_:)): onMove?(1)
        case #selector(moveUp(_:)): onMove?(-1)
        case #selector(insertNewline(_:)): onOpen?()
        case #selector(cancelOperation(_:)):
            stringValue = ""
            onChange?("")
        default: return false
        }
        return true
    }
}

extension Box {
    // An accent fill that fades in one second. It shows the row that a search opened.
    func flash() {
        let o = Box(fill: Palette.acc.withAlphaComponent(0.28), border: nil, radius: 6)
        o.translatesAutoresizingMaskIntoConstraints = false
        addSubview(o, positioned: .below, relativeTo: subviews.first)
        NSLayoutConstraint.activate([o.leadingAnchor.constraint(equalTo: leadingAnchor), o.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     o.topAnchor.constraint(equalTo: topAnchor), o.bottomAnchor.constraint(equalTo: bottomAnchor)])
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 1
            o.animator().alphaValue = 0
        }, completionHandler: { o.removeFromSuperview() })
    }
}

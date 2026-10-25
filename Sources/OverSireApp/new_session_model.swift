import Foundation
import OverSireCore
import UniformTypeIdentifiers

// ─── New panel state ─────────────────────────────────────────────────────────
// All state and rules of the panel, with no AppKit. It makes a session, an intake item or a work item.

struct NewSessionModel: Equatable {
    struct Choice: Equatable {
        var key: String
        var name: String
        var store: String       // ProjectRef.storeKey
        var root: String?       // the Orca workspace folder
        var states: [StatusOption] = []
        var agent: String? = nil    // the agent of the project; nil: the default agent
    }

    enum Mode: String, Codable, CaseIterable {
        case session, intake, item

        var label: String {
            switch self {
            case .session: return "Session"
            case .intake: return "Intake"
            case .item: return "Item"
            }
        }

        var symbol: String {
            switch self {
            case .session: return "apple.terminal"
            case .intake: return "tray"
            case .item: return "checkmark.square"
            }
        }
    }

    struct Attachment: Equatable {
        var id = UUID()
        var name: String
        var bytes: Int
        var isImage: Bool
        var data: Data

        init(name: String, data: Data, isImage: Bool? = nil) {
            self.name = name
            self.data = data
            bytes = data.count
            self.isImage = isImage ?? (UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false)
        }

        var mimeType: String {
            UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    enum Phase: Equatable { case edit, listening, starting(String), failed(String) }

    var choices: [Choice]
    var selected: String
    var lastUsed: String?
    var query = ""
    var listOpen = false
    var highlight = 0
    var mode: Mode
    var titleText = ""
    var text = ""
    var files: [Attachment] = []
    var intake: Bool
    var state: String?          // a status option id; nil: the todo state of the project
    var priority = "none"
    var phase = Phase.edit
    var maxBytes: Int
    var defaultAgent: String
    var picked: String?         // an agent for this start only
    var intakeOff: Set<String> = []   // store keys of projects with the intake off

    init(choices: [Choice], cfg: SessionConfig, agent: String) {
        self.choices = choices
        lastUsed = cfg.lastProject
        selected = choices.first { $0.store == cfg.lastProject }?.store ?? choices.first?.store ?? ""
        intake = cfg.intake
        mode = cfg.mode
        maxBytes = cfg.maxBytes
        defaultAgent = agent
    }

    /// The agent of the project, else the default agent. The chip menu marks it "default".
    var standard: String { selection?.agent ?? defaultAgent }

    /// The agent that Start uses: the pick, else the standard agent.
    var agent: String { picked ?? standard }

    /// The pick applies to this start only. A pick of the standard agent follows the project again.
    mutating func pickAgent(_ a: String) { picked = a == standard ? nil : a }

    /// Key prefix first, then name prefix, then the rest that holds the query in the key, name or folder name.
    var matches: [Choice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return choices }
        func rank(_ c: Choice) -> Int? {
            let key = c.key.lowercased(), name = c.name.lowercased(), root = ((c.root ?? "") as NSString).lastPathComponent.lowercased()
            if key.hasPrefix(q) { return 0 }
            if name.hasPrefix(q) { return 1 }
            if key.contains(q) || name.contains(q) || root.contains(q) { return 2 }
            return nil
        }
        return choices.compactMap { c in rank(c).map { (c, $0) } }.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    var selection: Choice? { choices.first { $0.store == selected } }

    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    var isStarting: Bool { if case .starting = phase { return true }; return false }

    var makesItem: Bool { mode != .session }

    /// Set in Intake mode when the project has its intake off.
    var intakeOffNote: String? {
        guard mode == .intake, let s = selection, intakeOff.contains(s.store) else { return nil }
        return "Intake is off for \(s.key) in Plane."
    }

    /// Why Start or Create is off, for the hint and VoiceOver. Nil: the button is on.
    var blocker: String? {
        guard let s = selection else { return "Track a project first." }
        if isStarting { return nil }
        if let n = intakeOffNote { return n }
        if makesItem {
            return itemTitle.isEmpty ? "Type a title or a description." : nil
        }
        if (s.root ?? "").isEmpty { return "Choose an Orca workspace folder for \(s.key)." }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty { return "Type a prompt or attach a file." }
        if !intake && totalBytes > maxBytes { return "Files are over \(maxBytes / (1024 * 1024)) MB. Turn on intake to send them." }
        return nil
    }

    /// The typed title, else the first line of the text. Empty when both are empty.
    var itemTitle: String {
        let t = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : title
    }

    /// The state that the Item mode sends: the picked one, else the first unstarted state, else the first todo state.
    var itemState: String? {
        let states = selection?.states ?? []
        return state ?? (states.first { $0.group == "unstarted" } ?? states.first { $0.category == .todo })?.id
    }

    var button: String {
        switch mode {
        case .session: return "Start session"
        case .intake: return "Create intake"
        case .item: return "Create item"
        }
    }

    var canStart: Bool { !isStarting && blocker == nil }

    var intakeHint: String {
        let key = selection?.key ?? "the project"
        switch mode {
        case .intake: return "The item goes to the \(key) intake for triage." + (files.isEmpty ? "" : " The files go on the item.") + " No session starts."
        case .item: return "Makes a work item in \(key), past triage." + (files.isEmpty ? "" : " The files go on the item.") + " No session starts."
        case .session: break
        }
        switch (intake, files.isEmpty) {
        case (true, false): return "The prompt is the description. The files go on the item."
        case (true, true): return "Tracks this work. The prompt is the description."
        case (false, false): return "No item. The files go to the sessions machine and the prompt gets their paths."
        case (false, true): return "No item. Good for a question or a quick chat."
        }
    }

    /// Only a session starts an agent. The intake check box does not change it.
    var picksAgent: Bool { mode == .session }

    /// The name of the next pasted image.
    var pasteName: String {
        var n = 1
        while files.contains(where: { $0.name == "pasted-\(n).png" }) { n += 1 }
        return "pasted-\(n).png"
    }

    var title: String { Self.title(text) }

    var termName: String { Self.termName(agent: agent, text: text) }

    /// The first line of the text, max 80 characters.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return "New session" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// "<agent>-<first 3 words>", in lowercase with dashes.
    static func termName(agent: String, text: String) -> String {
        let words = text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(3)
        return agent + "-" + (words.isEmpty ? "session" : words.joined(separator: "-"))
    }

    mutating func type(_ q: String) {
        query = q
        listOpen = true
        highlight = 0
    }

    mutating func move(_ d: Int) {
        listOpen = true
        highlight = max(0, min(matches.count - 1, highlight + d))
    }

    mutating func pick(_ store: String) {
        if choices.contains(where: { $0.store == store }) { selected = store }
        listOpen = false
        query = ""
        highlight = 0
    }

    /// Drops a file with the same name and size as one in the list.
    mutating func add(_ a: [Attachment]) {
        for f in a where !files.contains(where: { $0.name == f.name && $0.bytes == f.bytes }) { files.append(f) }
    }

    mutating func remove(_ id: UUID) { files.removeAll { $0.id == id } }
}

// The size and the place of the New panel. They stay after a restart.
struct NewPanelFrame: Equatable {
    static let widths: ClosedRange<Double> = 420...1000, prompts: ClosedRange<Double> = 100...520
    private static let key = "newPanel.frame"

    var width = 500.0
    var prompt = 146.0
    var topLeft: [Double]?      // x, y on the screen; nil: the default place

    /// Clamps to the limits.
    func resized(width w: Double, prompt p: Double) -> NewPanelFrame {
        var f = self
        f.width = min(max(w, Self.widths.lowerBound), Self.widths.upperBound)
        f.prompt = min(max(p, Self.prompts.lowerBound), Self.prompts.upperBound)
        return f
    }

    static func load(_ d: UserDefaults = .standard) -> NewPanelFrame {
        let v = d.array(forKey: key) as? [Double] ?? []
        guard v.count >= 2 else { return NewPanelFrame() }
        return NewPanelFrame(topLeft: v.count >= 4 ? [v[2], v[3]] : nil).resized(width: v[0], prompt: v[1])
    }

    func save(_ d: UserDefaults = .standard) {
        d.set([width, prompt] + (topLeft ?? []), forKey: Self.key)
    }
}

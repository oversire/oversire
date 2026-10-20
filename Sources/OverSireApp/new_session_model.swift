import Foundation
import UniformTypeIdentifiers

// ─── New session panel state ─────────────────────────────────────────────────
// All state and rules of the panel, with no AppKit.

struct NewSessionModel: Equatable {
    struct Choice: Equatable {
        var key: String
        var name: String
        var store: String       // ProjectRef.storeKey
        var root: String?       // the Orca workspace folder
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
    var text = ""
    var files: [Attachment] = []
    var intake: Bool
    var phase = Phase.edit
    var maxBytes: Int
    var agent: String

    init(choices: [Choice], cfg: SessionConfig, agent: String) {
        self.choices = choices
        lastUsed = cfg.lastProject
        selected = choices.first { $0.store == cfg.lastProject }?.store ?? choices.first?.store ?? ""
        intake = cfg.intake
        maxBytes = cfg.maxBytes
        self.agent = agent
    }

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

    /// Why Start is off, for the hint and VoiceOver. Nil: Start is on.
    var blocker: String? {
        guard let s = selection else { return "Track a project first." }
        if isStarting { return nil }
        if (s.root ?? "").isEmpty { return "Choose an Orca workspace folder for \(s.key)." }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty { return "Type a prompt or attach a file." }
        if !intake && totalBytes > maxBytes { return "Files are over \(maxBytes / (1024 * 1024)) MB. Turn on intake to send them." }
        return nil
    }

    var canStart: Bool { !isStarting && blocker == nil }

    var intakeHint: String {
        switch (intake, files.isEmpty) {
        case (true, false): return "The prompt is the description. The files go on the item."
        case (true, true): return "Tracks this work. The prompt is the description."
        case (false, false): return "No item. The files go to the Orca host and the prompt gets their paths."
        case (false, true): return "No item. Good for a question or a quick chat."
        }
    }

    var footerNote: String { intake ? "The agent gets the prompt and the item key." : "The prompt goes to the agent as typed." }

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

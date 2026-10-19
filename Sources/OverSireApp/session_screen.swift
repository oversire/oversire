import Foundation
import OverSireCore

// What the screen of an agent TUI shows. The rules know Claude Code. Other harnesses
// get only the generic rules: no empty lines, no border lines.
struct HarnessScreen {
    let lines: [String]
    let harness: AgentName

    init(_ lines: [String], harness: AgentName = .claude) {
        self.lines = lines.map { $0.replacingOccurrences(of: "\u{a0}", with: " ") }
        self.harness = harness
    }

    private var claude: Bool { harness == .claude }

    // MARK: Regions

    static func border(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("──") else { return false }
        return t.allSatisfy { $0 == "─" } || t.hasSuffix("─")
    }

    // The index of the top border of the input box at the bottom, if the screen shows one.
    private var boxTop: Int? {
        guard claude else { return nil }
        let borders = lines.indices.filter { HarnessScreen.border(lines[$0]) && $0 >= lines.count - 12 }
        return borders.count >= 2 ? borders[borders.count - 2] : nil
    }

    /// The conversation, without the input box, the status line and the mode footer.
    var body: [String] { boxTop.map { Array(lines[..<$0]) } ?? lines }

    /// The input box, the status line and the mode footer.
    var footer: [String] { boxTop.map { Array(lines[$0...]) } ?? [] }

    // MARK: Line kinds

    static let spinnerRE = try! NSRegularExpression(pattern: #"^[✶✻✽✢·*✳] \S+… ?(\(.*\))?$"#)
    static let turnEndRE = try! NSRegularExpression(pattern: #"^[✶✻✽✢·*✳] \S+ for (\d+h )?(\d+m )?\d+s"#)
    static let shellsRE = try! NSRegularExpression(pattern: #"\b(\d+) shells?\b"#)
    static let counterRE = try! NSRegularExpression(pattern: #"\d+(\.\d+)?[kKmM]?"#)

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func spinner(_ l: String) -> Bool { claude && HarnessScreen.matches(HarnessScreen.spinnerRE, l.trimmingCharacters(in: .whitespaces)) }
    func turnEnd(_ l: String) -> Bool { claude && HarnessScreen.matches(HarnessScreen.turnEndRE, l.trimmingCharacters(in: .whitespaces)) }

    /// A line that the harness draws, not the agent.
    func ui(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || HarnessScreen.border(l) { return true }
        guard claude else { return false }
        if t == "❯" || spinner(l) || turnEnd(l) { return true }
        return t.hasPrefix("new task? /clear") || t.hasPrefix("⎿  Tip:") || t.hasPrefix("⎿ Tip:")
            || t.hasPrefix("Jump to bottom") || t == "? for shortcuts" || t.hasPrefix("⏵⏵")
    }

    // MARK: Facts

    /// The text of the agent since the last user prompt, without the harness UI. The end is kept.
    func lastTurn(limit: Int = 6000) -> String {
        var b = body
        if claude, let i = b.lastIndex(where: { $0.hasPrefix("❯ ") && $0.count > 2 }) { b = Array(b[(i + 1)...]) }
        let text = b.filter { !ui($0) }
            .map { $0.replacingOccurrences(of: " (disable recaps in /config)", with: "").replacingOccurrences(of: "(disable recaps in /config)", with: "") }
            .joined(separator: "\n")
        return text.count > limit ? String(text.suffix(limit)) : text
    }

    /// A hash of the conversation without the UI, the spinner and the tips. Same screen, same hash.
    var fingerprint: String {
        let text = body.filter { !ui($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        return String(text.fnv1a, radix: 16)
    }

    /// The counters of the spinner line ("5m 56s · ↓ 15.6k tokens"), if the agent works.
    var counter: String? {
        guard let l = body.last(where: spinner), let o = l.firstIndex(of: "(") else { return nil }
        return String(l[o...]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
    }

    /// The shells that run in the background: the mode footer count, else the last turn-end line.
    var shells: Int {
        guard claude else { return 0 }
        for l in footer.reversed() where l.contains("shell") {
            if let n = HarnessScreen.count(HarnessScreen.shellsRE, l) { return n }
        }
        if let l = body.last(where: turnEnd), l.contains("still running") { return HarnessScreen.count(HarnessScreen.shellsRE, l) ?? 0 }
        return 0
    }

    static func count(_ re: NSRegularExpression, _ s: String) -> Int? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    /// The last "※ recap:" text of Claude Code, without the hint at its end.
    var recap: String? {
        guard claude, let i = body.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("※ recap:") }) else { return nil }
        var out = [body[i].trimmingCharacters(in: .whitespaces).dropFirst("※ recap:".count).trimmingCharacters(in: .whitespaces)]
        for l in body[(i + 1)...] {
            guard l.hasPrefix("  "), !ui(l) else { break }
            out.append(l.trimmingCharacters(in: .whitespaces))
        }
        return out.joined(separator: " ").replacingOccurrences(of: "(disable recaps in /config)", with: "").trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    /// FNV-1a 64. Stable across launches, unlike `Hasher`.
    var fnv1a: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

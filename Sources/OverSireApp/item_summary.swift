import Foundation
import CryptoKit
import OverSireCore
import OverSireAI

// An AI summary of an item description. `hash` is the hash of the description that the AI read.
struct ItemSummary: Codable, Equatable {
    static let version = 2
    static let maxLength = 500
    static let maxGist = 160

    var gist: String
    var points: [String] = []
    var open: [String] = []
    var hash: String
    var at = Date()
    var version = 1

    init(gist: String, points: [String] = [], open: [String] = [], hash: String, at: Date = Date(), version: Int = ItemSummary.version) {
        (self.gist, self.points, self.open, self.hash, self.at, self.version) = (gist, points, open, hash, at, version)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gist = try c.decode(String.self, forKey: .gist)
        points = try c.decodeIfPresent([String].self, forKey: .points) ?? []
        open = try c.decodeIfPresent([String].self, forKey: .open) ?? []
        hash = try c.decode(String.self, forKey: .hash)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    // The visible text: gist, points and open questions.
    var length: Int { ([gist] + points + open).reduce(0) { $0 + $1.count } }

    // A summary from an old prompt, or one over the limit, gets a refresh.
    var isOld: Bool { version < ItemSummary.version || length > ItemSummary.maxLength }

    var markdown: String {
        var out = gist + "\n"
        if !points.isEmpty { out += "\n" + points.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !open.isEmpty { out += "\n**Open:** " + open.joined(separator: " · ") + "\n" }
        return out
    }

    static func hash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ text: String, hash: String) -> ItemSummary? {
        guard let o = replyObject(text),
              let gist = (o["gist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !gist.isEmpty else { return nil }
        func list(_ k: String, _ n: Int) -> [String] {
            (o[k] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }.prefix(n).map { $0 }
        }
        var s = ItemSummary(gist: clip(gist, maxGist), points: list("points", 3), open: list("open", 2), hash: hash)
        while s.length > maxLength, !s.open.isEmpty { s.open.removeLast() }
        while s.length > maxLength, !s.points.isEmpty { s.points.removeLast() }
        return s
    }

    // Cuts the text at the last sentence end, else the last word end, and adds "…".
    static func clip(_ text: String, _ n: Int) -> String {
        guard text.count > n else { return text }
        let head = String(text.prefix(n - 1))
        if let end = head.indices.last(where: { i in ".!?".contains(head[i]) && (head.index(after: i) == head.endIndex || head[head.index(after: i)] == " ") }),
           head.distance(from: head.startIndex, to: end) > n / 3 {
            return String(head[...end])
        }
        let word = head.range(of: " ", options: .backwards).map { String(head[..<$0.lowerBound]) } ?? head
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
    }
}

// AI summaries of long item descriptions. `tick` asks the AI for open items, one at a time. The cache keeps the newest summaries.
final class ItemSummaries {
    static let changed = Notification.Name("ItemSummariesChanged")
    static let minLength = 1_500
    static let keep = 200
    static let recent: TimeInterval = 7 * 86400

    private var cache: [String: ItemSummary] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var tried: [String: String] = [:]     // key → the hash of the last automatic try
    private let path: String
    private let ai: () -> AIClient?
    /// False when another app owns the automations (AutomationOwner).
    var mayAct: () -> Bool = { true }
    /// The summaries that the Macs of the user share. The owner writes them, the other apps read them.
    var outputs: AIOutputBook? { didSet { attach() } }
    private var outputsObserver: NSObjectProtocol?

    init(path: String, ai: @escaping () -> AIClient? = { AIClient.current }) {
        self.path = path
        self.ai = ai
        if let d = FileManager.default.contents(atPath: path), let c = try? JSONDecoder().decode([String: ItemSummary].self, from: d) { cache = c }
    }

    var hasEngine: Bool { ai() != nil }

    static func offers(_ body: String) -> Bool { body.count > minLength }

    func summary(_ key: String) -> ItemSummary? { cache[key.uppercased()] }

    // The description changed after the summary.
    func isStale(_ key: String, body: String) -> Bool {
        guard let s = summary(key) else { return false }
        return s.hash != ItemSummary.hash(body) || s.isOld
    }

    func summarize(_ item: Item) {
        let k = item.key.uppercased()
        let body = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !busy.contains(k), let ai = ai() else { return }
        busy.insert(k)
        errors[k] = nil
        publish()
        let hash = ItemSummary.hash(body)
        ai.run(.itemSummary, AgentPrompts.summaryInput(key: k, title: item.title, body: body), id: "itemSummary:\(k)") { [weak self] r in
            guard let self else { return }
            self.busy.remove(k)
            switch r {
            case .success(let t):
                if let s = ItemSummary.parse(t, hash: hash) {
                    self.cache[k] = s
                    self.outputs?.put(.itemSummary, k, hash: hash, s, at: s.at, keep: ItemSummaries.keep)
                    self.save()
                    return
                }
                self.errors[k] = "The AI reply had no summary."
            case .failure(let e):
                self.errors[k] = e.message
            }
            self.publish()
        }
    }

    /// Summarizes the newest due item: open, changed in the last 7 days, a long description without a summary of this text.
    /// One try for each description, so a failure does not repeat.
    func tick(_ items: [(item: Item, open: Bool)], now: Date = Date()) {
        guard busy.isEmpty, hasEngine, mayAct() else { return }
        let due = items.filter { e in
            let body = (e.item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard e.open, ItemSummaries.offers(body), now.timeIntervalSince(e.item.activityAt) < ItemSummaries.recent else { return false }
            let k = e.item.key.uppercased(), h = ItemSummary.hash(body)
            return (cache[k]?.hash != h || cache[k]?.isOld == true) && tried[k] != h
        }
        guard let next = due.max(by: { $0.item.activityAt < $1.item.activityAt })?.item else { return }
        tried[next.key.uppercased()] = ItemSummary.hash((next.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        summarize(next)
    }

    // At the first start the local file goes to the store. Then the file is a cache only.
    private func attach() {
        outputsObserver.map(NotificationCenter.default.removeObserver)
        guard let outputs else { return }
        for (k, s) in cache where !outputs.contains(.itemSummary, k) { outputs.put(.itemSummary, k, hash: s.hash, s, at: s.at, keep: ItemSummaries.keep) }
        outputsObserver = NotificationCenter.default.addObserver(forName: AIOutputBook.changed, object: outputs, queue: .main) { [weak self] _ in self?.absorb() }
        absorb()
    }

    // A newer shared summary replaces the local one.
    private func absorb() {
        guard let outputs else { return }
        var changed = false
        for r in outputs.all(.itemSummary, as: ItemSummary.self) where (cache[r.subject]?.at ?? .distantPast) < r.value.at {
            cache[r.subject] = r.value
            changed = true
        }
        if changed { save() }
    }

    /// For `--uishots`: a summary without the AI.
    func seed(_ key: String, _ s: ItemSummary) { cache[key.uppercased()] = s }

    private func save() {
        if cache.count > ItemSummaries.keep {
            for (k, _) in cache.sorted(by: { $0.value.at < $1.value.at }).prefix(cache.count - ItemSummaries.keep) { cache[k] = nil }
        }
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: ItemSummaries.changed, object: self) }
}

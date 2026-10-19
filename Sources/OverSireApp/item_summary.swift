import Foundation
import CryptoKit
import OverSireCore
import OverSireAI

// An AI summary of an item description. `hash` is the hash of the description that the AI read.
struct ItemSummary: Codable, Equatable {
    var gist: String
    var points: [String] = []
    var open: [String] = []
    var hash: String
    var at = Date()

    var markdown: String {
        var out = gist + "\n"
        if !points.isEmpty { out += "\n" + points.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !open.isEmpty { out += "\n**Open**\n\n" + open.map { "- \($0)" }.joined(separator: "\n") + "\n" }
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
                .filter { !$0.isEmpty && $0.lowercased() != "none" }.prefix(n).map { String($0.prefix(400)) }
        }
        return ItemSummary(gist: String(gist.prefix(500)), points: list("points", 6), open: list("open", 3), hash: hash)
    }
}

// AI summaries of long item descriptions. Only a click asks the AI. The cache keeps the newest summaries.
final class ItemSummaries {
    static let changed = Notification.Name("ItemSummariesChanged")
    static let minLength = 1_500
    static let keep = 200

    private var cache: [String: ItemSummary] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private let path: String
    private let ai: () -> AIClient?

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
        return s.hash != ItemSummary.hash(body)
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
                if let s = ItemSummary.parse(t, hash: hash) { self.cache[k] = s; self.save(); return }
                self.errors[k] = "The AI reply had no summary."
            case .failure(let e):
                self.errors[k] = e.message
            }
            self.publish()
        }
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

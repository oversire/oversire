import Foundation
import CryptoKit
import OverSireCore
import OverSireAI

/// The AI text of the Status panel: 3 recap lines, the decision chips and the agent choices (OVERSIRE-383).
/// Each entry cites event ids. hash: the hash of the ids of the rows that the AI read.
struct Recap: Codable, Equatable {
    var lines: [CatchUp.Line]
    var decided: [CatchUp.Line]
    var choices: [CatchUp.Line]
    var hash: String
    var at = Date()

    static let budget = 6000

    static func hash(_ rows: [Event]) -> String {
        SHA256.hash(data: Data(rows.map(\.id).joined(separator: "\n").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Compact rows, newest kept when the budget is short. No payloads, no transcripts.
    static func input(key: String, title: String, since: Date?, rows: [Event]) -> AIInput {
        let f = ISO8601DateFormatter()
        var lines: [String] = []
        var size = 0
        for e in rows.reversed() {
            let l = "[\(e.id)] \(f.string(from: e.at)) \(e.item ?? key) \(e.kind.rawValue) \(e.actorType.rawValue):\(e.actor) \(e.summary)"
            if size + l.count + 1 > budget { break }
            size += l.count + 1
            lines.append(l)
        }
        return AIInput(text: lines.reversed().joined(separator: "\n"),
                       context: ["key": key, "title": title, "since": since.map { f.string(from: $0) } ?? ""])
    }

    /// The reply of the AI. An entry with no id of `rows` is dropped.
    static func parse(_ text: String, rows: [Event], hash: String) -> Recap? {
        guard let o = replyObject(text) else { return nil }
        let at = Dictionary(rows.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
        func list(_ k: String, _ n: Int, mark: String) -> [CatchUp.Line] {
            (o[k] as? [[String: Any]] ?? []).compactMap { e -> CatchUp.Line? in
                guard let t = (e["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                let ids = (e["ids"] as? [Any] ?? []).compactMap { $0 as? String }.filter { at[$0] != nil }
                guard !ids.isEmpty else { return nil }
                let reason = (e["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return CatchUp.Line(mark: mark, text: ItemSummary.clip(t, 140), at: ids.compactMap { at[$0] }.max(), ids: ids,
                                    reason: reason?.isEmpty == false ? reason : nil)
            }.prefix(n).map { $0 }
        }
        return Recap(lines: list("lines", 3, mark: "•"), decided: list("decided", 4, mark: "◆"), choices: list("choices", 2, mark: "?"), hash: hash)
    }
}

/// Runs the recap of the item that the page shows. One run at a time; the cache keeps the last recap of each item.
final class RecapJob {
    static let keep = 100

    private var cache: [String: Recap] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    var path: String?
    private let bus: ChangeBus
    var ai: () -> AIClient?

    init(path: String? = (CONFIG_DIR as NSString).appendingPathComponent("recaps.json"), bus: ChangeBus = .shared,
         ai: @escaping () -> AIClient? = { AI_CFG.enabled ? AIClient.current : nil }) {
        self.path = path
        self.bus = bus
        self.ai = ai
        if let path, let d = FileManager.default.contents(atPath: path), let c = try? JSONDecoder().decode([String: Recap].self, from: d) { cache = c }
    }

    var hasEngine: Bool { ai() != nil }

    /// The recap of these rows, or nil when the rows changed.
    func recap(_ key: String, rows: [Event]) -> Recap? {
        cache[key.uppercased()].flatMap { $0.hash == Recap.hash(rows) ? $0 : nil }
    }

    /// Asks the AI when there are new rows, the item is open and no recap of these rows exists.
    func want(_ key: String, title: String, since: Date?, rows: [Event], open: Bool) {
        let k = key.uppercased(), h = Recap.hash(rows)
        guard open, !rows.isEmpty, !busy.contains(k), cache[k]?.hash != h, errors[k + h] == nil, let ai = ai() else { return }
        busy.insert(k)
        ai.run(.recap, Recap.input(key: k, title: title, since: since, rows: rows), id: "recap:\(k)") { [weak self] r in
            guard let self else { return }
            self.busy.remove(k)
            switch r {
            case .success(let t):
                if let rc = Recap.parse(t, rows: rows, hash: h) { self.put(k, rc) } else { self.errors[k + h] = "The AI reply had no recap." }
            case .failure(let e):
                self.errors[k + h] = e.message
            }
            self.bus.post(DataChange(.events, items: [k], origin: .event))
        }
    }

    /// You confirmed an agent choice: it leaves the Pending list.
    func confirm(_ key: String, _ choice: CatchUp.Line) {
        guard var r = cache[key.uppercased()] else { return }
        r.choices.removeAll { $0 == choice }
        put(key, r)
        bus.post(DataChange(.events, items: [key.uppercased()], origin: .user))
    }

    /// For tests and `--uishots`.
    func put(_ key: String, _ r: Recap) {
        cache[key.uppercased()] = r
        if cache.count > Self.keep {
            for (k, _) in cache.sorted(by: { $0.value.at < $1.value.at }).prefix(cache.count - Self.keep) { cache[k] = nil }
        }
        guard let path, let d = try? JSONEncoder().encode(cache) else { return }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

let RECAPS = RecapJob()

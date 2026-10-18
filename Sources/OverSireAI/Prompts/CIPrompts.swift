import Foundation
import OverSireCore

/// Inputs of the CI prompts: the cause of a failed job and the morning digest.
public enum CIPrompts {
    /// The most log characters that go into one failure prompt.
    public static let logBudget = 12_000
    static let lineCap = 400

    /// `errors`: the error lines of the log. `tail`: the last lines.
    public static func failureInput(workflow: String, number: Int, branch: String, sha: String, commit: String, job: String,
                                    files: [String], errors: [String], tail: [String]) -> AIInput {
        AIInput(text: logText(errors: errors, tail: tail),
                context: ["workflow": workflow, "number": "\(number)", "branch": branch, "sha": String(sha.prefix(7)),
                          "commit": commit, "job": job, "files": files.isEmpty ? "unknown" : files.prefix(40).joined(separator: ", ")])
    }

    // The last lines that fit the budget. The tail keeps at least half of it, because the end of a log tells the most.
    static func logText(errors: [String], tail: [String], budget: Int = logBudget) -> String {
        let cut = { (l: String) in l.count > lineCap ? String(l.prefix(lineCap)) + "…" : l }
        let sep = "--- last lines ---"
        var t = fit(tail.suffix(60).map(cut), budget - sep.count - 1)
        let e = fit(errors.suffix(40).map(cut), max(budget / 2, budget - sep.count - 1 - size(t)))
        t = fit(t, budget - sep.count - 1 - size(e))
        return (e + [sep] + t).joined(separator: "\n")
    }

    // The last lines whose text and line breaks fit `budget`.
    private static func fit(_ lines: [String], _ budget: Int) -> [String] {
        var used = 0, start = lines.count
        while start > 0, used + lines[start - 1].count + 1 <= budget {
            start -= 1
            used += lines[start].count + 1
        }
        return Array(lines[start...])
    }

    private static func size(_ lines: [String]) -> Int { lines.reduce(0) { $0 + $1.count + 1 } }

    public static func digestInput(facts: [String]) -> AIInput { AIInput(text: facts.joined(separator: "\n")) }
}

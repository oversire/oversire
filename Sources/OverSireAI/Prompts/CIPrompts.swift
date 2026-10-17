import Foundation
import OverSireCore

/// Inputs of the CI prompts: the cause of a failed job and the morning digest.
public enum CIPrompts {
    /// `errors`: the error lines of the log. `tail`: the last lines.
    public static func failureInput(workflow: String, number: Int, branch: String, sha: String, commit: String, job: String,
                                    files: [String], errors: [String], tail: [String]) -> AIInput {
        AIInput(text: (Array(errors.suffix(40)) + ["--- last lines ---"] + Array(tail.suffix(60))).joined(separator: "\n"),
                context: ["workflow": workflow, "number": "\(number)", "branch": branch, "sha": String(sha.prefix(7)),
                          "commit": commit, "job": job, "files": files.isEmpty ? "unknown" : files.prefix(40).joined(separator: ", ")])
    }

    public static func digestInput(facts: [String]) -> AIInput { AIInput(text: facts.joined(separator: "\n")) }
}

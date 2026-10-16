import Foundation
import OverSireCore

/// Prompts about CI: the cause of a failed job and the morning digest.
public enum CIPrompts {
    /// `errors`: the error lines of the log. `tail`: the last lines.
    public static func failureInput(workflow: String, number: Int, branch: String, sha: String, commit: String, job: String,
                                    files: [String], errors: [String], tail: [String]) -> AIInput {
        AIInput(text: (Array(errors.suffix(40)) + ["--- last lines ---"] + Array(tail.suffix(60))).joined(separator: "\n"),
                context: ["workflow": workflow, "number": "\(number)", "branch": branch, "sha": String(sha.prefix(7)),
                          "commit": commit, "job": job, "files": files.isEmpty ? "unknown" : files.prefix(40).joined(separator: ", ")])
    }

    static func failureReason(_ i: AIInput) -> AIPrompt {
        let system = """
        You read a failed GitHub Actions job and give the likely cause in one or two short sentences.
        Use plain technical English. Do not guess past the log. Say so when the log does not tell.
        Reply with one JSON object only:
        {"cause":"the likely cause","fix":"the first thing to try","confidence":"low|medium|high"}
        """
        let user = """
        Workflow: \(i["workflow"]) #\(i["number"]) on \(i["branch"]) (\(i["sha"]))
        Commit: \(i["commit"])
        Job: \(i["job"])
        Changed files: \(i["files"])

        Log:
        \(i.text)
        """
        return AIPrompt(system: system, user: user, maxTokens: 400)
    }

    public static func digestInput(facts: [String]) -> AIInput { AIInput(text: facts.joined(separator: "\n")) }

    static func digest(_ i: AIInput) -> AIPrompt {
        AIPrompt(system: "You write a morning digest for a developer in two or three short sentences. Use only the facts. Say first what needs action.",
                 user: i.text, maxTokens: 200)
    }
}

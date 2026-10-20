import Foundation
import OverSireCore
import AgentBinder

// Reads the agent transcripts on this Mac through AgentBinder. RuntimeOrca gets it through ProviderEnvironment.
struct BinderTranscripts: TranscriptReading {
    var claudeHome: URL?

    func digest(file: String, agent: AgentName, budget: HistoryBudget) throws -> SessionDigest {
        let reader = TranscriptReader(budget: TranscriptBudget(earlier: budget.earlier, full: budget.full, maxChars: budget.maxChars),
                                      claudeHome: claudeHome)
        do {
            return SessionDigest(try reader.digest(file: URL(fileURLWithPath: file), harness: Harness(rawValue: agent.rawValue)))
        } catch TranscriptError.unsupportedHarness {
            throw ProviderError.unsupported(.sessionHistory)
        } catch TranscriptError.notFound {
            throw ProviderError.notFound
        }
    }

    func locate(agent: AgentName, sessionId: String) -> String? {
        try? TranscriptReader(claudeHome: claudeHome).locate(harness: Harness(rawValue: agent.rawValue), sessionId: sessionId).path
    }

    func newest(agent: AgentName, cwd: String) -> String? {
        try? TranscriptReader(claudeHome: claudeHome).newest(harness: Harness(rawValue: agent.rawValue), cwd: cwd).path
    }
}

extension SessionDigest {
    init(_ d: TranscriptDigest, source: Source = .file) {
        self.init(harness: AgentName(rawValue: d.harness.rawValue), sessionId: d.sessionId, source: source, turns: d.turns,
                  earlier: d.earlier.map { EarlierTurn(prompt: $0.prompt, closing: $0.closing, interrupted: $0.interrupted ? true : nil) },
                  last: d.last.map { LastTurn(prompt: $0.prompt, text: $0.text, tools: $0.tools, interrupted: $0.interrupted ? true : nil) },
                  truncated: d.truncated)
    }
}

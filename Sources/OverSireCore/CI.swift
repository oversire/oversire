import Foundation

// ─── CI model ────────────────────────────────────────────────────────────────

// An ID that the vendor sends as a number or as a string.
private func flexibleID<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> String {
    if let n = try? c.decode(Int.self, forKey: key) { return String(n) }
    return try c.decode(String.self, forKey: key)
}

public struct Run: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let displayTitle: String
    public let status: String
    public let conclusion: String?
    public let headBranch: String
    public let headSha: String
    public let event: String
    public let url: String
    public let updatedAt: String
    public let createdAt: String
    public let startedAt: String?
    public let number: Int
    public let workflowName: String?
    public let actorLogin: String?
    public var attempt: Int? = nil

    public init(id: String, name: String, displayTitle: String, status: String, conclusion: String?, headBranch: String,
                headSha: String, event: String, url: String, updatedAt: String, createdAt: String, startedAt: String?,
                number: Int, workflowName: String?, actorLogin: String?, attempt: Int? = nil) {
        self.id = id
        self.name = name
        self.displayTitle = displayTitle
        self.status = status
        self.conclusion = conclusion
        self.headBranch = headBranch
        self.headSha = headSha
        self.event = event
        self.url = url
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.number = number
        self.workflowName = workflowName
        self.actorLogin = actorLogin
        self.attempt = attempt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, displayTitle, status, conclusion, headBranch, headSha, event, url
        case updatedAt, createdAt, startedAt, number, workflowName, actorLogin, attempt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try flexibleID(c, .id)
        name = try c.decode(String.self, forKey: .name)
        displayTitle = try c.decode(String.self, forKey: .displayTitle)
        status = try c.decode(String.self, forKey: .status)
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
        headBranch = try c.decode(String.self, forKey: .headBranch)
        headSha = try c.decode(String.self, forKey: .headSha)
        event = try c.decode(String.self, forKey: .event)
        url = try c.decode(String.self, forKey: .url)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        number = try c.decode(Int.self, forKey: .number)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName)
        actorLogin = try c.decodeIfPresent(String.self, forKey: .actorLogin)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
    }

    public var isFailure: Bool { status == "completed" && conclusion == "failure" }

    // The mean duration of the completed runs of the same workflow in the last 3 days.
    public func estimatedTotal(history: [Run], now: Date = Date()) -> TimeInterval? {
        let wf = workflowName ?? name
        let cutoff = now.addingTimeInterval(-3 * 24 * 3600)
        let durs = history.compactMap { r -> TimeInterval? in
            guard (r.workflowName ?? r.name) == wf, r.status == "completed",
                  let s = parseISO(r.startedAt) ?? parseISO(r.createdAt), s >= cutoff,
                  let e = parseISO(r.updatedAt) else { return nil }
            let d = e.timeIntervalSince(s)
            return d > 0 ? d : nil
        }
        guard !durs.isEmpty else { return nil }
        return durs.reduce(0, +) / Double(durs.count)
    }
}

extension Array where Element == Run {
    // Puts the workflows of one trigger (same commit, branch, event, actor) into one row.
    // A second run of a workflow already in a row starts a new row. This keeps repeat dispatches apart.
    public func grouped() -> [[Run]] {
        var groups: [[Run]] = []
        var indexByKey: [String: Int] = [:]
        for run in self {
            let key = "\(run.displayTitle)|\(run.headSha)|\(run.headBranch)|\(run.event)|\(run.actorLogin ?? "")"
            if let i = indexByKey[key], !groups[i].contains(where: { $0.workflowName == run.workflowName }) {
                groups[i].append(run)
            } else {
                indexByKey[key] = groups.count
                groups.append([run])
            }
        }
        return groups
    }
}

public struct Step: Codable, Hashable, Sendable {
    public let name: String
    public let status: String?
    public let conclusion: String?
    public let startedAt: String?
    public let completedAt: String?

    public init(name: String, status: String?, conclusion: String?, startedAt: String?, completedAt: String?) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct Job: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let status: String?
    public let conclusion: String?
    public let url: String?
    public let startedAt: String?
    public let completedAt: String?
    public let runnerName: String?
    public let steps: [Step]?

    public init(id: String, name: String, status: String?, conclusion: String?, url: String?, startedAt: String?,
                completedAt: String?, runnerName: String?, steps: [Step]?) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.url = url
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.runnerName = runnerName
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, url, startedAt, completedAt, runnerName, steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try flexibleID(c, .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        runnerName = try c.decodeIfPresent(String.self, forKey: .runnerName)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps)
    }
}

public struct CheckAnnotation: Codable, Hashable, Sendable {
    public let message: String?
    public let path: String?
    public let startLine: Int?
    public let annotationLevel: String?

    public init(message: String?, path: String?, startLine: Int?, annotationLevel: String?) {
        self.message = message
        self.path = path
        self.startLine = startLine
        self.annotationLevel = annotationLevel
    }
}

/// Why a job failed: the failed step and the annotation messages.
public struct Failure: Codable, Hashable, Sendable {
    public let job: String
    public let step: String?
    public let messages: [String]

    public init(job: String, step: String?, messages: [String]) {
        self.job = job
        self.step = step
        self.messages = messages
    }
}

public struct RunQuery: Hashable, Sendable {
    public var repo: RepoRef?
    public var pipeline: String?
    public var branch: String?
    public var limit: Int

    public init(repo: RepoRef? = nil, pipeline: String? = nil, branch: String? = nil, limit: Int = 30) {
        self.repo = repo
        self.pipeline = pipeline
        self.branch = branch
        self.limit = limit
    }
}

public enum RunAction: String, Codable, Sendable, CaseIterable {
    case rerun, rerunFailed, cancel
}

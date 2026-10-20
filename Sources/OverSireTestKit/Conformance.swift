import Foundation
import OverSireCore

// ─── Conformance ─────────────────────────────────────────────────────────────
// Each suite takes a factory and returns a report. A test asserts that the report has no problems.
// A new adapter is done when ProviderConformance and the suite of its layer pass.

public struct ConformanceReport: Sendable, CustomStringConvertible {
    public private(set) var problems: [String] = []

    public init() {}

    public var passed: Bool { problems.isEmpty }
    public var description: String { passed ? "passed" : problems.joined(separator: "\n") }

    public mutating func expect(_ ok: Bool, _ problem: @autoclosure () -> String) {
        if !ok { problems.append(problem()) }
    }

    /// Runs `body`. An error is a problem and gives nil.
    public mutating func step<T>(_ name: String, _ body: () async throws -> T) async -> T? {
        do { return try await body() } catch {
            problems.append("\(name) threw \(error)")
            return nil
        }
    }

    /// `body` must throw a ProviderError that `match` accepts.
    public mutating func expectError(_ name: String, _ match: (ProviderError) -> Bool, _ body: () async throws -> Void) async {
        do {
            try await body()
            problems.append("\(name) did not throw")
        } catch let e as ProviderError {
            if !match(e) { problems.append("\(name) threw the wrong error \(e)") }
        } catch {
            problems.append("\(name) threw \(error), not a ProviderError")
        }
    }

    mutating func merge(_ other: ConformanceReport) { problems += other.problems }
}

/// What the factory sets up. `.unauthorized`: the vendor refuses the token (a 401 fixture, a fake with a failure).
public enum ConformanceScenario: Sendable { case normal, unauthorized }

public enum ProviderConformance {
    /// A capability that has a protocol and the protocol must go together.
    static let protocols: [(Capability, String, @Sendable (any Provider) -> Bool)] = [
        (.intake, "IntakeTriaging", { $0 is any IntakeTriaging }),
        (.intakeCreate, "IntakeCreating", { $0 is any IntakeCreating }),
        (.attachments, "AttachmentUploading", { $0 is any AttachmentUploading }),
        (.timeline, "TimelineReading", { $0 is any TimelineReading }),
        (.labels, "LabelManaging", { $0 is any LabelManaging }),
        (.links, "LinkManaging", { $0 is any LinkManaging }),
        (.relations, "RelationManaging", { $0 is any RelationManaging }),
        (.assets, "AssetResolving", { $0 is any AssetResolving }),
        (.webhooks, "WebhookManaging", { $0 is any WebhookManaging }),
        (.logs, "LogReading", { $0 is any LogReading }),
        (.rerunJob, "JobRerunning", { $0 is any JobRerunning }),
        (.sessionInput, "SessionIO", { $0 is any SessionIO }),
        (.sessionTail, "SessionIO", { $0 is any SessionIO }),
        (.reveal, "Revealing", { $0 is any Revealing }),
        (.hostFiles, "HostFileWriting", { $0 is any HostFileWriting }),
        (.sessionHistory, "SessionHistoryReading", { $0 is any SessionHistoryReading }),
        (.projectSettings, "ProjectSettingsReading", { $0 is any ProjectSettingsReading }),
        (.projectSettingsEdit, "ProjectSettingsEditing", { $0 is any ProjectSettingsEditing }),
    ]

    /// The capabilities agree with the protocols. No I/O.
    public static func capabilities(_ p: any Provider) -> ConformanceReport {
        var r = ConformanceReport()
        let caps = p.capabilities
        for (cap, name, conforms) in protocols {
            let has = conforms(p)
            r.expect(!caps.contains(cap) || has, "capability \(cap.rawValue) needs \(name)")
            // SessionIO has two capabilities. One of them is enough.
            let claimed = protocols.filter { $0.1 == name }.contains { caps.contains($0.0) }
            r.expect(!has || claimed, "\(name) needs the capability \(cap.rawValue)")
        }
        return r
    }

    public static func run(make: @Sendable (ConformanceScenario) async throws -> any Provider) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let p = await r.step("make(.normal)", { try await make(.normal) }) else { return r }
        r.merge(capabilities(p))
        r.expect(p.account.provider == p.id, "the account provider \(p.account.provider) is not the id \(p.id)")
        r.expect(p.pollPolicy.minInterval > .zero && p.pollPolicy.requestsPerHour > 0, "the poll policy allows no polls")

        if let me = await r.step("probe", { try await p.probe() }) {
            r.expect(!me.person.id.isEmpty, "probe gave a person with no id")
        }
        if let first = await r.step("poll(since: nil)", { try await p.poll(since: nil) }) {
            check(first.events, of: p, into: &r)
            if let next = await r.step("poll(since: cursor)", { try await p.poll(since: first.cursor) }) {
                check(next.events, of: p, into: &r)
                let again = Set(first.events.map(\.id)).intersection(next.events.map(\.id))
                r.expect(again.isEmpty, "the second poll repeats events \(again.sorted())")
            }
        }

        guard let bad = await r.step("make(.unauthorized)", { try await make(.unauthorized) }) else { return r }
        await r.expectError("probe with a refused token", { $0 == .unauthorized }) { _ = try await bad.probe() }
        await r.expectError("poll with a refused token", { _ in true }) { _ = try await bad.poll(since: nil) }
        return r
    }

    static func check(_ events: [ProviderEvent], of p: any Provider, into r: inout ConformanceReport) {
        for e in events {
            r.expect(e.provider == p.id && e.account == p.account, "event \(e.id) has the wrong provider or account")
            r.expect(e.schema == ProviderEvent.schemaVersion, "event \(e.id) has schema \(e.schema)")
        }
        r.expect(Set(events.map(\.id)).count == events.count, "a poll has two events with the same id")
    }
}

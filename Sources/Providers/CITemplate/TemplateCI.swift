import Foundation
import OverSireCore

// A skeleton for a new CI provider. See docs/adding-a-provider.md.
// Copy this folder, rename the types, and replace each throw with a call to the vendor.

extension ProviderID {
    public static let ciTemplate: ProviderID = "ci-template"
}

public final class TemplateCI: CIProvider {
    public static let descriptor = ProviderDescriptor(
        id: .ciTemplate, layer: .ci, displayName: "CI template", symbol: "hammer",
        fields: [ConfigField(key: "owner", label: "Owner", kind: .text),
                 ConfigField(key: "repos", label: "Repos", kind: .text, required: false, help: "owner/name, comma separated"),
                 ConfigField(key: "token", label: "API token", kind: .secret)],
        auth: [.token]
    ) { config, env in
        TemplateCI(account: config.account, http: env.http,
                   token: config.secretKeys.first.flatMap(env.secrets.secret))
    }

    public let id: ProviderID = .ciTemplate
    public let account: AccountID
    public let capabilities: Set<Capability> = []
    public let pollPolicy = PollPolicy(minInterval: .seconds(15), requestsPerHour: 1_000)
    let http: any HTTPTransport
    let token: String?

    public init(account: AccountID, http: any HTTPTransport, token: String?) {
        self.account = account
        self.http = http
        self.token = token
    }

    public func probe() async throws -> Identity { throw ProviderError.unsupported("probe") }
    public func poll(since: Cursor?) async throws -> EventPage { throw ProviderError.unsupported("poll") }

    public func pipelines(_ r: RepoRef) async throws -> [Pipeline] { throw ProviderError.unsupported("pipelines") }
    public func runs(_ q: RunQuery) async throws -> [Run] { throw ProviderError.unsupported("runs") }
    public func run(_ r: RunRef) async throws -> Run { throw ProviderError.unsupported("run") }
    public func jobs(_ r: RunRef) async throws -> [Job] { throw ProviderError.unsupported("jobs") }
    public func failures(_ r: RunRef) async throws -> [Failure] { throw ProviderError.unsupported("failures") }
    // Without the rerun or cancel capability, the matching action must throw unsupported.
    public func perform(_ a: RunAction, on r: RunRef) async throws { throw ProviderError.unsupported(.rerun) }
}

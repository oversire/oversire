import Foundation
import OverSireCore

// A skeleton for a new code host. See docs/adding-a-provider.md.
// Copy this folder, rename the types, and replace each throw with a call to the vendor.

extension ProviderID {
    public static let codeHostTemplate: ProviderID = "codehost-template"
}

public final class TemplateCodeHost: CodeHost {
    public static let descriptor = ProviderDescriptor(
        id: .codeHostTemplate, layer: .codeHost, displayName: "Code host template", symbol: "arrow.triangle.branch",
        fields: [ConfigField(key: "owner", label: "Owner", kind: .text),
                 ConfigField(key: "repos", label: "Repos", kind: .text, required: false, help: "owner/name, comma separated"),
                 ConfigField(key: "token", label: "API token", kind: .secret)],
        auth: [.token]
    ) { config, env in
        TemplateCodeHost(account: config.account, http: env.http,
                         token: config.secretKeys.first.flatMap(env.secrets.secret))
    }

    public let id: ProviderID = .codeHostTemplate
    public let account: AccountID
    public let capabilities: Set<Capability> = []
    public let pollPolicy = PollPolicy(minInterval: .seconds(30), requestsPerHour: 1_000)
    let http: any HTTPTransport
    let token: String?

    public init(account: AccountID, http: any HTTPTransport, token: String?) {
        self.account = account
        self.http = http
        self.token = token
    }

    public func probe() async throws -> Identity { throw ProviderError.unsupported("probe") }
    public func poll(since: Cursor?) async throws -> EventPage { throw ProviderError.unsupported("poll") }

    public func repos() async throws -> [Repo] { throw ProviderError.unsupported("repos") }
    public func changes(_ r: RepoRef, _ f: ChangeFilter) async throws -> [ChangeRequest] { throw ProviderError.unsupported("changes") }
    // Without the changeActions capability, this must throw unsupported(.changeActions).
    public func perform(_ a: ChangeAction, on c: ChangeRef) async throws { throw ProviderError.unsupported(.changeActions) }
    public func commitMessage(_ r: RepoRef, sha: String) async throws -> String { throw ProviderError.unsupported("commitMessage") }
}

// Optional: search and people. Conform, and add .changeSearch and .collaborators to capabilities.
// extension TemplateCodeHost: ChangeSearching, CollaboratorListing {
//     public func search(_ query: String, limit: Int) async throws -> [ChangeRequest] { throw ProviderError.unsupported(.changeSearch) }
//     public func collaborators(_ repo: RepoRef) async throws -> [PersonRef] { throw ProviderError.unsupported(.collaborators) }
// }

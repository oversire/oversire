import Foundation
import OverSireCore

// A skeleton for a new tracker. See docs/adding-a-provider.md.
// Copy this folder, rename the types, and replace each throw with a call to the vendor.

extension ProviderID {
    public static let trackerTemplate: ProviderID = "tracker-template"
}

public final class TemplateTracker: Tracker {
    public static let descriptor = ProviderDescriptor(
        id: .trackerTemplate, layer: .tracker, displayName: "Tracker template", symbol: "checklist",
        fields: [ConfigField(key: "workspace", label: "Workspace", kind: .text),
                 ConfigField(key: "token", label: "API token", kind: .secret)],
        auth: [.token]
    ) { config, env in
        TemplateTracker(account: config.account, http: env.http,
                        token: config.secretKeys.first.flatMap(env.secrets.secret))
    }

    public let id: ProviderID = .trackerTemplate
    public let account: AccountID
    public let capabilities: Set<Capability> = []
    public let pollPolicy = PollPolicy(minInterval: .seconds(60), requestsPerHour: 1_000)
    public let keyFormat: KeyFormat = .projectDash
    let http: any HTTPTransport
    let token: String?

    public init(account: AccountID, http: any HTTPTransport, token: String?) {
        self.account = account
        self.http = http
        self.token = token
    }

    public func probe() async throws -> Identity { throw ProviderError.unsupported("probe") }
    public func poll(since: Cursor?) async throws -> EventPage { throw ProviderError.unsupported("poll") }

    public func projects() async throws -> [ProjectSummary] { throw ProviderError.unsupported("projects") }
    public func statuses(_ p: ProjectRef) async throws -> [StatusOption] { throw ProviderError.unsupported("statuses") }
    public func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] { throw ProviderError.unsupported("items") }
    public func detail(_ i: ItemRef) async throws -> ItemDetail { throw ProviderError.unsupported("detail") }
    public func comments(_ i: ItemRef) async throws -> [Comment] { throw ProviderError.unsupported("comments") }
    public func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { throw ProviderError.unsupported("create") }
    public func update(_ i: ItemRef, _ patch: ItemPatch) async throws { throw ProviderError.unsupported("update") }
    public func comment(_ i: ItemRef, markdown: String) async throws { throw ProviderError.unsupported("comment") }
}

// Optional: project settings. Conform, and add .projectSettings and .projectSettingsEdit to capabilities.
// extension TemplateTracker: ProjectSettingsEditing {
//     public var editableSettings: Set<ProjectSettingsField> { [.name, .description] }
//     public func settings(_ p: ProjectRef) async throws -> ProjectSettings { throw ProviderError.unsupported(.projectSettings) }
//     public func update(_ p: ProjectRef, _ patch: ProjectSettingsPatch) async throws {
//         throw ProviderError.unsupported(.projectSettingsEdit)
//     }
// }

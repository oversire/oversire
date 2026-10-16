import Foundation
import OverSireCore

// A skeleton for a new agent runtime. See docs/adding-a-provider.md.
// Copy this folder, rename the types, and replace each throw with a call to the runtime.

extension ProviderID {
    public static let runtimeTemplate: ProviderID = "runtime-template"
}

public final class TemplateRuntime: AgentRuntime {
    public static let descriptor = ProviderDescriptor(
        id: .runtimeTemplate, layer: .runtime, displayName: "Runtime template", symbol: "terminal",
        fields: [ConfigField(key: "cli", label: "CLI path", kind: .text, required: false)],
        auth: [.localApp]
    ) { config, env in
        TemplateRuntime(account: config.account, commands: env.commands, exe: config.values["cli"] ?? "")
    }

    public let id: ProviderID = .runtimeTemplate
    public let account: AccountID
    public let capabilities: Set<Capability> = []
    public let pollPolicy = PollPolicy(minInterval: .seconds(10), requestsPerHour: 3_600)
    let commands: any CommandRunner
    let exe: String

    public init(account: AccountID, commands: any CommandRunner, exe: String) {
        self.account = account
        self.commands = commands
        self.exe = exe
    }

    public func probe() async throws -> Identity { throw ProviderError.unsupported("probe") }
    public func poll(since: Cursor?) async throws -> EventPage { throw ProviderError.unsupported("poll") }

    public func environments() async throws -> [RuntimeEnvironment] { throw ProviderError.unsupported("environments") }
    public func repos(in env: RuntimeEnvironment?) async throws -> [RuntimeRepo] { throw ProviderError.unsupported("repos") }
    public func workspaces() async throws -> [Workspace] { throw ProviderError.unsupported("workspaces") }
    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] { throw ProviderError.unsupported("sessions") }
    public func launch(_ r: LaunchRequest) async throws -> Launch { throw ProviderError.unsupported("launch") }
}

import Foundation
import OverSireCore

extension ProviderID {
    public static let orca: ProviderID = "orca"
}

extension OrcaRuntime {
    public static let descriptor = ProviderDescriptor(
        id: .orca, layer: .runtime, displayName: "Orca", symbol: "terminal",
        fields: [ConfigField(key: "environment", label: "Run sessions on", kind: .text, required: false,
                             help: "A paired Orca server, for example mbp. Empty runs on this Mac."),
                 ConfigField(key: "cli", label: "Orca CLI", kind: .text, required: false, help: OrcaRuntime.defaultPath)],
        auth: [.localApp], docsURL: URL(string: "https://github.com/stablyai/orca")
    ) { config, env in
        let cli = config.values["cli"].flatMap { $0.isEmpty ? nil : $0 } ?? OrcaRuntime.defaultPath
        return OrcaRuntime(exe: cli, environment: config.values["environment"], commands: env.commands)
    }
}

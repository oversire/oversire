import Foundation
import GitHubKit
import OverSireCore

extension ProviderID {
    public static let github: ProviderID = "github"
}

extension GitHubCodeHost {
    /// Without a token the adapter uses the login of the gh CLI.
    public static let descriptor = ProviderDescriptor(
        id: .github, layer: .codeHost, displayName: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
        fields: [ConfigField(key: "owner", label: "Owner", kind: .text, help: "A user or an org."),
                 ConfigField(key: "repos", label: "Repos", kind: .text, required: false, help: "owner/repo, comma separated"),
                 ConfigField(key: "token", label: "Token", kind: .secret, required: false, help: "Empty uses gh auth.")],
        auth: [.cli("gh"), .token], docsURL: URL(string: "https://cli.github.com/manual/gh_auth_login")
    ) { config, env in
        let token = config.secretKeys.first.flatMap { env.secrets.secret($0) }
        let repos = (config.values["repos"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return GitHubCodeHost(owner: config.values["owner"] ?? config.account.id, repos: repos,
                              client: GitHubClient(commands: env.commands, http: env.http, token: token))
    }
}

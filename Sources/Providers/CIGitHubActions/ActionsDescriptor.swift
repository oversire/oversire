import Foundation
import GitHubKit
import OverSireCore

extension ProviderID {
    public static let githubActions: ProviderID = "github-actions"
}

extension ActionsCI {
    /// Without a token the adapter uses the login of the gh CLI.
    public static let descriptor = ProviderDescriptor(
        id: .githubActions, layer: .ci, displayName: "GitHub Actions", symbol: "play.circle",
        fields: [ConfigField(key: "owner", label: "Owner", kind: .text, help: "A user or an org."),
                 ConfigField(key: "repos", label: "Repos", kind: .text, help: "owner/repo, comma separated"),
                 ConfigField(key: "token", label: "Token", kind: .secret, required: false, help: "Empty uses gh auth.")],
        auth: [.cli("gh"), .token], docsURL: URL(string: "https://cli.github.com/manual/gh_auth_login")
    ) { config, env in
        let s = GitHubAccountSettings(config, env)
        return ActionsCI(owner: s.owner, repos: s.repos, client: s.client)
    }
}

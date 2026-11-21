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
        auth: [.cli("gh"), .token], docsURL: URL(string: "https://cli.github.com/manual/gh_auth_login"),
        cli: VendorCLI(binary: "gh", passEnv: ["SHELL", "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "XDG_CONFIG_HOME",
                                               "XDG_DATA_HOME", "GNUPGHOME", "SSH_AUTH_SOCK"],
                       lockedFlags: ["--watch"],
                       deniedCommands: [["auth"], ["config", "set"], ["extension"], ["alias", "set"], ["run", "watch"],
                                        ["codespace", "ssh"], ["skill"]],
                       release: .homebrew(formula: "gh"))
    ) { config, env in
        let s = GitHubAccountSettings(config, env)
        return GitHubCodeHost(owner: s.owner, repos: s.repos, client: s.client)
    }
}

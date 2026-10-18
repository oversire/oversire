import Foundation
import CIGitHubActions
import CodeHostGitHub
import OverSireCore
import RuntimeOrca
import Security
import TrackerPlane

// Moves the data of a Cat Eye install to OverSire on the first start.
// It copies and never deletes, so the old app still works.

protocol SecretVault: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func keys() -> [String]
}

extension SecretStore: SecretVault {}

final class LegacyMigration {
    static let marker = "migrated-from-cat-eye"
    static let oldBundleID = "com.flarco.cateye"
    // Old Keychain service → new Keychain service.
    static let services = [
        "com.flarco.cat-eye.ai": "com.oversire.app.ai",
        "com.flarco.cat-eye.plane": "com.oversire.app.plane",
        "com.flarco.cat-eye.relay": "com.oversire.app.cloud",
    ]

    let oldDir: String
    let newDir: String
    private let vault: (String) -> SecretVault
    private let oldDefaults: () -> [String: Any]?
    private let newDefaults: UserDefaults

    init(home: String = NSHomeDirectory(),
         vault: @escaping (String) -> SecretVault = { SecretStore(service: $0) },
         oldDefaults: @escaping () -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: LegacyMigration.oldBundleID) },
         newDefaults: UserDefaults = .standard) {
        oldDir = (home as NSString).appendingPathComponent(".config/cat-eye")
        newDir = (home as NSString).appendingPathComponent(".config/oversire")
        self.vault = vault
        self.oldDefaults = oldDefaults
        self.newDefaults = newDefaults
    }

    /// Returns true when it migrated in this call.
    @discardableResult
    func run() -> Bool {
        let fm = FileManager.default
        let markerPath = (newDir as NSString).appendingPathComponent(Self.marker)
        if fm.fileExists(atPath: markerPath) { return false }
        if !fm.fileExists(atPath: newDir) && fm.fileExists(atPath: oldDir) {
            do { try fm.copyItem(atPath: oldDir, toPath: newDir) } catch { log.error("legacy config copy: \(error.localizedDescription)") }
        }
        for (old, new) in Self.services {
            let from = vault(old), to = vault(new)
            for k in from.keys() where to.get(k) == nil {
                if let v = from.get(k) { to.set(k, v) }
            }
        }
        for (k, v) in oldDefaults() ?? [:] where newDefaults.object(forKey: k) == nil {
            newDefaults.set(v, forKey: k)
        }
        try? fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)
        fm.createFile(atPath: markerPath, contents: Data(ISO8601DateFormatter().string(from: Date()).utf8))
        return true
    }
}

// Accounts from the settings that come before the accounts list. A config with no list gets them once.
extension LegacyMigration {
    static func accounts(from c: AppConfig) -> [AccountConfig] {
        var out: [AccountConfig] = []
        for w in c.projects?.workspaces ?? [] {
            out.append(AccountConfig(account: AccountID(provider: .plane, id: w.slug), values: ["host": w.host],
                                     secretKeys: ["PLANE_TOKEN_\(w.slug)"]))
        }
        var owners: [String] = []
        var repos: [String: [String]] = [:]
        for r in c.repos where isValidRepo(r) {
            let owner = String(r.split(separator: "/")[0])
            if repos[owner] == nil { owners.append(owner) }
            repos[owner, default: []].append(r)
        }
        for o in c.orgs ?? [] where repos[o] == nil {
            owners.append(o)
            repos[o] = []
        }
        for p in [ProviderID.github, .githubActions] {
            for o in owners {
                out.append(AccountConfig(account: AccountID(provider: p, id: o), values: ["repos": repos[o]!.joined(separator: ",")]))
            }
        }
        let orca = c.projects?.orca ?? OrcaConfig()
        if orca.enabled {
            var values = ["agent": c.projects?.runtime.agent ?? "claude"]
            if !orca.cli.isEmpty { values["cli"] = orca.cli }
            if let e = orca.environment { values["environment"] = e }
            out.append(AccountConfig(account: AccountID(provider: .orca, id: orca.environment ?? "local"), values: values))
        }
        return out
    }
}

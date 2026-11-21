import Foundation

// The wire types of the app calls vendor.run, vendor.list, vendor.skill, vendor.install and vendor.remove (app-call.json).

/// The args of vendor.run. Set `project` or `account`.
public struct VendorRunArgs: Codable, Hashable, Sendable {
    public var project: String?
    public var account: String?
    public var args: [String]
    public var cwd: String?

    public init(project: String? = nil, account: String? = nil, args: [String], cwd: String? = nil) {
        self.project = project
        self.account = account
        self.args = args
        self.cwd = cwd
    }
}

/// The data of a vendor.run result.
public struct VendorRunOutput: Codable, Hashable, Sendable {
    public var vendor: String
    public var account: String
    public var exit: Int
    public var stdout: String
    public var stderr: String
    public var truncated: Bool?
    public var timedOut: Bool?
    public var ms: Int

    public init(vendor: String, account: String, exit: Int, stdout: String, stderr: String,
                truncated: Bool? = nil, timedOut: Bool? = nil, ms: Int) {
        self.vendor = vendor
        self.account = account
        self.exit = exit
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.timedOut = timedOut
        self.ms = ms
    }
}

/// One row of the data of vendor.list. `path` is the binary that vendor.run runs. No state: an app before OVERSIRE-580.
public struct VendorCLIRow: Codable, Hashable, Sendable {
    public var provider: String
    public var vendor: String
    public var binary: String
    public var path: String?
    public var version: String?
    public var minVersion: String?
    public var source: VendorSource?
    public var state: VendorState?
    public var accounts: [String]
    public var projects: [String]
    /// The version of the OverSire copy, also when the PATH copy wins.
    public var ownVersion: String?
    /// An install or a remove that runs now.
    public var job: VendorJob?

    public init(provider: String, vendor: String, binary: String, path: String? = nil, version: String? = nil,
                minVersion: String? = nil, source: VendorSource? = nil, state: VendorState? = nil,
                accounts: [String], projects: [String], ownVersion: String? = nil, job: VendorJob? = nil) {
        self.provider = provider
        self.vendor = vendor
        self.binary = binary
        self.path = path
        self.version = version
        self.minVersion = minVersion
        self.source = source
        self.state = state
        self.accounts = accounts
        self.projects = projects
        self.ownVersion = ownVersion
        self.job = job
    }
}

/// The args of vendor.install and vendor.remove.
public struct VendorActionArgs: Codable, Hashable, Sendable {
    public var vendor: String

    public init(vendor: String) { self.vendor = vendor }
}

public enum VendorJob: String, Codable, Hashable, Sendable {
    case installing, removing
}

/// The data of a vendor.install or vendor.remove result.
public struct VendorChange: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Hashable, Sendable {
        case installed, updated, unchanged, removed
    }

    public var vendor: String
    public var binary: String
    public var action: Action
    public var version: String?
    /// The version before an update.
    public var previous: String?
    /// The OverSire copy after the change.
    public var path: String?
    /// trebi-catalog or github-release.
    public var release: String?

    public init(vendor: String, binary: String, action: Action, version: String? = nil, previous: String? = nil,
                path: String? = nil, release: String? = nil) {
        self.vendor = vendor
        self.binary = binary
        self.action = action
        self.version = version
        self.previous = previous
        self.path = path
        self.release = release
    }
}

/// The args of vendor.skill. `vendor` is a provider id: plane, bigtimer or github.
public struct VendorSkillArgs: Codable, Hashable, Sendable {
    public var vendor: String

    public init(vendor: String) { self.vendor = vendor }
}

/// Where the reference part of vendor.skill comes from.
public enum VendorSkillReference: String, Codable, Hashable, Sendable {
    case skill, help, notInstalled
}

/// The data of a vendor.skill result.
public struct VendorSkillOutput: Codable, Hashable, Sendable {
    public var vendor: String
    public var binary: String
    public var path: String?
    public var reference: VendorSkillReference
    public var markdown: String

    public init(vendor: String, binary: String, path: String? = nil, reference: VendorSkillReference, markdown: String) {
        self.vendor = vendor
        self.binary = binary
        self.path = path
        self.reference = reference
        self.markdown = markdown
    }
}

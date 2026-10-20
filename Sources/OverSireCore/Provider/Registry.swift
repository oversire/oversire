import Foundation

/// One vendor: its form fields, its auth and the factory for its adapter.
public struct ProviderDescriptor: Sendable {
    public let id: ProviderID
    public let layer: Layer
    public let displayName: String
    public let symbol: String                 // SF Symbol name
    public let fields: [ConfigField]          // the settings form
    public let auth: [AuthKind]
    public let docsURL: URL?
    public let make: @Sendable (AccountConfig, ProviderEnvironment) throws -> any Provider

    public init(id: ProviderID, layer: Layer, displayName: String, symbol: String, fields: [ConfigField], auth: [AuthKind],
                docsURL: URL? = nil, make: @escaping @Sendable (AccountConfig, ProviderEnvironment) throws -> any Provider) {
        self.id = id
        self.layer = layer
        self.displayName = displayName
        self.symbol = symbol
        self.fields = fields
        self.auth = auth
        self.docsURL = docsURL
        self.make = make
    }
}

public struct ConfigField: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text, secret, url
        case choice([String])
    }

    public let key: String
    public let label: String
    public let kind: Kind
    public let required: Bool
    public let help: String?

    public init(key: String, label: String, kind: Kind, required: Bool = true, help: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.required = required
        self.help = help
    }
}

public enum AuthKind: Hashable, Sendable {
    case token
    case cli(String)   // for example "gh"
    case localApp
    case cloudApp
}

/// One connected account. Secret fields hold only Keychain key names, never values.
public struct AccountConfig: Hashable, Codable, Sendable {
    public let account: AccountID
    public var values: [String: String]
    public var secretKeys: [String]

    public init(account: AccountID, values: [String: String] = [:], secretKeys: [String] = []) {
        self.account = account
        self.values = values
        self.secretKeys = secretKeys
    }
}

/// The I/O that the app gives to each adapter.
public struct ProviderEnvironment: Sendable {
    public let http: any HTTPTransport
    public let commands: any CommandRunner
    public let secrets: any SecretReader
    public let clock: any Clock<Duration>
    /// nil: the adapters read no local transcripts.
    public let transcripts: (any TranscriptReading)?

    public init(http: any HTTPTransport, commands: any CommandRunner, secrets: any SecretReader,
                clock: any Clock<Duration> = ContinuousClock(), transcripts: (any TranscriptReading)? = nil) {
        self.http = http
        self.commands = commands
        self.secrets = secrets
        self.clock = clock
        self.transcripts = transcripts
    }
}

public final class ProviderRegistry: @unchecked Sendable {
    public enum RegistryError: Error, Hashable, Sendable {
        case unknownProvider(ProviderID)
    }

    private let lock = NSLock()
    private var byID: [ProviderID: ProviderDescriptor] = [:]
    private var order: [ProviderID] = []

    public init() {}

    /// A second descriptor with the same id replaces the first.
    public func register(_ d: ProviderDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        if byID[d.id] == nil { order.append(d.id) }
        byID[d.id] = d
    }

    public func descriptor(_ id: ProviderID) -> ProviderDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return byID[id]
    }

    /// In the order of registration.
    public func descriptors(_ layer: Layer) -> [ProviderDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { byID[$0] }.filter { $0.layer == layer }
    }

    public func make(_ c: AccountConfig, environment: ProviderEnvironment) throws -> any Provider {
        guard let d = descriptor(c.account.provider) else { throw RegistryError.unknownProvider(c.account.provider) }
        return try d.make(c, environment)
    }
}

import Foundation
import OverSireAssistant
import OverSireCore

// The vendor CLI pass-through of `oversire vendor` (OVERSIRE-567). Only AppCalls calls it. Thus the assistant, the ⌘K
// palette, the member calls and the forwards of a client app never reach it: the local daemon is the only caller.
// The token goes to the child in its environment, never in argv, and the app removes it from the output.

enum VendorCallError: Error, Equatable {
    case client, noAccountGiven, bothGiven, unknownProject(String), unknownAccount(String), ambiguous([String]),
         noCLI(String), unusable(VendorBinary), noToken(String), badFolder(String), refused(VendorRefusal),
         unknownVendor(String, known: [String])

    var message: String {
        switch self {
        case .client: return "This Mac is a client. Run the command on the home Mac."
        case .noAccountGiven: return "Give --project or --account. Run oversire vendor ls."
        case .bothGiven: return "Give --project or --account, not both."
        case .unknownProject(let p): return "OverSire has no loaded project \(p)."
        case .unknownAccount(let a): return "OverSire has no account \(a)."
        case .ambiguous(let names):
            let id = names.first.map { String($0.drop { $0 != ":" }.dropFirst()) } ?? ""
            return "\(id) is \(names.joined(separator: " or ")). Give --account <provider>:<id>."
        case .noCLI(let tracker): return "\(tracker) has no vendor CLI in OverSire."
        case .unusable(let b): return b.problem ?? "OverSire can run \(b.binary)."
        case .noToken(let account): return "The Keychain has no token for \(account). Add it in Settings › Providers."
        case .badFolder(let p): return "The working folder \(p) does not exist."
        case .refused(let r): return r.message
        case .unknownVendor(let name, let known):
            guard let last = known.last else { return "OverSire has no vendor \(name)." }
            let list = known.count == 1 ? last : "\(known.dropLast().joined(separator: ", ")) or \(last)"
            return "OverSire has no vendor \(name). Give \(list)."
        }
    }
}

final class VendorCalls: @unchecked Sendable {
    static let actions: Set<String> = ["vendor.list", "vendor.run", "vendor.skill"]
    /// Under the 60 s that the daemon waits for an app call.
    static let timeout: Duration = .seconds(45)
    static let maxStdout = 1 << 20
    static let maxStderr = 64 << 10
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    /// The fixed part of each environment. The CLI gets nothing else, except its own keys.
    static let base: [String: String] = [
        "PATH": (searchPaths + ["/bin"]).joined(separator: ":"),
        "HOME": NSHomeDirectory(),
        "LANG": "en_US.UTF-8",
        "TMPDIR": NSTemporaryDirectory(),
        "NO_COLOR": "1",
        "TERM": "dumb",
    ]

    struct World: Sendable {
        /// True on a client Mac (ENV.mirrored).
        var isClient: @Sendable () -> Bool
        var accounts: @Sendable () -> [AccountConfig]
        var descriptor: @Sendable (ProviderID) -> ProviderDescriptor?
        /// The token of an account from the Keychain.
        var token: @Sendable (AccountConfig) -> String?
        var projects: @Sendable () async -> [(identifier: String, account: AccountID)]
        /// The first executable of a binary name in `searchPaths`.
        var find: @Sendable (String) -> String?
        var inherited: @Sendable () -> [String: String]
        /// The providers of the registry that have a `cli`.
        var vendors: @Sendable () -> [ProviderID] = { [] }
        /// The version that `<path> --version` gives.
        var version: @Sendable (String, VendorCLI) async -> VendorVersion? = { _, _ in nil }
    }

    typealias Resolved = (config: AccountConfig, descriptor: ProviderDescriptor, cli: VendorCLI, project: String?)

    private let world: World
    private let runner: any VendorProcessRunning
    private let events: EventDesk
    private let gate = AccountGate()

    init(world: World, runner: any VendorProcessRunning = VendorProcess(), events: EventDesk) {
        self.world = world
        self.runner = runner
        self.events = events
    }

    static func live(_ d: AppData) -> VendorCalls {
        let data = WeakData(d)
        let versions = VendorVersions(runner: VendorProcess())
        let world = World(
            isClient: { ENV.mirrored != nil },
            accounts: { ENV.accounts },
            descriptor: { ENV.registry.descriptor($0) },
            token: { c in ENV.secrets.secret(c.secretKeys.first ?? AppEnvironment.secretKey(c.account, field: "token")) },
            projects: {
                await MainActor.run {
                    (data.value?.projectStore.snapshots.values ?? [:].values).map { ($0.summary.identifier, $0.summary.ref.account) }
                }
            },
            find: { name in
                guard !name.contains("/") else { return nil }
                return searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
            },
            inherited: { ProcessInfo.processInfo.environment },
            vendors: { vendors(in: ENV.registry) },
            version: { await versions.version(of: $0, cli: $1) })
        return VendorCalls(world: world, events: EVENTS)
    }

    static func vendors(in registry: ProviderRegistry) -> [ProviderID] {
        Layer.allCases.flatMap { registry.descriptors($0) }.filter { $0.cli != nil }.map(\.id)
    }

    private final class WeakData: @unchecked Sendable {
        weak var value: AppData?
        init(_ v: AppData) { value = v }
    }

    /// Lets one call at a time run for each account (the Plane rate budget).
    private actor AccountGate {
        private var busy: Set<String> = []
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

        func enter(_ key: String) async {
            guard busy.contains(key) else {
                busy.insert(key)
                return
            }
            await withCheckedContinuation { waiting[key, default: []].append($0) }
        }

        func leave(_ key: String) {
            if var w = waiting[key], !w.isEmpty {
                let next = w.removeFirst()
                waiting[key] = w.isEmpty ? nil : w
                next.resume()
            } else {
                busy.remove(key)
            }
        }
    }

    // MARK: Calls

    func handle(_ call: AppCall) async -> AppCallResult {
        func notAllowed(_ e: VendorCallError) -> AppCallResult { AppCallResult(id: call.id, status: .notAllowed, summary: e.message) }
        switch call.action {
        case "vendor.list":
            if world.isClient() { return notAllowed(.client) }
            let rows = await list()
            return AppCallResult(id: call.id, status: .ok, summary: "\(rows.count) vendor CLI\(rows.count == 1 ? "" : "s").", data: JSONValue(encoding: rows))
        case "vendor.run":
            guard let a = try? JSONValue.decode(VendorRunArgs.self, from: call.args) else {
                return AppCallResult(id: call.id, status: .notAllowed, summary: "Give --project or --account, and the command after --.")
            }
            return await run(a, call: call)
        case "vendor.skill":
            let name = (try? JSONValue.decode(VendorSkillArgs.self, from: call.args))?.vendor ?? ""
            switch await skill(VendorSkillArgs(vendor: name)) {
            case .failure(let e): return notAllowed(e)
            case .success(let page):
                return AppCallResult(id: call.id, status: .ok, summary: page.summary, data: JSONValue(encoding: page.output))
            }
        default:
            return AppCallResult(id: call.id, status: .notAllowed, summary: "The app does not run \(call.action) from the CLI.")
        }
    }

    func list() async -> [VendorCLIRow] {
        let accounts = world.accounts()
        let projects = await world.projects()
        let providers = Set(accounts.map(\.account.provider)).filter { world.descriptor($0)?.cli != nil }
        let bins = await withTaskGroup(of: VendorBinary?.self) { g in
            for p in providers { g.addTask { await self.binary(p) } }
            var all: [ProviderID: VendorBinary] = [:]
            for await b in g { if let b { all[b.vendor] = b } }
            return all
        }
        return providers.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { provider in
            guard let d = world.descriptor(provider), let cli = d.cli, let b = bins[provider] else { return nil }
            return VendorCLIRow(
                provider: provider.rawValue, vendor: d.displayName, binary: cli.binary, path: b.path,
                version: b.version?.description, minVersion: cli.minVersion, source: b.source, state: b.state,
                accounts: accounts.filter { $0.account.provider == provider }.map { Self.name($0.account) }.sorted(),
                projects: projects.filter { $0.account.provider == provider }.map(\.identifier).sorted())
        }
    }

    /// The binary that vendor.run runs for a vendor, or nil when the vendor has no CLI.
    func binary(_ vendor: ProviderID) async -> VendorBinary? {
        guard let cli = world.descriptor(vendor)?.cli else { return nil }
        let path = world.find(cli.binary)
        var version: VendorVersion?
        if let path { version = await world.version(path, cli) }
        return VendorBinary(vendor: vendor, cli: cli, path: path, version: version, source: path == nil ? nil : .path)
    }

    /// A vendor id of the registry, with no case difference.
    func vendor(named name: String) -> Result<ProviderID, VendorCallError> {
        let all = world.vendors()
        if let p = all.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) { return .success(p) }
        return .failure(.unknownVendor(name, known: all.map(\.rawValue).sorted()))
    }

    /// The page of vendor.skill. A read: it writes no event.
    func skill(_ a: VendorSkillArgs) async -> Result<VendorSkillPage, VendorCallError> {
        if world.isClient() { return .failure(.client) }
        let provider: ProviderID
        switch vendor(named: a.vendor) {
        case .failure(let e): return .failure(e)
        case .success(let p): provider = p
        }
        guard let d = world.descriptor(provider), let cli = d.cli, let bin = await binary(provider) else {
            return .failure(.noCLI(world.descriptor(provider)?.displayName ?? provider.rawValue))
        }
        let accounts = world.accounts().filter { $0.account.provider == provider }.map { Self.name($0.account) }.sorted()
        let projects = await world.projects().filter { $0.account.provider == provider }.map(\.identifier).sorted()
        var text: String?
        if let exe = bin.path, cli.skillCommand != nil { text = await skillText(cli, exe: exe) }
        return .success(VendorSkillPage(vendor: provider, displayName: d.displayName, cli: cli, accounts: accounts,
                                        projects: projects, binary: bin, skillText: text))
    }

    /// The stdout of the skill command, or nil when the run fails or gives no text.
    private func skillText(_ cli: VendorCLI, exe: String) async -> String? {
        guard let args = cli.skillCommand else { return nil }
        let launch = VendorLaunch(exe: exe, args: args, environment: cli.skillEnvironment(base: Self.base), cwd: nil,
                                  timeout: Self.timeout, maxStdout: Self.maxStdout, maxStderr: Self.maxStderr,
                                  logWords: [cli.binary, "skill"])
        guard let exit = try? await runner.run(launch), !exit.timedOut, !exit.truncated, exit.status == 0 else { return nil }
        let text = Self.clean(exit.stdout, truncated: false, secrets: [])
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func name(_ a: AccountID) -> String { "\(a.provider.rawValue):\(a.id)" }

    func resolve(_ a: VendorRunArgs) async -> Result<Resolved, VendorCallError> {
        if world.isClient() { return .failure(.client) }
        let project = a.project.flatMap { $0.isEmpty ? nil : $0 }, account = a.account.flatMap { $0.isEmpty ? nil : $0 }
        let config: AccountConfig
        var identifier: String?
        switch (project, account) {
        case (nil, nil): return .failure(.noAccountGiven)
        case (.some, .some): return .failure(.bothGiven)
        case (let p?, nil):
            guard let found = await world.projects().first(where: { $0.identifier.caseInsensitiveCompare(p) == .orderedSame }) else {
                return .failure(.unknownProject(p))
            }
            guard let c = world.accounts().first(where: { $0.account == found.account }) else { return .failure(.unknownAccount(Self.name(found.account))) }
            config = c
            identifier = found.identifier
        case (nil, let name?):
            switch matchAccount(name) {
            case .failure(let e): return .failure(e)
            case .success(let c): config = c
            }
        }
        guard let d = world.descriptor(config.account.provider), let cli = d.cli else {
            return .failure(.noCLI(world.descriptor(config.account.provider)?.displayName ?? config.account.provider.rawValue))
        }
        return .success((config, d, cli, identifier))
    }

    /// `<provider>:<id>` or `<id>`. An id can hold a colon (a Big Timer server with a port).
    private func matchAccount(_ name: String) -> Result<AccountConfig, VendorCallError> {
        let all = world.accounts()
        let matches = all.filter { c in
            let id = c.account.id.lowercased(), provider = c.account.provider.rawValue.lowercased(), n = name.lowercased()
            return n == id || n == "\(provider):\(id)"
        }
        let withCLI = matches.filter { world.descriptor($0.account.provider)?.cli != nil }
        switch (matches.count, withCLI.count) {
        case (0, _): return .failure(.unknownAccount(name))
        case (_, 0): return .failure(.noCLI(world.descriptor(matches[0].account.provider)?.displayName ?? matches[0].account.provider.rawValue))
        case (_, 1): return .success(withCLI[0])
        default: return .failure(.ambiguous(withCLI.map { Self.name($0.account) }))
        }
    }

    private func run(_ a: VendorRunArgs, call: AppCall) async -> AppCallResult {
        func notAllowed(_ e: VendorCallError) -> AppCallResult { AppCallResult(id: call.id, status: .notAllowed, summary: e.message) }
        let r: Resolved
        switch await resolve(a) {
        case .failure(let e): return notAllowed(e)
        case .success(let v): r = v
        }
        let cli = r.cli, name = Self.name(r.config.account)
        if let refusal = cli.refusal(a.args, project: r.project != nil) { return notAllowed(.refused(refusal)) }
        guard let bin = await binary(r.config.account.provider) else { return notAllowed(.noCLI(r.descriptor.displayName)) }
        guard bin.state == .ok, let exe = bin.path else { return notAllowed(.unusable(bin)) }
        var token: String?
        if cli.tokenEnv != nil {
            guard let t = world.token(r.config), !t.isEmpty else { return notAllowed(.noToken(name)) }
            token = t
        }
        var cwd: URL?
        if let dir = a.cwd, !dir.isEmpty {
            var isDir: ObjCBool = false
            guard dir.hasPrefix("/"), FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return notAllowed(.badFolder(dir)) }
            cwd = URL(fileURLWithPath: dir)
        }
        let words = VendorCLI.summaryWords(a.args)
        let launch = VendorLaunch(
            exe: exe, args: a.args,
            environment: cli.environment(r.config, project: r.project, token: token, base: Self.base, inherited: world.inherited()),
            cwd: cwd, timeout: Self.timeout, maxStdout: Self.maxStdout, maxStderr: Self.maxStderr, logWords: [cli.binary] + words)
        await gate.enter(name)
        let exit: VendorExit
        do { exit = try await runner.run(launch) } catch {
            await gate.leave(name)
            let m = error is CancellationError ? "The call ended." : "OverSire could not start \(cli.binary): \(error.localizedDescription)"
            return AppCallResult(id: call.id, status: .failed, summary: m)
        }
        await gate.leave(name)
        let secrets = token.map { [$0] } ?? []
        let out = VendorRunOutput(
            vendor: cli.binary, account: name, exit: Int(exit.status),
            stdout: Self.clean(exit.stdout, truncated: exit.truncated, secrets: secrets),
            stderr: Self.clean(exit.stderr, truncated: exit.truncated, secrets: secrets),
            truncated: exit.truncated ? true : nil, timedOut: exit.timedOut ? true : nil, ms: exit.ms)
        record(call, out, words: words, project: r.project)
        let data = JSONValue(encoding: out)
        if exit.timedOut {
            let secs = Int(Self.timeout.components.seconds)
            return AppCallResult(id: call.id, status: .failed,
                                 summary: "\(cli.binary) did not end in \(secs) s. The app stopped it. A change can be made already.", data: data)
        }
        return AppCallResult(id: call.id, status: .ok, summary: "\(cli.binary) exit \(exit.status).", data: data)
    }

    /// One `vendor.call` row. The summary and the payload have the subcommand words, never the args.
    private func record(_ call: AppCall, _ out: VendorRunOutput, words: [String], project: String?) {
        let actor = ActionCaller.cli(agent: call.agent).actor
        var payload: [String: JSONValue] = ["vendor": .string(out.vendor), "account": .string(out.account), "command": .string(words.joined(separator: " ")),
                                            "exit": .int(out.exit), "ms": .int(out.ms)]
        if out.truncated == true { payload["truncated"] = .bool(true) }
        if out.timedOut == true { payload["timedOut"] = .bool(true) }
        let summary = "\(([out.vendor] + words).joined(separator: " ")), exit \(out.exit)"
        let events = events
        DispatchQueue.main.async {
            events.action(.vendorCall, item: nil, project: project, verb: "vendor:\(call.id)", summary, payload: payload,
                          actorType: actor.type, actor: actor.name, via: actor.via)
        }
    }

    /// Removes each secret value and the vendor token shapes. A cut stream also loses its last (longest secret - 1)
    /// bytes, so no part of a token stays.
    static func clean(_ out: Data, truncated: Bool, secrets: [String]) -> String {
        var data = out
        if truncated, let longest = secrets.map({ $0.utf8.count }).max(), longest > 1 { data = data.dropLast(longest - 1) }
        return Redactor(secrets: secrets).redact(String(decoding: data, as: UTF8.self))
    }
}

extension JSONValue {
    /// Decodes a value of `T` from a JSON value.
    static func decode<T: Decodable>(_ type: T.Type, from v: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(v))
    }
}

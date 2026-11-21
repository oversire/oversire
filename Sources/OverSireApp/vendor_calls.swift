import Foundation
import OverSireAssistant
import OverSireCore

// The vendor CLI pass-through of `oversire vendor` (OVERSIRE-567). Only AppCalls calls it. Thus the assistant, the ⌘K
// palette, the member calls and the forwards of a client app never reach it: the local daemon is the only caller.
// The token goes to the child in its environment, never in argv, and the app removes it from the output.

enum VendorCallError: Error, Equatable {
    case client, noAccountGiven, bothGiven, unknownProject(String), unknownAccount(String), ambiguous([String]),
         noCLI(String), unusable(VendorBinary), noToken(String), badFolder(String), refused(VendorRefusal),
         unknownVendor(String, known: [String]), busy(String, VendorJob), failed(String)

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
        case .busy(let binary, let job):
            return "\(job == .installing ? "An install" : "A remove") of \(binary) runs. Try again when it ends."
        case .failed(let m): return m
        }
    }
}

final class VendorCalls: @unchecked Sendable {
    static let actions: Set<String> = ["vendor.list", "vendor.run", "vendor.skill", "vendor.install", "vendor.remove"]
    /// Under the 60 s that the daemon waits for an app call. A longer install goes on in the app.
    static let installWait: Duration = .seconds(50)
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
        /// The OverSire copy of a vendor binary: (vendor, binary name).
        var own: @Sendable (ProviderID, String) -> String? = { _, _ in nil }
        /// An install or a remove ended.
        var changed: @Sendable () -> Void = {}
    }

    typealias Resolved = (config: AccountConfig, descriptor: ProviderDescriptor, cli: VendorCLI, project: String?)

    private let world: World
    private let runner: any VendorProcessRunning
    private let events: EventDesk
    private let gate = AccountGate()
    private let installer: (any VendorInstalling)?
    private let jobs: VendorJobs
    var installWait = VendorCalls.installWait

    init(world: World, runner: any VendorProcessRunning = VendorProcess(), installer: (any VendorInstalling)? = nil, events: EventDesk) {
        self.world = world
        self.runner = runner
        self.installer = installer
        self.jobs = VendorJobs(changed: world.changed)
        self.events = events
    }

    static func live(_ d: AppData) -> VendorCalls {
        let data = WeakData(d)
        let versions = VendorVersions(runner: VendorProcess())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let installer = VendorInstaller(http: URLSessionTransport(), commands: ProcessRunner(),
                                        probe: { await versions.version(of: $0, cli: $1) }, userAgent: "OverSire/\(version)")
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
            version: { await versions.version(of: $0, cli: $1) },
            own: { installer.ownCopy($0, binary: $1) },
            changed: { DispatchQueue.main.async { ChangeBus.shared.post(DataChange(.connection, origin: .event)) } })
        return VendorCalls(world: world, installer: installer, events: EVENTS)
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
        case "vendor.install", "vendor.remove":
            guard let a = try? JSONValue.decode(VendorActionArgs.self, from: call.args), !a.vendor.isEmpty else {
                return AppCallResult(id: call.id, status: .notAllowed, summary: "Give one vendor id, for example plane.")
            }
            let caller = ActionCaller.cli(agent: call.agent)
            let o = call.action == "vendor.install" ? await install(a.vendor, caller: caller) : await remove(a.vendor, caller: caller)
            return AppCallResult(id: call.id, status: o.status, summary: o.summary, data: o.change.flatMap { JSONValue(encoding: $0) })
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
        var running: [ProviderID: VendorJob] = [:]
        for p in providers { running[p] = await jobs.current(p) }
        return providers.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { provider in
            guard let d = world.descriptor(provider), let cli = d.cli, let b = bins[provider] else { return nil }
            return VendorCLIRow(
                provider: provider.rawValue, vendor: d.displayName, binary: cli.binary, path: b.path,
                version: b.version?.description, minVersion: cli.minVersion, source: b.source, state: b.state,
                accounts: accounts.filter { $0.account.provider == provider }.map { Self.name($0.account) }.sorted(),
                projects: projects.filter { $0.account.provider == provider }.map(\.identifier).sorted(),
                ownVersion: b.ownVersion?.description, job: running[provider])
        }
    }

    /// The binary that vendor.run runs for a vendor, or nil when the vendor has no CLI.
    func binary(_ vendor: ProviderID) async -> VendorBinary? {
        guard let cli = world.descriptor(vendor)?.cli else { return nil }
        let ownPath = world.own(vendor, cli.binary)
        var ownVersion: VendorVersion?
        if let ownPath { ownVersion = await world.version(ownPath, cli) }
        let own = VendorBinary(vendor: vendor, cli: cli, path: ownPath, version: ownVersion, source: ownPath == nil ? nil : .oversire)
        // An ok OverSire copy wins: no probe of the PATH copy.
        let path = own.state == .ok ? nil : world.find(cli.binary)
        var version: VendorVersion?
        if let path { version = await world.version(path, cli) }
        return VendorBinary.prefer(own: own, path: VendorBinary(vendor: vendor, cli: cli, path: path, version: version, source: path == nil ? nil : .path))
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

// MARK: Install and remove (OVERSIRE-582)

struct VendorOutcome: Sendable {
    let status: AppCallResult.Status
    let summary: String
    let change: VendorChange?

    static func refused(_ e: VendorCallError) -> VendorOutcome { VendorOutcome(status: .notAllowed, summary: e.message, change: nil) }
}

/// One install or remove at a time for each vendor. A second call of the same kind joins the job.
private actor VendorJobs {
    private var jobs: [ProviderID: (kind: VendorJob, task: Task<VendorChange, Error>)] = [:]
    private let changed: @Sendable () -> Void

    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }

    func start(_ v: ProviderID, _ kind: VendorJob, binary: String,
               _ work: @escaping @Sendable () async throws -> VendorChange) -> Result<Task<VendorChange, Error>, VendorCallError> {
        if let j = jobs[v] { return j.kind == kind ? .success(j.task) : .failure(.busy(binary, j.kind)) }
        // The task ends on this actor, after start returns.
        let task = Task<VendorChange, Error> {
            do {
                let c = try await work()
                await self.end(v)
                return c
            } catch {
                await self.end(v)
                throw error
            }
        }
        jobs[v] = (kind, task)
        return .success(task)
    }

    func current(_ v: ProviderID) -> VendorJob? { jobs[v]?.kind }

    private func end(_ v: ProviderID) {
        jobs[v] = nil
        changed()
    }
}

/// Resumes once: with the first value of the job or of the timer.
private final class FirstOf<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?

    init(_ c: CheckedContinuation<T, Never>) { cont = c }

    func resume(_ v: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            defer { cont = nil }
            return cont
        }
        c?.resume(returning: v)
    }
}

extension VendorCalls {
    private enum Target {
        case ok(ProviderID, VendorCLI, any VendorInstalling)
        case refused(VendorCallError)
    }

    private func target(_ name: String, removeText: Bool) -> Target {
        if world.isClient() { return .refused(.client) }
        let vendor: ProviderID
        switch self.vendor(named: name) {
        case .failure(let e): return .refused(e)
        case .success(let v): vendor = v
        }
        guard let cli = world.descriptor(vendor)?.cli else { return .refused(.noCLI(vendor.rawValue)) }
        if case .homebrew(let f)? = cli.release {
            return .refused(.failed(removeText ? "OverSire does not install \(f). Remove it with Homebrew: `brew uninstall \(f)`."
                                               : VendorInstallError.noInstall(formula: f).description))
        }
        guard cli.release != nil, let installer else { return .refused(.failed("OverSire does not install \(cli.binary).")) }
        return .ok(vendor, cli, installer)
    }

    /// The release that an install takes. It makes no download of the archive.
    func offer(_ vendor: ProviderID) async -> Result<VendorOffer, VendorCallError> {
        switch target(vendor.rawValue, removeText: false) {
        case .refused(let e): return .failure(e)
        case .ok(let v, let cli, let installer):
            do { return .success(try await installer.offer(v, cli)) } catch { return .failure(.failed(Self.text(error))) }
        }
    }

    func install(_ name: String, caller: ActionCaller) async -> VendorOutcome {
        let vendor: ProviderID, cli: VendorCLI, installer: any VendorInstalling
        switch target(name, removeText: false) {
        case .refused(let e): return .refused(e)
        case .ok(let v, let c, let i): (vendor, cli, installer) = (v, c, i)
        }
        let started = await jobs.start(vendor, .installing, binary: cli.binary) {
            try await self.installJob(vendor, cli, installer, caller: caller)
        }
        let task: Task<VendorChange, Error>
        switch started {
        case .failure(let e): return .refused(e)
        case .success(let t): task = t
        }
        let wait = installWait
        let first: Result<VendorChange, Error>? = await withCheckedContinuation { c in
            let once = FirstOf<Result<VendorChange, Error>?>(c)
            Task {
                do { once.resume(.success(try await task.value)) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: wait)
                once.resume(nil)
            }
        }
        switch first {
        case nil:
            return VendorOutcome(status: .failed, summary: "The install of \(cli.binary) goes on in the app. Run `oversire vendor ls` in one minute.", change: nil)
        case .failure(let e)?:
            return VendorOutcome(status: .failed, summary: Self.text(e), change: nil)
        case .success(let c)?:
            let v = c.version ?? ""
            let summary: String
            switch c.action {
            case .updated: summary = "Updated \(c.binary) from \(c.previous ?? "") to \(v)."
            case .unchanged: summary = "\(c.binary) \(v) is installed. It is the newest version."
            default:
                let dir = c.path.map { NSString(string: ($0 as NSString).deletingLastPathComponent).abbreviatingWithTildeInPath } ?? ""
                summary = "Installed \(c.binary) \(v) in \(dir)."
            }
            return VendorOutcome(status: .ok, summary: summary, change: c)
        }
    }

    private func installJob(_ vendor: ProviderID, _ cli: VendorCLI, _ installer: any VendorInstalling, caller: ActionCaller) async throws -> VendorChange {
        let offer = try await installer.offer(vendor, cli)
        var previous: VendorVersion?
        let ownPath = world.own(vendor, cli.binary)
        if let ownPath { previous = await world.version(ownPath, cli) }
        if previous == offer.version, let ownPath {
            return VendorChange(vendor: vendor.rawValue, binary: cli.binary, action: .unchanged, version: offer.version.description,
                                path: ownPath, release: offer.release)
        }
        let path = try await installer.install(vendor, cli, offer)
        let change = VendorChange(vendor: vendor.rawValue, binary: cli.binary, action: previous == nil ? .installed : .updated,
                                  version: offer.version.description, previous: previous?.description, path: path, release: offer.release)
        record(.vendorInstalled, change, caller: caller, sha256: offer.sha256)
        return change
    }

    func remove(_ name: String, caller: ActionCaller) async -> VendorOutcome {
        let vendor: ProviderID, cli: VendorCLI, installer: any VendorInstalling
        switch target(name, removeText: true) {
        case .refused(let e): return .refused(e)
        case .ok(let v, let c, let i): (vendor, cli, installer) = (v, c, i)
        }
        let started = await jobs.start(vendor, .removing, binary: cli.binary) {
            guard self.world.own(vendor, cli.binary) != nil else {
                return VendorChange(vendor: vendor.rawValue, binary: cli.binary, action: .unchanged)
            }
            let gone = try installer.remove(vendor)
            let change = VendorChange(vendor: vendor.rawValue, binary: cli.binary, action: .removed, version: gone.max()?.description)
            self.record(.vendorRemoved, change, caller: caller)
            return change
        }
        let change: VendorChange
        switch started {
        case .failure(let e): return .refused(e)
        case .success(let t):
            do { change = try await t.value } catch { return VendorOutcome(status: .failed, summary: Self.text(error), change: nil) }
        }
        guard change.action == .removed else {
            return VendorOutcome(status: .ok, summary: "OverSire has no copy of \(cli.binary). Nothing to remove.", change: change)
        }
        let removed = "Removed the OverSire copy of \(cli.binary)\(change.version.map { " \($0)" } ?? "")."
        if let now = await binary(vendor), now.state == .ok, let p = now.path {
            return VendorOutcome(status: .ok, summary: "\(removed) OverSire now uses \(p)\(now.version.map { " \($0)" } ?? "").", change: change)
        }
        return VendorOutcome(status: .ok, summary: "\(removed) `vendor run` refuses \(vendor.rawValue) until you install it again.", change: change)
    }

    /// The PATH copy of a vendor binary, also when the OverSire copy wins. The remove question names it.
    func pathCopy(_ vendor: ProviderID) async -> VendorBinary? {
        guard let cli = world.descriptor(vendor)?.cli, let path = world.find(cli.binary) else { return nil }
        return VendorBinary(vendor: vendor, cli: cli, path: path, version: await world.version(path, cli), source: .path)
    }

    /// One vendor.installed or vendor.removed row.
    private func record(_ kind: Event.Kind, _ change: VendorChange, caller: ActionCaller, sha256: String? = nil) {
        let actor = caller.actor
        let v = change.version ?? ""
        var payload: [String: JSONValue] = ["vendor": .string(change.vendor), "binary": .string(change.binary), "version": .string(v)]
        if kind == .vendorInstalled {
            if let p = change.previous { payload["previous"] = .string(p) }
            if let r = change.release { payload["release"] = .string(r) }
            if let sha256 { payload["sha256"] = .string(sha256) }
        }
        let summary: String
        switch change.action {
        case .updated: summary = "Updated \(change.binary) from \(change.previous ?? "") to \(v)"
        case .removed: summary = "Removed \(change.binary) \(v)"
        default: summary = "Installed \(change.binary) \(v)"
        }
        let events = events
        DispatchQueue.main.async {
            events.action(kind, item: nil, verb: "vendor-\(change.action.rawValue):\(change.vendor)", summary, payload: payload,
                          actorType: actor.type, actor: actor.name, via: actor.via)
        }
    }

    static func text(_ error: Error) -> String {
        switch error {
        case let e as VendorInstallError: return e.description
        case let e as InstallError: return e.description
        case let e as ProviderError: return "\(e)"
        default: return error.localizedDescription
        }
    }
}

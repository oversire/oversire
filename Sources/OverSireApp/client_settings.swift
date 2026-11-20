import Foundation
import OverSireCore
import OverSireSync

// The shared settings on a client (OVERSIRE-529). The home settings come from the mirror and sit over the config.
// A change to a shared section goes to the source app as `settings.patch`. A conflict puts back the home value.

final class ClientSettings: @unchecked Sendable {
    enum SaveState: Equatable {
        case idle, saving, conflict
        case failed(String)
    }

    typealias Call = @Sendable (MemberCallRequest) async throws -> AppCallResult

    static let shared = ClientSettings()

    /// Sends a call to the source app. Set when the client connects.
    var call: Call?
    /// The name of the source Mac, for the texts.
    var sourceName: @Sendable () -> String = { "home" }
    /// Runs after a patch that worked. The client pulls the mirror then.
    var sent: @Sendable () -> Void = {}
    /// Runs after each change of the state or of the home value. It is called on any thread.
    var changed: @Sendable () -> Void = { ChangeBus.shared.post(.config(.event)) }
    var cached: () -> JSONValue? = { MirrorCache(dir: MIRROR_DIR).settings() }
    var current: () -> HomeSettings = { homeSettings(from: currentConfig()) }
    var adopt: (HomeSettings) -> Void = { h in
        var c = currentConfig()
        apply(h, to: &c)
        adoptShared(c)
    }

    private let lock = NSLock()
    private var _home: HomeSettings?
    private var _state = SaveState.idle
    private var _held = Set<SettingsSection>()
    private var _flying = Set<SettingsSection>()

    /// The last settings of the home Mac.
    var home: HomeSettings? { lock.withLock { _home } }
    var state: SaveState { lock.withLock { _state } }
    /// The accounts of the home Mac, for Settings › Accounts and sync.
    var accounts: [AccountSummary] { home?.accounts ?? [] }

    /// Forgets all. For tests and for a home move.
    func reset() {
        lock.withLock {
            _home = nil
            _state = .idle
            _held = []
            _flying = []
        }
    }

    /// Sets the home value and the state, for the shots.
    func seed(_ h: HomeSettings?, state: SaveState) {
        lock.withLock {
            _home = h
            _state = state
        }
    }

    /// Lays the cached home settings over a config. The local sections stay.
    func overlay(_ c: inout AppConfig) {
        guard let body = cached(), let h = Self.decode(body) else { return }
        lock.withLock { _home = h }
        apply(h, to: &c)
    }

    private static func decode(_ body: JSONValue) -> HomeSettings? {
        guard let h = try? MirrorCodec.value(HomeSettings.self, from: body), h.v <= HomeSettings.version else { return nil }
        return h
    }

    /// A new home value from the mirror. A section with a change that is not saved yet keeps the local value.
    func received(_ body: JSONValue) {
        guard let h = Self.decode(body) else { return }
        let keep = lock.withLock { () -> Set<SettingsSection> in
            _home = h
            if _held.isEmpty, case .failed = _state { _state = .idle }
            return _held
        }
        var merged = h
        if !keep.isEmpty {
            let mine = current()
            for s in keep { merged = merged.adopting(s, from: mine) }
        }
        adopt(merged)
        changed()
    }

    /// Sends each shared section that differs from the home value. Called after each save of a client.
    func sync() {
        guard let call else { return }
        guard let home else {
            lock.withLock { _state = .failed(Self.noAnswer(sourceName())) }
            changed()
            return
        }
        let now = current()
        let todo = lock.withLock { () -> [SettingsSection] in
            let list = now.changed(since: home).filter { !_flying.contains($0) }
            _flying.formUnion(list)
            _held.formUnion(list)
            if !list.isEmpty { _state = .saving }
            return list
        }
        guard !todo.isEmpty else { return }
        changed()
        for s in todo {
            let base = home.hashes[s.rawValue] ?? ""
            let value = now.value(s)
            Task { await self.send(s, value, base: base, now: now, call: call) }
        }
    }

    /// The user taps "Try again". The held sections go again.
    func retry() {
        lock.withLock { if case .failed = _state { _state = .idle } }
        sync()
    }

    /// The user closed the conflict banner.
    func dismiss() {
        lock.withLock { _state = .idle }
        changed()
    }

    static func noAnswer(_ name: String) -> String { "\(name) did not answer. Try again." }

    private enum End {
        case saved, conflict
        case failed(String)
    }

    private func send(_ s: SettingsSection, _ value: JSONValue, base: String, now: HomeSettings, call: Call) async {
        let req = MemberCallRequest(action: "settings.patch", args: .object(["section": .string(s.rawValue), "value": value, "baseHash": .string(base)]))
        let end: End
        do {
            let r = try await call(req)
            switch r.status {
            case .ok: end = .saved
            case .failed where r.data?["conflict"]?.bool == true: end = .conflict
            case .failed, .notAllowed: end = .failed(r.summary)
            }
        } catch let e as ProviderError {
            if case .transport = e { end = .failed(Self.noAnswer(sourceName())) } else { end = .failed(e.message) }
        } catch {
            end = .failed(Self.noAnswer(sourceName()))
        }
        finish(s, end, now: now)
    }

    private func finish(_ s: SettingsSection, _ end: End, now: HomeSettings) {
        let known = lock.withLock { () -> HomeSettings? in
            _flying.remove(s)
            switch end {
            case .saved:
                _held.remove(s)
                _home = _home?.adopting(s, from: now)
                if _flying.isEmpty, _state == .saving { _state = .idle }
            case .conflict:
                _held.remove(s)
                _state = .conflict
            case .failed(let text):
                _state = .failed(text)
            }
            return _home
        }
        switch end {
        case .saved:
            sent()
            sync()
        case .conflict:
            if let known { adopt(current().adopting(s, from: known)) }
            sent()
        case .failed: break
        }
        changed()
    }
}

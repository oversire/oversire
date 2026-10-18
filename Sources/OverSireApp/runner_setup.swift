import Cocoa
import OverSireCore

/// The local runner: its status, and "Use this Mac as the runner". Main thread only.
final class RunnerSetup {
    static let shared = RunnerSetup()
    static let changed = Notification.Name("RunnerSetupChanged")
    private static let offeredKey = "runnerOffered"

    let installer = RunnerInstaller(http: URLSessionTransport(), commands: ProcessRunner())
    private(set) var local: RunnerStatus?
    private(set) var busy = false
    private(set) var error: String?
    private var loaded = false

    var statusText: String {
        if busy { return "Installing…" }
        if let error { return error }
        return local?.summary ?? (installer.isInstalled ? "Installed" : "Not installed")
    }

    func refresh() {
        guard !busy else { return }
        Task { @MainActor in
            self.local = try? await self.installer.status()
            self.loaded = true
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    /// Asks one time, when Orca runs on this Mac and no runner is paired.
    func offerOnce(records: CloudAIRecords) {
        let orca = PROJECTS_CFG.orca
        guard !UserDefaults.standard.bool(forKey: Self.offeredKey), records.runners.isEmpty, !installer.isInstalled,
              orca.enabled, orca.environment == nil, FileManager.default.isExecutableFile(atPath: orca.cli) else { return }
        UserDefaults.standard.set(true, forKey: Self.offeredKey)
        DispatchQueue.main.async { self.offer() }
    }

    func offer() {
        guard !busy else { return }
        let a = NSAlert()
        a.messageText = "Make this Mac the runner?"
        a.informativeText = "The runner starts the Orca sessions of the suggestions that you accept, also when you accept them on the phone. It takes only typed orders that your allow list permits. Edit the list in ~/.config/oversire-runner/allow.json."
        a.addButton(withTitle: "Use this Mac")
        a.addButton(withTitle: "Not now")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Keep this Mac awake on power while orders wait"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        install(keepAwake: a.suppressionButton?.state == .on)
    }

    private func install(keepAwake: Bool) {
        busy = true
        error = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        let api = RelayAPI(base: RELAY.workerURL, token: SecretStore().get(SecretStore.deviceToken))
        let name = Host.current().localizedName ?? "Mac"
        Task { @MainActor in
            do {
                self.local = try await self.installer.install(hub: RELAY.workerURL, name: name, keepAwake: keepAwake) {
                    try await Task.detached { try api.runnerCode().get().code }.value
                }
                log.info("Runner: installed and paired")
            } catch {
                self.error = "Install failed: \(error)"
                log.error("Runner: \(String(describing: error), privacy: .public)")
            }
            self.busy = false
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    var needsLoad: Bool { !loaded }
}

/// The local runner row of the Cloud AI card.
final class RunnerSetupRow: Row {
    private let status = NSTextField.text("", size: 12, color: Palette.dim)
    private let button = ActionButton("Use this Mac")
    private var observer: Any?

    init() {
        let glyph = Glyph("desktopcomputer", color: Palette.dim, size: 13)
        glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
        super.init([glyph, TwoLine("This Mac", "Run the work orders here, with the runner as a login item."), Spacer(), status, button],
                   height: 52)
        button.onClick = { RunnerSetup.shared.offer() }
        observer = NotificationCenter.default.addObserver(forName: RunnerSetup.changed, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
        update()
        if RunnerSetup.shared.needsLoad { RunnerSetup.shared.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func update() {
        let s = RunnerSetup.shared
        status.stringValue = s.statusText
        button.isHidden = s.local?.paired == true
        button.isEnabled = !s.busy
        setAccessibilityLabel("This Mac. \(s.statusText)")
    }
}

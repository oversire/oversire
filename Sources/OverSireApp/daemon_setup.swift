import Cocoa
import OverSireCore

/// The local daemon: its status, and "Use this Mac as the runner". Main thread only.
final class DaemonSetup {
    static let shared = DaemonSetup()
    static let changed = Notification.Name("DaemonSetupChanged")
    private static let updateOfferedKey = "daemonUpdateOffered"

    let installer = DaemonInstaller(http: URLSessionTransport(), commands: ProcessRunner())
    private(set) var local: DaemonStatus?
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

    /// Asks one time to replace an old oversire-runner install with the oversire CLI.
    func offerUpdateOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.updateOfferedKey), !installer.isInstalled,
              FileManager.default.fileExists(atPath: DaemonInstaller.legacyConfig.path) else { return }
        UserDefaults.standard.set(true, forKey: Self.updateOfferedKey)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let r = AlertConfirm.run(.init(title: "Update the OverSire runner?",
                                           info: "oversire-runner is now the oversire CLI. The update keeps the pairing, the allow list and the orders, and starts the OverSire daemon in place of the runner.",
                                           buttons: ["Update", "Not now"]))
            guard r.button == 0 else { return }
            self.install(keepAwake: false, pair: false)
        }
    }

    func offer() {
        guard !busy else { return }
        NSApp.activate(ignoringOtherApps: true)
        let r = AlertConfirm.run(.init(title: "Make this Mac the runner?",
                                       info: "The runner starts the Orca sessions of the suggestions that you accept, also when you accept them on the phone. It takes only typed orders that your allow list permits. Edit the list in ~/.config/oversire/daemon/allow.json.",
                                       buttons: ["Use this Mac", "Not now"], suppression: "Keep this Mac awake on power while orders wait"))
        guard r.button == 0 else { return }
        install(keepAwake: r.checked, pair: true)
    }

    func install(keepAwake: Bool, pair: Bool) {
        busy = true
        error = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        let api = RelayAPI(base: RELAY.workerURL, token: SecretStore().get(SecretStore.deviceToken))
        let name = Host.current().localizedName ?? "Mac"
        Task { @MainActor in
            do {
                let pairing = pair ? DaemonInstaller.Pairing(hub: RELAY.workerURL, name: name) {
                    try await Task.detached { try api.runnerCode().get().code }.value
                } : nil
                self.local = try await self.installer.install(keepAwake: keepAwake, pairing: pairing)
                log.info("Daemon: installed\(pair ? " and paired" : "")")
            } catch {
                self.error = "Install failed: \(error)"
                log.error("Daemon: \(String(describing: error), privacy: .public)")
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
        super.init([glyph, TwoLine("This Mac", "Run the work orders here, with the OverSire daemon as a login item."), Spacer(), status, button],
                   height: 52)
        button.onClick = { DaemonSetup.shared.offer() }
        observer = NotificationCenter.default.addObserver(forName: DaemonSetup.changed, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
        update()
        if DaemonSetup.shared.needsLoad { DaemonSetup.shared.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func update() {
        let s = DaemonSetup.shared
        status.stringValue = s.statusText
        button.isHidden = s.local?.paired == true && s.local?.roles?.contains("runner") != false
        button.isEnabled = !s.busy
        setAccessibilityLabel("This Mac. \(s.statusText)")
    }
}

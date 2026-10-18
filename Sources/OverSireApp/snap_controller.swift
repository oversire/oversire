import Cocoa
import OverSireCore

// ─── Snap Basket ─────────────────────────────────────────────────────────────
// Owns the store, the capture, the two shortcuts and the panels.

final class SnapController {
    let store: SnapStore
    private(set) lazy var capturer = SnapCapturer(guess: { [weak self] in self?.guess() ?? SnapProjectGuess([]) },
                                                  onShot: { [weak self] in self?.taken($0, png: $1) })
    private var snapHotKey: GlobalHotKey?
    private var basketHotKey: GlobalHotKey?
    private let projects: () -> [ProjectSummary]

    init(store: SnapStore = SnapStore(), projects: @escaping () -> [ProjectSummary]) {
        self.store = store
        self.projects = projects
        store.purge(olderThan: Date().addingTimeInterval(-Double(PROJECTS_CFG.capture.snap.keepDays) * 86_400))
    }

    var cfg: SnapConfig { PROJECTS_CFG.capture.snap }
    var snapShortcut: KeyShortcut { KeyShortcut(keyCode: cfg.keyCode, modifiers: cfg.modifiers) }
    var basketShortcut: KeyShortcut { KeyShortcut(keyCode: cfg.basketKeyCode, modifiers: cfg.basketModifiers) }

    /// Registers both shortcuts again. Returns the labels that macOS did not accept.
    @discardableResult
    func applyHotKeys() -> [String] {
        suspendHotKeys(true)
        guard cfg.enabled else { return [] }
        var failed: [String] = []
        if snapShortcut.hasShortcut {
            snapHotKey = GlobalHotKey(keyCode: cfg.keyCode, modifiers: cfg.modifiers) { [weak self] in self?.snap() }
            if snapHotKey == nil { failed.append(snapShortcut.shortcutLabel) }
        }
        if basketShortcut.hasShortcut {
            basketHotKey = GlobalHotKey(keyCode: cfg.basketKeyCode, modifiers: cfg.basketModifiers) { [weak self] in self?.toggleBasket() }
            if basketHotKey == nil { failed.append(basketShortcut.shortcutLabel) }
        }
        for f in failed { log.warning("Snap shortcut \(f, privacy: .public) is not available") }
        return failed
    }

    func suspendHotKeys(_ on: Bool) {
        if on {
            snapHotKey?.unregister(); snapHotKey = nil
            basketHotKey?.unregister(); basketHotKey = nil
        } else {
            applyHotKeys()
        }
    }

    func snap() { capturer.start() }

    func toggleBasket() {}

    private func guess() -> SnapProjectGuess { SnapProjectGuess(projects: projects(), cfg: PROJECTS_CFG) }

    private func taken(_ shot: SnapShot, png: Data) {
        do {
            try store.add(shot, png: png)
        } catch {
            log.error("Snap: OverSire could not save the shot: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}

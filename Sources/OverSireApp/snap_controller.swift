import Cocoa
import OverSireCore

// ─── Snap Basket ─────────────────────────────────────────────────────────────
// Owns the store, the capture, the two shortcuts and the panels.

final class SnapController {
    let store: SnapStore
    private(set) lazy var capturer = SnapCapturer(guess: { [weak self] in self?.guess() ?? SnapProjectGuess([]) },
                                                  onShot: { [weak self] in self?.taken($0, png: $1, near: $2) })
    private var snapHotKey: GlobalHotKey?
    private var basketHotKey: GlobalHotKey?
    private let projects: () -> [ProjectSummary]
    private var editor: ShotEditorPanel?

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

    private var choices: [SnapProjectChoice] {
        projects().map { SnapProjectChoice(key: $0.identifier, title: $0.title) }
    }

    /// The open basket in view: the one of the last project, else the newest one.
    private var currentBasket: SnapBasket? {
        let open = store.openBaskets
        if let l = cfg.lastProject, let b = open.first(where: { $0.project == l }) { return b }
        return open.first
    }

    private func taken(_ shot: SnapShot, png: Data, near: CGRect) {
        guard let img = NSBitmapImageRep(data: png)?.cgImage else { return NSSound.beep() }
        editor?.close()
        let b = currentBasket
        let model = SnapEditorModel(shot: shot, basketProject: b?.project, basketCount: b?.shots.count ?? 0, lastProject: cfg.lastProject)
        var a = ShotEditorPanel.Actions()
        a.add = { [weak self] s, again in self?.add(s, png: png, again: again) }
        a.closed = { [weak self] in self?.editor = nil }
        show(ShotEditorPanel(model: model, image: img, projects: choices, near: near, actions: a))
    }

    /// Opens a shot of a basket again, to change its marks and notes.
    func edit(_ shot: SnapShot, in basket: SnapBasket) {
        guard let png = store.png(of: shot.id, in: basket.id), let img = NSBitmapImageRep(data: png)?.cgImage else { return NSSound.beep() }
        editor?.close()
        let model = SnapEditorModel(shot: shot, existing: true, basketProject: basket.project, basketCount: basket.shots.count, lastProject: nil)
        var a = ShotEditorPanel.Actions()
        a.save = { [weak self] s in self?.save(s, in: basket.id) }
        a.remove = { [weak self] s in self?.attempt { try self?.store.remove(shot: s.id) } }
        a.closed = { [weak self] in self?.editor = nil }
        show(ShotEditorPanel(model: model, image: img, projects: choices, near: nil, actions: a))
    }

    private func show(_ p: ShotEditorPanel) {
        editor = p
        p.present()
    }

    private func add(_ s: SnapShot, png: Data, again: Bool) {
        attempt { _ = try store.add(s, png: png) }
        PROJECTS_CFG.capture.snap.lastProject = s.project
        saveConfig()
        if again { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.snap() } }
    }

    private func save(_ s: SnapShot, in basket: String) {
        guard var b = store.basket(basket), let i = b.shots.firstIndex(where: { $0.id == s.id }) else { return }
        b.shots[i] = s
        attempt { try store.update(b) }
    }

    private func attempt(_ f: () throws -> Void) {
        do { try f() } catch {
            log.error("Snap: OverSire could not save the shot: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}

import Cocoa
import OverSireCore

// ─── Snap Basket ─────────────────────────────────────────────────────────────
// Owns the store, the capture, the two shortcuts and the panels.

final class SnapController {
    let store: SnapStore
    private(set) lazy var capturer: SnapCapturer = {
        let c = SnapCapturer(guess: { [weak self] in self?.guess() ?? SnapProjectGuess([]) },
                             onShot: { [weak self] in self?.taken($0, png: $1, near: $2) })
        c.onEnd = { [weak self] in if self?.editor == nil { self?.panel.suspend(false) } }
        return c
    }()
    private(set) lazy var panel: BasketPanel = {
        var a = BasketPanel.Actions()
        a.edit = { [weak self] s, b in self?.edit(s, in: b) }
        a.send = { [weak self] b, mode in self?.send(b, mode: mode) }
        a.snap = { [weak self] in self?.snap() }
        a.copy = { [weak self] id in if let b = self?.store.basket(id) { self?.send(b, mode: .markdown) } }
        return BasketPanel(store: store, projects: { [weak self] in self?.choices ?? [] }, actions: a)
    }()
    private var snapHotKey: GlobalHotKey?
    private var basketHotKey: GlobalHotKey?
    private let projects: () -> [ProjectSummary]
    private var editor: ShotEditorPanel?
    private(set) lazy var sender = SnapSender(
        store: store,
        project: { [weak self] k in self?.summary(k)?.ref },
        tracker: { ENV.tracker($0.workspace) },
        terminal: { ENV.runtime as? SnapTerminal },
        root: { [weak self] k in self?.summary(k).flatMap { PROJECTS_CFG.orcaRoot($0) } })

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

    func snap() {
        panel.suspend(true)
        capturer.start()
    }

    func toggleBasket() { panel.toggle() }

    /// Shows the basket panel at launch when a basket has shots.
    func restore() { if !store.openBaskets.isEmpty { panel.showCollapsed(project: cfg.lastProject) } }

    /// The shots in all open baskets, for the menu bar count.
    var shotCount: Int { store.openBaskets.reduce(0) { $0 + $1.shots.count } }

    func send(_ b: SnapBasket, mode: SnapConfig.SendMode) {
        PROJECTS_CFG.capture.snap.sendMode = mode
        saveConfig()
        if mode == .markdown {
            do {
                try sender.copy(b)
                try store.set(b.id, .copied)
                panel.show(.init(text: "Copied the ticket and \(b.shots.count) image\(b.shots.count == 1 ? "" : "s"). Paste it anywhere."))
            } catch { fail(error, b) }
            return
        }
        panel.setSending(b.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let r = try await self.sender.send(b, agent: mode == .agent)
                self.panel.setSending(nil)
                self.sent(r, b, agent: mode == .agent)
            } catch {
                self.panel.setSending(nil)
                self.fail(error, b)
            }
        }
    }

    /// Uploads the missing files of a partly sent basket again.
    func retry(_ b: SnapBasket) {
        Task { @MainActor [weak self] in
            guard let self, let item = b.item else { return }
            do {
                let missing = try await self.sender.retry(b)
                try self.store.set(b.id, missing.isEmpty ? .sent(key: item.key, session: nil) : .partial(key: item.key, missing: missing))
            } catch { self.fail(error, b) }
        }
    }

    private func sent(_ r: SnapSender.Result, _ b: SnapBasket, agent: Bool) {
        let state: SnapBasket.State = r.missing.isEmpty ? .sent(key: r.key, session: r.session?.id) : .partial(key: r.key, missing: r.missing)
        attempt { try store.set(b.id, state, item: r.item) }
        if !r.missing.isEmpty {
            panel.show(.init(text: "\(r.key) has \(r.missing.count) missing image\(r.missing.count == 1 ? "" : "s"). Retry in Settings › Projects › Snap basket.",
                             link: r.item.url, bad: true))
        } else if agent {
            panel.show(.init(text: "\(r.key) is open in an agent terminal.", link: r.item.url))
        } else {
            panel.show(.init(text: "Created \(r.key) with \(b.shots.count) shot\(b.shots.count == 1 ? "" : "s").", link: r.item.url))
        }
    }

    private func fail(_ error: Error, _ b: SnapBasket) {
        log.error("Snap: send failed: \(error.localizedDescription, privacy: .public)")
        let copy = (error as? SnapSendError) == .noAttachments ? b.id : nil
        panel.show(.init(text: error.localizedDescription, bad: true, copy: copy))
    }

    private func summary(_ key: String) -> ProjectSummary? { projects().first { $0.identifier == key } }

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
        a.closed = { [weak self] in self?.editorClosed() }
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
        a.closed = { [weak self] in self?.editorClosed() }
        show(ShotEditorPanel(model: model, image: img, projects: choices, near: nil, actions: a))
    }

    private func editorClosed() {
        editor = nil
        if !capturer.isActive { panel.suspend(false) }
    }

    private func show(_ p: ShotEditorPanel) {
        editor = p
        p.present()
    }

    private func add(_ s: SnapShot, png: Data, again: Bool) {
        attempt { _ = try store.add(s, png: png) }
        PROJECTS_CFG.capture.snap.lastProject = s.project
        saveConfig()
        panel.showCollapsed(project: s.project)
        if again { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.snap() } }
    }

    private func save(_ s: SnapShot, in basket: String) {
        guard var b = store.basket(basket), let i = b.shots.firstIndex(where: { $0.id == s.id }) else { return }
        b.shots[i] = s
        panel.forget(s.id)
        attempt { try store.update(b) }
    }

    private func attempt(_ f: () throws -> Void) {
        do { try f() } catch {
            log.error("Snap: OverSire could not save the shot: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}

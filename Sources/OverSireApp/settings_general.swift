import Cocoa
import OverSireCore

// Settings › General: look, menu bar, runs and items, quick capture and snap, startup, shortcuts.
extension SettingsPage {
    static let hideDoneDays = [-1, 1, 7, 30, 0]
    static let snapKeepDays = [7, 30, 90]
    static var captureError: String?
    static var snapError: String?

    func general(_ b: NSStackView) {
        b.addFull(section(.appearance, [appearanceTheme(), FieldRow("Show OverSire in", note: "The window opens from both.", showIn())]))
        b.addFull(section(.menubar, [
            SwitchRow("Small popover", note: "Now, Runs and Work only.", on: GENERAL.smallPopover) { GENERAL.smallPopover = $0 },
            FieldRow("Tabs", note: "At least one tab stays on.", popoverTabs()),
            SwitchRow("Blue dot on the menu bar icon", note: "Unread Plane activity, or a session that waits for you.", on: PROJECTS_CFG.menuDot) { [weak self] in
                PROJECTS_CFG.menuDot = $0
                self?.app?.applyProjectSelection()
            },
        ]))
        b.addFull(section(.runs, runsAndItems()))
        b.addFull(section(.capture, capture()))
        b.addFull(section(.startup, startup()))
        b.addFull(section(.shortcuts, shortcutRows()))
    }

    private func appearanceTheme() -> NSView {
        let themes = Theme.allCases
        return FieldRow("Theme", note: "System follows the macOS setting.",
                        Segmented(themes.map(\.label), selected: themes.firstIndex(of: GENERAL.theme) ?? 1, label: "Theme") { [weak self] i in
            GENERAL.theme = themes[i]
            self?.app?.applySystemAppearance()
            self?.view.window?.appearance = NSApp.appearance
        })
    }

    func showIn() -> NSView {
        let all = ShowIn.allCases
        let names = ["Menu bar", "Dock", "Both"]
        return Segmented(all.map { names[all.firstIndex(of: $0)!] }, selected: all.firstIndex(of: GENERAL.showIn) ?? 2, label: "Show OverSire in") { [weak self] i in
            GENERAL.showIn = all[i]
            self?.app?.applyShowIn()
        }
    }

    private func popoverTabs() -> NSView {
        // The last tab that is on cannot go off.
        let on = [TABS.actions, TABS.prs, PROJECTS_CFG.showTab, TABS.insights].filter { $0 }.count
        let keep = { (now: Bool) in now && on == 1 }
        return ChipGroup([
            .init("Runs", on: TABS.actions) { if !keep(TABS.actions) { TABS.actions = $0 } },
            .init("Pull requests", on: TABS.prs) { if !keep(TABS.prs) { TABS.prs = $0 } },
            .init("Projects", on: PROJECTS_CFG.showTab) { if !keep(PROJECTS_CFG.showTab) { PROJECTS_CFG.showTab = $0 } },
            .init("Insights", on: TABS.insights) { if !keep(TABS.insights) { TABS.insights = $0 } },
        ], label: "Popover tabs")
    }

    private func runsAndItems() -> [NSView] {
        let rows = ONE_ROW_PER_WORKFLOW ? (LATEST_ACROSS_BRANCHES ? 2 : 1) : 0
        let items = [10, 25, 0]
        return [
            FieldRow("One row per workflow", note: "Show the latest run of each workflow.",
                     Segmented(["Off", "Per branch", "Per repo"], selected: rows, label: "One row per workflow") { i in
                ONE_ROW_PER_WORKFLOW = i > 0
                LATEST_ACROSS_BRANCHES = i == 2
            }),
            FieldRow("Project view", note: "The view that a project opens with.",
                     Segmented(["Board", "Activity"], selected: PROJECTS_CFG.defaultView == .activity ? 1 : 0, label: "Project view") { [weak self] i in
                PROJECTS_CFG.defaultView = i == 1 ? .activity : .board
                self?.app?.applyProjectSelection()
            }),
            FieldRow("Items per project", Segmented(["10", "25", "All"], selected: items.firstIndex(of: PROJECTS_CFG.itemsPerProject) ?? 0,
                                                    label: "Items per project") { [weak self] i in
                PROJECTS_CFG.itemsPerProject = items[i]
                self?.app?.applyProjectSelection()
            }),
            FieldRow("Hide Done items", PopUp(["Always", "Older than 1 day", "Older than 7 days", "Older than 30 days", "Never"],
                                              selected: Self.hideDoneDays.firstIndex(of: PROJECTS_CFG.hideDoneAfterDays) ?? 1, label: "Hide Done items") { [weak self] i in
                PROJECTS_CFG.hideDoneAfterDays = Self.hideDoneDays[i]
                settingsChanged()
                self?.app?.applyProjectSelection()
            }),
            SwitchRow("List sub-items as rows", note: "An open item always shows its sub-items.", on: PROJECTS_CFG.showSubItems) { [weak self] in
                PROJECTS_CFG.showSubItems = $0
                self?.app?.applyProjectSelection()
            },
        ]
    }

    // A shortcut field with Clear and Try. `apply` sets the keys in the config and in macOS.
    private func shortcutControl(_ key: KeyShortcut, label: String, enabled: Bool, recording: @escaping (Bool) -> Void,
                                 set: @escaping (KeyShortcut) -> Void, tryIt: @escaping () -> Void) -> NSView {
        let f = ShortcutField(key)
        f.isEnabled = enabled
        f.setAccessibilityLabel(label)
        f.onRecording = recording
        f.onChange = { code, mods in set(KeyShortcut(keyCode: code, modifiers: mods)) }
        let clear = ActionButton("Clear") { set(KeyShortcut(keyCode: key.keyCode, modifiers: 0)) }
        clear.isEnabled = enabled
        let t = ActionButton("Try", tryIt)
        t.toolTip = "Do what the shortcut does"
        return NSStackView(h: [f, clear, t], spacing: 6)
    }

    private func applyCapture() {
        saveConfig()
        let ok = app?.applyCaptureHotKey() ?? true
        Self.captureError = ok ? nil : "macOS did not accept \(PROJECTS_CFG.capture.shortcutLabel). Another app may use it."
        reload()
    }

    private func applySnap() {
        saveConfig()
        let failed = app?.snap.applyHotKeys() ?? []
        Self.snapError = failed.isEmpty ? nil : "macOS did not accept \(failed.joined(separator: ", ")). Another app may use it."
        reload()
    }

    private func capture() -> [NSView] {
        let c = PROJECTS_CFG.capture
        var rows: [NSView] = [
            SwitchRow("New item from any app", note: "A global shortcut opens the New item sheet.", on: c.enabled) { [weak self] in
                PROJECTS_CFG.capture.enabled = $0
                self?.applyCapture()
            },
            FieldRow("New item shortcut", shortcutControl(c.shortcut, label: "New item shortcut", enabled: c.enabled,
                                                          recording: { [weak self] in self?.app?.suspendCaptureHotKey($0) },
                                                          set: { [weak self] k in
                PROJECTS_CFG.capture.keyCode = k.keyCode
                PROJECTS_CFG.capture.modifiers = k.modifiers
                self?.applyCapture()
            }, tryIt: { [weak self] in self?.app?.quickCapture() })),
            SwitchRow("Put the clipboard text in the description", note: "Only when the clipboard has text.", on: c.pasteClipboard) {
                PROJECTS_CFG.capture.pasteClipboard = $0
            },
            SwitchRow("Write the title with AI at once", note: "Needs Settings › AI. AI also picks the project.", on: c.aiTitle) {
                PROJECTS_CFG.capture.aiTitle = $0
            },
        ]
        if let e = Self.captureError { rows.append(Padded(Banner(.bad, title: e))) }
        let s = c.snap
        let perm = SnapCapturer.hasPermission
        rows.append(Row([Glyph(perm ? .ok : .warning, size: 13),
                         TwoLine(perm ? "Screen Recording is on" : "Screen Recording is off", perm ? "Snaps can take screenshots." : "Snaps need it.", weight: .medium),
                         Spacer()] + (perm ? [] : [ActionButton("Turn on…") { SnapCapturer.requestPermission() }]), height: 52,
                        label: perm ? "Screen Recording is on" : "Screen Recording is off"))
        rows.append(SwitchRow("Snap shortcuts", note: "Global shortcuts take a snap and show the basket.", on: s.enabled) { [weak self] in
            PROJECTS_CFG.capture.snap.enabled = $0
            self?.applySnap()
        })
        let recording: (Bool) -> Void = { [weak self] in self?.app?.snap.suspendHotKeys($0) }
        rows.append(FieldRow("Take a snap", shortcutControl(KeyShortcut(keyCode: s.keyCode, modifiers: s.modifiers), label: "Take a snap shortcut",
                                                            enabled: s.enabled, recording: recording, set: { [weak self] k in
            PROJECTS_CFG.capture.snap.keyCode = k.keyCode
            PROJECTS_CFG.capture.snap.modifiers = k.modifiers
            self?.applySnap()
        }, tryIt: { [weak self] in self?.app?.snap.snap() })))
        rows.append(FieldRow("Show the basket", shortcutControl(KeyShortcut(keyCode: s.basketKeyCode, modifiers: s.basketModifiers),
                                                                label: "Show the basket shortcut", enabled: s.enabled, recording: recording, set: { [weak self] k in
            PROJECTS_CFG.capture.snap.basketKeyCode = k.keyCode
            PROJECTS_CFG.capture.snap.basketModifiers = k.modifiers
            self?.applySnap()
        }, tryIt: { [weak self] in self?.app?.snap.toggleBasket() })))
        if let e = Self.snapError { rows.append(Padded(Banner(.bad, title: e))) }
        rows.append(SwitchRow("Speak notes", note: "On-device speech to text in the shot editor.", on: s.voice) { PROJECTS_CFG.capture.snap.voice = $0 })
        let modes = SnapConfig.SendMode.allCases
        rows.append(FieldRow("Send the basket with", PopUp(modes.map(\.label), selected: modes.firstIndex(of: s.sendMode) ?? 0, label: "Send the basket with") { i in
            PROJECTS_CFG.capture.snap.sendMode = modes[i]
            settingsChanged()
        }))
        rows.append(FieldRow("Keep history", Segmented(Self.snapKeepDays.map { "\($0) days" }, selected: Self.snapKeepDays.firstIndex(of: s.keepDays) ?? 1,
                                                       label: "Keep history") { i in PROJECTS_CFG.capture.snap.keepDays = Self.snapKeepDays[i] }))
        rows += snapHistory()
        return rows
    }

    // The last five sent baskets, with Open or Retry.
    private func snapHistory() -> [NSView] {
        guard let snap = app?.snap else { return [] }
        let history = snap.store.history(limit: 5)
        guard !history.isEmpty else { return [] }
        let d = Disclosure("Sent baskets (\(history.count))", id: "snap-history")
        for b in history {
            let n = b.shots.count
            var what = "", action: NSView?
            switch b.state {
            case .sent(let key, _):
                what = "Sent as \(key)"
                if let u = b.item?.url { action = ActionButton("Open") { NSWorkspace.shared.open(u) } }
            case .partial(let key, let missing):
                what = "\(key): \(missing.count) image\(missing.count == 1 ? "" : "s") missing"
                action = ActionButton("Retry") { snap.retry(b) }
            case .copied: what = "Copied as Markdown"
            case .open: continue
            }
            let icon = NSImageView(image: PROJECT_ICONS.image(for: b.project, size: 14))
            d.add(Row([icon, TwoLine("\(b.project) · \(n) shot\(n == 1 ? "" : "s")", "\(relativeAgo(b.createdAt)) · \(what)"), Spacer()] + (action.map { [$0] } ?? []),
                      height: 44))
        }
        return [d]
    }

    private func startup() -> [NSView] {
        let u = data.updater
        let status = u.statusText
        let ready: Bool = { if case .ready = u.state { return true }; return false }()
        let failed: Bool = { if case .failed = u.state { return true }; return false }()
        let check = ActionButton(ready ? "Restart now" : "Check now") { ready ? u.install() : u.check(manual: true) }
        check.isEnabled = !u.busy
        var version: [NSView] = [TwoLine("Updates", "Version \(u.current)" + (status.isEmpty ? "" : " · \(status)"), weight: .medium), Spacer()]
        if failed { version.insert(Glyph(.bad, size: 13), at: 0) }
        return [
            SwitchRow("Open the window at launch", on: GENERAL.openWindowAtLaunch) { GENERAL.openWindowAtLaunch = $0 },
            SwitchRow("Install updates automatically", note: u.isDev ? "Off in a development build." : nil, on: AUTO_UPDATE, enabled: !u.isDev) {
                AUTO_UPDATE = $0
                if $0 { u.check(manual: false) }
            },
            Row(version + [check], height: 52, label: "Updates"),
        ]
    }

    private func shortcutRows() -> [NSView] {
        let f = ShortcutField(GENERAL.windowKey)
        f.onChange = { [weak self] code, mods in
            GENERAL.windowKey = KeyShortcut(keyCode: code, modifiers: mods)
            saveConfig()
            _ = self?.app?.applyWindowHotKey()
        }
        f.setAccessibilityLabel("Window shortcut")
        let d = Disclosure("Show the window shortcuts", id: "window-keys")
        let keys: [(String, String)] = [("⌘K", "Search or jump to a page"), ("⌘F", "Search settings"), ("⌘[  ⌘]", "Back and forward"), ("⌘R", "Refresh"),
                                         ("⌃⌘S", "Show or hide the sidebar"), ("⌘0", "Bring the window to the front"),
                                         ("1  2  3  H", "Intake: accept, duplicate, decline, snooze"), ("⌘,", "Settings")]
        keys.forEach { d.add(FieldRow($0.1, NSTextField.text($0.0, size: 12, color: Palette.mut, mono: true))) }
        return [
            FieldRow("Open the window", note: "From any app.", f),
            FieldRow("New item (quick capture)", note: "From any app. Change it in Quick capture and snap.",
                     NSTextField.text(PROJECTS_CFG.capture.enabled ? PROJECTS_CFG.capture.shortcutLabel : "Off", size: 12, color: Palette.mut, mono: true)),
            d,
        ]
    }
}

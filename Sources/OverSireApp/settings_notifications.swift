import Cocoa
import OverSireCore

// One tracker event with an "Any item" and a "My items" check box.
final class ScopeRow: Row {
    static let column: CGFloat = 72
    private let path: WritableKeyPath<ProjectNotificationSettings, NotifyScope>

    init(_ title: String, _ path: WritableKeyPath<ProjectNotificationSettings, NotifyScope>) {
        self.path = path
        let s = PROJECTS_CFG.notifications[keyPath: path]
        let any = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let mine = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        var cells: [NSView] = [NSTextField.text(title, size: 13), Spacer()]
        for (b, on, scope) in [(any, s.any, "any item"), (mine, s.mine, "my items")] {
            b.state = on ? .on : .off
            b.setAccessibilityLabel("\(title) for \(scope)")
            cells.append(ScopeRow.cell(b))
        }
        super.init(cells, height: 36, label: title)
        for b in [any, mine] { b.target = self; b.action = #selector(flip(_:)) }
        any.tag = 0
        mine.tag = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    static func cell(_ v: NSView) -> NSView {
        let c = NSStackView(h: [v], spacing: 0)
        c.alignment = .centerY
        c.distribution = .gravityAreas
        c.setHuggingPriority(.required, for: .horizontal)
        c.widthAnchor.constraint(equalToConstant: column).isActive = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.centerXAnchor.constraint(equalTo: c.centerXAnchor).isActive = true
        return c
    }

    @objc private func flip(_ b: NSButton) {
        if b.tag == 0 { PROJECTS_CFG.notifications[keyPath: path].any = b.state == .on }
        else { PROJECTS_CFG.notifications[keyPath: path].mine = b.state == .on }
        settingsChanged()
    }
}

// Settings › Notifications: all alerts in one place. A project can override them.
extension SettingsPage {
    func notifications(_ b: NSStackView) {
        b.addFull(section(.ci, [Padded(ChipGroup([
            .init("Started", on: NOTIFICATIONS.started) { NOTIFICATIONS.started = $0 },
            .init("Passed", on: NOTIFICATIONS.succeeded) { NOTIFICATIONS.succeeded = $0 },
            .init("Failed", on: NOTIFICATIONS.failed) { NOTIFICATIONS.failed = $0 },
            .init("Cancelled", on: NOTIFICATIONS.cancelled) { NOTIFICATIONS.cancelled = $0 },
            .init("Other endings", on: NOTIFICATIONS.other) { NOTIFICATIONS.other = $0 },
        ], label: "CI runs", note: "A flaky workflow re-runs once first."))]))

        let head = Row([NSTextField.text("Event", size: 11.5, weight: .semibold, color: Palette.dim), Spacer(),
                        ScopeRow.cell(NSTextField.text("Any item", size: 11.5, weight: .semibold, color: Palette.dim)),
                        ScopeRow.cell(NSTextField.text("My items", size: 11.5, weight: .semibold, color: Palette.dim))], height: 30)
        head.setAccessibilityElement(false)
        b.addFull(section(.tracker, [
            head,
            ScopeRow("New comment", \.comment),
            ScopeRow("Status changes", \.status),
            ScopeRow("Item is added", \.added),
            ScopeRow("Item is closed or Done", \.closed),
            ScopeRow("Other fields change", \.otherFields),
        ]))

        b.addFull(section(.mentions, [Padded(ChipGroup([
            .init("Someone mentions me", on: PROJECTS_CFG.notifications.mention) { PROJECTS_CFG.notifications.mention = $0 },
            .init("Assigned to me", on: PROJECTS_CFG.notifications.assigned) { PROJECTS_CFG.notifications.assigned = $0 },
            .init("New intake item", on: PROJECTS_CFG.notifications.intake) { PROJECTS_CFG.notifications.intake = $0 },
            .init("Session needs input", on: PROJECTS_CFG.notifications.agentWaiting) { PROJECTS_CFG.notifications.agentWaiting = $0 },
            .init("Session is done", on: PROJECTS_CFG.notifications.agentDone) { PROJECTS_CFG.notifications.agentDone = $0 },
        ], label: "Agents and mentions"))]))

        b.addFull(section(.oversire, [
            SwitchRow("OverSire problems", note: "A background job of OverSire fails, for example an AI job or a poll. Settings › Logs shows the details.",
                      on: NOTIFICATIONS.problems) { NOTIFICATIONS.problems = $0; settingsChanged() },
        ]))

        b.addFull(section(.overrides, overrideRows()))
    }

    private func overrideRows() -> [NSView] {
        let overrides = PROJECTS_CFG.notificationOverrides
        if overrides.isEmpty { return [Padded(EmptyNote("Each project uses these defaults.", symbol: "checkmark.circle"))] }
        return overrides.map { o in
            let note: String
            let action: ActionButton
            switch o.kind {
            case .muted:
                note = "Muted"
                action = ActionButton("Unmute", symbol: "bell") {
                    PROJECTS_CFG.settings[o.key]?.muted = false
                    settingsChanged()
                }
                action.setAccessibilityLabel("Unmute \(o.key)")
            case .custom(let n):
                note = n == 0 ? "Custom: same as the defaults" : n == 1 ? "Custom: 1 change" : "Custom: \(n) changes"
                action = ActionButton("Open") { [weak self] in self?.go(.projectSettings(o.key, .notifications)) }
                action.setAccessibilityLabel("Open the notifications of \(o.key)")
            }
            let icon = NSImageView(image: PROJECT_ICONS.image(for: o.key, size: 22))
            icon.setAccessibilityElement(false)
            return Row([icon, TwoLine(o.key, note), Spacer(), action], height: 48, label: o.key)
        }
    }
}

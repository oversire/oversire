import Cocoa

// The one place that shows an alert. The pages, the row menus and the action buttons use it.
// A test checks that no other source file makes an NSAlert.
enum AlertConfirm {
    struct Spec {
        var title: String
        var info = ""
        /// The first button is the default. The last button cancels when there are two or more.
        var buttons = ["OK"]
        var style: NSAlert.Style = .informational
        /// The first button deletes or forces something.
        var destructive = false
        var accessory: NSView?
        /// The view that gets the keyboard first, for example the field of the accessory.
        var focus: NSView?
        /// The title of a check box under the text.
        var suppression: String?
    }

    struct Answer {
        /// The index in `buttons`.
        let button: Int
        let checked: Bool
    }

    private static func alert(_ s: Spec) -> NSAlert {
        let a = NSAlert()
        a.messageText = s.title
        a.informativeText = s.info
        a.alertStyle = s.style
        s.buttons.forEach { a.addButton(withTitle: $0) }
        if s.destructive { a.buttons.first?.hasDestructiveAction = true }
        a.accessoryView = s.accessory
        if let f = s.focus { a.window.initialFirstResponder = f }
        if let t = s.suppression {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = t
        }
        return a
    }

    private static func answer(_ a: NSAlert, _ r: NSApplication.ModalResponse) -> Answer {
        Answer(button: r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue, checked: a.suppressionButton?.state == .on)
    }

    /// A sheet on `window`, else a modal alert.
    static func show(_ s: Spec, in window: NSWindow?, done: @escaping (Answer) -> Void = { _ in }) {
        let a = alert(s)
        if let window { a.beginSheetModal(for: window) { done(answer(a, $0)) } } else { done(answer(a, a.runModal())) }
    }

    /// A modal alert. For code that needs the answer before it goes on.
    @discardableResult
    static func run(_ s: Spec) -> Answer {
        let a = alert(s)
        return answer(a, a.runModal())
    }

    /// Asks before an action. `yes` runs only for the first button.
    static func ask(_ title: String, info: String = "", button: String, critical: Bool = false, in window: NSWindow?, _ yes: @escaping () -> Void) {
        show(Spec(title: title, info: info, buttons: [button, "Cancel"], style: critical ? .critical : .informational, destructive: critical), in: window) {
            if $0.button == 0 { yes() }
        }
    }

    static func tell(_ title: String, info: String = "", in window: NSWindow?) {
        show(Spec(title: title, info: info, style: .warning), in: window)
    }

    /// Asks for one line of text. `done` gets text that is not empty.
    static func input(_ title: String, info: String = "", placeholder: String = "", value: String = "", button: String,
                      width: CGFloat = 320, in window: NSWindow?, _ done: @escaping (String) -> Void) {
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        f.placeholderString = placeholder
        f.stringValue = value
        show(Spec(title: title, info: info, buttons: [button, "Cancel"], accessory: f, focus: f), in: window) {
            let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if $0.button == 0, !text.isEmpty { done(text) }
        }
    }
}

import Cocoa
import Carbon

// ─── Quick capture shortcut ──────────────────────────────────────────────────
// Carbon hot keys work from any app and need no Accessibility permission.

final class GlobalHotKey {
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextId: UInt32 = 1
    private static var handlerRef: EventHandlerRef?

    private let id: UInt32
    private var ref: EventHotKeyRef?
    private let handler: () -> Void

    // Nil when macOS refuses the combination, for example when another app has it.
    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        id = GlobalHotKey.nextId
        GlobalHotKey.nextId += 1
        GlobalHotKey.installHandler()
        let hkid = EventHotKeyID(signature: OSType(0x4354_4559), id: id)   // "CTEY"
        guard RegisterEventHotKey(keyCode, modifiers, hkid, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        GlobalHotKey.registry[id] = self
    }

    deinit { unregister() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        GlobalHotKey.registry[id] = nil
    }

    private static func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { GlobalHotKey.registry[hk.id]?.handler() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

// A key code and its Carbon modifier flags.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 50: "`", 36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    var hasShortcut: Bool { modifiers != 0 }

    // "⌃⌥N". Modifier order follows the macOS menus.
    var shortcutLabel: String {
        guard hasShortcut else { return "None" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (KeyShortcut.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

extension CaptureConfig {
    var shortcut: KeyShortcut { KeyShortcut(keyCode: keyCode, modifiers: modifiers) }
    var hasShortcut: Bool { shortcut.hasShortcut }
    var shortcutLabel: String { shortcut.shortcutLabel }
}

// Click, then press the new shortcut. Esc cancels. It needs ⌘, ⌃ or ⌥.
final class ShortcutField: NSButton {
    var onChange: ((UInt32, UInt32) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private var current: KeyShortcut
    private var recording = false { didSet { onRecording?(recording); updateTitle() } }

    init(_ cfg: KeyShortcut) {
        current = cfg
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(startRecording)
        toolTip = "Click, then press the new shortcut"
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ cfg: KeyShortcut) { current = cfg; updateTitle() }
    private func updateTitle() { title = recording ? "Press keys…" : current.shortcutLabel }

    override var acceptsFirstResponder: Bool { true }
    @objc func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        current.keyCode = UInt32(event.keyCode)
        current.modifiers = KeyShortcut.carbonModifiers(flags)
        recording = false
        onChange?(current.keyCode, current.modifiers)
    }
}

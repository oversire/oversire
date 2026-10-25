import Cocoa

// The work that runs now. The toolbar spinner and the page bar read it. Use it on the main queue.
final class BusyTracker {
    static let changed = Notification.Name("BusyChanged")

    struct Token: Hashable { fileprivate let id: Int }

    private var next = 0
    private var work: [(token: Token, label: String)] = []

    // Oldest first.
    var labels: [String] { work.map(\.label) }
    var isBusy: Bool { !work.isEmpty }

    func begin(_ label: String) -> Token {
        next += 1
        let t = Token(id: next)
        work.append((t, label))
        post()
        return t
    }

    // A new label for running work, for example "Loading projects: 2 of 4".
    func update(_ t: Token, _ label: String) {
        guard let i = work.firstIndex(where: { $0.token == t }), work[i].label != label else { return }
        work[i].label = label
        post()
    }

    func end(_ t: Token) {
        guard let i = work.firstIndex(where: { $0.token == t }) else { return }
        work.remove(at: i)
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

extension AppData {
    // True until the first snapshots of the tracked projects arrive.
    var projectsLoading: Bool { projectStore.snapshots.isEmpty && !projectStore.tracked.isEmpty && projectStore.lastError == nil }
    // True until the first fetch of runs and of projects ends.
    var loadingFirst: Bool { firstLoad || projectsLoading }
}

// A small spinner that stops when hidden.
final class Spinner: NSProgressIndicator {
    init(size: NSControl.ControlSize = .small) {
        super.init(frame: .zero)
        style = .spinning
        controlSize = size
        isIndeterminate = true
        isDisplayedWhenStopped = false
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Loading")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { isHidden ? stopAnimation(nil) : startAnimation(nil) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window != nil && !isHidden ? startAnimation(nil) : stopAnimation(nil)
    }
}

// A gray bar in place of text that loads.
final class Skeleton: Box {
    init(width: CGFloat, height: CGFloat = 10) {
        super.init(fill: Palette.raise, border: nil, radius: height / 2)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A view that builds its content again on each notification of one name and object.
final class NotifiedView: NSStackView {
    private var observer: Any?
    private let make: () -> NSView

    init(_ name: Notification.Name, object: AnyObject?, _ make: @escaping () -> NSView) {
        self.make = make
        super.init(frame: .zero)
        orientation = .vertical
        translatesAutoresizingMaskIntoConstraints = false
        observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.render() }
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func render() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        addFull(make())
    }
}

// A spinner and the step in words, for a card or a log that loads.
final class InlineSpinner: NSStackView {
    init(_ text: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        addArrangedSubview(Spinner())
        addArrangedSubview(NSTextField.text(text, size: 12.5, color: Palette.dim, lines: 2))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init(coder: NSCoder) { fatalError() }
}

// A centered spinner and a label for content with no data yet. It fades in, so a fast load does not flash.
// No placeholder rows: their count never matches the real list, so the page jumps when the data comes.
final class LoadingNote: NSView {
    init(_ label: String = "Loading", height: CGFloat = 120, compact: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        let text = NSTextField.text(label.hasSuffix("…") ? label : label + "…", size: compact ? 12 : 12.5, color: Palette.dim)
        let s = NSStackView(h: [Spinner(), text], spacing: 8)
        addSubview(s)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: compact ? 32 : height),
            s.centerXAnchor.constraint(equalTo: centerXAnchor),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
            s.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.25
        a.beginTime = CACurrentMediaTime() + 0.12
        a.fillMode = .backwards
        layer?.add(a, forKey: "fade")
    }
}

// A 2 pt bar under the toolbar while the page waits on its own fetch.
final class PageBar: NSView {
    private let runner = NSView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        runner.wantsLayer = true
        addSubview(runner)
        heightAnchor.constraint(equalToConstant: 2).isActive = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading the page")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool { didSet { animate() } }

    override func layout() {
        super.layout()
        runner.frame = NSRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func animate() {
        runner.layer?.backgroundColor = Palette.acc.cgColor
        runner.layer?.removeAnimation(forKey: "run")
        guard !isHidden, window != nil, bounds.width > 0 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            runner.frame = bounds
            runner.layer?.opacity = 0.6
            return
        }
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -bounds.width * 0.15
        a.toValue = bounds.width * 1.15
        a.duration = 1.2
        a.repeatCount = .infinity
        runner.layer?.add(a, forKey: "run")
    }
}

extension ActionButton {
    // Shows a spinner and a new title, and disables the button until done().
    func busy(_ title: String) {
        if idle == nil { idle = (self.title, image, isEnabled) }
        self.title = title
        image = nil
        isEnabled = false
        let s = subviews.compactMap { $0 as? Spinner }.first ?? {
            let s = Spinner(size: .mini)
            addSubview(s)
            NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), s.centerYAnchor.constraint(equalTo: centerYAnchor)])
            return s
        }()
        s.isHidden = false
        imagePosition = .imageLeading
        image = NSImage(size: NSSize(width: 12, height: 12))   // room for the spinner
        setAccessibilityLabel(title)
    }

    func done() {
        guard let idle else { return }
        title = idle.title
        image = idle.image
        isEnabled = idle.enabled
        self.idle = nil
        subviews.compactMap { $0 as? Spinner }.forEach { $0.removeFromSuperview() }
        setAccessibilityLabel(nil)
    }

    var isBusy: Bool { idle != nil }
}

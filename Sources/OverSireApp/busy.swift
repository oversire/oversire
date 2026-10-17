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

// Grey rows that stand in for a list with no data yet. They pulse, except with Reduce Motion.
final class SkeletonRows: NSStackView {
    init(count: Int = 5, height: CGFloat = 38, label: String = "Loading") {
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 0
        alignment = .leading
        translatesAutoresizingMaskIntoConstraints = false
        let widths: [CGFloat] = [0.62, 0.48, 0.71, 0.4, 0.55]
        for i in 0..<count {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let a = Bone(), b = Bone()
            row.addSubview(a)
            row.addSubview(b)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: height),
                a.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                a.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                a.widthAnchor.constraint(equalToConstant: 64),
                b.leadingAnchor.constraint(equalTo: a.trailingAnchor, constant: 16),
                b.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                b.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: widths[i % widths.count], constant: -92),
            ])
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(label)
    }
    required init(coder: NSCoder) { fatalError() }

    // One grey bar.
    final class Bone: NSView {
        init(height: CGFloat = 10) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 4
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override func updateLayer() { layer?.backgroundColor = Palette.line.cgColor }
        override var wantsUpdateLayer: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            layer?.removeAnimation(forKey: "pulse")
            guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.45
            a.duration = 0.7
            a.autoreverses = true
            a.repeatCount = .infinity
            layer?.add(a, forKey: "pulse")
        }
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

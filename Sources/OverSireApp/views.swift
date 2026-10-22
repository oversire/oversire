import Cocoa
import OverSireCore
import GitHubKit

// ─── Shared Views ────────────────────────────────────────────────────────────

class Badge: NSView {
    /// Text longer than `maxChars` keeps its first and last characters around an ellipsis.
    let tint: NSColor?
    init(_ text: String, maxChars: Int = .max, maxWidth: CGFloat = .greatestFiniteMagnitude, tint: NSColor? = nil) {
        self.tint = tint
        let half = (maxChars - 1) / 2
        let shown = text.count > maxChars ? "\(text.prefix(half))\u{2026}\(text.suffix(half))" : text
        let l = NSTextField(labelWithString: shown)
        l.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        l.textColor = tint == nil ? .secondaryLabelColor : .labelColor
        l.alignment = .center
        l.lineBreakMode = .byTruncatingMiddle
        l.maximumNumberOfLines = 1
        // The label cell needs a few points more than its intrinsic width, or it truncates.
        let sz = l.intrinsicContentSize
        let textW = ceil(sz.width) + 4
        let w = min(textW + 14, maxWidth)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 20))
        l.frame = NSRect(x: 7, y: (20 - sz.height) / 2, width: w - 14, height: sz.height)
        addSubview(l)
        toolTip = text
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if let t = tint {
            t.withAlphaComponent(0.22).setFill(); p.fill()
            t.withAlphaComponent(0.6).setStroke(); p.lineWidth = 0.5; p.stroke()
            return
        }
        // Inverse-of-background fill so the badge is visible in both modes:
        // dark fill in light mode, light fill in dark mode.
        NSColor.labelColor.withAlphaComponent(0.08).setFill(); p.fill()
        NSColor.separatorColor.setStroke(); p.lineWidth = 0.5; p.stroke()
    }
}

let REPO_PALETTE: [NSColor] = [
    (0.36, 0.55, 0.95), (0.93, 0.45, 0.25), (0.30, 0.75, 0.45), (0.75, 0.45, 0.90),
    (0.95, 0.75, 0.20), (0.20, 0.75, 0.80), (0.92, 0.40, 0.60), (0.55, 0.70, 0.25),
    (0.60, 0.50, 0.40), (0.45, 0.45, 0.85), (0.95, 0.55, 0.45), (0.40, 0.60, 0.65),
].map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }

/// Gives each new repo the least used palette slot. The config keeps the slots, so colors stay the same.
func assignRepoColors(_ repos: [String]) {
    let new = repos.filter { REPO_COLORS[$0] == nil }
    guard !new.isEmpty else { return }
    var uses = [Int](repeating: 0, count: REPO_PALETTE.count)
    for i in REPO_COLORS.values { uses[i % uses.count] += 1 }
    for r in new {
        let i = uses.indices.min { uses[$0] < uses[$1] }!
        REPO_COLORS[r] = i
        uses[i] += 1
    }
    saveConfig()
}

func repoColor(_ repo: String) -> NSColor {
    assignRepoColors([repo])
    return REPO_PALETTE[REPO_COLORS[repo]! % REPO_PALETTE.count]
}

class Clicker: NSView {
    let url: String
    init(_ url: String) { self.url = url; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

class EmptyRow: NSView {
    init(_ text: String, w: CGFloat, icon: String? = nil) {
        let h: CGFloat = icon != nil ? 52 : 36
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        if let iconName = icon {
            let iv = NSImageView(frame: NSRect(x: 16, y: (h - 20) / 2, width: 20, height: 20))
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                iv.image = img; iv.contentTintColor = .secondaryLabelColor
                iv.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            }
            addSubview(iv)
        }
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 42, y: (h - 20) / 2, width: w - 54, height: 20)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

class Flipped: NSView { override var isFlipped: Bool { true } }

// A label that recomputes its text every second while it is in a window.
final class LiveLabel: NSTextField {
    var text: (() -> String)? { didSet { tick() } }
    private var timer: Timer?

    static func make(_ font: NSFont, _ color: NSColor, _ text: @escaping () -> String) -> LiveLabel {
        let l = LiveLabel(labelWithString: "")
        l.font = font; l.textColor = color; l.maximumNumberOfLines = 1
        l.text = text
        return l
    }

    private func tick() { if let t = text { stringValue = t() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        tick()
        // The common mode keeps it ticking while the list scrolls.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

class LoadingRow: NSView {
    init(w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 48))
        let spinner = NSProgressIndicator(frame: NSRect(x: 16, y: 14, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        addSubview(spinner)
        let l = NSTextField(labelWithString: "Loading...")
        l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 44, y: 14, width: w - 56, height: 20)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

class Footer: NSView {
    static let problemH: CGFloat = 26

    /// `problems` adds one line above the buttons while OverSire has open problems.
    init(_ w: CGFloat, updated: Date, problems: [Problem] = []) {
        let h = FTR_H + (problems.isEmpty ? 0 : Self.problemH)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        if !problems.isEmpty { addSubview(problemLine(problems, w: w)) }
        let sep = NSView(frame: NSRect(x: 0, y: h - 0.5, width: w, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(sep)

        let rb = NSButton(title: "Refresh", target: NSApp.delegate, action: #selector(GHActionsBar.doRefresh))
        rb.bezelStyle = .inline; rb.font = .systemFont(ofSize: 11)
        rb.frame = NSRect(x: 8, y: 8, width: 80, height: 24)
        addSubview(rb)

        quota.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        quota.frame = NSRect(x: 92, y: 11, width: 148, height: 16)
        addSubview(quota)
        showQuota((NSApp.delegate as? GHActionsBar)?.rateLimit.latest)

        let ts = stamp
        showUpdated(updated)
        ts.font = .systemFont(ofSize: 10); ts.textColor = .secondaryLabelColor; ts.alignment = .center
        ts.frame = NSRect(x: 244, y: 11, width: w - 448, height: 16)
        addSubview(ts)
        if let v = (NSApp.delegate as? GHActionsBar)?.updater.readyVersion {
            ts.frame.size.height = 12; ts.frame.origin.y = 22
            let ub = NSButton(title: "v\(v) ready · Install", target: NSApp.delegate, action: #selector(GHActionsBar.showUpdates))
            ub.isBordered = false
            ub.attributedTitle = NSAttributedString(string: ub.title, attributes: [.foregroundColor: Palette.acc, .font: NSFont.systemFont(ofSize: 10.5, weight: .medium)])
            ub.frame = NSRect(x: 244, y: 4, width: w - 448, height: 16)
            ub.setAccessibilityLabel("Version \(v) is ready. Open the update settings")
            addSubview(ub)
        }

        // Live updates: green = live, grey = polling, orange = relay error.
        if let (color, tip) = (NSApp.delegate as? GHActionsBar)?.relay.statusDot {
            let dot = Dot(color: color, frame: NSRect(x: w - 124, y: 15, width: 10, height: 10))
            dot.toolTip = tip
            addSubview(dot)
        }

        let ask = NSButton(title: "Ask", target: NSApp.delegate, action: #selector(GHActionsBar.askAssistant))
        ask.bezelStyle = .inline; ask.font = .systemFont(ofSize: 11)
        ask.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        ask.imagePosition = .imageLeading
        ask.contentTintColor = AI_COLOR
        ask.toolTip = "Ask the assistant (⌘J)"
        ask.setAccessibilityLabel("Ask the assistant")
        ask.frame = NSRect(x: w - 196, y: 8, width: 64, height: 24)
        addSubview(ask)

        // Settings gear
        let gear = NSButton(frame: NSRect(x: w - 100, y: 8, width: 36, height: 24))
        if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") { gear.image = img }
        gear.bezelStyle = .inline; gear.imagePosition = .imageOnly
        gear.target = NSApp.delegate; gear.action = #selector(GHActionsBar.showSettings as (GHActionsBar) -> () -> Void)
        gear.toolTip = "Settings"
        addSubview(gear)

        let qb = NSButton(title: "Quit", target: NSApp.delegate, action: #selector(GHActionsBar.quitApp))
        qb.bezelStyle = .inline; qb.font = .systemFont(ofSize: 11)
        qb.frame = NSRect(x: w - 56, y: 8, width: 48, height: 24)
        addSubview(qb)
    }
    required init?(coder: NSCoder) { fatalError() }

    let quota = NSTextField(labelWithString: "")
    let stamp = NSTextField(labelWithString: "")

    // "▲ 2 problems · History read, Status   View". View opens Settings › Logs.
    private func problemLine(_ problems: [Problem], w: CGFloat) -> NSView {
        let line = NSView(frame: NSRect(x: 0, y: FTR_H, width: w, height: Self.problemH))
        let jobs = Array(NSOrderedSet(array: problems.map(\.job))).compactMap { $0 as? String }.joined(separator: ", ")
        let n = problems.count
        let text = NSMutableAttributedString(string: "▲ ", attributes: [.foregroundColor: C_QUEUED, .font: NSFont.systemFont(ofSize: 11)])
        text.append(NSAttributedString(string: "\(n) problem\(n == 1 ? "" : "s")",
                                       attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
        text.append(NSAttributedString(string: " · " + jobs, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 5, width: w - 90, height: 16)
        label.setAccessibilityLabel("\(n) OverSire problem\(n == 1 ? "" : "s"): \(jobs)")
        line.addSubview(label)
        let view = NSButton(title: "View", target: NSApp.delegate, action: #selector(GHActionsBar.showLogs))
        view.bezelStyle = .inline; view.font = .systemFont(ofSize: 11)
        view.frame = NSRect(x: w - 64, y: 2, width: 56, height: 22)
        line.addSubview(view)
        let sep = NSView(frame: NSRect(x: 12, y: 0, width: w - 24, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.addSubview(sep)
        return line
    }

    func showUpdated(_ updated: Date) {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"
        let version = (NSApp.delegate as? GHActionsBar).map { "v\($0.updater.current) · " } ?? ""
        stamp.stringValue = "\(version)Updated \(f.string(from: updated))"
    }

    func showQuota(_ rl: RateLimit?) {
        quota.stringValue = rl?.footerLabel ?? ""
        quota.textColor = rl?.color ?? .secondaryLabelColor
        quota.toolTip = rl?.tooltip
    }
}

class SeparatorLine: NSView {
    init(y: CGFloat, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: y, width: w, height: 0.5))
        wantsLayer = true; layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

func textHeight(_ s: String, font: NSFont, width: CGFloat) -> CGFloat {
    let r = (s as NSString).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font])
    return ceil(r.height)
}

class Dot: NSView {
    init(color: NSColor, frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

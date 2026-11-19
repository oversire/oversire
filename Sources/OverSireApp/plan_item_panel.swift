import Cocoa
import OverSireCore

/// The selected item of the Map and the Timeline, by project identifier. It stays when the view builds again.
enum PlanSelection {
    static var keys: [String: String] = [:]
}

/// The panel under the Map and the Timeline: the facts of the selected item, why this item and why this epic.
final class PlanItemPanel: Box {
    var onJump: (String) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    private let row = NSStackView(h: [], spacing: 22, align: .top)

    init() {
        super.init(fill: Palette.panel, border: Palette.line, radius: 10)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14), row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Selected item")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Nil, or a key that is not on the plan, shows the hint.
    func show(key: String?, model: PlanModel, showCritical: Bool) {
        row.clear()
        guard let key, let f = PlanItemFacts(key: key, model: model, showCritical: showCritical) else {
            row.addArrangedSubview(NSTextField.text("Click an item to pin it here.", size: 13, color: Palette.mut))
            return
        }
        let leftW: CGFloat = 250, rightW: CGFloat = 280
        var head: [NSView] = [PlanKeyButton(f.key)]
        if let e = f.epicName { head.append(PlanItemKit.epicChip(e)) }
        let left = NSStackView(v: [NSStackView(h: head + [Spacer()], spacing: 8),
                                   PlanItemKit.wrap(f.title, size: 15, weight: .bold, width: leftW)], spacing: 7)
        if let s = f.summary { left.addArrangedSubview(PlanItemKit.wrap(s, size: 12.5, color: Palette.mut, width: leftW)) }
        left.addArrangedSubview(PlanItemKit.wrap(f.stateText, size: 12, color: f.stateColor, width: leftW))
        let open = ActionButton("Open item") { [weak self] in self?.onOpen(f.key) }
        open.setAccessibilityLabel("Open \(f.key)")
        left.addArrangedSubview(open)
        left.widthAnchor.constraint(equalToConstant: leftW).isActive = true

        let mid = NSStackView(v: [Self.caps("WHY THIS ITEM")], spacing: 6)
        mid.setHuggingPriority(.init(1), for: .horizontal)
        let midW: CGFloat = 330
        mid.addArrangedSubview(PlanItemKit.wrap(f.why, size: 13, width: midW))
        mid.addArrangedSubview(PlanItemKit.row("Dates", PlanItemKit.wrap(f.dates, size: 12, width: midW - 72), width: midW))
        let jump: (String) -> Void = { [weak self] k in self?.onJump(k) }
        mid.addArrangedSubview(PlanItemKit.row("Waits for", PlanItemKit.links(f.waits, none: "Nothing", width: midW - 72, jump: jump), width: midW))
        mid.addArrangedSubview(PlanItemKit.row("Blocks", PlanItemKit.links(f.blocks, none: "Nothing", width: midW - 72, jump: jump), width: midW))

        let right = NSStackView(v: [Self.caps("WHY THIS EPIC")], spacing: 6)
        right.addArrangedSubview(PlanItemKit.wrap(f.epicWhy ?? "The item has no epic.", size: 13, width: rightW))
        if let c = f.critical { right.addArrangedSubview(PlanItemKit.callout("◆", c, color: PlanColor.critical, width: rightW)) }
        if let q = f.question { right.addArrangedSubview(PlanItemKit.callout("▲", q, color: Palette.warn, width: rightW)) }
        right.widthAnchor.constraint(equalToConstant: rightW).isActive = true

        row.addArrangedSubview(left)
        row.addArrangedSubview(Self.divider())
        row.addArrangedSubview(mid)
        row.addArrangedSubview(Self.divider())
        row.addArrangedSubview(right)
        setAccessibilityLabel("Selected item: \(f.key), \(f.title)")
    }

    private static func caps(_ s: String) -> NSTextField {
        let t = NSTextField.text(s, size: 11, weight: .semibold, color: Palette.dim)
        t.attributedStringValue = NSAttributedString(string: s, attributes: [.kern: 0.5, .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                             .foregroundColor: Palette.dim])
        return t
    }

    private static func divider() -> NSView {
        let v = Box(fill: Palette.line, border: nil, radius: 0)
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 120).isActive = true
        return v
    }
}

import Cocoa
import OverSireCore

/// The page that holds the Plan tab.
protocol PlanHost: AnyObject {
    var data: AppData { get }
    func go(_ r: Route)
    /// The toolbar state changed: build again.
    func planChanged()
    func show(plan segment: PlanView.Segment, focus key: String?, epic: EpicID?)
}

enum PlanColor {
    /// Okabe-Ito yellow for the critical path. The light value is darker, for contrast on white.
    static let critical = NSColor(name: nil) { a in
        Palette.isDark(a) ? NSColor(srgbRed: 0xF0 / 255.0, green: 0xE4 / 255.0, blue: 0x42 / 255.0, alpha: 1)
                          : NSColor(srgbRed: 0x8A / 255.0, green: 0x7E / 255.0, blue: 0x00 / 255.0, alpha: 1)
    }
}

/// The Plan tab: the toolbar and one segment. Map and Timeline come in their own files and change only `segmentView(for:)`.
final class PlanView: NSStackView {
    enum Segment: String, CaseIterable {
        case summary, map, timeline

        var title: String {
            switch self {
            case .summary: return "Summary"
            case .map: return "Map"
            case .timeline: return "Timeline"
            }
        }
    }

    private weak var host: PlanHost?
    let controls: PlanControls
    private(set) var model: PlanModel

    init(_ model: PlanModel, controls: PlanControls, host: PlanHost) {
        self.model = model
        self.controls = controls
        self.host = host
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 14
        translatesAutoresizingMaskIntoConstraints = false
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ model: PlanModel) {
        self.model = model
        rebuild()
    }

    private func rebuild() {
        clear()
        addFull(toolbar())
        addFull(segmentView(for: controls.segment))
    }

    func segmentView(for segment: Segment) -> NSView {
        guard let host else { return NSView() }
        switch segment {
        case .summary: return PlanSummaryView(model, controls: controls, host: host)
        case .map: return EmptyNote("Map comes next.", symbol: "point.3.connected.trianglepath.dotted")
        case .timeline: return EmptyNote("Timeline comes next.", symbol: "calendar")
        }
    }

    private func toolbar() -> NSView {
        let c = controls
        var views: [NSView] = [Segmented(Segment.allCases.map(\.title), selected: Segment.allCases.firstIndex(of: c.segment) ?? 0, label: "Plan view") { [weak self] i in
            self?.host?.show(plan: Segment.allCases[i], focus: nil, epic: nil)
        }]
        if c.segment != .summary {
            views.append(Segmented(["All epics", "Active and linked"], selected: c.mode == .all ? 0 : 1, label: "Epics to show") { [weak self] i in
                c.mode = i == 0 ? .all : .activeAndLinked
                self?.host?.planChanged()
            })
            views.append(ToggleChip("◆ Critical path", on: c.critical) { [weak self] in
                c.critical.toggle()
                self?.host?.planChanged()
            })
            let planned = Set(model.graph.epics.filter { $0.state != .active }.map(\.id))
            let fold = ActionButton(c.folded.isEmpty ? "Fold planned" : "Unfold all", style: .ghost) { [weak self] in
                c.folded = c.folded.isEmpty ? planned : []
                self?.host?.planChanged()
            }
            views.append(fold)
        }
        views.append(Spacer())
        let p = model.progress
        if p.loaded < p.total {
            let t = NSTextField.text("Relations \(p.loaded) of \(p.total)" + (p.failed > 0 ? " · \(p.failed) failed" : ""), size: 12,
                                     color: p.failed > 0 ? Palette.warn : Palette.dim)
            t.toolTip = "OverSire loads the relations of each open epic item. The plan changes when they arrive."
            views.append(t)
        }
        let n = model.openEpics, open = model.openCount
        views.append(NSTextField.text("\(n) epic\(n == 1 ? "" : "s") · \(open) open item\(open == 1 ? "" : "s")", size: 12, color: Palette.dim))
        let bar = NSStackView(h: views, spacing: 12)
        bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return bar
    }
}

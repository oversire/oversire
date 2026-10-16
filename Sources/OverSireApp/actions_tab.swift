import Cocoa

// ─── Run Row View ────────────────────────────────────────────────────────────

class RunRow: NSView {
    let urlStr: String
    let repo: String
    let group: [Run]
    let expanded: Bool
    let showRepo: Bool
    var onToggle: (() -> Void)?
    var trackingArea: NSTrackingArea?

    init(repo: String, group: [Run], history: [Run], w: CGFloat, expanded: Bool = false, showRepo: Bool = false) {
        let primary = RunRow.pickPrimary(group)
        self.urlStr = primary.url
        self.repo = repo
        self.group = group
        self.expanded = expanded
        self.showRepo = showRepo
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: ROW_H))
        wantsLayer = true
        layer?.backgroundColor = restingColor
        build(group: group, primary: primary, history: history, w: w)
    }
    required init?(coder: NSCoder) { fatalError() }

    var restingColor: CGColor? {
        expanded ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor : nil
    }

    // Pick the run that drives the status icon, click target, and elapsed/ETA.
    // Priority: in_progress (longest-running) > queued > completed-failure > anything else.
    static func pickPrimary(_ group: [Run]) -> Run {
        let inProg = group.filter { $0.status == "in_progress" }
        if let r = inProg.max(by: { runElapsed($0) < runElapsed($1) }) { return r }
        if let r = group.first(where: { $0.status == "queued" }) { return r }
        if let r = group.first(where: { $0.isFailure && !IGNORED.contains($0) }) { return r }
        return group[0]
    }

    func build(group: [Run], primary: Run, history: [Run], w: CGFloat) {
        let pad: CGFloat = 12, iconSz: CGFloat = 20
        let textX = pad + iconSz + 10, linkW: CGFloat = 28, copyW: CGFloat = 28
        let rightW: CGFloat = 165          // fixed allocation for start time + duration
        let rightX = w - rightW - linkW - copyW - 8
        let textW = rightX - textX - 8     // leave 8px gap before the right column

        let iv = NSImageView(frame: NSRect(x: pad, y: (ROW_H - iconSz) / 2, width: iconSz, height: iconSz))
        let ignored = IGNORED.contains(primary)
        let statusDesc = statusText(primary) + (ignored ? " (ignored)" : "")
        if let img = NSImage(systemSymbolName: sfName(primary), accessibilityDescription: statusDesc) {
            iv.image = img; iv.contentTintColor = ignored ? .systemGray : sfColor(primary)
            iv.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        }
        iv.toolTip = statusDesc
        addSubview(iv)

        let title = lbl(primary.displayTitle, .systemFont(ofSize: 12.5, weight: .semibold))
        title.frame = NSRect(x: textX, y: ROW_H - 24, width: textW, height: 18)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = primary.displayTitle
        addSubview(title)

        // Subtitle: branch badge + event + actor. For groups, the workflow list collapses to
        // "N workflows" and a small stack chip with a (done/total) progress counter sits at the front.
        let actor = primary.actorLogin.map { " by \($0)" } ?? ""
        var subX = textX
        var subRemaining = textW

        if group.count > 1 {
            let done = group.filter { $0.status == "completed" }.count
            let chip = makeGroupChip(done: done, total: group.count)
            chip.frame.origin = NSPoint(x: subX, y: 6)
            addSubview(chip)
            subX += chip.frame.width + 6
            subRemaining -= chip.frame.width + 6
        }

        if showRepo {
            let short = repo.components(separatedBy: "/").last ?? repo
            let rb = Badge(short, maxChars: 22, tint: repoColor(repo))
            rb.toolTip = repo
            rb.frame.origin = NSPoint(x: subX, y: 4)
            addSubview(rb)
            subX += rb.frame.width + 6
            subRemaining -= rb.frame.width + 6
        }

        if !primary.headBranch.isEmpty {
            // Branch gets its own badge. Names over 15 characters keep both ends,
            // and the tooltip shows the full name.
            let bb = Badge(primary.headBranch, maxChars: 15)
            bb.frame.origin = NSPoint(x: subX, y: 4)
            addSubview(bb)
            subX += bb.frame.width + 6
            subRemaining -= bb.frame.width + 6
        }

        let wf = primary.workflowName ?? primary.name
        let name = group.count > 1 ? "\(group.count) workflows" : wf
        let number = group.count > 1 ? "" : " #\(primary.number)"
        let sub = NSTextField(labelWithString: "")
        let subAttr = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        subAttr.append(NSAttributedString(string: "\(number) \u{00B7} \(primary.event)\(actor)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        sub.attributedStringValue = subAttr
        sub.frame = NSRect(x: subX, y: 6, width: subRemaining, height: 16)
        sub.lineBreakMode = .byTruncatingTail; sub.maximumNumberOfLines = 1
        sub.toolTip = sub.stringValue
        addSubview(sub)

        // Time column. For groups: earliest start, longest elapsed (driven by primary).
        let groupStart = group.compactMap { parseISO($0.startedAt) ?? parseISO($0.createdAt) }.min()
        let startedISO: String? = groupStart.map { isoFmt.string(from: $0) } ?? (primary.startedAt ?? primary.createdAt)

        let anyActive = group.contains { $0.status == "in_progress" || $0.status == "queued" }
        if anyActive {
            let started = lbl(fmtStartedAt(startedISO), .systemFont(ofSize: 10.5), .secondaryLabelColor)
            started.alignment = .right
            started.frame = NSRect(x: rightX, y: ROW_H - 23, width: rightW, height: 14)
            addSubview(started)

            let el = LiveLabel.make(.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), C_RUNNING) {
                "\(fmtDuration(runElapsed(primary))) elapsed"
            }
            el.alignment = .right
            el.frame = NSRect(x: rightX, y: 22, width: rightW, height: 14)
            addSubview(el)

            let est = estimatedTotal(for: primary, history: history)
            let eta = LiveLabel.make(.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .secondaryLabelColor) {
                guard let est = est else { return "estimating..." }
                let rem = max(0, est - runElapsed(primary))
                return rem > 0 ? "~\(fmtDuration(rem)) remaining" : "finishing..."
            }
            eta.alignment = .right
            eta.frame = NSRect(x: rightX, y: 6, width: rightW, height: 14)
            addSubview(eta)
        } else {
            let started = lbl(fmtStartedAt(startedISO), .systemFont(ofSize: 10.5), .secondaryLabelColor)
            started.alignment = .right
            started.frame = NSRect(x: rightX, y: ROW_H - 23, width: rightW, height: 14)
            addSubview(started)

            // For groups: total wall-clock from earliest start to latest end.
            let durText: String
            if group.count > 1,
               let s = groupStart,
               let e = group.compactMap({ parseISO($0.updatedAt) }).max() {
                durText = fmtDuration(e.timeIntervalSince(s))
            } else {
                durText = runDuration(primary)
            }
            // Spell out non-success outcomes so state is readable without colour.
            let concl = primary.conclusion ?? ""
            let word: String? = ignored ? "Ignored" : ["failure": "Failed", "cancelled": "Cancelled", "skipped": "Skipped"][concl]
            let failed = concl == "failure" && !ignored
            let dur = lbl(word.map { "\($0) \u{00B7} \(durText)" } ?? durText,
                          .systemFont(ofSize: 10, weight: failed ? .semibold : .regular),
                          failed ? C_FAILURE : .secondaryLabelColor)
            dur.alignment = .right
            dur.frame = NSRect(x: rightX, y: 6, width: rightW, height: 14)
            addSubview(dur)
        }

        let lk = NSButton(frame: NSRect(x: w - linkW - copyW - 4, y: (ROW_H - 24) / 2, width: linkW, height: 24))
        if let img = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open in GitHub") { lk.image = img }
        lk.bezelStyle = .recessed; lk.isBordered = false; lk.imagePosition = .imageOnly
        lk.target = self; lk.action = #selector(openURL); lk.toolTip = "Open run on GitHub"
        addSubview(lk)

        let cp = NSButton(frame: NSRect(x: w - copyW - 4, y: (ROW_H - 24) / 2, width: copyW, height: 24))
        if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL") { cp.image = img }
        cp.bezelStyle = .recessed; cp.isBordered = false; cp.imagePosition = .imageOnly
        cp.target = self; cp.action = #selector(copyURL(_:)); cp.toolTip = "Copy run URL"
        addSubview(cp)

        let sep = NSView(frame: NSRect(x: textX, y: 0, width: w - textX - pad, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(sep)
    }

    @objc func openURL() { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }

    // Right-click menu. Only completed runs can be re-run.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let done = group.filter { $0.status == "completed" }
        let failed = group.filter { $0.isFailure }
        func item(_ title: String, _ action: Selector, _ runs: [Run], into menu: NSMenu? = nil) {
            let i = NSMenuItem(title: title, action: runs.isEmpty ? nil : action, keyEquivalent: "")
            i.target = self; i.representedObject = runs
            (menu ?? m).addItem(i)
        }
        if group.count > 1 {
            item("Re-run all workflows", #selector(rerun(_:)), done)
            item("Re-run failed jobs", #selector(rerunFailed(_:)), failed)
            let one = NSMenu()
            for r in group {
                let wf = r.workflowName ?? r.name
                item("\(wf) #\(r.number)", #selector(rerun(_:)), r.status == "completed" ? [r] : [], into: one)
                if r.isFailure { item("\(wf) #\(r.number): failed jobs", #selector(rerunFailed(_:)), [r], into: one) }
            }
            let sub = NSMenuItem(title: "Re-run one workflow", action: nil, keyEquivalent: "")
            sub.submenu = one
            m.addItem(sub)
        } else {
            item("Re-run workflow", #selector(rerun(_:)), done)
            item("Re-run failed jobs", #selector(rerunFailed(_:)), failed)
        }
        m.addItem(.separator())
        let allIgnored = !failed.isEmpty && failed.allSatisfy { IGNORED.contains($0) }
        item(allIgnored ? "Stop ignoring failure" : "Ignore failure", #selector(toggleIgnore(_:)), failed)
        m.addItem(.separator())
        item("Open on GitHub", #selector(openURL), group)
        item("Copy URL", #selector(copyURL(_:)), group)
        return m
    }

    @objc func rerun(_ sender: NSMenuItem) { app?.rerun(repo: repo, runs: sender.representedObject as? [Run] ?? [], failedOnly: false) }
    @objc func rerunFailed(_ sender: NSMenuItem) { app?.rerun(repo: repo, runs: sender.representedObject as? [Run] ?? [], failedOnly: true) }
    @objc func toggleIgnore(_ sender: NSMenuItem) {
        let runs = sender.representedObject as? [Run] ?? []
        app?.setIgnored(runs, ignored: !runs.allSatisfy { IGNORED.contains($0) })
    }
    var app: GHActionsBar? { NSApp.delegate as? GHActionsBar }

    func lbl(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font; l.textColor = color; l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true; return l
    }

    // Subtle "stack + (done/total)" indicator for grouped workflow runs.
    func makeGroupChip(done: Int, total: Int) -> NSView {
        let countText = "\(done)/\(total)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let textW = (countText as NSString).size(withAttributes: [.font: font]).width
        let iconW: CGFloat = 11, gap: CGFloat = 3, padX: CGFloat = 5
        let w = padX + iconW + gap + textW + padX
        let chip = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 16))

        let iv = NSImageView(frame: NSRect(x: padX, y: 2, width: iconW, height: 11))
        if let img = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "\(total) workflows") {
            iv.image = img; iv.contentTintColor = .secondaryLabelColor
            iv.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        }
        chip.addSubview(iv)

        let l = NSTextField(labelWithString: countText)
        l.font = font; l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: padX + iconW + gap, y: 0, width: textW + 1, height: 14)
        chip.addSubview(l)
        chip.toolTip = "\(done) of \(total) workflows complete"
        return chip
    }

    @objc func copyURL(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
        if let btn = sender as? NSButton,
           let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) {
            let orig = btn.image; btn.image = img; btn.contentTintColor = C_SUCCESS
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { btn.image = orig; btn.contentTintColor = nil }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }
    // Scrolling moves rows under a still pointer, so hover follows the real pointer position.
    override func mouseEntered(with event: NSEvent) { animateHover() }
    override func mouseExited(with event: NSEvent) { animateHover() }
    func animateHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15; ctx.allowsImplicitAnimation = true; syncHover()
        }
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15; ctx.allowsImplicitAnimation = true; layer?.backgroundColor = restingColor
        }
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.contains(loc) else { return }
        for sub in subviews where sub is NSButton { if sub.frame.contains(loc) { return } }
        onToggle?()
    }

    func syncHover() {
        guard let win = window else { return }
        // visibleRect can extend past the row, so intersect it with bounds.
        let inside = bounds.intersection(visibleRect).contains(convert(win.mouseLocationOutsideOfEventStream, from: nil))
        layer?.backgroundColor = inside ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor : restingColor
    }

    // Keyboard accessibility
    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .exterior }
        set {}
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return or Space
            onToggle?()
        } else { super.keyDown(with: event) }
    }
}

// ─── Run Detail View ─────────────────────────────────────────────────────────

// Inline expansion under a run row. Renders synchronously from the detail caches;
// TabVC kicks off background fetches and rebuilds when data lands.
class RunDetailView: Flipped {
    let urlStr: String

    init(group: [Run], primary: Run, repo: String, history: [Run], w: CGFloat) {
        self.urlStr = primary.url
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        let pad: CGFloat = 42, rPad: CGFloat = 16
        let contentW = w - pad - rPad
        var y: CGFloat = 10

        func wrapped(_ text: String, _ font: NSFont, _ color: NSColor, maxH: CGFloat, indent: CGFloat = 0) {
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: contentW - indent, height: maxH),
                options: [.usesLineFragmentOrigin], attributes: [.font: font])
            let h = min(ceil(rect.height) + 2, maxH)
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = font; l.textColor = color
            l.frame = NSRect(x: pad + indent, y: y, width: contentW - indent, height: h)
            l.isSelectable = true
            addSubview(l)
            y += h + 4
        }

        func infoLine(_ name: String, _ value: @autoclosure @escaping () -> String, _ valueColor: NSColor = .labelColor,
                      live: Bool = false) {
            let n = NSTextField(labelWithString: name)
            n.font = .systemFont(ofSize: 10.5); n.textColor = .tertiaryLabelColor
            n.frame = NSRect(x: pad, y: y, width: 80, height: 15)
            addSubview(n)
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            let v = live ? LiveLabel.make(font, valueColor, value) : NSTextField(labelWithString: value())
            v.font = font; v.textColor = valueColor
            v.frame = NSRect(x: pad + 84, y: y, width: contentW - 84, height: 15)
            v.isSelectable = true
            addSubview(v)
            y += 17
        }

        func divider() {
            let s = NSView(frame: NSRect(x: pad, y: y, width: contentW, height: 0.5))
            s.wantsLayer = true; s.layer?.backgroundColor = NSColor.separatorColor.cgColor
            addSubview(s); y += 7
        }

        // ── Full commit message ──
        let cachedMsg = commitMsgCache[primary.headSha]
        wrapped(cachedMsg ?? "Loading commit message\u{2026}",
                .systemFont(ofSize: 11.5),
                cachedMsg == nil ? .tertiaryLabelColor : .labelColor, maxH: 170)
        y += 3
        divider()

        // ── Timing ──
        let groupStart = group.compactMap { parseISO($0.startedAt) ?? parseISO($0.createdAt) }.min()
        let allDone = group.allSatisfy { $0.status == "completed" }
        let groupEnd = group.compactMap { parseISO($0.updatedAt) }.max()
        if let s = groupStart { infoLine("Started", timestampFmt.string(from: s)) }
        if allDone, let e = groupEnd {
            infoLine("Completed", timestampFmt.string(from: e))
            if let s = groupStart { infoLine("Duration", fmtDuration(e.timeIntervalSince(s))) }
        } else {
            infoLine("Elapsed", fmtDuration(runElapsed(primary)), C_RUNNING, live: true)
        }
        if let est = estimatedTotal(for: primary, history: history) {
            infoLine("Expected", "~\(fmtDuration(est))")
        }
        y += 3
        divider()

        // ── Workflows ──
        for run in group.prefix(8) {
            let iv = NSImageView(frame: NSRect(x: pad, y: y + 1, width: 13, height: 13))
            if let img = NSImage(systemSymbolName: sfName(run), accessibilityDescription: statusText(run)) {
                iv.image = img; iv.contentTintColor = sfColor(run)
                iv.symbolConfiguration = .init(pointSize: 9.5, weight: .semibold)
            }
            iv.toolTip = statusText(run)
            addSubview(iv)
            let name = NSTextField(labelWithString: "\(run.workflowName ?? run.name) #\(run.number)")
            name.font = .systemFont(ofSize: 11); name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines = 1
            name.frame = NSRect(x: pad + 19, y: y, width: contentW - 19 - 155, height: 15)
            addSubview(name)
            let st = LiveLabel.make(.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                    run.conclusion == "failure" ? C_FAILURE : .secondaryLabelColor) {
                switch run.status {
                case "completed": return "\(statusText(run)) \u{00B7} \(runDuration(run))"
                case "in_progress": return "\(fmtDuration(runElapsed(run))) elapsed"
                default: return statusText(run)
                }
            }
            st.alignment = .right
            st.frame = NSRect(x: pad + contentW - 150, y: y, width: 150, height: 15)
            addSubview(st)
            let open = Clicker(run.url)
            open.frame = NSRect(x: pad, y: y, width: contentW, height: 15)
            open.toolTip = "Open the workflow run on GitHub"
            addSubview(open)
            y += 18
            y = layoutJobChips(run, repo: repo, x: pad + 19, y: y, w: contentW - 19)
        }
        if group.count > 8 {
            wrapped("+ \(group.count - 8) more workflows", .systemFont(ofSize: 10), .tertiaryLabelColor, maxH: 14)
        }

        // ── Failure details ──
        let failedRuns = group.filter { $0.conclusion == "failure" }
        if !failedRuns.isEmpty {
            y += 2
            divider()
            let hdr = NSTextField(labelWithString: "WHY IT FAILED")
            hdr.font = .systemFont(ofSize: 9.5, weight: .bold); hdr.textColor = C_FAILURE
            hdr.frame = NSRect(x: pad, y: y, width: contentW, height: 13)
            addSubview(hdr); y += 18
            for run in failedRuns.prefix(3) {
                if group.count > 1 {
                    wrapped(run.workflowName ?? run.name, .systemFont(ofSize: 10.5, weight: .semibold),
                            .labelColor, maxH: 16)
                }
                if let fails = failureCache[run.id] {
                    if fails.isEmpty {
                        wrapped("No failure annotations \u{2014} open the run on GitHub for full logs.",
                                .systemFont(ofSize: 10.5), .secondaryLabelColor, maxH: 30)
                    }
                    for f in fails {
                        let head = f.step.map { "\(f.job) \u{00B7} \($0)" } ?? f.job
                        wrapped(head, .systemFont(ofSize: 10.5, weight: .semibold), C_FAILURE, maxH: 32)
                        if f.messages.isEmpty {
                            wrapped("No annotation message \u{2014} see logs on GitHub.",
                                    .systemFont(ofSize: 10), .secondaryLabelColor, maxH: 14, indent: 10)
                        }
                        for m in f.messages {
                            wrapped(m, .monospacedSystemFont(ofSize: 10, weight: .regular),
                                    .labelColor, maxH: 110, indent: 10)
                        }
                    }
                } else {
                    wrapped("Fetching failure details\u{2026}", .systemFont(ofSize: 10.5),
                            .tertiaryLabelColor, maxH: 16)
                }
            }
        }

        // ── GitHub link ──
        y += 4
        let gh = NSButton(title: "View on GitHub", target: self, action: #selector(openGH))
        gh.bezelStyle = .inline; gh.font = .systemFont(ofSize: 11, weight: .medium)
        gh.contentTintColor = .linkColor
        gh.frame = NSRect(x: pad, y: y, width: 130, height: 22)
        addSubview(gh)
        y += 32

        frame = NSRect(x: 0, y: 0, width: w, height: y)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func openGH() { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }

    // Wraps the run's job chips in rows. Returns the y below the last row.
    private func layoutJobChips(_ run: Run, repo: String, x: CGFloat, y: CGFloat, w: CGFloat) -> CGFloat {
        guard let jobs = jobsCache[run.id]?.jobs else {
            let l = NSTextField(labelWithString: "Loading jobs\u{2026}")
            l.font = .systemFont(ofSize: 10); l.textColor = .tertiaryLabelColor
            l.frame = NSRect(x: x, y: y, width: w, height: 14)
            addSubview(l)
            return y + 18
        }
        let notes = Dictionary((failureCache[run.id] ?? []).map { ($0.job, $0.messages) }, uniquingKeysWith: { a, _ in a })
        var cx = x, cy = y
        for job in jobs {
            let chip = JobChip(job: job, notes: notes[job.name] ?? [], maxW: w)
            if cx > x && cx + chip.frame.width > x + w { cx = x; cy += JobChip.height + 4 }
            chip.frame.origin = NSPoint(x: cx, y: cy)
            addSubview(chip)
            cx += chip.frame.width + 4
        }
        return jobs.isEmpty ? y : cy + JobChip.height + 8
    }
}

class RepoHeader: NSView {
    init(_ repo: String, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: HDR_H))
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        let short = repo.components(separatedBy: "/").last ?? repo
        let l = NSTextField(labelWithString: short.uppercased())
        l.font = .systemFont(ofSize: 11, weight: .bold); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 12, y: 6, width: w - 150, height: 20)
        addSubview(l)
        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh \(short)")!,
                              target: nil, action: nil)
        reload.isBordered = false; reload.contentTintColor = .secondaryLabelColor
        reload.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        reload.frame = NSRect(x: w - 132, y: 6, width: 20, height: 20)
        reload.toolTip = "Get the latest runs from GitHub"
        reload.target = self; reload.action = #selector(refreshRepo(_:))
        addSubview(reload)
        let link = NSTextField(labelWithString: "Open Actions")
        link.font = .systemFont(ofSize: 10, weight: .medium); link.textColor = .linkColor
        link.frame = NSRect(x: w - 105, y: 8, width: 93, height: 16); link.alignment = .right
        addSubview(link)
        let click = Clicker("https://github.com/\(repo)/actions")
        click.frame = NSRect(x: w - 110, y: 0, width: 110, height: HDR_H)
        addSubview(click)
        self.repo = repo
    }
    required init?(coder: NSCoder) { fatalError() }

    private var repo = ""

    // Polls GitHub for this repo at once, so a missed relay event does not hide new runs.
    @objc func refreshRepo(_ sender: NSButton) {
        guard let app = NSApp.delegate as? GHActionsBar else { return }
        sender.isEnabled = false
        app.refreshRepos([repo], includePRs: true, completedRuns: []) { _ in }
    }
}

extension TabVC {
func filteredGrouped() -> [(String, [Run])] {
    let data = selectedRepo.map { sel in grouped.filter { $0.0 == sel } } ?? grouped
    return SORT_BY_RECENT ? sortedByRecent(data) : data
}

func buildActionsContent(_ w: CGFloat) -> [NSView] {
    var rows: [NSView] = []
    let data = filteredGrouped()
    if let err = lastFetchError {
        rows.append(EmptyRow(err, w: w, icon: "exclamationmark.triangle"))
        return rows
    }
    if loading && data.isEmpty {
        rows.append(LoadingRow(w: w)); return rows
    }
    if SORT_BY_RECENT {
        if let sel = selectedRepo { rows.append(RepoHeader(sel, w: w)) }
        // Each group sorts by its most recent run.
        let items = data.flatMap { repo, runs in
            let visible = visibleRuns(runs)
            return groupRuns(shownRuns(visible)).map {
                (repo: repo, group: $0, lead: $0.min(by: newerActivity)!, history: visible)
            }
        }.sorted { newerActivity($0.lead, $1.lead) }
        for it in items {
            appendRun(&rows, repo: it.repo, group: it.group, history: it.history, w: w, showRepo: selectedRepo == nil)
        }
        if items.isEmpty {
            rows.append(EmptyRow(FILTER_DEFAULT_BRANCHES ? "No recent runs on main or develop" : "No recent runs", w: w))
        }
        return rows
    }
    for (repo, runs) in data {
        rows.append(RepoHeader(repo, w: w))
        let visible = visibleRuns(runs)
        if visible.isEmpty {
            let msg = FILTER_DEFAULT_BRANCHES && !runs.isEmpty
                ? "No recent runs on main or develop"
                : "No recent runs"
            rows.append(EmptyRow(msg, w: w))
        } else {
            let sorted = shownRuns(visible).sorted { a, b in
                let aActive = a.status == "in_progress" || a.status == "queued"
                let bActive = b.status == "in_progress" || b.status == "queued"
                if aActive != bActive { return aActive }
                return false  // preserve API order otherwise
            }
            for group in groupRuns(sorted) {
                appendRun(&rows, repo: repo, group: group, history: visible, w: w, showRepo: false)
            }
        }
    }
    if rows.isEmpty { rows.append(EmptyRow("No actions to show", w: w)) }
    return rows
}

func shownRuns(_ visible: [Run]) -> [Run] {
    ONE_ROW_PER_WORKFLOW ? latestPerWorkflow(visible, acrossBranches: LATEST_ACROSS_BRANCHES) : visible
}

func appendRun(_ rows: inout [NSView], repo: String, group: [Run], history: [Run], w: CGFloat, showRepo: Bool) {
    let primary = RunRow.pickPrimary(group)
    let key = primary.url
    let isExpanded = expandedRun == key
    let row = RunRow(repo: repo, group: group, history: history, w: w, expanded: isExpanded, showRepo: showRepo)
    row.onToggle = { [weak self] in
        guard let self = self else { return }
        self.expandedRun = self.expandedRun == key ? nil : key
        self.rebuildContent()
    }
    rows.append(row)
    if isExpanded {
        ensureRunDetail(repo: repo, group: group, key: key)
        rows.append(RunDetailView(group: group, primary: primary, repo: repo, history: history, w: w))
    }
}

func ensureRunDetail(repo: String, group: [Run], key: String) {
    let primary = RunRow.pickPrimary(group)
    let sha = primary.headSha
    let needMsg = !sha.isEmpty && commitMsgCache[sha] == nil
    let needFails = group.filter { $0.conclusion == "failure" && failureCache[$0.id] == nil }
    let needJobs = group.filter { jobsCache[$0.id]?.updatedAt != $0.updatedAt }
    guard needMsg || !needFails.isEmpty || !needJobs.isEmpty else { return }
    guard !detailFetchInFlight.contains(key) else { return }
    detailFetchInFlight.insert(key)
    let fallbackMsg = primary.displayTitle
    let cachedJobs = jobsCache.mapValues(\.jobs)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let msg = needMsg ? fetchCommitMessage(repo: repo, sha: sha) : nil
        var jobs: [(Run, [RunJob])] = []
        for r in needJobs { if let j = fetchRunJobs(repo: repo, runId: r.id) { jobs.append((r, j)) } }
        var fails: [(Int, [RunFailure])] = []
        for r in needFails {
            guard let j = jobs.first(where: { $0.0.id == r.id })?.1 ?? cachedJobs[r.id] else { continue }
            fails.append((r.id, fetchRunFailures(repo: repo, jobs: j)))
        }
        DispatchQueue.main.async {
            if commitMsgCache.count > 300 { commitMsgCache.removeAll() }
            if failureCache.count > 200 { failureCache.removeAll() }
            if jobsCache.count > 200 { jobsCache.removeAll() }
            if needMsg { commitMsgCache[sha] = msg ?? fallbackMsg }
            for (r, j) in jobs { jobsCache[r.id] = (r.updatedAt, j) }
            for (id, f) in fails { failureCache[id] = f }
            detailFetchInFlight.remove(key)
            guard let self = self, self.expandedRun == key else { return }
            self.rebuildContent()
        }
    }
}
}

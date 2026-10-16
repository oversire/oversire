import Cocoa

// ─── PR Helpers ──────────────────────────────────────────────────────────────

func prReviewIcon(_ pr: PR) -> String {
    if pr.isDraft { return "pencil.circle" }
    switch pr.reviewDecision ?? "" {
    case "APPROVED": return "checkmark.circle.fill"
    case "CHANGES_REQUESTED": return "xmark.circle.fill"
    case "REVIEW_REQUIRED": return "circle.badge.questionmark"
    default: return "circle.dashed"
    }
}

func prReviewColor(_ pr: PR) -> NSColor {
    if pr.isDraft { return .systemGray }
    switch pr.reviewDecision ?? "" {
    case "APPROVED": return C_SUCCESS
    case "CHANGES_REQUESTED": return C_FAILURE
    case "REVIEW_REQUIRED": return C_QUEUED
    default: return .secondaryLabelColor
    }
}

func prRelativeTime(_ iso: String) -> String {
    guard let d = parseISO(iso) else { return "" }
    return relativeTime(d)
}

func relativeTime(_ d: Date) -> String {
    let secs = -d.timeIntervalSinceNow
    if secs < 60 { return "just now" }
    if secs < 3600 { return "\(Int(secs/60))m ago" }
    if secs < 86400 { return "\(Int(secs/3600))h ago" }
    return "\(Int(secs/86400))d ago"
}

let PR_ROW_H: CGFloat = 56

// ─── PR Row View ─────────────────────────────────────────────────────────────

class PRRow: NSView {
    let urlStr: String
    let expanded: Bool
    var onToggle: (() -> Void)?
    var trackingArea: NSTrackingArea?

    init(_ pr: PR, repo: String, w: CGFloat, expanded: Bool) {
        self.urlStr = pr.url
        self.expanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: PR_ROW_H))
        wantsLayer = true
        layer?.backgroundColor = restingColor
        build(pr, repo: repo, w: w)
    }
    required init?(coder: NSCoder) { fatalError() }

    var restingColor: CGColor? {
        expanded ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor : nil
    }

    func build(_ pr: PR, repo: String, w: CGFloat) {
        let pad: CGFloat = 12, iconSz: CGFloat = 20
        let textX = pad + iconSz + 10, linkW: CGFloat = 28, copyW: CGFloat = 28
        let rightW: CGFloat = 140
        let textW = w - textX - rightW - linkW - copyW

        // Review status icon
        let iv = NSImageView(frame: NSRect(x: pad, y: (PR_ROW_H - iconSz) / 2, width: iconSz, height: iconSz))
        let reviewDesc = pr.isDraft ? "Draft" : (pr.reviewDecision ?? "Pending review")
        if let img = NSImage(systemSymbolName: prReviewIcon(pr), accessibilityDescription: reviewDesc) {
            iv.image = img; iv.contentTintColor = prReviewColor(pr)
            iv.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        }
        iv.toolTip = reviewDesc
        addSubview(iv)

        // Title
        let title = lbl(pr.title, .systemFont(ofSize: 12.5, weight: .semibold))
        title.frame = NSRect(x: textX, y: PR_ROW_H - 24, width: textW, height: 18)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = pr.title
        addSubview(title)

        // Subtitle: #number by author + branch (bold number)
        let sub = NSTextField(labelWithString: "")
        let subAttr = NSMutableAttributedString()
        subAttr.append(NSAttributedString(string: "#\(pr.number)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        subAttr.append(NSAttributedString(string: " by \(pr.author.login)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        sub.attributedStringValue = subAttr
        sub.frame = NSRect(x: textX, y: 6, width: textW * 0.5, height: 16)
        sub.lineBreakMode = .byTruncatingTail; sub.maximumNumberOfLines = 1
        addSubview(sub)

        // Branch badge: names over 15 characters keep both ends, the tooltip shows the full name
        let badge = Badge(pr.headRefName, maxChars: 15, maxWidth: textW * 0.5 - 8)
        badge.frame.origin = NSPoint(x: textX + textW * 0.5, y: 8)
        addSubview(badge)

        // Right side: +/- and time
        let rX = w - rightW - linkW - copyW
        let diffText = "+\(pr.additions) -\(pr.deletions)"
        let diffLabel = lbl(diffText, .monospacedDigitSystemFont(ofSize: 10, weight: .medium), .secondaryLabelColor)
        diffLabel.alignment = .right
        diffLabel.frame = NSRect(x: rX, y: PR_ROW_H - 22, width: rightW - 4, height: 14)
        addSubview(diffLabel)

        let timeLabel = lbl(prRelativeTime(pr.updatedAt), .systemFont(ofSize: 10), .secondaryLabelColor)
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: rX, y: 6, width: rightW - 4, height: 14)
        addSubview(timeLabel)

        // Draft badge
        if pr.isDraft {
            let draft = lbl("Draft", .systemFont(ofSize: 9, weight: .medium), .systemGray)
            draft.frame = NSRect(x: rX, y: PR_ROW_H / 2 - 6, width: 32, height: 12)
            addSubview(draft)
        }

        // Open in GitHub button
        let linkBtn = NSButton(frame: NSRect(x: w - linkW - copyW - 4, y: (PR_ROW_H - 24) / 2, width: linkW, height: 24))
        if let img = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open in GitHub") { linkBtn.image = img }
        linkBtn.bezelStyle = .recessed; linkBtn.isBordered = false; linkBtn.imagePosition = .imageOnly
        linkBtn.target = self; linkBtn.action = #selector(openURL)
        addSubview(linkBtn)

        // Copy URL button
        let cpBtn = NSButton(frame: NSRect(x: w - copyW - 4, y: (PR_ROW_H - 24) / 2, width: copyW, height: 24))
        if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL") { cpBtn.image = img }
        cpBtn.bezelStyle = .recessed; cpBtn.isBordered = false; cpBtn.imagePosition = .imageOnly
        cpBtn.target = self; cpBtn.action = #selector(copyURL); cpBtn.toolTip = "Copy PR URL"
        addSubview(cpBtn)

        // Separator
        let sep = NSView(frame: NSRect(x: textX, y: 0, width: w - textX - pad, height: 0.5))
        sep.wantsLayer = true; sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(sep)
    }

    func lbl(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font; l.textColor = color; l.maximumNumberOfLines = 1
        l.cell?.truncatesLastVisibleLine = true; return l
    }

    @objc func openURL() { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }
    @objc func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }
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
        if event.keyCode == 36 || event.keyCode == 49 { onToggle?() }
        else { super.keyDown(with: event) }
    }
}

// ─── PR Detail View ──────────────────────────────────────────────────────────

class PRDetailView: NSView {
    var onAction: ((PRAction) -> Void)?
    var confirmingClose = false
    var commentField: NSTextField!

    init(_ pr: PR, repo: String, w: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        // Inverse-of-background tint so the expanded panel is distinct from the doc bg in both modes.
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        let pad: CGFloat = 42, rPad: CGFloat = 16
        let contentW = w - pad - rPad
        var y: CGFloat = 8

        // Body text
        let bodyText = String((pr.body ?? "No description.").prefix(500))
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5)]
        let bodyRect = (bodyText as NSString).boundingRect(
            with: NSSize(width: contentW, height: 100),
            options: [.usesLineFragmentOrigin], attributes: bodyAttrs)
        let bodyH = min(ceil(bodyRect.height) + 4, 100)
        let bodyLabel = NSTextField(wrappingLabelWithString: bodyText)
        bodyLabel.font = .systemFont(ofSize: 11.5); bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.frame = NSRect(x: pad, y: y, width: contentW, height: bodyH)
        bodyLabel.maximumNumberOfLines = 6
        addSubview(bodyLabel)
        y += bodyH + 8

        // Labels
        if !pr.labels.isEmpty {
            var lx: CGFloat = pad
            for label in pr.labels.prefix(5) {
                let lb = Badge(label.name)
                lb.frame.origin = NSPoint(x: lx, y: y)
                addSubview(lb)
                lx += lb.frame.width + 6
            }
            y += 24
        }

        // Separator
        let sep1 = NSView(frame: NSRect(x: pad, y: y, width: contentW, height: 0.5))
        sep1.wantsLayer = true; sep1.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(sep1); y += 8

        // Action buttons row
        let btnH: CGFloat = 24
        var bx: CGFloat = pad

        let approveBtn = makeBtn("Approve", color: C_SUCCESS, x: bx, y: y, h: btnH)
        approveBtn.target = self; approveBtn.action = #selector(doApprove)
        addSubview(approveBtn); bx += approveBtn.frame.width + 6

        let changesBtn = makeBtn("Changes", color: C_QUEUED, x: bx, y: y, h: btnH)
        changesBtn.target = self; changesBtn.action = #selector(doRequestChanges)
        addSubview(changesBtn); bx += changesBtn.frame.width + 6

        let mergePopup = NSPopUpButton(frame: NSRect(x: bx, y: y, width: 130, height: btnH), pullsDown: false)
        mergePopup.addItems(withTitles: ["Merge commit", "Rebase", "Squash"])
        mergePopup.font = .systemFont(ofSize: 11)
        addSubview(mergePopup); mergePopup.tag = 100; bx += 136

        let mergeBtn = makeBtn("Merge", color: .systemPurple, x: bx, y: y, h: btnH)
        mergeBtn.target = self; mergeBtn.action = #selector(doMerge)
        addSubview(mergeBtn); bx += mergeBtn.frame.width + 6

        let closeBtn = makeBtn("Close", color: C_FAILURE, x: bx, y: y, h: btnH)
        closeBtn.target = self; closeBtn.action = #selector(doClose(_:))
        closeBtn.tag = 200
        addSubview(closeBtn)
        y += btnH + 10

        // Comment field + submit
        let sep2 = NSView(frame: NSRect(x: pad, y: y, width: contentW, height: 0.5))
        sep2.wantsLayer = true; sep2.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(sep2); y += 8

        let cf = NSTextField(frame: NSRect(x: pad, y: y, width: contentW - 80, height: 24))
        cf.placeholderString = "Leave a comment..."
        cf.font = .systemFont(ofSize: 11.5)
        addSubview(cf); commentField = cf

        let submitBtn = makeBtn("Comment", color: .linkColor, x: pad + contentW - 72, y: y, h: 24)
        submitBtn.target = self; submitBtn.action = #selector(doComment)
        addSubview(submitBtn)
        y += 32

        self.frame = NSRect(x: 0, y: 0, width: w, height: y)
    }
    required init?(coder: NSCoder) { fatalError() }

    func makeBtn(_ title: String, color: NSColor, x: CGFloat, y: CGFloat, h: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11, weight: .medium)
        b.contentTintColor = color
        let tw = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
        b.frame = NSRect(x: x, y: y, width: tw + 20, height: h)
        return b
    }

    func disableActions(_ message: String) {
        for sub in subviews where sub is NSButton {
            (sub as! NSButton).isEnabled = false
        }
        commentField.isEnabled = false
        commentField.stringValue = ""
        commentField.placeholderString = message
    }

    @objc func doApprove() {
        let body = commentField.stringValue.isEmpty ? nil : commentField.stringValue
        disableActions("Approving...")
        onAction?(.approve(body))
    }
    @objc func doRequestChanges() {
        let body = commentField.stringValue
        guard !body.isEmpty else { commentField.placeholderString = "Required: describe changes needed"; return }
        disableActions("Submitting review...")
        onAction?(.requestChanges(body))
    }
    @objc func doComment() {
        let body = commentField.stringValue
        guard !body.isEmpty else { return }
        disableActions("Posting comment...")
        onAction?(.comment(body))
    }
    @objc func doMerge() {
        let popup = subviews.compactMap { $0 as? NSPopUpButton }.first(where: { $0.tag == 100 })
        let methods = ["-m", "-r", "-s"]
        let method = methods[popup?.indexOfSelectedItem ?? 0]
        disableActions("Merging...")
        onAction?(.merge(method))
    }
    @objc func doClose(_ sender: NSButton) {
        if confirmingClose {
            onAction?(.close)
        } else {
            confirmingClose = true
            sender.title = "Sure?"; sender.contentTintColor = .white
            sender.layer?.backgroundColor = C_FAILURE.cgColor; sender.layer?.cornerRadius = 4
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, self.confirmingClose else { return }
                self.confirmingClose = false
                sender.title = "Close"; sender.contentTintColor = C_FAILURE
                sender.layer?.backgroundColor = nil
            }
        }
    }
}

extension TabVC {
func filteredPRs() -> [(String, [PR])] {
    guard let sel = selectedRepo else { return prGrouped }
    return prGrouped.filter { $0.0 == sel }
}

func buildPRContent(_ w: CGFloat) -> [NSView] {
    var rows: [NSView] = []
    let data = filteredPRs()
    if let err = lastFetchError {
        rows.append(EmptyRow(err, w: w, icon: "exclamationmark.triangle"))
        return rows
    }
    let hasPRs = data.contains { !$0.1.isEmpty }
    if !hasPRs {
        rows.append(EmptyRow("No pull requests awaiting your review", w: w, icon: "checkmark.seal"))
        return rows
    }
    for (repo, prs) in data {
        if prs.isEmpty { continue }
        rows.append(RepoHeader(repo, w: w))
        for pr in prs {
            let key = "\(repo)#\(pr.number)"
            let isExpanded = expandedPR == key
            let row = PRRow(pr, repo: repo, w: w, expanded: isExpanded)
            row.onToggle = { [weak self] in
                guard let self = self else { return }
                self.expandedPR = self.expandedPR == key ? nil : key
                // Semitransient when expanded (prevents accidental close while typing comment)
                let appDel = NSApp.delegate as? GHActionsBar
                appDel?.popover.behavior = self.expandedPR != nil ? .semitransient : .transient
                self.rebuildContent()
            }
            rows.append(row)
            if isExpanded {
                let detail = PRDetailView(pr, repo: repo, w: w)
                detail.onAction = { [weak self] action in
                    self?.handlePRAction(repo: repo, pr: pr, action: action)
                }
                rows.append(detail)
            }
        }
    }
    return rows
}

func handlePRAction(repo: String, pr: PR, action: PRAction) {
    executePRAction(repo: repo, number: pr.number, action: action) {
        (NSApp.delegate as? GHActionsBar)?.doRefresh()
    }
}
}

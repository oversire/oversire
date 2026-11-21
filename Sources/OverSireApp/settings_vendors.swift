import Cocoa
import OverSireCore

// Settings › Accounts and sync › Vendor CLIs (OVERSIRE-583): the version, the source and the state of each vendor CLI,
// with Install, Update and Remove. The app calls of OVERSIRE-582 do the work and write the event rows.

/// The rows of the Vendor CLIs section. The page and the tests make it from the state of `VendorsController`.
struct VendorsModel {
    /// The last install or remove of a vendor that failed.
    struct Failure: Equatable {
        let job: VendorJob
        let text: String
    }

    enum Badge: Equatable {
        case ok, old(String), missing, installing, removing, failed(String)

        /// Each state has its own symbol and word. Color is never the only signal.
        var tone: Tone {
            switch self {
            case .ok: return Tone(symbol: "checkmark.circle.fill", color: Palette.ok, word: "OK")
            case .old(let w): return Tone(symbol: "exclamationmark.triangle.fill", color: Palette.warn, word: w)
            case .missing: return Tone(symbol: "minus.circle", color: Palette.dim, word: "Not installed")
            case .installing: return Tone(symbol: "circle.dashed", color: Palette.run, word: "Installing…", spins: true)
            case .removing: return Tone(symbol: "circle.dashed", color: Palette.run, word: "Removing…", spins: true)
            case .failed(let w): return Tone(symbol: "exclamationmark.triangle.fill", color: Palette.warn, word: w)
            }
        }

        var word: String { tone.word }
    }

    struct Button: Equatable {
        enum Kind: Equatable {
            case install, update, remove
            /// Runs the Homebrew command in Terminal.
            case brew(String)
        }

        let kind: Kind
        let title: String
        let primary: Bool
        let enabled: Bool
        let label: String
        var tip: String?
    }

    struct Line {
        let vendor: String
        let symbol: String
        let title: String
        let detail: String
        let badge: Badge
        let error: String?
        let buttons: [Button]
        let label: String
    }

    static let footerText = "OverSire runs its own copy first. It uses the copy on PATH only when that copy is new enough. Remove deletes only the OverSire copy."
    static let emptyText = "Add a Plane or Big Timer account to use its vendor CLI."

    let lines: [Line]
    let footer: String
    let checkError: String?
    let empty: String?

    /// `offers`: the newest release of each vendor id. `busy`: the jobs that a click started. `client`: the name of the
    /// home Mac on a client.
    init(rows: [VendorCLIRow], offers: [String: String], offerError: String?, busy: [String: VendorJob],
         errors: [String: Failure], checkedAt: Date?, now: Date, client: String?, registry: ProviderRegistry = ENV.registry) {
        if let client {
            lines = []
            footer = ""
            checkError = nil
            empty = "OverSire runs the vendor CLIs on \(client). Install them there."
            return
        }
        lines = rows.map { r in
            let d = registry.descriptor(ProviderID(rawValue: r.provider))
            return Self.line(r, symbol: d?.symbol ?? "terminal", cli: d?.cli, offer: offers[r.provider],
                             job: busy[r.provider] ?? r.job, failure: errors[r.provider])
        }
        empty = rows.isEmpty ? Self.emptyText : nil
        footer = Self.footerText + (checkedAt.map { " Last check for updates: \(Self.ago($0, now: now))." } ?? "")
        checkError = offerError.map { "Could not check for updates: \($0)" }
    }

    static func line(_ r: VendorCLIRow, symbol: String, cli: VendorCLI?, offer: String?, job: VendorJob?, failure: Failure?) -> Line {
        let b = r.binary
        let failure = job == nil ? failure : nil
        var formula: String?
        if case .homebrew(let f)? = cli?.release { formula = f }
        let installed = r.path != nil
        let state = r.state ?? (installed ? .ok : .missing)
        let hasOwn = r.source == .oversire || r.ownVersion != nil
        let ownVersion = r.ownVersion ?? (r.source == .oversire ? r.version : nil)
        let title = installed ? ([b] + [r.version].compactMap { $0 }).joined(separator: " ") : b

        var parts = [r.vendor]
        if let path = r.path {
            if let s = r.source { parts.append(s == .oversire ? "OverSire copy" : "PATH copy") }
            parts.append((path as NSString).abbreviatingWithTildeInPath)
            if r.source == .path, let own = r.ownVersion { parts.append("OverSire copy \(own) is old") }
            if let cli, cli.tokenEnv == nil { parts.append("\(b) keeps its own login") }
        } else {
            parts.append(formula != nil ? "Not installed. Install it with Homebrew." : "Not installed. vendor run refuses \(r.provider).")
        }

        let badge: Badge
        switch job {
        case .installing?: badge = .installing
        case .removing?: badge = .removing
        case nil:
            if let failure {
                badge = .failed(failure.job == .installing ? "Install failed" : "Remove failed")
            } else {
                switch state {
                case .ok: badge = .ok
                case .old: badge = .old(r.minVersion.map { "Old: needs \($0)" } ?? "Old")
                case .missing: badge = .missing
                }
            }
        }

        let remove = Button(kind: .remove, title: "Remove…", primary: false, enabled: job == nil, label: "Remove the OverSire copy of \(b)")
        var buttons: [Button] = []
        if let formula {
            if !installed {
                buttons = [Button(kind: .brew("brew install \(formula)"), title: "Install in Terminal…", primary: false, enabled: true,
                                  label: "Install \(b) with Homebrew in Terminal")]
            } else if state == .old {
                buttons = [Button(kind: .brew("brew upgrade \(formula)"), title: "Update in Terminal…", primary: true, enabled: true,
                                  label: "Update \(b) with Homebrew in Terminal")]
            }
        } else if job == .installing {
            buttons = [Button(kind: .install, title: "Installing…", primary: true, enabled: false, label: "Installing \(b)")]
                + (hasOwn ? [remove] : [])
        } else if failure?.job == .installing {
            buttons = [Button(kind: .install, title: "Try again", primary: true, enabled: true, label: "Try the install of \(b) again")]
                + (hasOwn ? [remove] : [])
        } else {
            let newest = offer.flatMap(VendorVersion.init)
            let on = job == nil
            if hasOwn {
                // The OverSire copy is old, or the PATH copy wins over it.
                let ownOld = r.source == .path || state != .ok
                if let newest, let o = offer, ownVersion.flatMap(VendorVersion.init).map({ $0 < newest }) ?? true {
                    buttons.append(Button(kind: .update, title: "Update to \(o)", primary: true, enabled: on, label: "Update \(b) to \(o)"))
                } else if offer == nil, ownOld {
                    buttons.append(Button(kind: .update, title: "Update", primary: true, enabled: on, label: "Update \(b)"))
                }
                buttons.append(remove)
            } else if installed, state == .ok {
                buttons.append(Button(kind: .install, title: "Install", primary: false, enabled: on,
                                      label: "Install an OverSire copy of \(b). The PATH copy stays.",
                                      tip: "Install an OverSire copy. The PATH copy stays."))
            } else {
                buttons.append(Button(kind: .install, title: offer.map { "Install \($0)" } ?? "Install", primary: true, enabled: on,
                                      label: "Install \(b)" + (offer.map { " \($0)" } ?? "")))
            }
        }

        var said = [title]
        if installed, let s = r.source { said.append(s == .oversire ? "OverSire copy" : "PATH copy") }
        said.append(badge.word)
        if let failure { said.append(failure.text) }
        if let next = buttons.first(where: { $0.primary && $0.enabled }) { said.append(next.title.prefix(1).lowercased() + next.title.dropFirst()) }
        return Line(vendor: r.provider, symbol: symbol, title: title, detail: parts.joined(separator: " · "), badge: badge,
                    error: failure?.text, buttons: buttons, label: said.joined(separator: ", "))
    }

    /// The title and the text of the remove question. `pathCopy`: a PATH copy that is new enough.
    static func removeQuestion(_ r: VendorCLIRow, pathCopy: (path: String, version: String?)?) -> (title: String, info: String) {
        let own = r.ownVersion ?? (r.source == .oversire ? r.version : nil)
        let title = "Remove the OverSire copy of \(r.binary)\(own.map { " \($0)" } ?? "")?"
        guard let p = pathCopy else { return (title, "Then vendor run refuses \(r.provider) until you install it again.") }
        let path = (p.path as NSString).abbreviatingWithTildeInPath
        return (title, "OverSire then uses \(path)\(p.version.map { " \($0)" } ?? "") from PATH.")
    }

    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}

/// Reads the vendor CLIs for the section and runs Install, Update and Remove. Main thread only.
final class VendorsController {
    static let shared = VendorsController()
    static let checkEvery: TimeInterval = 3600

    private static var calls: VendorCalls? { (NSApp?.delegate as? GHActionsBar)?.vendorCalls }

    var list: () async -> [VendorCLIRow] = { await VendorsController.calls?.list() ?? [] }
    /// The newest release of a vendor, or the reason that the check failed.
    var offer: (String) async -> Result<String, VendorCallError> = { id in
        guard let calls = VendorsController.calls else { return .failure(.failed("The app does not run vendor calls.")) }
        switch await calls.offer(ProviderID(rawValue: id)) {
        case .success(let o): return .success(o.version.description)
        case .failure(let e): return .failure(e)
        }
    }
    /// The app call of a click: the event rows name a human.
    var installCall: (String) async -> VendorOutcome = { id in
        guard let calls = VendorsController.calls else { return .refused(.failed("The app does not run vendor calls.")) }
        return await calls.install(id, caller: .user)
    }
    var removeCall: (String) async -> VendorOutcome = { id in
        guard let calls = VendorsController.calls else { return .refused(.failed("The app does not run vendor calls.")) }
        return await calls.remove(id, caller: .user)
    }
    /// The PATH copy of a vendor when it is new enough. The remove question names it.
    var pathCopy: (String) async -> (path: String, version: String?)? = { id in
        guard let b = await VendorsController.calls?.pathCopy(ProviderID(rawValue: id)), b.state == .ok, let p = b.path else { return nil }
        return (p, b.version?.description)
    }
    var changed: () -> Void = { ChangeBus.shared.post(DataChange(.connection, origin: .user)) }
    var now: () -> Date = { Date() }
    var registry: ProviderRegistry = ENV.registry

    private(set) var rows: [VendorCLIRow] = []
    private(set) var offers: [String: String] = [:]
    private(set) var offerError: String?
    private(set) var busy: [String: VendorJob] = [:]
    private(set) var errors: [String: VendorsModel.Failure] = [:]
    private(set) var checkedAt: Date?
    private(set) var checking = false
    private(set) var loaded = false
    private var loading = false
    private var again = false

    func model(client: String?) -> VendorsModel {
        VendorsModel(rows: rows, offers: offers, offerError: offerError, busy: busy, errors: errors, checkedAt: checkedAt,
                     now: now(), client: client, registry: registry)
    }

    /// Reads the rows again. The page calls it on each build. It posts a change only when the rows change.
    func load() {
        guard !loading else { again = true; return }
        loading = true
        Task { @MainActor in await self.reload() }
    }

    @MainActor func reload(post: Bool = true) async {
        loading = true
        let new = await list()
        loading = false
        let differs = !loaded || new != rows
        rows = new
        loaded = true
        if differs, post { changed() }
        if again {
            again = false
            load()
        }
        await checkNow(force: false)
    }

    /// Reads the release sources at most once each hour, unless `force` is true.
    func check(force: Bool) {
        Task { @MainActor in await self.checkNow(force: force) }
    }

    @MainActor func checkNow(force: Bool) async {
        guard !checking else { return }
        let ids = rows.map(\.provider).filter(installable)
        guard !ids.isEmpty else { return }
        if !force, let at = checkedAt, now().timeIntervalSince(at) < Self.checkEvery { return }
        checking = true
        changed()
        var failed: [String] = []
        for id in ids {
            switch await offer(id) {
            case .success(let v): offers[id] = v
            case .failure(let e): if !failed.contains(e.message) { failed.append(e.message) }
            }
        }
        offerError = failed.isEmpty ? nil : failed.joined(separator: " ")
        checkedAt = now()
        checking = false
        changed()
    }

    /// OverSire installs the vendor itself: not a Homebrew formula.
    private func installable(_ id: String) -> Bool {
        switch registry.descriptor(ProviderID(rawValue: id))?.cli?.release {
        case .trebiCatalog?, .githubRelease?: return true
        case .homebrew?, nil: return false
        }
    }

    func install(_ vendor: String) { Task { @MainActor in await self.run(.installing, vendor) } }
    func remove(_ vendor: String) { Task { @MainActor in await self.run(.removing, vendor) } }

    @MainActor func run(_ job: VendorJob, _ vendor: String) async {
        guard busy[vendor] == nil else { return }
        busy[vendor] = job
        errors[vendor] = nil
        changed()
        let o = job == .installing ? await installCall(vendor) : await removeCall(vendor)
        busy[vendor] = nil
        await reload(post: false)
        // A long install goes on in the app after the call returns. The row then shows its job, not an error.
        if o.status != .ok, rows.first(where: { $0.provider == vendor })?.job == nil {
            errors[vendor] = VendorsModel.Failure(job: job, text: o.summary)
        }
        changed()
    }

    /// `--uishots`: a fixed state.
    func seed(rows: [VendorCLIRow], offers: [String: String] = [:], offerError: String? = nil, busy: [String: VendorJob] = [:],
              errors: [String: VendorsModel.Failure] = [:], checkedAt: Date? = nil) {
        self.rows = rows
        self.offers = offers
        self.offerError = offerError
        self.busy = busy
        self.errors = errors
        self.checkedAt = checkedAt
        loaded = true
    }
}

extension SettingsPage {
    func vendors(_ b: NSStackView) {
        let c = VendorsController.shared
        c.load()
        let m = c.model(client: nil)
        var head: NSView?
        if !m.lines.isEmpty {
            let check = ActionButton(c.checking ? "Checking…" : "Check for updates", style: .link) { c.check(force: true) }
            check.isEnabled = !c.checking
            head = check
        }
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.vendors.title, action: head)], spacing: 6)
        let card = ListCard()
        if let e = m.empty { card.add(Padded(NSTextField.text(e, size: 12, color: Palette.dim))) }
        m.lines.forEach { card.add(vendorRow($0)) }
        v.addFull(card)
        if !m.lines.isEmpty {
            v.addFull(NSTextField.text(m.footer, size: 11.5, color: Palette.dim, lines: 0))
            if let e = m.checkError {
                v.addFull(NSStackView(h: [Glyph("exclamationmark.triangle.fill", color: Palette.warn, size: 11, label: "Warning"),
                                          NSTextField.text(e, size: 11.5, color: Palette.warn, lines: 0)], spacing: 5, align: .top))
            }
        }
        v.identifier = SettingsAnchor.vendors.id
        b.addFull(v)
    }

    /// A client runs no vendor CLI: one line, no rows.
    func clientVendors(_ b: NSStackView) {
        let m = VendorsModel(rows: [], offers: [:], offerError: nil, busy: [:], errors: [:], checkedAt: nil, now: Date(), client: data.clientName)
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.vendors.title)], spacing: 6)
        v.addFull(NSTextField.text(m.empty ?? "", size: 12, color: Palette.dim, lines: 0))
        v.identifier = SettingsAnchor.vendors.id
        b.addFull(v)
    }

    private func vendorRow(_ l: VendorsModel.Line) -> NSView {
        let c = VendorsController.shared
        var sub: [NSView] = [NSTextField.text(l.detail, size: 11.5, color: Palette.dim)]
        if let e = l.error {
            sub.append(NSStackView(h: [Glyph("exclamationmark.triangle.fill", color: Palette.warn, size: 11),
                                       NSTextField.text(e, size: 11.5, color: Palette.warn, lines: 2)], spacing: 4, align: .top))
        }
        var cells: [NSView] = [Glyph(l.symbol, size: 16), TwoLine(l.title, subView: NSStackView(v: sub, spacing: 2)), Spacer(),
                               Pill(l.badge.tone, spins: true)]
        for btn in l.buttons {
            let a = ActionButton(btn.title, style: btn.primary ? .primary : .plain) { [weak self] in
                switch btn.kind {
                case .install, .update: c.install(l.vendor)
                case .remove: self?.confirmRemove(l)
                case .brew(let command): runInTerminal(command)
                }
            }
            a.isEnabled = btn.enabled
            a.setAccessibilityLabel(btn.label)
            if let tip = btn.tip { a.toolTip = tip }
            cells.append(a)
        }
        return Row(cells, height: l.error == nil ? 56 : 74, label: l.label)
    }

    private func confirmRemove(_ line: VendorsModel.Line) {
        let c = VendorsController.shared
        guard let row = c.rows.first(where: { $0.provider == line.vendor }) else { return }
        Task { @MainActor [weak self] in
            var path: (path: String, version: String?)?
            if row.source == .path, row.state == .ok, let p = row.path { path = (p, row.version) } else { path = await c.pathCopy(row.provider) }
            let q = VendorsModel.removeQuestion(row, pathCopy: path)
            AlertConfirm.ask(q.title, info: q.info, button: "Remove", critical: true, in: self?.view.window) { c.remove(row.provider) }
        }
    }
}

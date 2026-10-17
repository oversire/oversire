import Cocoa
import OverSireCore

// Settings › Providers: the accounts of each layer. The form of a new account comes from the
// ConfigField list of the provider descriptor.
final class ProvidersForm {
    /// The layer whose "Add account" is open, the provider and the account that the form edits.
    var layer: Layer?
    var provider: ProviderID?
    var editing: AccountID?
    var values: [String: String] = [:]
    var status: (text: String, error: Bool)?
    var testing = false
    var fields: [String: NSControl] = [:]
    /// The probe result of each account: the name of the user, or the error.
    var probes: [AccountID: Result<String, ProviderError>] = [:]
    var probing: Set<AccountID> = []

    func close() {
        layer = nil
        provider = nil
        editing = nil
        values = [:]
        status = nil
        fields = [:]
    }

    /// Reads the controls into `values`, so a rebuild keeps what the user typed.
    func keep() {
        for (k, c) in fields {
            if let p = c as? NSPopUpButton { values[k] = p.titleOfSelectedItem ?? "" }
            else { values[k] = c.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

/// The typed secrets of the form under the key "FORM_<field>". An empty field keeps the stored secret.
struct FormSecrets: SecretReader {
    let typed: [String: String]
    let stored: [String: String]      // field → stored key
    let base: any SecretReader

    func secret(_ key: String) -> String? {
        guard key.hasPrefix("FORM_") else { return base.secret(key) }
        let field = String(key.dropFirst(5))
        if let v = typed[field], !v.isEmpty { return v }
        return stored[field].flatMap(base.secret)
    }
}

extension SettingsPage {
    static let providersForm = ProvidersForm()
    private var form: ProvidersForm { SettingsPage.providersForm }

    static let layerInfo: [(Layer, String, String)] = [
        (.tracker, "Tracker", "Items, projects and comments"),
        (.codeHost, "Code host", "Repos, branches and pull requests"),
        (.ci, "CI", "Runs and logs"),
        (.runtime, "Agent runtime", "Agent sessions and workspaces"),
    ]

    /// The features that the UI hides without the capability.
    static let features: [(String, Capability)] = [
        ("Intake tab and intake triage", .intake), ("Item timeline", .timeline), ("Sub-items", .subItems),
        ("Re-run and cancel a run", .rerun), ("Run logs and failure reasons", .logs),
        ("Merge and approve from OverSire", .changeActions), ("Send input to a session", .sessionInput),
    ]

    func providers(_ b: NSStackView) {
        b.addFull(NSTextField.text("The accounts that OverSire reads, by layer. Each account polls on its own. The cloud adds live updates on top.",
                                   size: 12, color: Palette.dim, lines: 0))
        for (layer, title, why) in Self.layerInfo { b.addFull(layerCard(layer, title: title, why: why)) }
        let have = ENV.capabilities()
        let off = Self.features.filter { !have.contains($0.1) }
        let c = Card(title: "Features off", trailing: [NSTextField.text("No account has the capability", size: 11.5, color: Palette.dim)])
        if off.isEmpty { c.add(NSTextField.text("All features are on.", size: 12.5, color: Palette.dim)) }
        for (name, cap) in off {
            c.add(NSStackView(h: [NSTextField.text(name, size: 12.5), Spacer(), Chiplet(cap.rawValue, mono: true)], spacing: 8))
        }
        b.addFull(c)
    }

    private func layerCard(_ layer: Layer, title: String, why: String) -> NSView {
        let open = form.layer == layer
        let add = ActionButton(open ? "Close" : "Add account") { [weak self] in
            guard let self else { return }
            if open { self.form.close() } else {
                self.form.close()
                self.form.layer = layer
                self.form.provider = ENV.registry.descriptors(layer).first?.id
            }
            self.reload()
        }
        let c = Card(title: title, trailing: [NSTextField.text(why, size: 11.5, color: Palette.dim), add])
        let list = ENV.accounts(layer)
        if list.isEmpty { c.add(NSTextField.text("No \(title.lowercased()) account. OverSire hides the features of this layer.", size: 12.5, color: Palette.dim)) }
        for a in list { c.add(accountRow(a)) }
        if layer == .codeHost || layer == .ci, !list.isEmpty {
            c.add(NSTextField.text("GitHub and GitHub Actions follow the repos that you pick on the Repos page.", size: 11.5, color: Palette.dim, lines: 0))
        }
        if open { formViews(layer).forEach(c.add) }
        return c
    }

    private func accountRow(_ a: AccountConfig) -> NSView {
        guard let d = ENV.descriptor(a.account) else { return NSTextField.text(a.account.provider.rawValue, size: 12.5) }
        var parts: [String] = []
        for f in d.fields where f.kind != .secret {
            guard let v = a.values[f.key], !v.isEmpty, v != a.account.id, v != f.help else { continue }
            let n = v.split(separator: ",").count
            parts.append(n > 1 ? "\(n) \(f.label.lowercased())" : v.hasPrefix("/") ? (v as NSString).abbreviatingWithTildeInPath : v)
        }
        let hasSecret = a.secretKeys.contains { !(ENV.secrets.secret($0) ?? "").isEmpty }
        if hasSecret { parts.append("token in Keychain") }
        else if case .cli(let name)? = d.auth.first(where: { if case .cli = $0 { return true }; return false }) { parts.append("\(name) login") }
        else if d.fields.contains(where: { $0.kind == .secret && $0.required }) { parts.append("no token") }

        let status: NSView
        if form.probing.contains(a.account) { status = Pill(.running, text: "Testing") }
        else {
            switch form.probes[a.account] {
            case .success(let who)?: status = Pill(.ok, text: "Connected as \(who)")
            case .failure(let e)?: status = Pill(.bad, text: e.message)
            case nil: status = Pill(.queued, text: ENV.error(a.account) ?? "Not tested")
            }
        }
        let title = NSStackView(h: [NSTextField.text(d.displayName, size: 13, weight: .semibold),
                                    NSTextField.text("· " + a.account.id, size: 13, color: Palette.mut)], spacing: 4)
        let text = NSStackView(v: [title, NSTextField.text(parts.joined(separator: " · "), size: 11.5, color: Palette.dim)], spacing: 2)
        let buttons: [NSView] = [
            ActionButton("Test") { [weak self] in self?.probe(a.account) },
            ActionButton("Edit") { [weak self] in
                guard let self else { return }
                self.form.close()
                self.form.layer = d.layer
                self.form.provider = d.id
                self.form.editing = a.account
                self.form.values = a.values
                self.reload()
            },
            ActionButton("Remove") { [weak self] in self?.removeAccount(a, d) },
        ]
        let top = NSStackView(h: [Glyph(d.symbol, size: 15), text, Spacer(), status] + buttons, spacing: 8)
        let caps = (ENV.provider(a.account)?.capabilities ?? []).map(\.rawValue).sorted()
        let row = NSStackView(v: [top], spacing: 6)
        top.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        if !caps.isEmpty {
            let wrap = Wrap(caps.map { Chiplet($0, mono: true) })
            let line = NSStackView(h: [Spacer(23), wrap], spacing: 0, align: .top)
            row.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        if form.probes[a.account] == nil, !form.probing.contains(a.account), ENV.error(a.account) == nil { probe(a.account) }
        return row
    }

    private func probe(_ id: AccountID) {
        guard let p = ENV.provider(id) else { reload(); return }
        form.probing.insert(id)
        Task { @MainActor [weak self] in
            let r: Result<String, ProviderError>
            do { r = .success(try await p.probe().person.name) } catch {
                r = .failure(error as? ProviderError ?? .transport(error.localizedDescription))
            }
            SettingsPage.providersForm.probing.remove(id)
            SettingsPage.providersForm.probes[id] = r
            self?.reloadSoon()
        }
    }

    private func removeAccount(_ a: AccountConfig, _ d: ProviderDescriptor) {
        let alert = NSAlert()
        alert.messageText = "Remove the \(d.displayName) account \(a.account.id)?"
        alert.informativeText = d.layer == .codeHost || d.layer == .ci
            ? "OverSire stops to track the repos of \(a.account.id), for GitHub and GitHub Actions."
            : "OverSire deletes its secrets from the Keychain and stops to read this account."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ENV.remove(a.account)
        form.probes[a.account] = nil
        accountsChanged()
    }

    private func accountsChanged() {
        saveConfig()
        NotificationCenter.default.post(name: AppEnvironment.changed, object: nil)
        reload()
    }

    // MARK: Form

    private func formViews(_ layer: Layer) -> [NSView] {
        let all = ENV.registry.descriptors(layer)
        var out: [NSView] = []
        if form.editing == nil {
            let picks = all.map { d in
                ActionButton(d.displayName, symbol: d.symbol, style: d.id == form.provider ? .primary : .plain) { [weak self] in
                    self?.form.keep()
                    self?.form.provider = d.id
                    self?.form.values = [:]
                    self?.form.status = nil
                    self?.reload()
                } as NSView
            }
            out.append(NSStackView(h: [NSTextField.text("Provider", size: 12, color: Palette.dim)] + picks + [Spacer()], spacing: 6))
        }
        guard let d = all.first(where: { $0.id == form.provider }) else { return out }
        form.fields = [:]
        let head = form.editing.map { "Edit \(d.displayName) · \($0.id)" } ?? "New \(d.displayName) account"
        out.append(NSStackView(h: [Glyph(d.symbol, size: 14), NSTextField.text(head, size: 13, weight: .semibold), Spacer()], spacing: 6))
        for f in d.fields { out.append(fieldRow(f)) }
        var acts: [NSView] = [
            ActionButton(form.testing ? "Testing…" : form.editing == nil ? "Test & Add" : "Test & Save", style: .primary) { [weak self] in self?.submit(d) },
            ActionButton("Cancel") { [weak self] in self?.form.close(); self?.reload() },
        ]
        if let url = d.docsURL { acts.append(ActionButton("Help", symbol: "questionmark.circle") { NSWorkspace.shared.open(url) }) }
        if let s = form.status { acts.append(NSTextField.text(s.text, size: 12, color: s.error ? Palette.bad : Palette.ok, lines: 0)) }
        out.append(NSStackView(h: acts + [Spacer()], spacing: 8))
        return out
    }

    private func fieldRow(_ f: ConfigField) -> NSView {
        let value = form.values[f.key] ?? ""
        let control: NSControl
        let inPlaceholder = f.kind == .url || f.help?.hasPrefix("/") == true
        switch f.kind {
        case .choice(let options):
            let p = NSPopUpButton()
            p.addItems(withTitles: options)
            p.selectItem(withTitle: value)
            control = p
        case .secret:
            let s = NSSecureTextField()
            s.placeholderString = form.editing == nil ? "" : "Unchanged"
            control = s
        case .text, .url:
            let t = NSTextField()
            t.stringValue = value
            if inPlaceholder { t.placeholderString = f.help }
            control = t
        }
        control.setAccessibilityLabel(f.label)
        control.widthAnchor.constraint(equalToConstant: 280).isActive = true
        form.fields[f.key] = control
        var note = f.kind == .secret ? "OverSire keeps it in the Keychain." : nil
        if let h = f.help, !inPlaceholder { note = [h, note].compactMap { $0 }.joined(separator: " ") }
        return FieldRow(f.required ? f.label : f.label + " (optional)", note: note, control)
    }

    private func submit(_ d: ProviderDescriptor) {
        form.keep()
        let missing = d.fields.filter { $0.required && $0.kind != .secret && (form.values[$0.key] ?? "").isEmpty }
            + d.fields.filter { $0.required && $0.kind == .secret && form.editing == nil && (form.values[$0.key] ?? "").isEmpty }
        if !missing.isEmpty {
            form.status = ("Fill in " + missing.map(\.label).joined(separator: ", ") + ".", true)
            reload(); return
        }
        if let bad = d.fields.first(where: { $0.kind == .url && !(form.values[$0.key] ?? "").isEmpty
                                             && !(form.values[$0.key]!.hasPrefix("https://") || form.values[$0.key]!.hasPrefix("http://")) }) {
            form.status = ("\(bad.label) must start with https://", true)
            reload(); return
        }
        let secretFields = d.fields.filter { $0.kind == .secret }.map(\.key)
        let typed = form.values.filter { secretFields.contains($0.key) }
        var values = form.values.filter { !secretFields.contains($0.key) }
        for (k, v) in values where v.hasSuffix("/") && d.fields.first(where: { $0.key == k })?.kind == .url { values[k] = String(v.dropLast()) }
        let old = form.editing.flatMap { id in ENV.accounts.first { $0.account == id } }
        var stored: [String: String] = [:]
        for k in secretFields { stored[k] = old.map { AppEnvironment.secretKey($0.account, field: k) } }
        let trial = AccountConfig(account: AccountID(provider: d.id, id: d.fields.lazy.compactMap { values[$0.key] }.first { !$0.isEmpty } ?? "new"),
                                  values: values, secretKeys: secretFields.map { "FORM_" + $0 })
        let io = ENV.io(d.id, secrets: FormSecrets(typed: typed, stored: stored, base: ENV.secrets))
        let editing = form.editing
        form.testing = true
        form.status = ("Testing…", false)
        reload()
        Task { @MainActor [weak self] in
            let f = SettingsPage.providersForm
            f.testing = false
            do {
                let p = try d.make(trial, io)
                let who = try await p.probe().person.name
                ENV.save(AccountConfig(account: p.account, values: values), secrets: typed, replacing: editing)
                f.close()
                f.probes[p.account] = .success(who)
                self?.accountsChanged()
            } catch {
                let e = error as? ProviderError ?? .transport(error.localizedDescription)
                f.status = ("\(e.message). Nothing was saved.", true)
                self?.reload()
            }
        }
    }
}

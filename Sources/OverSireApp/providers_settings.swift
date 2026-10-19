import Cocoa
import OverSireCore

// Settings › Accounts and sync: the accounts of each layer. The form of a new account comes from the
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
        var cards: [NSView] = []
        for (layer, _, _) in Self.layerInfo {
            for d in ENV.registry.descriptors(layer) {
                let list = ENV.accounts(layer).filter { $0.account.provider == d.id }
                if !list.isEmpty { cards.append(serviceCard(d, list)) }
            }
        }
        cards.append(ServiceCard(icon: ServiceCard.icon("+", color: nil), name: "Add a service", detail: "Tracker, code host, CI or agent runtime",
                                 status: nil, actions: [], dashed: true) { [weak self] in self?.openForm(.tracker) })
        let v = NSStackView(v: [SectionTitle("Services")], spacing: 6)
        v.addFull(CardGrid(cards, minWidth: 240))
        v.identifier = SettingsAnchor.services.id
        if form.layer != nil { v.addFull(formCard()) }
        v.addFull(ghLogin())
        let off = Self.features.filter { !ENV.capabilities().contains($0.1) }.map(\.0)
        if !off.isEmpty {
            v.addFull(NSTextField.text("Features off, because no account has them: " + off.joined(separator: ", ") + ".", size: 11.5, color: Palette.dim, lines: 0))
        }
        b.addFull(v)
    }

    private func openForm(_ layer: Layer, provider: ProviderID? = nil) {
        form.close()
        form.layer = layer
        form.provider = provider ?? ENV.registry.descriptors(layer).first?.id
        reload()
    }

    private func formCard() -> NSView {
        let editing = form.editing != nil
        let c = Card(title: editing ? "Edit the account" : "Add a service",
                     trailing: [ActionButton("Close") { [weak self] in self?.form.close(); self?.reload() }])
        guard let layer = form.layer else { return c }
        if !editing {
            let layers = Self.layerInfo.map(\.0)
            c.add(FieldRow("Layer", note: Self.layerInfo.first { $0.0 == layer }?.2,
                           Segmented(Self.layerInfo.map(\.1), selected: layers.firstIndex(of: layer) ?? 0, label: "Layer") { [weak self] i in
                self?.openForm(layers[i])
            }))
        }
        formViews(layer).forEach(c.add)
        return c
    }

    // gh owns the GitHub login. OverSire keeps no GitHub token.
    private func ghLogin() -> NSView {
        let cat = app?.catalog
        let user = cat?.user
        let text = user.map { "Signed in as \($0)" } ?? (cat?.authChecked == true ? "Not signed in. GitHub pages stay empty." : "Checks the gh login…")
        let act = user == nil ? ActionButton("Sign in…") { runInTerminal("gh auth login --web -p https") }
                              : ActionButton("Sign out…") { runInTerminal("gh auth logout") }
        let c = ListCard()
        c.add(Row([Glyph(user == nil ? .warning : .ok, size: 14), TwoLine("GitHub CLI login", text, weight: .medium), Spacer(), act], height: 52,
                  label: "GitHub CLI login"))
        return c
    }

    // One card for each provider. Edit and Remove ask for the account when the provider has more than one.
    private func serviceCard(_ d: ProviderDescriptor, _ list: [AccountConfig]) -> NSView {
        var detail = [Self.layerInfo.first { $0.0 == d.layer }?.1 ?? "", list.map(\.account.id).joined(separator: ", ")]
        if list.count == 1, let a = list.first {
            for f in d.fields where f.kind != .secret {
                guard let v = a.values[f.key], !v.isEmpty, v != a.account.id, v != f.help else { continue }
                let n = v.split(separator: ",").count
                detail.append(n > 1 ? "\(n) \(f.label.lowercased())" : v.hasPrefix("/") ? (v as NSString).abbreviatingWithTildeInPath : v)
            }
        }
        if case .cli(let name)? = d.auth.first(where: { if case .cli = $0 { return true }; return false }) { detail.append("\(name) login") }
        var errors: [String] = [], who: [String] = []
        for a in list {
            switch form.probes[a.account] {
            case .success(let n)?: who.append("\(a.account.id): \(n)")
            case .failure(let e)?: errors.append("\(a.account.id): \(e.message)")
            case nil:
                if let e = ENV.error(a.account) { errors.append("\(a.account.id): \(e)") }
                else if !form.probing.contains(a.account) { probe(a.account) }
            }
        }
        let status: Pill
        if list.contains(where: { form.probing.contains($0.account) }) { status = Pill(.running, text: "Testing") }
        else if !errors.isEmpty { status = Pill(.bad, text: list.count == 1 ? "Failed" : "\(errors.count) failed") }
        else if who.count == list.count { status = Pill(.ok, text: "OK") }
        else { status = Pill(.queued, text: "Not tested") }
        status.toolTip = (errors + who.map { "Connected as \($0)" }).joined(separator: "\n")
        if !errors.isEmpty { detail = [errors.joined(separator: " · ")] }

        let edit: (AccountConfig) -> Void = { [weak self] a in
            guard let self else { return }
            self.form.close()
            self.form.layer = d.layer
            self.form.provider = d.id
            self.form.editing = a.account
            self.form.values = a.values
            self.reload()
        }
        let remove: (AccountConfig) -> Void = { [weak self] a in self?.removeAccount(a, d) }
        func pick(_ title: String, _ run: @escaping (AccountConfig) -> Void) -> NSView {
            if list.count == 1 { return ActionButton(title) { run(list[0]) } }
            return MenuChip(title + "…") { list.map { a in MenuAction(a.account.id) { run(a) } } }
        }
        let actions: [NSView] = [
            ActionButton("Test") { [weak self] in list.forEach { self?.probe($0.account) } },
            pick("Edit", edit), pick("Remove", remove),
            ActionButton("Add account", style: .link) { [weak self] in
                self?.openForm(d.layer, provider: d.id)
            },
        ]
        let icon = Box(fill: Palette.raise, border: nil, radius: 7)
        let g = Glyph(d.symbol, size: 15)
        g.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(g)
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
                                     g.centerXAnchor.constraint(equalTo: icon.centerXAnchor), g.centerYAnchor.constraint(equalTo: icon.centerYAnchor)])
        return ServiceCard(icon: icon, name: d.displayName, detail: detail.filter { !$0.isEmpty }.joined(separator: " · "), status: status, actions: actions)
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

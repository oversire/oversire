import Cocoa
import OverSireAssistant
import OverSireCore

// "New epic": a sheet over epic.create. It shows only the fields that the tracker gives to an epic.
final class NewEpicSheet: NSObject, NSTextFieldDelegate {
    private static var open: NewEpicSheet?

    /// `done` gets the id of the new epic.
    static func present(over window: NSWindow?, snap: ProjectSnapshot, data: AppData, done: ((EpicID) -> Void)? = nil) {
        let s = NewEpicSheet(snap: snap, data: data, done: done)
        open = s
        s.show(over: window)
    }

    private let snap: ProjectSnapshot
    private unowned let data: AppData
    private let finished: ((EpicID) -> Void)?
    private let fields: Set<EpicField>
    private let sheet = DialogSheet(title: "New epic", width: 480)
    private let title = NSTextField()
    private let goal = NSTextView()
    private var dates: [EpicField: (on: NSButton, picker: NSDatePicker)] = [:]
    private let lead = NSPopUpButton(frame: .zero, pullsDown: false)
    private let problem = NSTextField.text("", size: 12, color: Palette.bad, lines: 2)

    private init(snap: ProjectSnapshot, data: AppData, done: ((EpicID) -> Void)?) {
        self.snap = snap
        self.data = data
        finished = done
        fields = ENV.descriptor(snap.summary.ref.account)?.epicFields ?? []
        super.init()
    }

    private func labeled(_ text: String, _ view: NSView) -> NSView {
        let v = NSStackView(v: [NSTextField.text(text, size: 12, weight: .medium), view], spacing: 5)
        view.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        return v
    }

    private func show(over window: NSWindow?) {
        let noun = ENV.descriptor(snap.summary.ref.account)?.epicNoun
        sheet.setTitle("New epic in \(snap.summary.title)")
        _ = noun.map { sheet.note("OverSire makes a \(ENV.descriptor(snap.summary.ref.account)?.displayName ?? "") \($0).") }

        title.placeholderString = "Short name of the epic"
        title.setAccessibilityLabel("Title")
        title.delegate = self
        title.translatesAutoresizingMaskIntoConstraints = false
        sheet.stack.addFull(labeled("Title", title))

        if fields.contains(.goal) {
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            goal.isRichText = false
            goal.font = .systemFont(ofSize: 12.5)
            goal.isVerticallyResizable = true
            goal.autoresizingMask = [.width]
            goal.textContainerInset = NSSize(width: 4, height: 4)
            goal.setAccessibilityLabel("Goal")
            scroll.documentView = goal
            scroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
            sheet.stack.addFull(labeled("Goal (Markdown)", scroll))
        }

        var pickers: [NSView] = []
        for (field, name) in [(EpicField.startDate, "Start date"), (.targetDate, "Target date")] where fields.contains(field) {
            let on = NSButton(checkboxWithTitle: name, target: self, action: #selector(dateToggled))
            let picker = NSDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.dateValue = Calendar.current.date(byAdding: .day, value: field == .startDate ? 0 : 14, to: Date()) ?? Date()
            picker.isEnabled = false
            picker.setAccessibilityLabel(name)
            on.setAccessibilityLabel("Set \(name.lowercased())")
            dates[field] = (on, picker)
            pickers.append(NSStackView(v: [on, picker], spacing: 5, align: .leading))
        }
        if !pickers.isEmpty { sheet.stack.addFull(NSStackView(h: pickers + [Spacer()], spacing: 24, align: .top)) }

        if fields.contains(.lead) {
            lead.addItem(withTitle: "No lead")
            lead.setAccessibilityLabel("Lead")
            if let id = snap.meId {
                lead.addItem(withTitle: "Me" + (snap.me.map { " (\($0))" } ?? ""))
                lead.lastItem?.representedObject = id
                lead.selectItem(at: 1)
            }
            lead.translatesAutoresizingMaskIntoConstraints = false
            sheet.stack.addFull(labeled("Lead", lead))
            loadPeople()
        }

        problem.isHidden = true
        sheet.stack.addFull(problem)
        sheet.onClose = { if NewEpicSheet.open === self { NewEpicSheet.open = nil } }
        sheet.buttons(cancel: "Cancel", primary: "Create epic", onCancel: { [weak self] in self?.sheet.dismiss() }) { [weak self] in self?.create() }
        sheet.primaryButton?.isEnabled = false
        sheet.present(over: window)
        sheet.makeFirstResponder(title)
    }

    // The members of the project join the list when they arrive.
    private func loadPeople() {
        let key = snap.summary.ref.storeKey, mine = snap.meId
        Task { [data] in
            let r = await data.actions.run("people.list", ActionArgs(.object(["project": .string(key)])))
            guard case .ok(_, let rows?, _) = r, let list = try? JSONDecoder().decode([PersonDetail].self, from: JSONEncoder().encode(rows)) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for p in list where p.id != mine && self.lead.itemArray.allSatisfy({ ($0.representedObject as? String) != p.id }) {
                    self.lead.addItem(withTitle: p.name)
                    self.lead.lastItem?.representedObject = p.id
                }
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        sheet.primaryButton?.isEnabled = !title.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func dateToggled() {
        dates.values.forEach { $0.picker.isEnabled = $0.on.state == .on }
    }

    private func day(_ field: EpicField) -> String? {
        guard let d = dates[field], d.on.state == .on else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d.picker.dateValue)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func create() {
        let name = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let start = day(.startDate), target = day(.targetDate)
        if let start, let target, start > target {
            problem.stringValue = "▲ The start date is after the target date."
            problem.isHidden = false
            return
        }
        problem.isHidden = true
        var args: [String: JSONValue] = ["project": .string(snap.summary.identifier), "title": .string(name)]
        let text = goal.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if fields.contains(.goal), !text.isEmpty { args["goal"] = .string(text) }
        if let start { args["startDate"] = .string(start) }
        if let target { args["targetDate"] = .string(target) }
        if fields.contains(.lead), let id = lead.selectedItem?.representedObject as? String { args["lead"] = .string(id) }
        let button = sheet.primaryButton
        data.actions.click("epic.create", args, in: sheet, asked: true, started: { button?.busy("Creating…") }) { [weak self] r in
            button?.done()
            guard let self, case .ok(_, let result, _) = r else { return }
            self.sheet.dismiss()
            if let id = result?["id"]?.string { self.finished?(EpicID(rawValue: id)) }
        }
    }
}

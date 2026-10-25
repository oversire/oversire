import Cocoa
import Quartz
import OverSireCore

/// The uploaded files of items. A list lives 5 minutes or until the item changes. A signed link lives 50 minutes.
/// Each file downloads one time, for its thumbnail and Quick Look. The open strips live in memory only.
@MainActor
final class AttachmentBook {
    nonisolated static let changed = Notification.Name("AttachmentBookChanged")
    static let listAge: TimeInterval = 300
    static let linkAge: TimeInterval = 3000

    private let reader: (ItemRef) -> (any AttachmentReading)?
    private let download: (URL) async throws -> Data
    var dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oversire-attachments")
    /// `--uishots`: the list of an item, with no tracker call.
    var sample: ((ItemRef) -> [ItemAttachment]?)?

    private var lists: [String: (files: [ItemAttachment], at: Date)] = [:]   // item id
    private var links: [String: (url: URL, at: Date)] = [:]                  // attachment id
    private var asking: Set<String> = []                                     // item ids
    private var fetching: Set<String> = []                                   // attachment ids
    private(set) var failed: Set<String> = []                                // attachment ids
    private var open: Set<String> = []                                       // item ids

    init(reader: @escaping (ItemRef) -> (any AttachmentReading)?,
         download: @escaping (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }) {
        self.reader = reader
        self.download = download
    }

    convenience init(store: ProjectStore) {
        self.init(reader: { [weak store] ref in
            guard let t = store?.tracker(of: ref.project), t.capabilities.contains(.attachmentsRead) else { return nil }
            return t as? any AttachmentReading
        })
    }

    /// The last list, also when it is old. Nil: no list yet. An old list or a newer item asks again.
    func files(of ref: ItemRef, changedAt: Date) -> [ItemAttachment]? {
        if let s = sample?(ref) { return s }
        let have = lists[ref.id]
        if have.map({ -$0.at.timeIntervalSinceNow > Self.listAge || changedAt > $0.at }) ?? true { ask(ref) }
        return have?.files
    }

    private func ask(_ ref: ItemRef) {
        guard let r = reader(ref), asking.insert(ref.id).inserted else { return }
        Task { [weak self] in
            let got = try? await r.attachments(of: ref)
            guard let self else { return }
            self.asking.remove(ref.id)
            // A failed call keeps the old list and waits for the next age.
            let before = self.lists[ref.id]?.files
            self.lists[ref.id] = (got ?? before ?? [], Date())
            if got != nil, got != before { self.post() }
        }
    }

    func isOpen(_ ref: ItemRef) -> Bool { open.contains(ref.id) }

    func toggle(_ ref: ItemRef) {
        if open.remove(ref.id) == nil { open.insert(ref.id) }
        post()
    }

    /// The downloaded copy. Nil until `fetch` ends.
    func local(_ a: ItemAttachment) -> URL? {
        let u = path(a)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func path(_ a: ItemAttachment) -> URL {
        let safe = a.name.replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent(a.id).appendingPathComponent(safe.isEmpty ? "file" : safe)
    }

    /// Downloads the file one time. `done` gets the local copy, or nil when the download fails.
    func fetch(_ a: ItemAttachment, of ref: ItemRef, done: ((URL?) -> Void)? = nil) {
        if let u = local(a) { done?(u); return }
        guard let r = reader(ref), fetching.insert(a.id).inserted else { done?(nil); return }
        failed.remove(a.id)
        let cached = links[a.id].flatMap { -$0.at.timeIntervalSinceNow < Self.linkAge ? $0.url : nil }
        let target = path(a), download = download
        Task { [weak self] in
            var link = cached
            if link == nil { link = try? await r.attachmentURL(a, of: ref) }
            var file: URL?
            if let link, let data = try? await download(link),
               (try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
               (try? data.write(to: target, options: .atomic)) != nil {
                file = target
            }
            guard let self else { return }
            self.fetching.remove(a.id)
            if let link, cached == nil { self.links[a.id] = (link, Date()) }
            if file == nil { self.failed.insert(a.id) }
            done?(file)
            self.post()
        }
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

/// The files of one item. Folded: one line with the count, the size and the first names.
/// Open: image thumbnails and a chip for each other file. A click on a thumbnail opens Quick Look.
final class AttachmentStrip: Box, QLPreviewPanelDataSource {
    private let book: AttachmentBook
    private let ref: ItemRef
    private let files: [ItemAttachment]
    private var preview: [URL] = []

    init(_ files: [ItemAttachment], of ref: ItemRef, book: AttachmentBook) {
        self.book = book
        self.ref = ref
        self.files = files
        super.init(fill: Palette.panel, border: Palette.line, radius: 10)
        let open = book.isOpen(ref)
        let body = NSStackView(v: [], spacing: 10)
        let images = files.filter(\.isImage)
        let title = images.count == files.count ? "Images" : "Files"
        let size = ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.size }), countStyle: .file)
        var names = files.prefix(3).map(\.name).joined(separator: ", ")
        if files.count > 3 { names += " +\(files.count - 3)" }
        let name = NSTextField.text(names, size: 12, color: Palette.dim)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = "\(title), \(files.count), \(size). \(open ? "Press to fold" : "Press to show")."
        body.addFull(Row([Glyph(open ? "chevron.down" : "chevron.right", color: Palette.dim, size: 11),
                          NSTextField.text(title, size: 13, weight: .semibold),
                          NSTextField.text("\(files.count) · \(size)", size: 12, color: Palette.mut), name, Spacer()],
                         height: 26, inset: 2, label: label) { [weak self] in
            guard let self else { return }
            self.book.toggle(self.ref)
        })
        if open {
            var tiles: [NSView] = images.map { a in
                AttachmentThumb(a, file: book.local(a), failed: book.failed.contains(a.id)) { [weak self] in self?.quickLook(a) }
            }
            tiles += files.filter { !$0.isImage }.map { a in
                AttachmentChip(a, open: { [weak self] in self?.openFile(a) }, save: { [weak self] in self?.save(a) })
            }
            body.addFull(Wrap(tiles))
            if !images.isEmpty {
                body.addFull(NSTextField.text("Click an image to open it large. ← → step, Space or Esc closes.", size: 12, color: Palette.dim))
            }
            for a in images where book.local(a) == nil && !book.failed.contains(a.id) { book.fetch(a, of: ref) }
        }
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 10), body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The hash parts of the strip: a page builds it again when one changes.
    static func sig(_ files: [ItemAttachment], of ref: ItemRef, book: AttachmentBook) -> [AnyHashable] {
        [files, book.isOpen(ref), files.map { book.local($0) != nil }, files.map { book.failed.contains($0.id) }]
    }

    private func quickLook(_ a: ItemAttachment) {
        guard let u = book.local(a) else { book.fetch(a, of: ref); return }
        preview = files.filter(\.isImage).compactMap(book.local)
        guard let i = preview.firstIndex(of: u), let ql = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        ql.dataSource = self
        ql.reloadData()
        ql.currentPreviewItemIndex = i
        ql.makeKeyAndOrderFront(nil)
    }

    private func openFile(_ a: ItemAttachment) {
        book.fetch(a, of: ref) { u in if let u { NSWorkspace.shared.open(u) } }
    }

    private func save(_ a: ItemAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.name
        guard panel.runModal() == .OK, let to = panel.url else { return }
        book.fetch(a, of: ref) { u in
            guard let u else { return }
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: u, to: to)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { preview.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { preview[index] as NSURL }
}

/// An image file: a thumbnail with its name. It shows a skeleton until the file is here.
final class AttachmentThumb: NSView {
    private let open: () -> Void

    init(_ a: ItemAttachment, file: URL?, failed: Bool, open: @escaping () -> Void) {
        self.open = open
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let frame = Box(fill: Palette.raise, border: Palette.line, radius: 6)
        let inner: NSView
        if let file, let img = NSImage(contentsOf: file) {
            let v = NSImageView(image: img)
            v.imageScaling = .scaleProportionallyUpOrDown
            inner = v
        } else if failed {
            inner = NSStackView(v: [Glyph("exclamationmark.triangle", color: Palette.dim, size: 13),
                                    NSTextField.text("Could not load", size: 10.5, color: Palette.dim)], spacing: 3)
        } else {
            inner = Spinner(size: .small)
        }
        inner.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(inner)
        let name = NSTextField.text(a.name, size: 10.5, color: Palette.mut)
        name.lineBreakMode = .byTruncatingMiddle
        for v in [frame, name] as [NSView] { addSubview(v) }
        let fills = inner is NSImageView
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 132), heightAnchor.constraint(equalToConstant: 112),
            frame.leadingAnchor.constraint(equalTo: leadingAnchor), frame.trailingAnchor.constraint(equalTo: trailingAnchor),
            frame.topAnchor.constraint(equalTo: topAnchor), frame.heightAnchor.constraint(equalToConstant: 92),
            inner.centerXAnchor.constraint(equalTo: frame.centerXAnchor), inner.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor), name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: 4),
        ])
        if fills {
            NSLayoutConstraint.activate([inner.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -8),
                                         inner.heightAnchor.constraint(equalTo: frame.heightAnchor, constant: -8)])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(a.name), image. Press to open it large.")
        toolTip = a.name
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with e: NSEvent) { open() }
    override func accessibilityPerformPress() -> Bool { open(); return true }
}

/// A file that is not an image: icon, name, size, Open and Save.
final class AttachmentChip: Box {
    init(_ a: ItemAttachment, open: @escaping () -> Void, save: @escaping () -> Void) {
        super.init(fill: Palette.raise, border: Palette.line, radius: 6)
        let size = ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)
        let name = NSTextField.text(a.name, size: 11.5, color: Palette.fg, mono: true)
        name.lineBreakMode = .byTruncatingMiddle
        name.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        let row = NSStackView(h: [Glyph("doc", size: 11), name, NSTextField.text(size, size: 11, color: Palette.dim),
                                  ActionButton("Open") { open() }, ActionButton("Save") { save() }], spacing: 6)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

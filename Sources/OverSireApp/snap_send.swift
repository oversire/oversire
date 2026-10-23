import Cocoa
import OverSireCore

// ─── Snap send ───────────────────────────────────────────────────────────────
// One basket becomes one intake item with its files. The agent mode then opens an
// agent terminal in the main checkout with a prompt that names the item.

enum SnapSendError: LocalizedError, Equatable {
    case noProject(String)
    case noAttachments
    case noRoot(String)
    case noRuntime
    case badCommand(String)

    var errorDescription: String? {
        switch self {
        case .noProject(let k): return "OverSire does not track the project \(k)."
        case .noAttachments: return "This tracker cannot take attachments."
        case .noRoot(let k): return "Choose an Orca workspace for \(k) first: start any item of the project once."
        case .noRuntime: return "No OverSire daemon runs on the sessions machine. See Settings › Machines."
        case .badCommand(let e): return "The agent command is not valid: \(e)"
        }
    }
}

final class SnapSender {
    struct Result: Equatable {
        var item: ItemRef
        var key: String { item.key }
        var missing: [String]          // the files that did not upload after the retries
        var session: SessionRef?
    }

    typealias Tracker = IntakeCreating & AttachmentUploading

    private let store: SnapStore
    private let renderer: SnapRenderer
    private let project: (String) -> ProjectRef?
    private let tracker: (ProjectRef) -> (any OverSireCore.Tracker)?
    private let terminal: () -> AgentTerminal?
    private let root: (String) -> String?
    private let uploader: AttachmentUploader

    init(store: SnapStore, renderer: SnapRenderer = SnapRenderer(),
         project: @escaping (String) -> ProjectRef?,
         tracker: @escaping (ProjectRef) -> (any OverSireCore.Tracker)?,
         terminal: @escaping () -> AgentTerminal?,
         root: @escaping (String) -> String?,
         uploader: AttachmentUploader = AttachmentUploader()) {
        self.store = store
        self.renderer = renderer
        self.project = project
        self.tracker = tracker
        self.terminal = terminal
        self.root = root
        self.uploader = uploader
    }

    /// The tracker of the basket's project, when it can take the ticket. Else the error to show.
    func target(_ b: SnapBasket) throws -> (ProjectRef, any Tracker) {
        guard let p = project(b.project) else { throw SnapSendError.noProject(b.project) }
        guard let t = tracker(p) as? any Tracker, t.capabilities.contains(.intakeCreate), t.capabilities.contains(.attachments) else {
            throw SnapSendError.noAttachments
        }
        return (p, t)
    }

    /// Renders each shot into out/. Returns the files in ticket order.
    func render(_ b: SnapBasket) throws -> [SnapFile] {
        let out = store.outDir(b.id)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var files: [SnapFile] = []
        for (i, s) in b.shots.enumerated() {
            guard let png = store.png(of: s.id, in: b.id) else { throw SnapRenderError.badImage }
            files += try renderer.render(s, png: png, index: i + 1)
        }
        for f in files { try f.data.write(to: out.appendingPathComponent(f.name), options: .atomic) }
        return files
    }

    /// Plane mode: the intake item and its files. The agent mode adds the terminal.
    func send(_ b: SnapBasket, agent: Bool) async throws -> Result {
        let (p, t) = try target(b)
        // Check the agent side before the item exists, so a missing root does not leave a half ticket.
        var launch: (AgentTerminal, String, String)?
        if agent {
            guard let r = root(b.project), !r.isEmpty else { throw SnapSendError.noRoot(p.key ?? b.project) }
            guard let term = terminal() else { throw SnapSendError.noRuntime }
            let cfg = PROJECTS_CFG.runtime
            let cmd: String
            do { cmd = try cfg.command(for: cfg.agent).resolve(name: "snap-" + b.project.lowercased(), key: b.project, title: SnapTicket.title(b)) } catch {
                throw SnapSendError.badCommand(String(describing: error))
            }
            launch = (term, r, cmd)
        }
        let files = try render(b)
        let made = try await t.createIntake(ItemDraft(title: SnapTicket.title(b), bodyMarkdown: SnapTicket.markdown(b)), in: p)
        let missing = await upload(files, to: made.item, with: t)
        var result = Result(item: made.item, missing: missing, session: nil)
        guard let (term, path, cmd) = launch else { return result }
        let prompt = SnapTicket.prompt(template: PROJECTS_CFG.runtime.snapPrompt, values: [
            "key": made.item.key, "item": made.item.id, "intake": made.intake.id, "count": "\(b.shots.count)",
            "workspace": p.account.id, "project": p.key ?? b.project, "dir": store.outDir(b.id).path + "/download",
        ]).replacingOccurrences(of: "\n", with: " ")
        let s = try await term.openTerminal(path: path, title: "snap-" + made.item.key, agent: AgentName(rawValue: PROJECTS_CFG.runtime.agent),
                                         command: cmd, prompt: prompt)
        try? await term.show(s)
        result.session = s
        return result
    }

    func upload(_ files: [SnapFile], to item: ItemRef, with t: any Tracker) async -> [String] {
        await uploader.upload(files.map { AttachmentUpload(name: $0.name, mimeType: "image/png", data: $0.data) }, to: item, with: t)
    }

    /// Uploads the missing files of a partly sent basket again.
    func retry(_ b: SnapBasket) async throws -> [String] {
        guard case .partial(_, let missing) = b.state, let item = b.item else { return [] }
        let (_, t) = try target(b)
        let out = store.outDir(b.id)
        let files = missing.compactMap { n in (try? Data(contentsOf: out.appendingPathComponent(n))).map { SnapFile(name: n, data: $0, role: .clean) } }
        return await upload(files, to: item, with: t) + missing.filter { n in !files.contains { $0.name == n } }
    }

    /// Markdown mode: the text and the rendered PNG files as file URLs.
    func copy(_ b: SnapBasket, to pb: NSPasteboard = .general) throws {
        let files = try render(b)
        let out = store.outDir(b.id)
        pb.clearContents()
        pb.writeObjects([SnapTicket.markdown(b) as NSString] + files.map { out.appendingPathComponent($0.name) as NSURL })
    }
}

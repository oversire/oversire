import Foundation
import OverSireCore

// ─── New session start ───────────────────────────────────────────────────────
// Intake on: an intake item with the files, then a terminal with a prompt that names the item.
// Intake off: the files go to the Orca host, then a terminal with a prompt that lists their paths.

enum SessionStartError: LocalizedError, Equatable {
    case noProject(String)
    case noRoot(String)
    case noRuntime
    case noIntake(String)
    case badCommand(String)
    case hostFiles(String)

    var errorDescription: String? {
        switch self {
        case .noProject(let k): return "OverSire does not track the project \(k)."
        case .noRoot(let k): return "Choose an Orca workspace folder for \(k) first."
        case .noRuntime: return "Add an agent runtime account in Settings › Accounts and sync."
        case .noIntake(let k): return "The tracker of \(k) cannot make intake items with files."
        case .badCommand(let e): return "The agent command is not valid: \(e)"
        case .hostFiles(let e): return "The files did not go to the Orca host: \(e)"
        }
    }
}

/// The first message of the agent. A placeholder in the user text stays as it is.
enum SessionPrompt {
    static let intakeDefault = """
        {text}

        This request is intake item {key}.
        Its files: plane-cli wi attachment download {item} -w {workspace} -p {project} --dir .oversire/{key}
        """
    static let filesDefault = "{text}\n\nAttached files:\n{paths}"

    /// With no files, the template lines that hold {item} drop.
    static func intake(_ template: String, values: [String: String], files: Bool) -> String {
        let t = files ? template : template.components(separatedBy: "\n").filter { !$0.contains("{item}") }.joined(separator: "\n")
        return resolve(t, values).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func files(_ template: String, text: String, paths: [String]) -> String {
        resolve(template, ["text": text, "paths": paths.joined(separator: "\n")]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One pass, so that a value is never read as a template.
    static func resolve(_ template: String, _ values: [String: String]) -> String {
        let re = try! NSRegularExpression(pattern: "\\{([a-zA-Z]+)\\}")
        let ns = template as NSString
        var out = "", at = 0
        for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            guard let v = values[ns.substring(with: m.range(at: 1))] else { continue }
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at)) + v
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }
}

final class SessionStarter {
    struct Request {
        var project: String          // ProjectRef.storeKey
        var text: String
        var files: [NewSessionModel.Attachment]
        var intake: Bool
    }

    struct Result: Equatable {
        var session: SessionRef
        var item: ItemRef?
        var paths: [String]          // the host paths of the direct route
        var missing: [String]        // the files that did not upload after the retries
        var terminal: String         // the terminal title

        /// The last line of the toast.
        func detail(files: Int) -> String {
            let n = "\(files) file\(files == 1 ? "" : "s")"
            if let i = item {
                if !missing.isEmpty { return "\(missing.count) of \(n) did not upload to \(i.key): \(missing.joined(separator: ", "))." }
                return files == 0 ? "Intake \(i.key) tracks this work. The prompt names it." : "Intake \(i.key) holds \(n). The prompt names it."
            }
            return paths.isEmpty ? "The prompt went as typed." : "\(n) copied to the Orca host. The prompt has their paths."
        }
    }

    typealias IntakeTracker = IntakeCreating & AttachmentUploading

    private let project: (String) -> ProjectRef?
    private let tracker: (ProjectRef) -> (any OverSireCore.Tracker)?
    private let terminal: () -> AgentTerminal?
    private let hostFiles: () -> (any HostFileWriting)?
    private let root: (String) -> String?
    private let uploader: AttachmentUploader

    init(project: @escaping (String) -> ProjectRef?,
         tracker: @escaping (ProjectRef) -> (any OverSireCore.Tracker)?,
         terminal: @escaping () -> AgentTerminal?,
         hostFiles: @escaping () -> (any HostFileWriting)?,
         root: @escaping (String) -> String?,
         uploader: AttachmentUploader = AttachmentUploader()) {
        self.project = project
        self.tracker = tracker
        self.terminal = terminal
        self.hostFiles = hostFiles
        self.root = root
        self.uploader = uploader
    }

    /// `progress` gets the label of each step. All checks come before the first change.
    func start(_ r: Request, progress: @escaping (String) -> Void) async throws -> Result {
        guard let p = project(r.project) else { throw SessionStartError.noProject(r.project) }
        let key = p.key ?? r.project
        guard let path = root(r.project), !path.isEmpty else { throw SessionStartError.noRoot(key) }
        guard let term = terminal() else { throw SessionStartError.noRuntime }
        let cfg = PROJECTS_CFG.runtime
        let name = NewSessionModel.termName(agent: cfg.agent, text: r.text)
        let title = NewSessionModel.title(r.text)
        let cmd: String
        do { cmd = try cfg.command(for: cfg.agent).resolve(name: name, key: key, title: title) } catch {
            throw SessionStartError.badCommand(String(describing: error))
        }
        var intake: (any IntakeTracker)?
        var host: (any HostFileWriting)?
        if r.intake {
            guard let t = tracker(p) as? any IntakeTracker, t.capabilities.contains(.intakeCreate),
                  r.files.isEmpty || t.capabilities.contains(.attachments) else { throw SessionStartError.noIntake(key) }
            intake = t
        } else if !r.files.isEmpty {
            guard let h = hostFiles(), h.capabilities.contains(.hostFiles) else { throw SessionStartError.hostFiles("the runtime cannot take files.") }
            host = h
        }

        var item: ItemRef?
        var paths: [String] = [], missing: [String] = []
        let prompt: String
        let count = "\(r.files.count) file\(r.files.count == 1 ? "" : "s")"
        if let t = intake {
            progress("Creating item…")
            let made = try await t.createIntake(ItemDraft(title: title, bodyMarkdown: r.text), in: p)
            item = made.item
            if !r.files.isEmpty {
                progress("Sending \(count)…")
                let files = r.files.map { AttachmentUpload(name: $0.name, mimeType: $0.mimeType, data: $0.data) }
                missing = await uploader.upload(files, to: made.item, with: t)
            }
            prompt = SessionPrompt.intake(cfg.sessionIntakePrompt, values: [
                "text": r.text, "key": made.item.key, "item": made.item.id, "intake": made.intake.id,
                "workspace": p.account.id, "project": key,
            ], files: !r.files.isEmpty)
        } else if let h = host {
            progress("Sending \(count)…")
            do {
                paths = try await h.writeFiles(r.files.map { HostFile(name: $0.name, data: $0.data) }, workspacePath: path,
                                                      dir: "/tmp/oversire/" + UUID().uuidString.lowercased()) { _, _ in }
            } catch {
                throw SessionStartError.hostFiles((error as? ProviderError)?.message ?? error.localizedDescription)
            }
            prompt = SessionPrompt.files(cfg.sessionFilesPrompt, text: r.text, paths: paths)
        } else {
            prompt = r.text
        }
        progress("Opening terminal…")
        let s = try await term.openTerminal(path: path, title: name, command: cmd, prompt: prompt)
        try? await term.reveal(s)
        return Result(session: s, item: item, paths: paths, missing: missing, terminal: name)
    }
}

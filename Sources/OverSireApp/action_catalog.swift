import Cocoa
import OverSireCore
import OverSireAI
import OverSireAssistant

// The actions of the app. Buttons, row menus, the ⌘K palette and the assistant run them here.
// The specs call the same models as the pages. The models live on the main thread.
final class AppActionCatalog: ActionCatalog, @unchecked Sendable {
    let link: ActionLink
    let all: [ActionSpec]
    private let byId: [String: ActionSpec]

    init(data: AppData, extra: [ActionSpec] = []) {
        let link = ActionLink(data)
        self.link = link
        all = ItemActions(link: link).specs + SessionActions(link: link).specs + QueueActions(link: link).specs
            + RepoActions(link: link).specs + IntakeActions(link: link).specs + MachineActions(link: link).specs
            + PageActions(link: link).specs + extra
        byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func spec(_ id: String) -> ActionSpec? { byId[id] }

    /// The page does not filter: the assistant sees all actions that a provider supports.
    func specs(for page: PageContext?) async -> [ActionSpec] {
        await link.main([]) { d, done in done(self.supported(d)) }
    }

    func run(_ id: String, _ args: ActionArgs) async -> ActionResult {
        guard let spec = byId[id] else { return .notAllowed("No action \(id).") }
        return await spec.perform(args)
    }

    /// For a click. `done` runs on the main thread.
    func run(_ id: String, _ values: [String: JSONValue], done: @escaping (ActionResult) -> Void = { _ in }) {
        Task {
            let r = await run(id, ActionArgs(.object(values)))
            await MainActor.run { done(r) }
        }
    }

    /// A user click: an outward action asks first, and a failure shows its reason.
    /// `started` runs after the confirm. `done` runs on the main thread.
    /// `asked`: the click came from a dialog already, so no confirm.
    func click(_ id: String, _ values: [String: JSONValue] = [:], in window: NSWindow?, confirm: String? = nil, asked: Bool = false,
               started: (() -> Void)? = nil, done: ((ActionResult) -> Void)? = nil) {
        guard let spec = byId[id] else { return }
        let go = {
            started?()
            self.run(id, values) { r in
                switch r {
                case .ok: break
                case .failed(let m), .notAllowed(let m): AlertConfirm.tell("\(spec.title) did not work", info: m, in: window)
                }
                done?(r)
            }
        }
        guard !asked, confirm != nil || spec.kind == .outward else { go(); return }
        AlertConfirm.ask(confirm ?? "\(spec.title)?", info: spec.help, button: spec.title, in: window, go)
    }

    func supported(_ d: AppData) -> [ActionSpec] { all.filter { $0.capability.map(d.has) ?? true } }

    /// The ⌘K entries of a route: the actions of its domain. Actions that need args the route does not give stay out.
    func palette(_ route: Route, data: AppData) -> [(ActionSpec, [String: JSONValue])] {
        let subject = route.actionSubject
        return supported(data).compactMap { s in
            guard s.kind != .read, subject.domains.contains(where: { s.id.hasPrefix($0 + ".") }) else { return nil }
            let required = Set(s.input["required"]?.array?.compactMap(\.string) ?? [])
            guard required.isSubset(of: subject.args.keys) else { return nil }
            return (s, subject.args.filter { s.input["properties"]?[$0.key] != nil })
        }
    }
}

extension ActionButton {
    /// Runs a catalog action on click. The button is busy until the action is done.
    convenience init(_ title: String, symbol: String? = nil, style: Style = .plain, action id: String, _ args: [String: JSONValue] = [:],
                     confirm: String? = nil, done: ((ActionResult) -> Void)? = nil) {
        self.init(title, symbol: symbol, style: style)
        onClick = { [weak self] in
            guard let self, let catalog = (NSApp.delegate as? AppData)?.actions else { return }
            catalog.click(id, args, in: self.window, confirm: confirm, started: { [weak self] in self?.busy(self?.title ?? "") }) { [weak self] r in
                self?.done()
                done?(r)
            }
        }
    }
}

extension Route {
    /// The action domains of the page, and the args that the page gives.
    var actionSubject: (domains: [String], args: [String: JSONValue]) {
        switch self {
        case .item(let key, _): return (["item", "session", "queue", "status"], ["key": .string(key)])
        case .project(let key): return (["project", "item"], ["project": .string(key)])
        case .intake(let key): return (["intake"], key.map { ["project": .string($0)] } ?? [:])
        case .run(let repo, let id): return (["run"], ["repo": .string(repo), "runId": .string(id)])
        case .work(.lanes): return (["queue", "plan"], [:])
        case .work: return (["worktree"], [:])
        case .settings(.machines, _, _): return (["machine"], [:])
        default: return ([], [:])
        }
    }
}

/// The way from an action to the app. It holds the app weakly.
final class ActionLink: @unchecked Sendable {
    weak var data: AppData?
    /// True when the chat moves the window: Follow along. The assistant sets it.
    var follows: @Sendable (String) async -> Bool = { _ in true }

    init(_ data: AppData) { self.data = data }

    /// Runs `body` on the main thread and waits for its answer. A second answer is dropped.
    func main<T>(_ closed: T, _ body: @escaping (AppData, @escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            DispatchQueue.main.async {
                guard let d = self.data else { c.resume(returning: closed); return }
                var done = false
                body(d) { v in
                    guard !done else { return }
                    done = true
                    c.resume(returning: v)
                }
            }
        }
    }

    func run(_ body: @escaping (AppData, @escaping (ActionResult) -> Void) -> Void) async -> ActionResult {
        await main(.failed("The app is closing."), body)
    }

    /// Runs `body` with the loaded item of the `key` arg.
    func item(_ a: ActionArgs, _ body: @escaping (AppData, (key: String, snap: ProjectSnapshot, item: Item), @escaping (ActionResult) -> Void) -> Void) async -> ActionResult {
        guard let key = a.string("key")?.uppercased(), !key.isEmpty else { return .notAllowed("Give the key of an item, for example OVERSIRE-12.") }
        return await run { d, done in
            guard let found = d.projectStore.item(key: key) else { done(.notAllowed("OverSire has no loaded item \(key).")); return }
            body(d, found, done)
        }
    }

    /// The result of a ProjectStore write.
    static func stored(_ d: AppData, _ ok: Bool, _ summary: String) -> ActionResult {
        ok ? .ok(summary: summary) : .failed(d.projectStore.lastError ?? "The tracker did not take the change.")
    }
}

extension ActionArgs {
    /// An array of strings, or one string with commas.
    func list(_ key: String) -> [String] {
        if let a = self[key]?.array { return a.compactMap(\.string) }
        return string(key)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }
}

/// An option of a field, found by id or by name.
extension Array where Element == StatusOption {
    func find(_ s: String) -> StatusOption? {
        first { $0.id == s } ?? first { $0.name.caseInsensitiveCompare(s) == .orderedSame }
    }

    var names: String { map(\.name).joined(separator: ", ") }
}

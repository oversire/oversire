import Foundation
import OverSireAssistant
import OverSireCore

// ─── Item filing ─────────────────────────────────────────────────────────────
// The way Snap, the session starter and the new item sheet make items and send files.
// The catalog actions run on the home, or on a client through the home.

struct ItemFiling {
    var can: (_ project: ProjectRef, _ c: Capability) -> Bool
    var create: (_ d: ItemDraft, _ p: ProjectRef) async throws -> ItemRef
    var createIntake: (_ d: ItemDraft, _ p: ProjectRef) async throws -> (item: ItemRef, intake: IntakeItem)
    var attach: (_ f: AttachmentUpload, _ to: ItemRef) async throws -> String
    /// False when the intake is off. Nil when the tracker does not tell.
    var intakeOn: (_ p: ProjectRef) async -> Bool?
    var enableIntake: (_ p: ProjectRef) async throws -> Void

    static func catalog(_ actions: AppActionCatalog, store: ProjectStore) -> ItemFiling {
        func run(_ id: String, _ values: [String: JSONValue]) async throws -> JSONValue? {
            switch await actions.run(id, ActionArgs(.object(values))) {
            case .ok(_, let data, _): return data
            case .failed(let m), .notAllowed(let m): throw ProviderError.vendor(code: "action", message: m)
            }
        }
        func main<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }
        func text(_ data: JSONValue?, _ key: String) throws -> String {
            guard let s = data?[key]?.string else { throw ProviderError.decoding("The action gave no \(key).") }
            return s
        }
        func ref(_ data: JSONValue?, _ p: ProjectRef) throws -> ItemRef {
            guard let url = URL(string: try text(data, "url")) else { throw ProviderError.decoding("The action gave a bad url.") }
            return ItemRef(project: p, id: try text(data, "id"), key: try text(data, "key"), url: url)
        }
        func fields(_ d: ItemDraft, _ p: ProjectRef) -> [String: JSONValue] {
            var v: [String: JSONValue] = ["project": .string(p.storeKey), "title": .string(d.title)]
            if let b = d.bodyMarkdown { v["body"] = .string(b) }
            if let s = d.status { v["status"] = .string(s) }
            if let x = d.priority { v["priority"] = .string(x) }
            return v
        }
        return ItemFiling(
            can: { p, c in main { store.snapshot(p.storeKey).map { store.has(c, in: $0) } ?? false } },
            create: { d, p in try ref(try await run("item.create", fields(d, p)), p) },
            createIntake: { d, p in
                let data = try await run("intake.create", fields(d, p))
                guard let raw = data?["intake"] else { throw ProviderError.decoding("The action gave no intake item.") }
                return (try ref(data, p), try MirrorCodec.value(IntakeItem.self, from: raw))
            },
            attach: { f, item in
                try text(try await run("item.attach", [
                    "key": .string(item.key), "project": .string(item.project.storeKey), "id": .string(item.id), "url": .string(item.url.absoluteString),
                    "name": .string(f.name), "mimeType": .string(f.mimeType), "data": .string(f.data.base64EncodedString()),
                ]), "id")
            },
            intakeOn: { p in
                await withCheckedContinuation { c in
                    DispatchQueue.main.async {
                        store.projectSettings(projectKey: p.storeKey) { c.resume(returning: (try? $0.get())?.settings.features[.intake]) }
                    }
                }
            },
            enableIntake: { p in
                let patch = try MirrorCodec.body(ProjectSettingsPatch(features: [.intake: true]))
                _ = try await run("project.updateSettings", ["project": .string(p.storeKey), "patch": patch])
            })
    }
}

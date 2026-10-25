import Foundation
import OverSireAI
import OverSireCore

// ─── Groom Apply ─────────────────────────────────────────────────────────────
// Writes the selected Groom lines to the tracker, one item at a time. Each step reads the item first and skips a write that is
// already there. Thus "Try again" writes no second comment. A failed line stops only that line.

struct GroomOutcome: Codable, Equatable, Sendable {
    var written: [String] = []            // proposal ids
    var failed: [String: String] = [:]    // proposal id → error
    var vague: [String] = []              // keys for Enhance
}

struct GroomApplier {
    /// An item of the Groom input. `intake` is set when the item waits in the intake.
    struct Target: Sendable {
        var ref: ItemRef
        var intake: IntakeItem?
    }

    let tracker: any Tracker
    let snapshot: ProjectSnapshot
    let targets: [String: Target]          // uppercased key → target
    let journal: GroomJournal
    let projectKey: String
    var now: @Sendable () -> Date = { Date() }

    private var project: ProjectRef { snapshot.summary.ref }

    /// The ref of a key: an input item, else a loaded item of the project.
    func ref(_ key: String) -> ItemRef? {
        let k = key.uppercased()
        if let t = targets[k] { return t.ref }
        return snapshot.items.first { $0.key.uppercased() == k }.flatMap { $0.ref(in: project) }
    }

    func apply(_ lines: [GroomResult.Proposal], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> GroomOutcome {
        var out = GroomOutcome()
        var pending = Set(((try? await (tracker as? any IntakeTriaging)?.intake(project)) ?? []).map(\.id))
        for (n, p) in lines.enumerated() {
            progress(n, lines.count)
            if p.kind == .vague {
                out.vague += p.keys.map { $0.uppercased() }
                continue
            }
            do {
                try await write(p, pending: &pending)
                out.written.append(p.id)
            } catch {
                out.failed[p.id] = (error as? ProviderError)?.message ?? error.localizedDescription
            }
        }
        progress(lines.count, lines.count)
        return out
    }

    private func target(_ key: String) throws -> Target {
        guard let t = targets[key.uppercased()] else { throw ProviderError.vendor(code: "groom", message: "\(key) is not in this Groom run.") }
        return t
    }

    private func write(_ p: GroomResult.Proposal, pending: inout Set<String>) async throws {
        let cancelled = snapshot.firstState(group: "cancelled", else: .done)?.id
        let done = snapshot.firstState(group: "completed", else: .done)?.id
        switch p.kind {
        case .merge:
            guard let keepKey = p.keep else { return }
            let keep = try target(keepKey)
            if let text = p.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                try await describe(keep, text)
            }
            for k in p.merged {
                let o = try target(k)
                try await relate(o, ItemRelation(kind: .duplicate, item: keep.ref))
                try await comment(o, "Merged into \(keep.ref.key) by Groom. \(p.reason)")
                try await close(o, state: cancelled, intake: .duplicate(of: keep.ref.id), pending: &pending)
            }
        case .done:
            let text = (["Done: \(p.reason)"] + p.evidence).joined(separator: "\n")
            for k in p.keys {
                let t = try target(k)
                try await comment(t, text)
                try await close(t, state: done, intake: .decline, pending: &pending)
            }
        case .obsolete:
            for k in p.keys {
                let t = try target(k)
                try await comment(t, "Obsolete: \(p.reason)")
                try await close(t, state: cancelled, intake: .decline, pending: &pending)
            }
        case .fold:
            guard let key = p.keys.first, let pk = p.parent else { return }
            let t = try target(key)
            guard let parent = ref(pk) else { throw ProviderError.vendor(code: "groom", message: "\(pk) is not a loaded item.") }
            try await fold(t, under: parent, pending: &pending)
        case .relate:
            guard let key = p.keys.first, let r = p.relation, let kind = r.relationKind else { return }
            guard let other = ref(r.key) else { throw ProviderError.vendor(code: "groom", message: "\(r.key) is not a loaded item.") }
            try await relate(try target(key), ItemRelation(kind: kind, item: other))
        default:
            throw ProviderError.unsupported(.changeActions)
        }
    }

    // ─── Steps ───────────────────────────────────────────────────────────────

    private func intakeTracker() throws -> any IntakeTriaging {
        guard let t = tracker as? any IntakeTriaging else { throw ProviderError.unsupported(.intake) }
        return t
    }

    private func entry(_ t: Target) -> GroomJournal.Entry { GroomJournal.Entry(key: t.ref.key.uppercased(), ref: t.ref, intake: t.intake) }

    private func wrote(_ t: Target) async { await journal.written(t.ref.key.uppercased(), at: now(), in: projectKey) }

    /// The new description. The OverSire block of the old description stays at the end.
    private func describe(_ t: Target, _ text: String) async throws {
        var e = entry(t)
        if let i = t.intake {
            let it = try intakeTracker()
            let old = (try? await it.intakeDetail(i, in: project))?.body ?? ""
            let body = Self.keepingBlock(of: old, text)
            guard body != old else { return }
            e.body = old
            await journal.record(before: e, in: projectKey)
            try await it.triage(i, in: project, .update(IntakeEdit(patch: ItemPatch(bodyMarkdown: body))))
        } else {
            let old = try await tracker.detail(t.ref).item.body ?? ""
            let body = Self.keepingBlock(of: old, text)
            guard body != old else { return }
            e.body = old
            await journal.record(before: e, in: projectKey)
            try await tracker.update(t.ref, ItemPatch(bodyMarkdown: body))
        }
        await wrote(t)
    }

    private func relate(_ t: Target, _ r: ItemRelation) async throws {
        guard let rel = tracker as? any RelationManaging else { throw ProviderError.unsupported(.relations) }
        let have = (try? await rel.relations(of: t.ref)) ?? []
        guard !have.contains(where: { $0.kind == r.kind && $0.item.id == r.item.id }) else { return }
        var e = entry(t)
        e.added = [r]
        await journal.record(before: e, in: projectKey)
        if let i = t.intake {
            try await intakeTracker().triage(i, in: project, .update(IntakeEdit(relations: [r])))
        } else {
            try await rel.apply(RelationPatch(add: [r]), to: t.ref)
        }
        await wrote(t)
    }

    private func comment(_ t: Target, _ text: String) async throws {
        let have = (try? await tracker.comments(t.ref)) ?? []
        guard !have.contains(where: { $0.body?.trimmingCharacters(in: .whitespacesAndNewlines) == text }) else { return }
        await journal.record(before: entry(t), in: projectKey)
        try await tracker.comment(t.ref, markdown: text)
        await wrote(t)
    }

    /// An intake item gets the intake action. A work item gets the state.
    private func close(_ t: Target, state: String?, intake action: IntakeAction, pending: inout Set<String>) async throws {
        var e = entry(t)
        if let i = t.intake {
            guard pending.contains(i.id) else { return }
            e.triaged = true
            await journal.record(before: e, in: projectKey)
            try await intakeTracker().triage(i, in: project, action)
            pending.remove(i.id)
        } else {
            guard let state else { throw ProviderError.vendor(code: "groom", message: "The project has no closed state.") }
            let old = try await tracker.detail(t.ref).item.statusOptionId
            guard old != state else { return }
            e.status = old
            await journal.record(before: e, in: projectKey)
            try await tracker.update(t.ref, ItemPatch(status: state))
        }
        await wrote(t)
    }

    /// An intake item gets the parent, then Accept: a sub-item is not a new note.
    private func fold(_ t: Target, under parent: ItemRef, pending: inout Set<String>) async throws {
        var e = entry(t)
        if let i = t.intake {
            guard pending.contains(i.id) else { return }
            e.parent = .init(id: nil)
            e.triaged = true
            await journal.record(before: e, in: projectKey)
            let it = try intakeTracker()
            try await it.triage(i, in: project, .update(IntakeEdit(patch: ItemPatch(parent: parent.id))))
            try await it.triage(i, in: project, .accept)
            pending.remove(i.id)
        } else {
            let old = try await tracker.detail(t.ref).item.parentId
            guard old != parent.id else { return }
            e.parent = .init(id: old)
            await journal.record(before: e, in: projectKey)
            try await tracker.update(t.ref, ItemPatch(parent: parent.id))
        }
        await wrote(t)
    }

    /// The new text plus the OverSire block of the old text. The user does not edit that block, and OverSire updates it later.
    static func keepingBlock(of old: String, _ text: String) -> String {
        for (start, end) in OverSireBlock.markers {
            guard let s = old.range(of: start, options: .backwards) else { continue }
            let e = old.range(of: end, range: s.upperBound..<old.endIndex)?.upperBound ?? old.endIndex
            return text + "\n\n" + old[s.lowerBound..<e]
        }
        return text
    }
}

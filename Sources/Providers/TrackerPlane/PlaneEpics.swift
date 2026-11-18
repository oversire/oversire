import Foundation
import OverSireCore

// Epics are Plane Modules (v2 API). Membership comes from `module_ids` in the work item index.

extension PlaneTracker: EpicTracking {
    public func epics(in p: ProjectRef) async throws -> [Epic] {
        try await requireModules(p)
        return try await moduleList(p)
    }

    public func createEpic(_ d: EpicDraft, in p: ProjectRef) async throws -> Epic {
        try await requireModules(p)
        var body: [String: Any] = ["name": d.title, "status": Self.planeStatus(d.state)]
        if let g = d.goal { body["description"] = g }
        if let l = d.lead { body["lead_id"] = l }
        if let s = d.startDate { body["start_date"] = Self.day(s) }
        if let t = d.targetDate { body["target_date"] = Self.day(t) }
        let obj = try await api.send("POST", "\(api.v2)/projects/\(p.id)/modules/", body: body)
        guard let epic = (obj as? [String: Any]).flatMap({ parseModule($0, project: p) }) else {
            throw ProviderError.decoding("no module in the answer")
        }
        clearEpicCaches(p)
        return epic
    }

    public func updateEpic(_ e: Epic, _ patch: EpicPatch) async throws -> Epic {
        try await requireModules(e.project)
        var body: [String: Any] = [:]
        if let v = patch.title { body["name"] = v }
        if let v = patch.goal { body["description"] = v }
        if let v = patch.state { body["status"] = Self.planeStatus(v) }
        if let v = patch.lead { body["lead_id"] = v }
        if let v = patch.startDate { body["start_date"] = Self.day(v) }
        if let v = patch.targetDate { body["target_date"] = Self.day(v) }
        for f in patch.clear {
            switch f {
            case .goal: body["description"] = ""
            case .lead: body["lead_id"] = NSNull()
            case .startDate: body["start_date"] = NSNull()
            case .targetDate: body["target_date"] = NSNull()
            default: break
            }
        }
        let path = "\(api.v2)/projects/\(e.project.id)/modules/\(e.id.rawValue)/"
        if !body.isEmpty { _ = try await api.send("PATCH", path, body: body) }
        clearEpicCaches(e.project)
        // The answer of a PATCH is not always the whole module, so read it again.
        guard let epic = (try await api.send("GET", path) as? [String: Any]).flatMap({ parseModule($0, project: e.project) }) else {
            throw ProviderError.decoding("no module in the answer")
        }
        return epic
    }

    /// Adds the item to the new module first, then removes it from the others, so a failure never leaves it with no epic.
    public func setEpic(_ epic: EpicID?, for item: ItemRef) async throws {
        let p = item.project
        try await requireModules(p)
        if let epic, !(try await moduleList(p)).contains(where: { $0.id == epic }) { throw ProviderError.unsupported(.epics) }
        let obj = try await api.send("GET", "\(api.v2)/projects/\(p.id)/work-items/\(item.id)/", query: [URLQueryItem(name: "fields", value: "module_ids")])
        let current = ((obj as? [String: Any])?["module_ids"] as? [Any] ?? []).compactMap { PlaneAPI.id($0) }
        defer { clearEpicCaches(p) }
        if let epic, !current.contains(epic.rawValue) { try await manage(p, module: epic.rawValue, ["add": [item.id]]) }
        for m in current where m != epic?.rawValue { try await manage(p, module: m, ["remove": [item.id]]) }
    }

    private func manage(_ p: ProjectRef, module: String, _ body: [String: Any]) async throws {
        _ = try await api.send("POST", "\(api.v2)/projects/\(p.id)/modules/\(module)/work-items/", body: body)
    }

    // MARK: Modules

    /// The active modules in the order of the board: `sort_order`, then `created_at`. Kept for `epicsMaxAge`.
    func moduleList(_ p: ProjectRef) async throws -> [Epic] {
        if let c = lock.withLock({ moduleCache[p.id] }), -c.at.timeIntervalSinceNow < epicsMaxAge { return c.epics }
        let rows = try await api.listOffset("\(api.v2)/projects/\(p.id)/modules/", max: 1000)
        let sorted = rows.enumerated().sorted { a, b in
            let (x, y) = (Self.sortOrder(a.element), Self.sortOrder(b.element))
            if x != y { return x < y }
            let (cx, cy) = (parseISO(a.element["created_at"] as? String), parseISO(b.element["created_at"] as? String))
            if let cx, let cy, cx != cy { return cx < cy }
            return a.offset < b.offset
        }
        let epics = sorted.compactMap { parseModule($0.element, project: p) }
        lock.withLock { moduleCache[p.id] = (epics, Date()) }
        return epics
    }

    /// Throws `unsupported(.epics)` when the project has the Modules feature off. An unknown state counts as on.
    func requireModules(_ p: ProjectRef) async throws {
        if let c = lock.withLock({ modulesOn[p.id] }), -c.at.timeIntervalSinceNow < Self.statusMaxAge {
            if !c.on { throw ProviderError.unsupported(.epics) }
            return
        }
        var on = true
        do {
            let o = try await api.send("GET", "\(ws)/projects/\(p.id)/") as? [String: Any]
            on = o?["module_view"] as? Bool ?? true
        } catch ProviderError.rateLimited(let after) {
            throw ProviderError.rateLimited(retryAfter: after)
        } catch {}
        lock.withLock { modulesOn[p.id] = (on, Date()) }
        if !on { throw ProviderError.unsupported(.epics) }
    }

    /// A write changes the members, so the index and the items load again.
    func clearEpicCaches(_ p: ProjectRef) {
        lock.withLock {
            moduleCache[p.id] = nil
            indexCache[p.id] = nil
            itemCache[p.id] = nil
        }
    }

    func parseModule(_ r: [String: Any], project p: ProjectRef) -> Epic? {
        guard let id = PlaneAPI.id(r["id"]), let name = r["name"] as? String else { return nil }
        if let a = r["archived_at"], !(a is NSNull) { return nil }
        let native = r["status"] as? String ?? ""
        let goal = (r["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let lead = PlaneAPI.id(r["lead_id"]) ?? PlaneAPI.id(r["lead"]) ?? PlaneAPI.id((r["lead"] as? [String: Any])?["id"])
        return Epic(id: EpicID(rawValue: id), title: name, goal: goal, state: Self.epicState(native), nativeState: native, lead: lead,
                    startDate: Self.date(r["start_date"]), targetDate: Self.date(r["target_date"]),
                    url: workspace.moduleURL(project: p.id, module: id), project: p,
                    createdAt: parseISO(r["created_at"] as? String), updatedAt: parseISO(r["updated_at"] as? String))
    }

    static func epicState(_ planeStatus: String) -> EpicState {
        switch planeStatus {
        case "in-progress": return .active
        case "paused": return .paused
        case "completed": return .done
        case "cancelled": return .canceled
        default: return .planned
        }
    }

    static func planeStatus(_ s: EpicState) -> String {
        switch s {
        case .planned: return "planned"
        case .active: return "in-progress"
        case .paused: return "paused"
        case .done: return "completed"
        case .canceled: return "cancelled"
        }
    }

    private static func sortOrder(_ r: [String: Any]) -> Double { (r["sort_order"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude }

    // A date with no time ("2026-11-30"), in the time zone of the user, like the rollup.
    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let n = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard n.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: n[0], month: n[1], day: n[2]))
    }

    private static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

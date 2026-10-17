import Foundation
import OverSireCore

// Project settings: GET and PATCH projects/{id}/, plus states, labels and members.

extension PlaneTracker: ProjectSettingsEditing {
    public var editableSettings: Set<ProjectSettingsField> {
        [.name, .description, .logo, .lead, .defaultAssignee, .visibility, .features, .labels]
    }

    public func settings(_ p: ProjectRef) async throws -> ProjectSettings {
        async let project = api.send("GET", "\(ws)/projects/\(p.id)/")
        async let statuses = statuses(p)
        async let labels = labels(p)
        async let memberRows = api.list("\(ws)/projects/\(p.id)/members/", max: 1000)
        guard let o = try await project as? [String: Any] else { throw ProviderError.decoding("no project in the answer") }
        let members = try await memberRows.compactMap(Self.member)
        let names = members.isEmpty ? await memberNames() : [:]
        func person(_ v: Any?) -> PersonRef? {
            guard let id = PlaneAPI.id(v) else { return nil }
            return members.first { $0.person.id == id }?.person ?? PersonRef(id: id, name: names[id] ?? id)
        }
        return Self.settings(o, statuses: try await statuses, labels: try await labels, members: members, person: person)
    }

    public func update(_ p: ProjectRef, _ patch: ProjectSettingsPatch) async throws {
        let body = try patch.planeFields
        if !body.isEmpty { _ = try await api.send("PATCH", "\(ws)/projects/\(p.id)/", body: body) }
        for l in patch.newLabels ?? [] { _ = try await createLabel(l.name, color: l.color, in: p) }
    }

    static func settings(_ o: [String: Any], statuses: [StatusOption], labels: [StatusOption], members: [ProjectMember],
                         person: (Any?) -> PersonRef?) -> ProjectSettings {
        let html = o["description_html"] as? String ?? ""
        let text = html.isEmpty ? (o["description"] as? String ?? "") : PlaneMarkup.markdown(fromHTML: html)
        var features: [ProjectFeature: Bool] = [:]
        for (f, key) in featureKeys { features[f] = o[key] as? Bool ?? false }
        features[.estimates] = PlaneAPI.id(o["estimate"]) != nil
        let network = PlaneAPI.int(o["network"])
        return ProjectSettings(name: o["name"] as? String ?? "", key: (o["identifier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               description: text.isEmpty ? nil : text, logo: logo(o["logo_props"]),
                               lead: person(o["project_lead"]), defaultAssignee: person(o["default_assignee"]),
                               visibility: network.map { $0 == 2 ? .public : .private },
                               statuses: statuses, labels: labels, priorities: StatusOption.priorities.map(\.id),
                               members: members, features: features, readOnlyFeatures: [.estimates])
    }

    // The estimate is a scheme id, not a switch, so it is read only.
    static let featureKeys: [(ProjectFeature, String)] = [
        (.iterations, "cycle_view"), (.modules, "module_view"), (.intake, "intake_view"),
        (.pages, "page_view"), (.timeTracking, "is_time_tracking_enabled"),
    ]

    static func member(_ r: [String: Any]) -> ProjectMember? {
        let u = (r["member"] as? [String: Any]) ?? r
        guard let id = PlaneAPI.id(u["id"]), u["is_bot"] as? Bool != true else { return nil }
        let name = (u["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (u["email"] as? String) ?? id
        let role = (r["role_slug"] as? String) ?? PlaneAPI.int(r["role"]).map { $0 >= 20 ? "admin" : $0 >= 15 ? "member" : "guest" }
        return ProjectMember(person: PersonRef(id: id, name: name, login: u["display_name"] as? String), role: role)
    }

    /// logo_props: {"in_use": "emoji", "emoji": {"value": "128512-65039"}} or {"in_use": "icon", "icon": {"name", "color"}}.
    static func logo(_ props: Any?) -> ProjectLogo? {
        guard let o = props as? [String: Any], let use = o["in_use"] as? String, let v = o[use] as? [String: Any] else { return nil }
        switch use {
        case "emoji":
            let scalars = (v["value"] as? String ?? "").split(separator: "-").compactMap { UInt32($0).flatMap(Unicode.Scalar.init) }
            return scalars.isEmpty ? nil : ProjectLogo(kind: .emoji, value: String(String.UnicodeScalarView(scalars)))
        case "icon":
            guard let name = v["name"] as? String, !name.isEmpty else { return nil }
            return ProjectLogo(kind: .icon, value: name, color: v["color"] as? String)
        default:
            return nil
        }
    }
}

extension ProjectLogo {
    /// The logo_props body. Plane has no image logos.
    var planeProps: [String: Any] {
        get throws {
            switch kind {
            case .emoji:
                return ["in_use": "emoji", "emoji": ["value": value.unicodeScalars.map { String($0.value) }.joined(separator: "-")]]
            case .icon:
                var icon: [String: Any] = ["name": value]
                if let color { icon["color"] = color }
                return ["in_use": "icon", "icon": icon]
            case .image:
                throw ProviderError.unsupported(.projectSettingsEdit)
            }
        }
    }
}

extension ProjectSettingsPatch {
    var planeFields: [String: Any] {
        get throws {
            var f: [String: Any] = [:]
            if let name { f["name"] = name }
            if let description { f["description_html"] = PlaneMarkup.html(fromMarkdown: description) }
            if let logo { f["logo_props"] = try logo.map { try $0.planeProps } ?? [:] }
            if let lead { f["project_lead"] = lead ?? NSNull() }
            if let defaultAssignee { f["default_assignee"] = defaultAssignee ?? NSNull() }
            if let visibility { f["network"] = visibility == .public ? 2 : 0 }
            for (feature, on) in features ?? [:] {
                if let key = PlaneTracker.featureKeys.first(where: { $0.0 == feature })?.1 { f[key] = on }
                else if feature == .estimates, !on { f["estimate"] = NSNull() }
            }
            return f
        }
    }
}

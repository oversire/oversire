import Foundation

// ─── Project settings ────────────────────────────────────────────────────────
// The overlap of the project settings of the trackers. Each adapter fills the fields that it has.
// The settings page shows a field only when the adapter has it, and edits it only when the adapter can write it.

/// The logo of a project in the tracker.
public struct ProjectLogo: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case emoji, icon, image }

    public var kind: Kind
    public var value: String          // emoji, icon name, or image URL
    public var color: String?         // hex, for icon

    public init(kind: Kind, value: String, color: String? = nil) {
        self.kind = kind
        self.value = value
        self.color = color
    }
}

public enum ProjectVisibility: String, Hashable, Sendable, Codable, CaseIterable {
    case `public`, `private`

    public var label: String { self == .public ? "Public" : "Private" }
}

public enum ProjectFeature: String, Hashable, Sendable, Codable, CaseIterable {
    case iterations, modules, intake, pages, estimates, timeTracking

    public var label: String {
        switch self {
        case .iterations: return "Cycles"
        case .modules: return "Modules"
        case .intake: return "Intake"
        case .pages: return "Pages"
        case .estimates: return "Estimates"
        case .timeTracking: return "Time tracking"
        }
    }
}

public enum ProjectSettingsField: String, Hashable, Sendable, Codable, CaseIterable {
    case name, description, logo, lead, defaultAssignee, visibility, features, labels, statuses

    public var label: String {
        switch self {
        case .name: return "Name"
        case .description: return "Description"
        case .logo: return "Logo"
        case .lead: return "Lead"
        case .defaultAssignee: return "Default assignee"
        case .visibility: return "Visibility"
        case .features: return "Features"
        case .labels: return "Labels"
        case .statuses: return "Statuses"
        }
    }
}

public struct ProjectMember: Hashable, Sendable {
    public var person: PersonRef
    public var role: String?          // "admin", "member", "guest"

    public init(person: PersonRef, role: String? = nil) {
        self.person = person
        self.role = role
    }
}

public struct ProjectSettings: Hashable, Sendable {
    public var name: String
    public var key: String?
    public var description: String?   // Markdown
    public var logo: ProjectLogo?
    public var lead: PersonRef?
    public var defaultAssignee: PersonRef?
    public var visibility: ProjectVisibility?
    public var statuses: [StatusOption]
    public var labels: [StatusOption]
    public var priorities: [String]   // option ids, urgent first
    public var members: [ProjectMember]
    /// Only the features that the tracker has.
    public var features: [ProjectFeature: Bool]
    /// Features that the adapter reads but cannot turn on or off.
    public var readOnlyFeatures: Set<ProjectFeature>

    public init(name: String, key: String? = nil, description: String? = nil, logo: ProjectLogo? = nil,
                lead: PersonRef? = nil, defaultAssignee: PersonRef? = nil, visibility: ProjectVisibility? = nil,
                statuses: [StatusOption] = [], labels: [StatusOption] = [], priorities: [String] = [],
                members: [ProjectMember] = [], features: [ProjectFeature: Bool] = [:],
                readOnlyFeatures: Set<ProjectFeature> = []) {
        self.name = name
        self.key = key
        self.description = description
        self.logo = logo
        self.lead = lead
        self.defaultAssignee = defaultAssignee
        self.visibility = visibility
        self.statuses = statuses
        self.labels = labels
        self.priorities = priorities
        self.members = members
        self.features = features
        self.readOnlyFeatures = readOnlyFeatures
    }
}

/// A new label for a project.
public struct LabelDraft: Hashable, Sendable {
    public var name: String
    public var color: String

    public init(name: String, color: String) {
        self.name = name
        self.color = color
    }
}

/// A typed write to the project settings. Nil fields stay as they are.
/// For lead, defaultAssignee and logo, `.some(nil)` clears the value.
public struct ProjectSettingsPatch: Hashable, Sendable {
    public var name: String?
    public var description: String?   // Markdown
    public var logo: ProjectLogo??
    public var lead: String??         // person id
    public var defaultAssignee: String??
    public var visibility: ProjectVisibility?
    public var features: [ProjectFeature: Bool]?
    public var newLabels: [LabelDraft]?

    public init(name: String? = nil, description: String? = nil, logo: ProjectLogo?? = nil, lead: String?? = nil,
                defaultAssignee: String?? = nil, visibility: ProjectVisibility? = nil,
                features: [ProjectFeature: Bool]? = nil, newLabels: [LabelDraft]? = nil) {
        self.name = name
        self.description = description
        self.logo = logo
        self.lead = lead
        self.defaultAssignee = defaultAssignee
        self.visibility = visibility
        self.features = features
        self.newLabels = newLabels
    }

    /// The fields that the patch changes. The confirmation names them.
    public var fields: Set<ProjectSettingsField> {
        var f: Set<ProjectSettingsField> = []
        if name != nil { f.insert(.name) }
        if description != nil { f.insert(.description) }
        if logo != nil { f.insert(.logo) }
        if lead != nil { f.insert(.lead) }
        if defaultAssignee != nil { f.insert(.defaultAssignee) }
        if visibility != nil { f.insert(.visibility) }
        if features != nil { f.insert(.features) }
        if newLabels != nil { f.insert(.labels) }
        return f
    }

    public var isEmpty: Bool { fields.isEmpty }
}

public protocol ProjectSettingsReading: Tracker {
    func settings(_ p: ProjectRef) async throws -> ProjectSettings
}

public protocol ProjectSettingsEditing: ProjectSettingsReading {
    var editableSettings: Set<ProjectSettingsField> { get }
    /// Throws `.unsupported(.projectSettingsEdit)` for a field that is not in editableSettings.
    func update(_ p: ProjectRef, _ patch: ProjectSettingsPatch) async throws
}

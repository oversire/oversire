import Foundation
import OverSireCore

// The domain types live in OverSireCore. This file keeps the Plane and UI parts.

extension ProjectRef {
    init(workspace: String, id: String, key: String? = nil) {
        self.init(account: AccountID(provider: .plane, id: workspace), id: id, key: key)
    }

    var workspace: String { account.id }
}

extension IntakeEdit {
    /// The names of the fields that the edit writes, for the event row.
    var fieldNames: [String] {
        let p = patch
        var out: [String] = []
        if p.title != nil { out.append("title") }
        if p.bodyMarkdown != nil { out.append("body") }
        if p.priority != nil { out.append("priority") }
        if p.status != nil { out.append("status") }
        if p.assignees != nil { out.append("assignees") }
        if p.labels != nil { out.append("labels") }
        if p.parent != nil { out.append("parent") }
        if !relations.isEmpty { out.append("relations") }
        return out
    }
}

extension IntakeAction {
    var failure: String {
        switch self {
        case .accept: return "Could not accept: "
        case .decline: return "Could not decline: "
        case .snooze: return "Could not snooze: "
        case .duplicate: return "Could not mark as duplicate: "
        case .delete: return "Could not delete: "
        case .pending: return "Could not put the item back in the intake: "
        case .update: return "Could not write the changes: "
        }
    }
}

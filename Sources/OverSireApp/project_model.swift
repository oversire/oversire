import Foundation
import OverSireCore

// The domain types live in OverSireCore. This file keeps the Plane and UI parts.

extension ProjectRef {
    init(workspace: String, id: String, key: String? = nil) {
        self.init(account: AccountID(provider: .plane, id: workspace), id: id, key: key)
    }

    var workspace: String { account.id }
}

extension IntakeAction {
    // The body for the Plane status endpoint. Delete has its own endpoint.
    var body: [String: Any]? {
        switch self {
        case .accept: return ["status": 1]
        case .decline: return ["status": -1]
        case .snooze(let d): return ["status": 0, "snoozed_till": ISO8601DateFormatter().string(from: d)]
        case .duplicate(let id): return ["status": 2, "duplicate_to": id]
        case .delete: return nil
        }
    }

    var failure: String {
        switch self {
        case .accept: return "Could not accept: "
        case .decline: return "Could not decline: "
        case .snooze: return "Could not snooze: "
        case .duplicate: return "Could not mark as duplicate: "
        case .delete: return "Could not delete: "
        }
    }
}

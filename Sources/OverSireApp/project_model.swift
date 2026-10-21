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
    var failure: String {
        switch self {
        case .accept: return "Could not accept: "
        case .decline: return "Could not decline: "
        case .snooze: return "Could not snooze: "
        case .duplicate: return "Could not mark as duplicate: "
        case .delete: return "Could not delete: "
        case .update: return "Could not write the changes: "
        }
    }
}

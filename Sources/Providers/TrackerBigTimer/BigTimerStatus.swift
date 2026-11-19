import Foundation
import OverSireCore

/// The statuses of the server are fixed. The adapter makes no call for them.
enum BigTimerStatus {
    static let options: [StatusOption] = [
        StatusOption(id: "open", name: "Open", color: "#9CA3AF", group: "unstarted"),
        StatusOption(id: "in_progress", name: "In progress", color: "#3B82F6", group: "started"),
        StatusOption(id: "blocked", name: "Blocked", color: "#EF4444", group: "started"),
        StatusOption(id: "client_reviewing", name: "Client reviewing", color: "#F59E0B", group: "started"),
        StatusOption(id: "done", name: "Done", color: "#22C55E", group: "completed"),
        StatusOption(id: "cancelled", name: "Cancelled", color: "#6B7280", group: "cancelled"),
    ]

    static let openIDs: Set<String> = ["open", "in_progress", "blocked", "client_reviewing"]
}

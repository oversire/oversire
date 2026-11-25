import Foundation
import UserNotifications

/// The calls of the notification center that `NoticeCenter` uses. Tests give a fake.
protocol NoticePosting: AnyObject {
    func deliver(_ request: UNNotificationRequest)
    func removeDelivered(_ ids: [String])
}

extension UNUserNotificationCenter: NoticePosting {
    func deliver(_ request: UNNotificationRequest) { add(request, withCompletionHandler: nil) }
    func removeDelivered(_ ids: [String]) { removeDeliveredNotifications(withIdentifiers: ids) }
}

/// Posts and withdraws notices.
final class NoticeCenter {
    private let center: any NoticePosting

    init(center: any NoticePosting) { self.center = center }

    func post(_ n: Notice) {
        center.deliver(UNNotificationRequest(identifier: n.id, content: Self.content(n), trigger: nil))
    }

    func withdraw(_ ids: [String]) { center.removeDelivered(ids) }

    static func content(_ n: Notice) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.subtitle = n.subtitle
        c.body = n.body
        c.threadIdentifier = n.thread
        c.categoryIdentifier = n.category?.id ?? ""
        c.sound = .default
        return c
    }
}

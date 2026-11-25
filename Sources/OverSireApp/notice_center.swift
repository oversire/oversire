import Foundation
import UserNotifications

/// The calls of the notification center that `NoticeCenter` uses. Tests give a fake.
protocol NoticePosting: AnyObject {
    func deliver(_ request: UNNotificationRequest)
    func removeDelivered(_ ids: [String])
    func setCategories(_ categories: Set<UNNotificationCategory>)
    /// Runs `done` after the categories that were set before are in.
    func categories(_ done: @escaping (Set<UNNotificationCategory>) -> Void)
}

extension UNUserNotificationCenter: NoticePosting {
    func deliver(_ request: UNNotificationRequest) { add(request, withCompletionHandler: nil) }
    func removeDelivered(_ ids: [String]) { removeDeliveredNotifications(withIdentifiers: ids) }
    func setCategories(_ categories: Set<UNNotificationCategory>) { setNotificationCategories(categories) }
    func categories(_ done: @escaping (Set<UNNotificationCategory>) -> Void) { getNotificationCategories(completionHandler: done) }
}

/// Posts and withdraws notices. It owns all the notification categories of the app.
final class NoticeCenter {
    static let maxQuestions = 20

    private let center: any NoticePosting
    /// The question categories that are set, the oldest first.
    private(set) var questions: [NoticeCategory] = []

    init(center: any NoticePosting) { self.center = center }

    /// Sets the fixed categories and the question categories.
    func register() {
        center.setCategories(Set((NoticeCategory.fixed + questions).map(Self.category)))
    }

    func post(_ n: Notice) {
        let request = UNNotificationRequest(identifier: n.id, content: Self.content(n), trigger: nil)
        guard let c = n.category, case .question = c, !questions.contains(c) else { center.deliver(request); return }
        questions.append(c)
        if questions.count > Self.maxQuestions { questions.removeFirst(questions.count - Self.maxQuestions) }
        register()
        // A notice with a category that is not in yet shows no buttons.
        center.categories { [center] _ in center.deliver(request) }
    }

    func withdraw(_ ids: [String]) { center.removeDelivered(ids) }

    static func content(_ n: Notice) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.subtitle = n.subtitle
        c.body = n.body
        c.threadIdentifier = n.thread
        c.categoryIdentifier = n.category?.id ?? ""
        c.userInfo = n.target.userInfo
        c.sound = .default
        return c
    }

    static func category(_ c: NoticeCategory) -> UNNotificationCategory {
        let actions: [UNNotificationAction] = c.actions.map { a in
            var options: UNNotificationActionOptions = []
            if a.foreground { options.insert(.foreground) }
            if a.destructive { options.insert(.destructive) }
            guard a == .reply else { return UNNotificationAction(identifier: a.id, title: a.title, options: options) }
            return UNTextInputNotificationAction(identifier: a.id, title: a.title, options: options, textInputButtonTitle: "Send",
                                                 textInputPlaceholder: c.replyPlaceholder)
        }
        return UNNotificationCategory(identifier: c.id, actions: actions, intentIdentifiers: [], options: [])
    }
}

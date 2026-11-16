import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectNotifierTests: XCTestCase {
    func testAwayLineGivesNoNotification() {
        let notifier = ProjectNotifier(post: { _, _, _, _ in })
        var all = ProjectNotificationSettings()
        all.comment = NotifyScope(any: true, mine: true)
        XCTAssertFalse(notifier.allows(.away(items: 5), item: nil, me: "me", settings: all))
        XCTAssertFalse(notifier.allows(.away(items: 1), item: nil, me: nil, settings: ProjectNotificationSettings()))
    }
}

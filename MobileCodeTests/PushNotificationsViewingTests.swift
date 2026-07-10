import UIKit
import XCTest
@testable import CodeAgentsMobile

final class PushNotificationsViewingTests: XCTestCase {
    private let projectId = UUID()
    private let otherId = UUID()

    func testActivelyViewingRequiresForegroundActive() {
        XCTAssertTrue(
            PushNotificationsManager.isActivelyViewingChat(
                projectId: projectId,
                selectedTab: .chat,
                activeProjectId: projectId,
                applicationState: .active
            )
        )

        // User left the app while Chat was still selected — must not suppress push.
        XCTAssertFalse(
            PushNotificationsManager.isActivelyViewingChat(
                projectId: projectId,
                selectedTab: .chat,
                activeProjectId: projectId,
                applicationState: .background
            )
        )
        XCTAssertFalse(
            PushNotificationsManager.isActivelyViewingChat(
                projectId: projectId,
                selectedTab: .chat,
                activeProjectId: projectId,
                applicationState: .inactive
            )
        )
    }

    func testActivelyViewingRequiresChatTabAndMatchingAgent() {
        XCTAssertFalse(
            PushNotificationsManager.isActivelyViewingChat(
                projectId: projectId,
                selectedTab: .files,
                activeProjectId: projectId,
                applicationState: .active
            )
        )
        XCTAssertFalse(
            PushNotificationsManager.isActivelyViewingChat(
                projectId: projectId,
                selectedTab: .chat,
                activeProjectId: otherId,
                applicationState: .active
            )
        )
        XCTAssertFalse(
            PushNotificationsManager.isActivelyViewingChat(
                projectId: projectId,
                selectedTab: .chat,
                activeProjectId: nil,
                applicationState: .active
            )
        )
    }
}

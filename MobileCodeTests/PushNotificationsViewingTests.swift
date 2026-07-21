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

    func testPresentationDoesNotSuppressUnreadEvenInMatchingActiveChat() {
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                lastReadCursor: 3,
                incomingAssistantCount: 4
            )
        )
        XCTAssertTrue(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                lastReadCursor: 4,
                incomingAssistantCount: 4
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_other0000001",
                lastReadCursor: 3,
                incomingAssistantCount: 4
            )
        )
    }

    func testPresentationSuppressesAlreadyReadDeliveryAfterLeavingChat() {
        XCTAssertTrue(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: false,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                lastReadCursor: 7,
                incomingAssistantCount: 7
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: false,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                lastReadCursor: 7,
                incomingAssistantCount: 8
            )
        )
    }

    func testPresentationRequiresSessionAndCountForDurableReadSuppression() {
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: nil,
                lastReadCursor: 7,
                incomingAssistantCount: 7
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                lastReadCursor: 7,
                incomingAssistantCount: nil
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: false,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: nil,
                lastReadCursor: 7,
                incomingAssistantCount: 7
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: false,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                lastReadCursor: 7,
                incomingAssistantCount: 7
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: false,
                currentSessionId: "ses_newsession001",
                unreadConversationId: "ses_oldsession001",
                payloadSessionId: "ses_newsession001",
                lastReadCursor: 99,
                incomingAssistantCount: 1
            )
        )
    }

    func testPresentationFailsOpenForLegacyCursorOrMalformedSession() {
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "ses_current00001",
                unreadConversationId: "ses_current00001",
                payloadSessionId: "ses_current00001",
                currentCursorVersion: nil,
                payloadCursorVersion: OpenCodeUnreadCursorSchema.currentVersion,
                lastReadCursor: 4,
                incomingAssistantCount: 4
            )
        )
        XCTAssertFalse(
            ReplyFinishedPresentationPolicy.shouldSuppress(
                applicationIsActive: true,
                isActiveChat: true,
                currentSessionId: "legacy-id",
                unreadConversationId: "legacy-id",
                payloadSessionId: "legacy-id",
                lastReadCursor: 4,
                incomingAssistantCount: 4
            )
        )
    }

    func testSessionPolicyRejectsReplacementButAllowsFirstAdoption() {
        XCTAssertEqual(
            ReplyFinishedSessionPolicy.relationship(
                currentSessionId: nil,
                incomingSessionId: "ses_incoming0001"
            ),
            .adoptable
        )
        XCTAssertEqual(
            ReplyFinishedSessionPolicy.relationship(
                currentSessionId: "ses_current00001",
                incomingSessionId: "ses_current00001"
            ),
            .matching
        )
        XCTAssertEqual(
            ReplyFinishedSessionPolicy.relationship(
                currentSessionId: "ses_current00001",
                incomingSessionId: "ses_other0000001"
            ),
            .conflicting
        )
        XCTAssertEqual(
            ReplyFinishedSessionPolicy.relationship(
                currentSessionId: "invalid",
                incomingSessionId: "ses_incoming0001"
            ),
            .adoptable
        )
        XCTAssertNil(
            ReplyFinishedSessionPolicy.cursorSessionId(
                incomingSessionId: nil,
                incomingAssistantCount: 4
            )
        )
        XCTAssertNil(
            ReplyFinishedSessionPolicy.cursorSessionId(
                incomingSessionId: "ses_current00001",
                incomingAssistantCount: nil
            )
        )
        XCTAssertNil(
            ReplyFinishedSessionPolicy.cursorSessionId(
                incomingSessionId: "legacy-conversation-id",
                incomingAssistantCount: 4
            )
        )
        XCTAssertEqual(
            ReplyFinishedSessionPolicy.cursorSessionId(
                incomingSessionId: " ses_current00001 ",
                incomingAssistantCount: 4
            ),
            "ses_current00001"
        )
    }

    func testTapPolicyNeverOpensTheWrongChatSession() {
        XCTAssertEqual(ReplyFinishedTapPolicy.destination(for: .matching), .chat)
        XCTAssertEqual(ReplyFinishedTapPolicy.destination(for: .adoptable), .chat)
        XCTAssertEqual(ReplyFinishedTapPolicy.destination(for: .conflicting), .tasks)
        XCTAssertEqual(ReplyFinishedTapPolicy.destination(for: .noIncomingSession), .tasks)
    }
}

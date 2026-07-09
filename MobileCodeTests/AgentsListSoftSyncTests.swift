import XCTest
@testable import CodeAgentsMobile

final class AgentsListSoftSyncTests: XCTestCase {
    func testUnreadCursorBumpsForNewAssistants() {
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 3,
            lastRead: 3,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            newAssistantCount: 2
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 3)
        XCTAssertEqual(next?.unreadConversationId, "ses_a")
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 2)
    }

    func testUnreadCursorNoChangeWithoutNewAssistants() {
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 4,
            lastRead: 2,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            newAssistantCount: 0
        )
        XCTAssertNil(next)
    }

    func testUnreadCursorResetsReadWhenSessionChanges() {
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 10,
            lastRead: 10,
            unreadConversationId: "ses_old",
            sessionId: "ses_new",
            newAssistantCount: 1
        )

        XCTAssertEqual(next?.lastRead, 0)
        XCTAssertEqual(next?.lastKnown, 1)
        XCTAssertEqual(next?.unreadConversationId, "ses_new")
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
    }

    func testUnreadCursorIgnoresEmptySessionId() {
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 1,
            lastRead: 0,
            unreadConversationId: "ses_a",
            sessionId: "  ",
            newAssistantCount: 3
        )
        XCTAssertNil(next)
    }

    func testUnreadCursorDoesNotDecreaseKnown() {
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 8,
            lastRead: 5,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            newAssistantCount: 1
        )
        // proposed = 5+1 = 6, already known 8 → no bump
        XCTAssertNil(next)
    }

    func testUnreadCursorBaselinesOnFirstBind() {
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 0,
            lastRead: 0,
            unreadConversationId: nil,
            sessionId: "ses_a",
            newAssistantCount: 4
        )

        // Existing history should not all show as unread on first soft poll.
        XCTAssertEqual(next?.lastKnown, 4)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(next?.unreadConversationId, "ses_a")
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
    }

    func testUnreadCursorBumpsAfterFirstBindBaseline() {
        // After baseline, a later poll with new assistants must still badge.
        let next = AgentsListUnreadCursor.applying(
            lastKnown: 4,
            lastRead: 4,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            newAssistantCount: 1
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
    }
}

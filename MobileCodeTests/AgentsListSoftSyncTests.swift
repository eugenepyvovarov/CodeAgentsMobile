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

    func testAbsoluteCursorRaisesKnownWithoutInsertDelta() {
        // Soft-sync used to miss streaming placeholders that only updated in place.
        let next = AgentsListUnreadCursor.applyingAbsolute(
            lastKnown: 3,
            lastRead: 3,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 3)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 2)
    }

    func testAbsoluteCursorNoChangeWhenEqual() {
        let next = AgentsListUnreadCursor.applyingAbsolute(
            lastKnown: 5,
            lastRead: 3,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5
        )
        XCTAssertNil(next)
    }

    func testAbsoluteCursorBaselinesFirstBind() {
        let next = AgentsListUnreadCursor.applyingAbsolute(
            lastKnown: 0,
            lastRead: 0,
            unreadConversationId: nil,
            sessionId: "ses_a",
            absoluteAssistantCount: 7
        )
        XCTAssertEqual(next?.lastKnown, 7)
        XCTAssertEqual(next?.lastRead, 7)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
    }

    func testAbsoluteCursorResetsOnSessionChange() {
        let next = AgentsListUnreadCursor.applyingAbsolute(
            lastKnown: 10,
            lastRead: 10,
            unreadConversationId: "ses_old",
            sessionId: "ses_new",
            absoluteAssistantCount: 2
        )
        XCTAssertEqual(next?.lastKnown, 2)
        XCTAssertEqual(next?.lastRead, 0)
        XCTAssertEqual(next?.unreadConversationId, "ses_new")
    }

    func testInteractiveReplyFirstBindLeavesOneUnreadWhenNotViewing() {
        // Soft-poll first-bind baselines known==read; interactive finish must not wipe the badge.
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 0,
            lastRead: 0,
            unreadConversationId: nil,
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            isViewingChat: false
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
        XCTAssertEqual(next?.unreadConversationId, "ses_a")
    }

    func testInteractiveReplyWhileViewingMarksFullyRead() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 3,
            lastRead: 3,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            isViewingChat: true
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 5)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
    }

    func testInteractiveReplyBumpsKnownAndKeepsExistingUnreadGap() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 4,
            lastRead: 2,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 6,
            isViewingChat: false
        )

        XCTAssertEqual(next?.lastKnown, 6)
        XCTAssertEqual(next?.lastRead, 2)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 4)
    }

    func testInteractiveReplyWhenAlreadyCaughtUpLeavesOneUnreadOffscreen() {
        // absolute equal to known (no raise) but reply finished while away.
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 5,
            lastRead: 5,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            isViewingChat: false
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
    }
}

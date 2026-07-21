import XCTest
@testable import CodeAgentsMobile

final class AgentsListSoftSyncTests: XCTestCase {
    func testCursorMigrationDoesNotTreatHistoricalFinalityBackfillAsNew() {
        XCTAssertFalse(
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: "msg_historical",
                existedBeforeHydration: true,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: false,
                hydratedRole: .assistant,
                hydratedIsComplete: true,
                hydratedText: "Historical reply",
                isCursorMigration: true,
                migrationBoundedCandidateRuntimeMessageIDs: ["msg_historical"]
            )
        )
    }

    func testCursorMigrationKeepsNewlyAddedRuntimeReplyUnread() {
        XCTAssertTrue(
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: "msg_new",
                existedBeforeHydration: false,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: false,
                hydratedRole: .assistant,
                hydratedIsComplete: true,
                hydratedText: "Just arrived",
                isCursorMigration: true,
                migrationBoundedCandidateRuntimeMessageIDs: ["msg_new"]
            )
        )
    }

    func testCursorMigrationCountsBoundedCompletionAcrossTwoPolls() {
        let firstPollCandidates = AgentsListAssistantFinality.migrationBoundedCandidateRuntimeMessageIDs(
            isCursorMigration: true,
            previousHydrationMessageIDs: ["msg_recent_anchor"],
            initialBoundedAddedMessageIDs: ["msg_streaming"],
            initialBoundedHydratedMessageIDs: ["msg_streaming"]
        )

        XCTAssertFalse(
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: "msg_streaming",
                existedBeforeHydration: false,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: false,
                hydratedRole: .assistant,
                hydratedIsComplete: false,
                hydratedText: "Still working",
                isCursorMigration: true,
                migrationBoundedCandidateRuntimeMessageIDs: firstPollCandidates
            )
        )

        let secondPollCandidates = AgentsListAssistantFinality.migrationBoundedCandidateRuntimeMessageIDs(
            isCursorMigration: true,
            previousHydrationMessageIDs: ["msg_recent_anchor", "msg_streaming"],
            initialBoundedAddedMessageIDs: [],
            initialBoundedHydratedMessageIDs: ["msg_streaming"]
        )

        XCTAssertTrue(
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: "msg_streaming",
                existedBeforeHydration: true,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: true,
                hydratedRole: .assistant,
                hydratedIsComplete: true,
                hydratedText: "Finished reply",
                isCursorMigration: true,
                migrationBoundedCandidateRuntimeMessageIDs: secondPollCandidates
            )
        )
    }

    func testCursorMigrationUsesBoundedCandidatesInsteadOfHistoricalFullRefreshAdditions() {
        let migrationCandidateIDs = AgentsListAssistantFinality.migrationBoundedCandidateRuntimeMessageIDs(
            isCursorMigration: true,
            previousHydrationMessageIDs: ["msg_recent_anchor"],
            initialBoundedAddedMessageIDs: ["msg_new"],
            initialBoundedHydratedMessageIDs: ["msg_new"]
        )
        let fullRefreshRows: [(id: String, existedLocally: Bool)] = [
            ("msg_historical_out_of_window", false),
            ("msg_historical_existing", true),
            ("msg_new", false),
        ]

        let counted = fullRefreshRows.compactMap { row -> String? in
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: row.id,
                existedBeforeHydration: row.existedLocally,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: false,
                hydratedRole: .assistant,
                hydratedIsComplete: true,
                hydratedText: "Final reply",
                isCursorMigration: true,
                migrationBoundedCandidateRuntimeMessageIDs: migrationCandidateIDs
            ) ? row.id : nil
        }

        XCTAssertEqual(counted, ["msg_new"])
    }

    func testCursorMigrationWithoutPriorAnchorsBaselinesInitialSnapshot() {
        let migrationCandidateIDs = AgentsListAssistantFinality.migrationBoundedCandidateRuntimeMessageIDs(
            isCursorMigration: true,
            previousHydrationMessageIDs: [],
            initialBoundedAddedMessageIDs: ["msg_unknown_age"],
            initialBoundedHydratedMessageIDs: ["msg_unknown_age"]
        )

        XCTAssertTrue(migrationCandidateIDs.isEmpty)
    }

    func testPostMigrationCompletionTransitionCountsOnce() {
        XCTAssertTrue(
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: "msg_existing",
                existedBeforeHydration: true,
                wasRuntimeFinalized: false,
                wasLocallyIncompleteOrStreaming: true,
                hydratedRole: .assistant,
                hydratedIsComplete: true,
                hydratedText: "Final reply",
                isCursorMigration: false,
                migrationBoundedCandidateRuntimeMessageIDs: []
            )
        )
        XCTAssertFalse(
            AgentsListAssistantFinality.shouldCountAsNew(
                runtimeMessageID: "msg_existing",
                existedBeforeHydration: true,
                wasRuntimeFinalized: true,
                wasLocallyIncompleteOrStreaming: false,
                hydratedRole: .assistant,
                hydratedIsComplete: true,
                hydratedText: "Final reply",
                isCursorMigration: false,
                migrationBoundedCandidateRuntimeMessageIDs: []
            )
        )
    }

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

    func testInteractiveReplyFirstBindLeavesExactlyOneUnreadWhenFinalUnseen() {
        // Soft-poll first-bind baselines known==read; interactive finish must not wipe the badge.
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 0,
            lastRead: 0,
            unreadConversationId: nil,
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            wasFinalOutputSeen: false
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
        XCTAssertEqual(next?.unreadConversationId, "ses_a")
    }

    func testInteractiveReplyFirstBindMarksAllReadWhenFinalSeen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 0,
            lastRead: 0,
            unreadConversationId: nil,
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            wasFinalOutputSeen: true
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 5)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
        XCTAssertEqual(next?.unreadConversationId, "ses_a")
    }

    func testInteractiveReplyNewCountMarksAllReadWhenFinalSeen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 3,
            lastRead: 3,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            wasFinalOutputSeen: true
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 5)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
    }

    func testInteractiveReplyNewCountKeepsExistingUnreadGapWhenFinalUnseen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 4,
            lastRead: 2,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 6,
            wasFinalOutputSeen: false
        )

        XCTAssertEqual(next?.lastKnown, 6)
        XCTAssertEqual(next?.lastRead, 2)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 4)
    }

    func testInteractiveReplyEqualCountLeavesOneUnreadWhenFinalUnseen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 5,
            lastRead: 5,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            wasFinalOutputSeen: false
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
    }

    func testInteractiveReplyEqualCountStaysReadWhenFinalSeen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 5,
            lastRead: 5,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 5,
            wasFinalOutputSeen: true
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 5)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
    }

    func testInteractiveReplyStaleCountLeavesOneUnreadWhenFinalUnseen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 5,
            lastRead: 5,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 3,
            wasFinalOutputSeen: false
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 4)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 1)
    }

    func testInteractiveReplyStaleCountDoesNotConsumeNewerKnownUnread() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 5,
            lastRead: 2,
            unreadConversationId: "ses_a",
            sessionId: "ses_a",
            absoluteAssistantCount: 3,
            wasFinalOutputSeen: true
        )

        XCTAssertEqual(next?.lastKnown, 5)
        XCTAssertEqual(next?.lastRead, 3)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 2)
    }

    func testInteractiveReplySessionChangeLeavesNewSessionUnreadWhenFinalUnseen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 8,
            lastRead: 8,
            unreadConversationId: "ses_old",
            sessionId: "ses_new",
            absoluteAssistantCount: 3,
            wasFinalOutputSeen: false
        )

        XCTAssertEqual(next?.lastKnown, 3)
        XCTAssertEqual(next?.lastRead, 0)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 3)
        XCTAssertEqual(next?.unreadConversationId, "ses_new")
    }

    func testInteractiveReplySessionChangeMarksNewSessionReadWhenFinalSeen() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 8,
            lastRead: 8,
            unreadConversationId: "ses_old",
            sessionId: "ses_new",
            absoluteAssistantCount: 3,
            wasFinalOutputSeen: true
        )

        XCTAssertEqual(next?.lastKnown, 3)
        XCTAssertEqual(next?.lastRead, 3)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
        XCTAssertEqual(next?.unreadConversationId, "ses_new")
    }

    func testInteractiveReplyUnseenZeroCountDoesNotInventUnread() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 0,
            lastRead: 0,
            unreadConversationId: nil,
            sessionId: "ses_a",
            absoluteAssistantCount: 0,
            wasFinalOutputSeen: false
        )

        XCTAssertEqual(next?.lastKnown, 0)
        XCTAssertEqual(next?.lastRead, 0)
        XCTAssertEqual(max(0, (next?.lastKnown ?? 0) - (next?.lastRead ?? 0)), 0)
        XCTAssertEqual(next?.unreadConversationId, "ses_a")
    }

    func testInteractiveReplyIgnoresEmptySessionId() {
        let next = AgentsListUnreadCursor.applyingInteractiveReplyFinished(
            lastKnown: 5,
            lastRead: 5,
            unreadConversationId: "ses_a",
            sessionId: "  ",
            absoluteAssistantCount: 6,
            wasFinalOutputSeen: false
        )

        XCTAssertNil(next)
    }
}

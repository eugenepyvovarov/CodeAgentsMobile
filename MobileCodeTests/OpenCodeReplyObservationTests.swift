import XCTest
@testable import CodeAgentsMobile

final class OpenCodeReplyObservationTests: XCTestCase {
    func testFinalOutputRequiresAVisibleRevisionAfterSendStarted() {
        let generation = UUID()
        let messageID = UUID()
        var observation = OpenCodeReplyObservation()
        observation.begin(generation: generation, initialMessageID: messageID)

        XCTAssertFalse(observation.wasFinalOutputSeen(generation: generation))

        observation.noteContentChange(generation: generation, messageID: messageID)
        observation.recordVisible(generation: generation, messageID: messageID)

        XCTAssertTrue(observation.wasFinalOutputSeen(generation: generation))
    }

    func testOutputThatChangesAfterLeavingIsNotTreatedAsSeen() {
        let generation = UUID()
        let messageID = UUID()
        var observation = OpenCodeReplyObservation()
        observation.begin(generation: generation, initialMessageID: messageID)
        observation.noteContentChange(generation: generation, messageID: messageID)
        observation.recordVisible(generation: generation, messageID: messageID)
        observation.noteContentChange(generation: generation, messageID: messageID)

        XCTAssertFalse(observation.wasFinalOutputSeen(generation: generation))
    }

    func testWrongGenerationCannotRecordOrClearActiveObservation() {
        let generation = UUID()
        let otherGeneration = UUID()
        let messageID = UUID()
        var observation = OpenCodeReplyObservation()
        observation.begin(generation: generation, initialMessageID: messageID)
        observation.noteContentChange(generation: generation, messageID: messageID)
        observation.recordVisible(generation: otherGeneration, messageID: messageID)
        observation.clear(generation: otherGeneration)

        XCTAssertFalse(observation.wasFinalOutputSeen(generation: generation))

        observation.recordVisible(generation: generation, messageID: messageID)
        XCTAssertTrue(observation.wasFinalOutputSeen(generation: generation))
    }

    func testUnrelatedAssistantMessageDoesNotAffectActiveReplyObservation() {
        let generation = UUID()
        let replyMessageID = UUID()
        let unrelatedMessageID = UUID()
        var observation = OpenCodeReplyObservation()
        observation.begin(generation: generation, initialMessageID: replyMessageID)

        observation.noteContentChange(generation: generation, messageID: unrelatedMessageID)
        observation.recordVisible(generation: generation, messageID: unrelatedMessageID)

        XCTAssertEqual(observation.outputRevision, 0)
        XCTAssertFalse(observation.wasFinalOutputSeen(generation: generation))
    }

    func testEveryChangedReplyMessageMustBeSeenAtItsLatestRevision() {
        let generation = UUID()
        let firstMessageID = UUID()
        let secondMessageID = UUID()
        var observation = OpenCodeReplyObservation()
        observation.begin(generation: generation, initialMessageID: firstMessageID)
        observation.registerMessage(
            generation: generation,
            messageID: secondMessageID,
            hasVisibleContent: false
        )
        observation.noteContentChange(generation: generation, messageID: firstMessageID)
        observation.noteContentChange(generation: generation, messageID: secondMessageID)

        observation.recordVisible(generation: generation, messageID: secondMessageID)
        XCTAssertFalse(observation.wasFinalOutputSeen(generation: generation))

        observation.recordVisible(generation: generation, messageID: firstMessageID)
        XCTAssertTrue(observation.wasFinalOutputSeen(generation: generation))

        observation.noteContentChange(generation: generation, messageID: firstMessageID)
        XCTAssertFalse(observation.wasFinalOutputSeen(generation: generation))
    }

    func testRemovedTransientMessageNoLongerBlocksFinalSeenState() {
        let generation = UUID()
        let progressMessageID = UUID()
        let finalMessageID = UUID()
        var observation = OpenCodeReplyObservation()
        observation.begin(generation: generation, initialMessageID: progressMessageID)
        observation.noteContentChange(generation: generation, messageID: progressMessageID)
        observation.registerMessage(
            generation: generation,
            messageID: finalMessageID,
            hasVisibleContent: true
        )

        observation.removeMessage(generation: generation, messageID: progressMessageID)
        observation.recordVisible(generation: generation, messageID: finalMessageID)

        XCTAssertEqual(observation.pendingMessageIDs, [])
        XCTAssertTrue(observation.wasFinalOutputSeen(generation: generation))
    }

    func testVisibilityPolicyRejectsMountedChatWhileAppIsBackgrounded() {
        let projectID = UUID()

        XCTAssertFalse(
            OpenCodeReplyVisibilityPolicy.shouldRecord(
                isViewVisible: true,
                isSceneActive: false,
                isChatTabSelected: true,
                viewModelProjectID: projectID,
                activeProjectID: projectID
            )
        )
        XCTAssertTrue(
            OpenCodeReplyVisibilityPolicy.shouldRecord(
                isViewVisible: true,
                isSceneActive: true,
                isChatTabSelected: true,
                viewModelProjectID: projectID,
                activeProjectID: projectID
            )
        )
    }

    func testVisibilityPolicyRejectsOtherTabsAndProjects() {
        let projectID = UUID()

        XCTAssertFalse(
            OpenCodeReplyVisibilityPolicy.shouldRecord(
                isViewVisible: true,
                isSceneActive: true,
                isChatTabSelected: false,
                viewModelProjectID: projectID,
                activeProjectID: projectID
            )
        )
        XCTAssertFalse(
            OpenCodeReplyVisibilityPolicy.shouldRecord(
                isViewVisible: true,
                isSceneActive: true,
                isChatTabSelected: true,
                viewModelProjectID: projectID,
                activeProjectID: UUID()
            )
        )
    }

    @MainActor
    func testRetainedUnseenObservationBlocksUntilItsRowIsActuallyRecorded() {
        let viewModel = ChatViewModel()
        let generation = UUID()
        let messageID = UUID()
        viewModel.beginOpenCodeReplyObservation(generation: generation, initialMessageID: messageID)
        viewModel.noteOpenCodeReplyMessageContentChanged(messageID: messageID)
        viewModel.retainUnseenOpenCodeReplyObservation(generation: generation)

        XCTAssertEqual(viewModel.openCodeReplyPendingMessageIDs, [messageID])
        XCTAssertTrue(viewModel.retainedUnseenOpenCodeReplyGenerations.contains(generation))

        XCTAssertTrue(viewModel.recordVisibleOpenCodeReplyRevision(messageID: messageID))
        XCTAssertTrue(viewModel.openCodeReplyPendingMessageIDs.isEmpty)
        XCTAssertFalse(viewModel.retainedUnseenOpenCodeReplyGenerations.contains(generation))
    }

    @MainActor
    func testRemoteUnreadRequiresAdvertisedContentNotMerelyAHydrationCallback() {
        let viewModel = ChatViewModel()
        let sessionID = "ses_current00001"

        XCTAssertTrue(viewModel.isUnreadHydrationRequirementSatisfied)
        viewModel.requireHydrationForUnreadReply(
            sessionID: sessionID,
            minimumAssistantMessageCount: 1
        )
        XCTAssertFalse(viewModel.isUnreadHydrationRequirementSatisfied)

        // Empty/stale network hydration is not proof that the pushed reply arrived.
        viewModel.noteOpenCodeHydrationApplied()
        XCTAssertFalse(viewModel.isUnreadHydrationRequirementSatisfied)

        let hydrated = Message(content: "Done", role: .assistant)
        hydrated.originalJSON = OpenCodeChatMapper.normalizedPayloadData(
            type: "assistant",
            role: "assistant",
            text: "Done",
            sessionID: sessionID,
            messageID: "msg_runtime_1",
            partIDs: ["part_1"],
            rawEvent: nil
        )
        hydrated.openCodeRuntimeFinalized = true
        viewModel.messages.append(hydrated)
        XCTAssertTrue(viewModel.isUnreadHydrationRequirementSatisfied)
    }
}

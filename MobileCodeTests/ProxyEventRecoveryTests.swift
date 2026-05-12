import XCTest
@testable import CodeAgentsMobile

final class ProxyEventRecoveryTests: XCTestCase {
    @MainActor
    func testChatOpenDecisionSkipsRemoteWorkWhenNoActiveStreamingMessageExists() {
        XCTAssertEqual(
            ProxyEventRecovery.chatOpenDecision(activeStreamingMessageId: nil, activeMessage: nil),
            .idleNoRemoteWork
        )
    }

    @MainActor
    func testChatOpenDecisionOnlyRunsRemoteRecoveryForUsableActiveStreams() {
        let streamingMessage = Message(
            content: "streaming",
            role: .assistant,
            isComplete: false,
            isStreaming: true
        )

        XCTAssertEqual(
            ProxyEventRecovery.chatOpenDecision(
                activeStreamingMessageId: streamingMessage.id,
                activeMessage: streamingMessage
            ),
            .remoteRecovery(streamingMessage.id)
        )

        streamingMessage.isStreaming = false
        streamingMessage.isComplete = true

        XCTAssertEqual(
            ProxyEventRecovery.chatOpenDecision(
                activeStreamingMessageId: streamingMessage.id,
                activeMessage: streamingMessage
            ),
            .clearCompletedActiveMessage(streamingMessage.id)
        )
    }

    @MainActor
    func testUsableAnchorUsesMaximumPersistedMessageEventIdWhenStoredAnchorIsMissing() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        let oldMessage = Message(content: "old", role: .assistant)
        oldMessage.proxyEventId = 7
        let latestMessage = Message(content: "latest", role: .assistant)
        latestMessage.proxyEventId = 12

        XCTAssertEqual(ProxyEventRecovery.usableAnchor(project: project, messages: [oldMessage, latestMessage]), 12)
    }

    @MainActor
    func testUsableAnchorKeepsMonotonicMaximumOfStoredAndPersistedMessageEventIds() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyLastEventId = 20
        let message = Message(content: "older", role: .assistant)
        message.proxyEventId = 12

        XCTAssertEqual(ProxyEventRecovery.usableAnchor(project: project, messages: [message]), 20)

        message.proxyEventId = 25
        XCTAssertEqual(ProxyEventRecovery.usableAnchor(project: project, messages: [message]), 25)
    }

    @MainActor
    func testFullReplayRepairOnlyWhenLocalMessagesHaveNoUsableAnchor() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        let message = Message(content: "existing", role: .assistant)

        XCTAssertTrue(ProxyEventRecovery.shouldRepairFullReplay(
            hasLocalMessages: true,
            usableAnchor: ProxyEventRecovery.usableAnchor(project: project, messages: [message])
        ))

        message.proxyEventId = 3
        XCTAssertFalse(ProxyEventRecovery.shouldRepairFullReplay(
            hasLocalMessages: true,
            usableAnchor: ProxyEventRecovery.usableAnchor(project: project, messages: [message])
        ))
        XCTAssertFalse(ProxyEventRecovery.shouldRepairFullReplay(hasLocalMessages: false, usableAnchor: nil))
        XCTAssertEqual(ProxyEventRecovery.repairReplayStartEventId(hasLocalMessages: true, usableAnchor: nil), 0)
        XCTAssertNil(ProxyEventRecovery.repairReplayStartEventId(hasLocalMessages: true, usableAnchor: 3))
        XCTAssertNil(ProxyEventRecovery.repairReplayStartEventId(hasLocalMessages: false, usableAnchor: nil))
    }

    @MainActor
    func testOverlappingReplayEventsAreDedupedAndLastEventIdAdvancesMonotonically() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyLastEventId = 2
        let existingEventIds: Set<Int> = [1, 2]
        let overlappingEvent = ProxyStreamEvent(eventId: 2, jsonLine: #"{"type":"assistant","message":{"content":"old"}}"#)
        let newEvent = ProxyStreamEvent(eventId: 3, jsonLine: #"{"type":"assistant","message":{"content":"new"}}"#)

        XCTAssertTrue(ProxyEventRecovery.isDuplicateReplayEvent(overlappingEvent, existingEventIds: existingEventIds))
        XCTAssertFalse(ProxyEventRecovery.isDuplicateReplayEvent(newEvent, existingEventIds: existingEventIds))

        XCTAssertTrue(ProxyEventRecovery.advanceLastEventId(project: project, events: [newEvent, overlappingEvent]))
        XCTAssertEqual(project.proxyLastEventId, 3)

        XCTAssertFalse(ProxyEventRecovery.advanceLastEventId(project: project, to: 2))
        XCTAssertEqual(project.proxyLastEventId, 3)
    }

    func testDestructiveResyncOnlyForConfirmedConversationSwitches() {
        XCTAssertTrue(ProxyEventRecovery.shouldDestructivelyResync(
            previousConversationId: "old",
            currentConversationId: "new",
            didInitiallyBindFromMissingConversation: false
        ))
        XCTAssertFalse(ProxyEventRecovery.shouldDestructivelyResync(
            previousConversationId: nil,
            currentConversationId: "new",
            didInitiallyBindFromMissingConversation: true
        ))
        XCTAssertFalse(ProxyEventRecovery.shouldDestructivelyResync(
            previousConversationId: "same",
            currentConversationId: "same",
            didInitiallyBindFromMissingConversation: false
        ))
    }
}

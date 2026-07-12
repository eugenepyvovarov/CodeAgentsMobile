import XCTest
@testable import CodeAgentsMobile

final class ChatDeferredStartupTests: XCTestCase {
    func testOpenCodeIdleReopenWithLocalHistoryDoesNotBlockChatOpen() {
        let decision = OpenCodeChatOpenPolicy.decision(
            hasOpenCodeSession: true,
            localMessageCount: 12,
            activeStreamingMessageId: nil,
            messages: []
        )
        XCTAssertEqual(decision, OpenCodeChatOpenPolicy.Decision.idleLocalFirst)
        XCTAssertFalse(OpenCodeChatOpenPolicy.blocksChatOpen(for: decision))
    }

    func testOpenCodeEmptyLocalHistoryRequiresRemoteHydration() {
        let decision = OpenCodeChatOpenPolicy.decision(
            hasOpenCodeSession: true,
            localMessageCount: 0,
            activeStreamingMessageId: nil,
            messages: []
        )
        XCTAssertEqual(decision, OpenCodeChatOpenPolicy.Decision.remoteHydrationRequired)
        XCTAssertTrue(OpenCodeChatOpenPolicy.blocksChatOpen(for: decision))
    }

    func testOpenCodeActiveStreamingMessageBlocksChatOpenForRecovery() {
        let message = Message(content: "streaming", role: .assistant, projectId: UUID())
        message.isStreaming = true
        message.isComplete = false
        let decision = OpenCodeChatOpenPolicy.decision(
            hasOpenCodeSession: true,
            localMessageCount: 3,
            activeStreamingMessageId: message.id,
            messages: [message]
        )
        XCTAssertEqual(decision, OpenCodeChatOpenPolicy.Decision.activeStreamRecovery)
        XCTAssertTrue(OpenCodeChatOpenPolicy.blocksChatOpen(for: decision))
    }

    func testOpenCodeStaleActiveMarkerWithLocalHistoryStaysLocalFirst() {
        let message = Message(content: "done", role: .assistant, projectId: UUID())
        message.isStreaming = false
        message.isComplete = true
        let decision = OpenCodeChatOpenPolicy.decision(
            hasOpenCodeSession: true,
            localMessageCount: 5,
            activeStreamingMessageId: message.id,
            messages: [message]
        )
        XCTAssertEqual(decision, OpenCodeChatOpenPolicy.Decision.idleLocalFirst)
        XCTAssertFalse(OpenCodeChatOpenPolicy.blocksChatOpen(for: decision))
    }

    func testSendTimeMCPPolicyFetchesWhenCacheIsEmpty() {
        let now = Date()

        XCTAssertTrue(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 0,
            isInvalidated: false,
            lastFetchedAt: now,
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeMCPPolicyFetchesWhenCacheWasInvalidated() {
        let now = Date()

        XCTAssertTrue(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 2,
            isInvalidated: true,
            lastFetchedAt: now,
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeMCPPolicyFetchesWhenCacheIsStale() {
        let now = Date()

        XCTAssertTrue(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-301),
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeMCPPolicyUsesFreshPopulatedCache() {
        let now = Date()

        XCTAssertFalse(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-60),
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeSetupPlanFetchesMCPAndRulesWhenCacheIsEmpty() {
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: 0,
            isInvalidated: false,
            lastFetchedAt: Date(),
            now: Date(),
            staleInterval: 300,
            includeRules: true
        )

        XCTAssertEqual(plan, ChatMCPServerSetupPlan(
            shouldFetchMCPServers: true,
            shouldEnsureRules: true
        ))
    }

    func testSendTimeSetupPlanSkipsMCPFetchOnOpenCodeCriticalPath() {
        let now = Date()
        // OpenCode send does not consume app-side MCP lists; avoid blocking first message.
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-600),
            now: now,
            staleInterval: 300,
            includeRules: false,
            allowMCPFetch: false
        )

        XCTAssertEqual(plan, ChatMCPServerSetupPlan(
            shouldFetchMCPServers: false,
            shouldEnsureRules: false
        ))
    }

    func testSendTimeSetupPlanStillFetchesMCPWhenAllowlisted() {
        let now = Date()
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-600),
            now: now,
            staleInterval: 300,
            includeRules: false,
            allowMCPFetch: true
        )

        XCTAssertEqual(plan, ChatMCPServerSetupPlan(
            shouldFetchMCPServers: true,
            shouldEnsureRules: false
        ))
    }

    func testSendTimeSetupPlanKeepsRulesEnsureWhenMCPServerCacheIsFresh() {
        let now = Date()
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-60),
            now: now,
            staleInterval: 300,
            includeRules: true
        )

        XCTAssertEqual(plan, ChatMCPServerSetupPlan(
            shouldFetchMCPServers: false,
            shouldEnsureRules: true
        ))
    }

    func testPostReadyDeferredSetupPlanRefreshesStaleMCPWithoutRules() {
        let now = Date()
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: 1,
            isInvalidated: true,
            lastFetchedAt: now.addingTimeInterval(-30),
            now: now,
            staleInterval: 300,
            includeRules: false
        )

        XCTAssertEqual(plan, ChatMCPServerSetupPlan(
            shouldFetchMCPServers: true,
            shouldEnsureRules: false
        ))
    }

    func testPostReadyMediaPrefetchUsesProjectScopedMessageSnapshot() {
        let projectID = UUID()
        var snapshots = [
            ChatMediaPrefetchMessageSnapshot(
                role: .assistant,
                isComplete: true,
                content: codeAgentsUIImageBlock(path: "images/ready.png")
            )
        ]

        let request = ChatMediaPrefetchPlanner.postReadyRequest(projectID: projectID, messages: snapshots)
        snapshots.append(ChatMediaPrefetchMessageSnapshot(
            role: .assistant,
            isComplete: true,
            content: codeAgentsUIImageBlock(path: "images/later.png")
        ))

        let sources = ChatMediaPrefetchPlanner.mediaSources(in: request.messages, projectID: request.projectID)

        XCTAssertEqual(request.projectID, projectID)
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(sources.count, 1)
        if let source = sources.first, case .projectFile(let path) = source {
            XCTAssertEqual(path, "images/ready.png")
        } else {
            XCTFail("Expected project file media source")
        }
    }

    func testMediaPrefetchCompletionDoesNotClearStaleProjectOrCancelledTasks() {
        let taskProjectID = UUID()
        let otherProjectID = UUID()
        let token = UUID()

        XCTAssertFalse(ChatMediaPrefetchCompletionPolicy.shouldClearTask(
            isCancelled: true,
            currentProjectID: taskProjectID,
            taskProjectID: taskProjectID,
            storedToken: token,
            taskToken: token
        ))

        XCTAssertFalse(ChatMediaPrefetchCompletionPolicy.shouldClearTask(
            isCancelled: false,
            currentProjectID: otherProjectID,
            taskProjectID: taskProjectID,
            storedToken: token,
            taskToken: token
        ))
    }

    func testMediaPrefetchCompletionOnlyClearsMatchingCurrentTaskToken() {
        let projectID = UUID()
        let token = UUID()

        XCTAssertFalse(ChatMediaPrefetchCompletionPolicy.shouldClearTask(
            isCancelled: false,
            currentProjectID: projectID,
            taskProjectID: projectID,
            storedToken: UUID(),
            taskToken: token
        ))

        XCTAssertTrue(ChatMediaPrefetchCompletionPolicy.shouldClearTask(
            isCancelled: false,
            currentProjectID: projectID,
            taskProjectID: projectID,
            storedToken: token,
            taskToken: token
        ))
    }

    func testDeferredStartupCompletionDoesNotClearCancelledStaleOrReplacedTasks() {
        let projectID = UUID()
        let token = UUID()

        XCTAssertFalse(ChatDeferredStartupCompletionPolicy.shouldClearTask(
            isCancelled: true,
            storedProjectID: projectID,
            taskProjectID: projectID,
            storedToken: token,
            taskToken: token
        ))

        XCTAssertFalse(ChatDeferredStartupCompletionPolicy.shouldClearTask(
            isCancelled: false,
            storedProjectID: UUID(),
            taskProjectID: projectID,
            storedToken: token,
            taskToken: token
        ))

        XCTAssertFalse(ChatDeferredStartupCompletionPolicy.shouldClearTask(
            isCancelled: false,
            storedProjectID: projectID,
            taskProjectID: projectID,
            storedToken: UUID(),
            taskToken: token
        ))
    }

    func testDeferredStartupCompletionOnlyClearsMatchingCurrentTaskToken() {
        let projectID = UUID()
        let token = UUID()

        XCTAssertTrue(ChatDeferredStartupCompletionPolicy.shouldClearTask(
            isCancelled: false,
            storedProjectID: projectID,
            taskProjectID: projectID,
            storedToken: token,
            taskToken: token
        ))
    }

    private func codeAgentsUIImageBlock(path: String) -> String {
        """
        ```codeagents-ui
        { "type": "codeagents_ui", "version": 1, "elements": [
          { "type": "image", "id": "img1", "source": { "kind": "project_file", "path": "\(path)" } }
        ] }
        ```
        """
    }
}

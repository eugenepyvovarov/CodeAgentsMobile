import XCTest
@testable import CodeAgentsMobile

final class ChatDeferredStartupTests: XCTestCase {
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

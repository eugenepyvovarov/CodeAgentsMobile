import XCTest
@testable import CodeAgentsMobile

final class CodingAgentRuntimeSelectionTests: XCTestCase {
    func testRuntimeSelectionDefaultsToOpenCode() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedRuntime(), .openCode)
    }

    func testRuntimeSelectionPersistsOpenCode() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)

        store.setSelectedRuntime(.openCode)

        XCTAssertEqual(store.selectedRuntime(), .openCode)
        XCTAssertEqual(defaults.string(forKey: CodingAgentRuntimeSelectionStore.selectedRuntimeKey), "openCode")
    }

    func testRuntimeSelectionFallsBackWhenStoredValueIsUnknown() throws {
        let defaults = try makeDefaults()
        defaults.set("futureRuntime", forKey: CodingAgentRuntimeSelectionStore.selectedRuntimeKey)
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedRuntime(), .openCode)
    }

    func testRuntimeResolverUsesProjectRuntimeAndFallsBackNilToOpenCode() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)
        store.setSelectedRuntime(.openCode)
        let project = RemoteProject(name: "Test", serverId: UUID())

        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: store), .openCode)

        project.agentRuntimeRawValue = nil
        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: store), .openCode)

        project.selectedAgentRuntime = .claudeProxy
        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: store), .claudeProxy)
    }

    func testRuntimeResolverKeepsOpenCodeAndClaudeProxyProjectContextsDistinct() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)
        store.setSelectedRuntime(.openCode)

        let openCodeProject = RemoteProject(name: "OpenCode", serverId: UUID())
        openCodeProject.selectedAgentRuntime = .openCode

        let claudeProxyProject = RemoteProject(name: "Claude Proxy", serverId: UUID())
        claudeProxyProject.selectedAgentRuntime = .claudeProxy

        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: openCodeProject, selectionStore: store), .openCode)
        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: claudeProxyProject, selectionStore: store), .claudeProxy)
    }

    func testRuntimeDisplayNames() {
        XCTAssertEqual(CodingAgentRuntimeKind.claudeProxy.displayName, "Claude Proxy (Legacy)")
        XCTAssertEqual(CodingAgentRuntimeKind.openCode.displayName, "OpenCode")
        XCTAssertEqual(ConnectionPurpose.opencode.description, "OpenCode")
        XCTAssertEqual(ConnectionPurpose.agentDaemon.description, "Agent Daemon")
    }

    func testOpenCodeSessionStateMapping() {
        XCTAssertEqual(CodingAgentRuntimeSessionState.openCode(runtime: .openCode, rawStatus: nil).status, .idle)
        XCTAssertEqual(CodingAgentRuntimeSessionState.openCode(runtime: .openCode, rawStatus: "idle").status, .idle)
        XCTAssertEqual(CodingAgentRuntimeSessionState.openCode(runtime: .openCode, rawStatus: "busy").status, .busy)
        XCTAssertEqual(CodingAgentRuntimeSessionState.openCode(runtime: .openCode, rawStatus: "retrying").status, .retrying)
        XCTAssertEqual(CodingAgentRuntimeSessionState.openCode(runtime: .openCode, rawStatus: "retry").status, .retrying)
        XCTAssertEqual(CodingAgentRuntimeSessionState.openCode(runtime: .openCode, rawStatus: "future").status, .unknown("future"))
    }

    func testOpenCodeRuntimeDiagnosticsDescribeStreamContext() {
        let diagnostics = OpenCodeRuntimeDiagnostics(
            eventPath: "/event?directory=/workspace",
            directory: "/workspace",
            sessionID: "ses_fixture",
            modelID: "openai/gpt-4.1"
        )

        XCTAssertEqual(
            diagnostics.description,
            "eventPath=/event?directory=/workspace directory=/workspace sessionID=ses_fixture modelID=openai/gpt-4.1"
        )
        XCTAssertTrue(
            OpenCodeRuntimeError.streamAttachmentTimedOut(diagnostics)
                .localizedDescription
                .contains("sessionID=ses_fixture")
        )
        XCTAssertTrue(
            OpenCodeRuntimeError.streamAttachmentTimedOut(diagnostics)
                .localizedDescription
                .contains("event stream did not attach")
        )
    }

    func testOpenCodeStreamAttachDefaultsAllowSlowHostsAndOneRetry() {
        // Regression guard: a 5s attach window was too aggressive for real droplets and
        // produced "OpenCode event stream did not attach before sending the prompt".
        XCTAssertGreaterThanOrEqual(
            OpenCodeRuntimeService.defaultStreamAttachTimeoutNanoseconds,
            15_000_000_000
        )
        XCTAssertEqual(OpenCodeRuntimeService.defaultStreamAttachRetryCount, 1)
    }

    func testOpenCodeCompletedToolChunkDoesNotFinishRuntimeStream() {
        let completedToolChunk = MessageChunk(
            content: "skill completed",
            isComplete: true,
            isError: false,
            metadata: ["type": "opencode_tool"]
        )
        let finalAnswerChunk = MessageChunk(
            content: "Done",
            isComplete: true,
            isError: false,
            metadata: ["type": "result"]
        )

        XCTAssertFalse(OpenCodeStreamCompletionPolicy.shouldFinish(after: completedToolChunk))
        XCTAssertTrue(OpenCodeStreamCompletionPolicy.shouldFinish(after: finalAnswerChunk))
    }

    func testOpenCodeQuestionChunkDoesNotFinishRuntimeStream() {
        let questionChunk = MessageChunk(
            content: "Which setup?",
            isComplete: false,
            isError: false,
            metadata: ["type": "opencode_question"]
        )

        XCTAssertFalse(OpenCodeStreamCompletionPolicy.shouldFinish(after: questionChunk))
    }

    @MainActor
    func testRuntimeRegistryAlwaysResolvesToOpenCode() {
        let openCode = StubRuntime(kind: .openCode)
        let registry = CodingAgentRuntimeRegistry(openCodeRuntime: openCode)

        XCTAssertTrue(registry.runtime(for: .claudeProxy) === openCode)
        XCTAssertTrue(registry.runtime(for: .openCode) === openCode)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CodingAgentRuntimeSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class StubRuntime: CodingAgentRuntimeService {
    let kind: CodingAgentRuntimeKind

    init(kind: CodingAgentRuntimeKind) {
        self.kind = kind
    }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth {
        .unknown(runtime: kind)
    }

    func sendMessage(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID?,
        mcpServers: [MCPServer]
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func hydrateMessages(for project: RemoteProject) async throws -> [CodingAgentRuntimeHydratedMessage] {
        []
    }

    func abort(project: RemoteProject) async throws {}

    func replyToPermission(
        project: RemoteProject,
        permissionId: String,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope,
        message: String?
    ) async throws {}

    func reset(project: RemoteProject) async throws {}
}

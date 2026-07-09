import SwiftData
import XCTest
@testable import CodeAgentsMobile

final class RemoteProjectOpenCodeStateTests: XCTestCase {
    func testNewProjectDefaultsToOpenCodeAndEmptyOpenCodeState() {
        let project = makeProject()

        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.agentRuntimeRawValue, CodingAgentRuntimeKind.openCode.rawValue)
        XCTAssertNil(project.openCodeSessionId)
        XCTAssertTrue(project.openCodeHydrationState.messageIDs.isEmpty)
        XCTAssertTrue(project.openCodeHydrationState.partIDs.isEmpty)
        XCTAssertNil(project.lastSuccessfulRuntimeProviderRawValue)
    }

    func testLegacyProjectWithoutStoredRuntimeDefaultsToOpenCode() {
        let project = makeProject()
        project.agentRuntimeRawValue = nil

        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertNil(project.agentRuntimeRawValue)
    }

    func testRuntimeSelectionAndOpenCodeHydrationStateAreStored() {
        let project = makeProject()

        project.selectedAgentRuntime = .openCode
        project.openCodeSessionId = "ses_fixture"
        project.lastSuccessfulRuntimeProviderRawValue = "opencode:lmstudio/qwen"
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(
            messageIDs: ["msg_b", "msg_a"],
            partIDs: ["prt_b", "prt_a"]
        ))

        XCTAssertEqual(project.agentRuntimeRawValue, CodingAgentRuntimeKind.openCode.rawValue)
        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.openCodeSessionId, "ses_fixture")
        XCTAssertEqual(project.openCodeLastMessageIds, ["msg_a", "msg_b"])
        XCTAssertEqual(project.openCodeLastPartIds, ["prt_a", "prt_b"])
        XCTAssertEqual(project.openCodeHydrationState, OpenCodeHydrationState(
            messageIDs: ["msg_a", "msg_b"],
            partIDs: ["prt_a", "prt_b"]
        ))
    }

    func testUnknownStoredRuntimeFallsBackToOpenCode() {
        let project = makeProject()
        project.agentRuntimeRawValue = "futureRuntime"

        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.agentRuntimeRawValue, "futureRuntime")
    }

    func testResetOpenCodeRuntimeStatePreservesLegacyClaudeState() {
        let project = makeProject()
        let streamingMessageId = UUID()

        project.claudeSessionId = "claude_session"
        project.hasActiveClaudeStream = true
        project.activeStreamingMessageId = streamingMessageId
        project.proxyLastEventId = 42
        project.proxyConversationId = "proxy_conversation"
        project.proxyConversationGroupId = "proxy_group"
        project.proxyAgentId = "proxy_agent"
        project.nohupProcessId = "nohup_pid"
        project.outputFilePath = "/tmp/claude.out"
        project.lastOutputFilePosition = 900
        let legacyState = project.legacyClaudeRuntimeState

        project.selectedAgentRuntime = .openCode
        project.openCodeSessionId = "ses_fixture"
        project.lastSuccessfulRuntimeProviderRawValue = "opencode:provider/model"
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messageIDs: ["msg"], partIDs: ["prt"]))

        project.resetOpenCodeRuntimeState()

        XCTAssertNil(project.openCodeSessionId)
        XCTAssertTrue(project.openCodeLastMessageIds.isEmpty)
        XCTAssertTrue(project.openCodeLastPartIds.isEmpty)
        XCTAssertNil(project.lastSuccessfulRuntimeProviderRawValue)
        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.legacyClaudeRuntimeState, legacyState)
    }

    func testApplyingOpenCodePushSessionClearsHydrationAnchorsWhenSessionChanges() {
        let project = makeProject()
        project.selectedAgentRuntime = .openCode
        // Session ids must pass OpenCodeSessionID.sanitize (≥12-char token).
        project.openCodeSessionId = "ses_oldsession01"
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messageIDs: ["msg_old"], partIDs: ["prt_old"]))

        let didChange = project.applyOpenCodeSessionFromPush(" ses_newsession01 ")

        XCTAssertTrue(didChange)
        XCTAssertEqual(project.openCodeSessionId, "ses_newsession01")
        XCTAssertTrue(project.openCodeLastMessageIds.isEmpty)
        XCTAssertTrue(project.openCodeLastPartIds.isEmpty)
    }

    func testApplyingSameOpenCodePushSessionLeavesHydrationAnchorsIntact() {
        let project = makeProject()
        project.selectedAgentRuntime = .openCode
        project.openCodeSessionId = "ses_current00001"
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messageIDs: ["msg_current"], partIDs: ["prt_current"]))

        let didChange = project.applyOpenCodeSessionFromPush("ses_current00001")

        XCTAssertFalse(didChange)
        XCTAssertEqual(project.openCodeSessionId, "ses_current00001")
        XCTAssertEqual(project.openCodeHydrationState, OpenCodeHydrationState(
            messageIDs: ["msg_current"],
            partIDs: ["prt_current"]
        ))
    }

    @MainActor
    func testOpenCodeStatePersistsInSwiftDataContainer() throws {
        let schema = CodeAgentsSwiftDataSchema.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let project = makeProject()

        project.selectedAgentRuntime = .openCode
        project.openCodeSessionId = "ses_persisted"
        project.lastSuccessfulRuntimeProviderRawValue = "opencode:openai/gpt-fixture"
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(
            messageIDs: ["msg_persisted"],
            partIDs: ["prt_persisted"]
        ))

        container.mainContext.insert(project)
        try container.mainContext.save()

        let fetchedProjects = try container.mainContext.fetch(FetchDescriptor<RemoteProject>())
        let fetched = try XCTUnwrap(fetchedProjects.first)
        XCTAssertEqual(fetched.selectedAgentRuntime, .openCode)
        XCTAssertEqual(fetched.openCodeSessionId, "ses_persisted")
        XCTAssertEqual(fetched.lastSuccessfulRuntimeProviderRawValue, "opencode:openai/gpt-fixture")
        XCTAssertEqual(fetched.openCodeHydrationState, OpenCodeHydrationState(
            messageIDs: ["msg_persisted"],
            partIDs: ["prt_persisted"]
        ))
    }

    private func makeProject() -> RemoteProject {
        RemoteProject(name: "Test", serverId: UUID())
    }
}

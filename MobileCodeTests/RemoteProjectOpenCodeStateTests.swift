import SwiftData
import XCTest
@testable import CodeAgentsMobile

final class RemoteProjectOpenCodeStateTests: XCTestCase {
    func testNewProjectDefaultsToClaudeProxyAndEmptyOpenCodeState() {
        let project = makeProject()

        XCTAssertEqual(project.selectedAgentRuntime, .claudeProxy)
        XCTAssertNil(project.agentRuntimeRawValue)
        XCTAssertNil(project.openCodeSessionId)
        XCTAssertTrue(project.openCodeHydrationState.messageIDs.isEmpty)
        XCTAssertTrue(project.openCodeHydrationState.partIDs.isEmpty)
        XCTAssertNil(project.lastSuccessfulRuntimeProviderRawValue)
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

    func testUnknownStoredRuntimeFallsBackToClaudeProxy() {
        let project = makeProject()
        project.agentRuntimeRawValue = "futureRuntime"

        XCTAssertEqual(project.selectedAgentRuntime, .claudeProxy)
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

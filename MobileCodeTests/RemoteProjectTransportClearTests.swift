import XCTest
@testable import CodeAgentsMobile

@MainActor
final class RemoteProjectTransportClearTests: XCTestCase {
    func testClearLegacyClaudeTransportStateWipesProxyAndClaudeSessionFields() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.claudeSessionId = "ses_legacy"
        project.proxyConversationId = "conv-1"
        project.proxyConversationGroupId = "grp-1"
        project.proxyLastEventId = 42
        project.openCodeSessionId = "ses_open"

        project.clearLegacyClaudeTransportState()

        XCTAssertNil(project.claudeSessionId)
        XCTAssertNil(project.proxyConversationId)
        XCTAssertNil(project.proxyConversationGroupId)
        XCTAssertNil(project.proxyLastEventId)
        // OpenCode session is cleared separately via resetOpenCodeRuntimeState.
        XCTAssertEqual(project.openCodeSessionId, "ses_open")
    }

    func testSanitizedProxyConversationIdTrimsWhitespace() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyConversationId = "  abc  \n"
        XCTAssertEqual(project.sanitizedProxyConversationId, "abc")

        project.proxyConversationId = "   "
        XCTAssertNil(project.sanitizedProxyConversationId)
    }
}

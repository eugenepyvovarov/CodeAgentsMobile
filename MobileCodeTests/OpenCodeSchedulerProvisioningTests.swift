import XCTest
@testable import CodeAgentsMobile

@MainActor
final class OpenCodeSchedulerProvisioningTests: XCTestCase {
    func testManagedSchedulerServerIncludesProjectHeaders() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.path = "/home/codeagent/projects/demo"
        project.proxyAgentId = "agent-demo"
        project.proxyConversationId = "session-demo"

        let server = MCPTaskSchedulerProvisionService.shared.managedSchedulerServer(for: project)

        XCTAssertEqual(server.name, MCPServer.managedSchedulerServerName)
        XCTAssertEqual(server.url, "http://127.0.0.1:8787/mcp")
        XCTAssertEqual(server.headers?["x-codeagents-agent-id"], "agent-demo")
        XCTAssertEqual(server.headers?["x-codeagents-conversation-id"], "session-demo")
        XCTAssertEqual(server.headers?["x-codeagents-project-path"], "/home/codeagent/projects/demo")
    }
}

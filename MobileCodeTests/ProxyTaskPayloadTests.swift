import XCTest
@testable import CodeAgentsMobile

final class ProxyTaskPayloadTests: XCTestCase {
    @MainActor
    func testOpenCodeTaskPayloadTargetsActiveAgentChat() throws {
        let project = RemoteProject(name: "MobileCode", serverId: UUID(), basePath: "/workspace")
        project.proxyAgentId = "agent_fixture"
        project.selectedAgentRuntime = .openCode
        let task = AgentScheduledTask(
            projectId: project.id,
            title: "Daily check",
            prompt: "Summarize status",
            isEnabled: true,
            timeZoneId: "UTC",
            frequency: .daily,
            interval: 1,
            weekdayMask: WeekdayMask.mask(for: .friday),
            timeOfDayMinutes: 9 * 60
        )

        let body = try AgentTaskService.shared.buildPayload(
            for: task,
            project: project,
            conversationId: "proxy_conversation"
        )
        let payload = try decodePayload(body)

        XCTAssertEqual(payload["agent_id"] as? String, "agent_fixture")
        XCTAssertEqual(payload["conversation_id"] as? String, "proxy_conversation")
        XCTAssertEqual(payload["cwd"] as? String, "/workspace/MobileCode")
        XCTAssertNil(payload["open_code_session_id"])
        XCTAssertEqual(payload["open_code_session_target"] as? String, "active_agent_chat")
        XCTAssertEqual(payload["title"] as? String, "Daily check")

        let schedule = try XCTUnwrap(payload["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["frequency"] as? String, "daily")
        XCTAssertEqual(schedule["weekday_mask"] as? Int, WeekdayMask.mask(for: .friday))
        XCTAssertEqual(schedule["time_minutes"] as? Int, 9 * 60)
    }

    @MainActor
    func testClaudeTaskPayloadOmitsOpenCodeSessionTarget() throws {
        let project = RemoteProject(name: "MobileCode", serverId: UUID(), basePath: "/workspace")
        project.selectedAgentRuntime = .claudeProxy
        let task = AgentScheduledTask(projectId: project.id, prompt: "Run checks")

        let body = try AgentTaskService.shared.buildPayload(
            for: task,
            project: project,
            conversationId: "proxy_conversation"
        )
        let payload = try decodePayload(body)

        XCTAssertNil(payload["open_code_session_id"])
        XCTAssertNil(payload["open_code_session_target"])
    }

    private func decodePayload(_ body: String) throws -> [String: Any] {
        let data = try XCTUnwrap(body.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

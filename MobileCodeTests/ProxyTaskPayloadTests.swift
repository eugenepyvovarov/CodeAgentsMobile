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

    @MainActor
    func testOnceTaskPayloadIncludesNextRunAt() throws {
        let project = RemoteProject(name: "MobileCode", serverId: UUID(), basePath: "/workspace")
        project.proxyAgentId = "agent_fixture"
        project.selectedAgentRuntime = .openCode

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let runAt = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 0))!

        let task = AgentScheduledTask(
            projectId: project.id,
            title: "One shot",
            prompt: "Do this once",
            isEnabled: true,
            timeZoneId: "UTC",
            frequency: .once,
            interval: 1,
            dayOfMonth: 15,
            monthOfYear: 7,
            timeOfDayMinutes: 9 * 60,
            nextRunAt: runAt
        )

        let body = try AgentTaskService.shared.buildPayload(
            for: task,
            project: project,
            conversationId: "proxy_conversation"
        )
        let payload = try decodePayload(body)

        let schedule = try XCTUnwrap(payload["schedule"] as? [String: Any])
        XCTAssertEqual(schedule["frequency"] as? String, "once")
        XCTAssertEqual(schedule["time_minutes"] as? Int, 9 * 60)
        XCTAssertEqual(schedule["day_of_month"] as? Int, 15)
        XCTAssertEqual(schedule["month"] as? Int, 7)

        let nextRun = try XCTUnwrap(payload["next_run_at"] as? String)
        XCTAssertTrue(nextRun.contains("2026-07-15"), "next_run_at should include fire date: \(nextRun)")
    }

    private func decodePayload(_ body: String) throws -> [String: Any] {
        let data = try XCTUnwrap(body.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

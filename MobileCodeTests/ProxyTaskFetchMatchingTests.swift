import XCTest
@testable import CodeAgentsMobile

@MainActor
final class ProxyTaskFetchMatchingTests: XCTestCase {
    func testResolvedAgentIdPrefersProxyAgentId() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.proxyAgentId = "agent-demo"
        XCTAssertEqual(ProxyTaskService.resolvedAgentId(for: project), "agent-demo")
    }

    func testResolvedAgentIdLowercasesProxyAgentId() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.proxyAgentId = "A027C2D3-79AA-416D-8349-7DDFEE4E9A46"
        XCTAssertEqual(
            ProxyTaskService.resolvedAgentId(for: project),
            "a027c2d3-79aa-416d-8349-7ddfee4e9a46"
        )
    }

    func testResolvedAgentIdFallsBackToLowercasedProjectUUID() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.proxyAgentId = nil
        XCTAssertEqual(
            ProxyTaskService.resolvedAgentId(for: project),
            project.id.uuidString.lowercased()
        )
    }

    func testTasksMatchingRecoversCaseMismatchedAgentId() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.path = "/home/codeagent/projects/demo"
        project.proxyAgentId = "Agent-Demo"

        let remote = ProxyTaskRecord(
            id: "task_1",
            title: "Daily morning check-in",
            prompt: "Ask me how I am doing today.",
            isEnabled: true,
            timeZoneId: "Europe/Berlin",
            schedule: ProxyTaskSchedule(
                frequency: .daily,
                interval: 1,
                weekdayMask: 1,
                monthlyMode: .dayOfMonth,
                dayOfMonth: 1,
                ordinalWeek: .first,
                ordinalWeekday: .monday,
                monthOfYear: 1,
                timeOfDayMinutes: 480
            ),
            nextRunAt: nil,
            lastRunAt: nil,
            lastError: nil,
            agentId: "agent-demo",
            cwd: "/other/path"
        )

        let matched = ProxyTaskService.tasksMatching(
            project: project,
            preferredAgentId: "Agent-Demo",
            from: [remote]
        )
        XCTAssertEqual(matched.map(\.id), ["task_1"])
    }

    func testTasksMatchingRecoversByProjectCwdWhenAgentIdDrifted() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.path = "/home/codeagent/projects/demo"
        project.proxyAgentId = "current-agent"

        let remote = ProxyTaskRecord(
            id: "task_2",
            title: "Daily morning check-in",
            prompt: "Ask me how I am doing today.",
            isEnabled: true,
            timeZoneId: "UTC",
            schedule: nil,
            nextRunAt: nil,
            lastRunAt: nil,
            lastError: nil,
            agentId: "stale-pre-identity-uuid",
            cwd: "/root/projects/demo/"
        )

        let matched = ProxyTaskService.tasksMatching(
            project: project,
            preferredAgentId: "current-agent",
            from: [remote]
        )
        XCTAssertEqual(matched.map(\.id), ["task_2"])
    }

    func testTasksMatchingIgnoresUnrelatedProjects() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.path = "/home/codeagent/projects/demo"
        project.proxyAgentId = "current-agent"

        let remote = ProxyTaskRecord(
            id: "task_3",
            title: "Other",
            prompt: "Nope",
            isEnabled: true,
            timeZoneId: "UTC",
            schedule: nil,
            nextRunAt: nil,
            lastRunAt: nil,
            lastError: nil,
            agentId: "other-agent",
            cwd: "/home/codeagent/projects/other"
        )

        let matched = ProxyTaskService.tasksMatching(
            project: project,
            preferredAgentId: "current-agent",
            from: [remote]
        )
        XCTAssertTrue(matched.isEmpty)
    }
}

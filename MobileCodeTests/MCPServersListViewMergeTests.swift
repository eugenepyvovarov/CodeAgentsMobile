import XCTest
@testable import CodeAgentsMobile

final class MCPServersListViewMergeTests: XCTestCase {

    func testMerge_EmptyHostAndProject_ReturnsEmpty() {
        let merged = MergedMCPServer.merge(projectServers: [], hostServers: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMerge_ProjectOnlyServer_GetsProjectBadge() {
        let projectServer = MCPServer(
            name: "project-only",
            command: "node",
            args: ["index.js"],
            env: nil,
            url: nil,
            headers: nil
        )

        let merged = MergedMCPServer.merge(projectServers: [projectServer], hostServers: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.server.name, "project-only")
        XCTAssertEqual(merged.first?.source, .project)
    }

    func testMerge_HostOnlyServer_GetsHostBadge() {
        let hostServer = MCPServer(
            name: "host-only",
            command: "npx",
            args: ["-y", "fetch-mcp"],
            env: nil,
            url: nil,
            headers: nil
        )

        let merged = MergedMCPServer.merge(projectServers: [], hostServers: [hostServer])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.server.name, "host-only")
        XCTAssertEqual(merged.first?.source, .host)
    }

    func testMerge_ProjectEntryShadowsHost_GetsProjectOverrideBadge() {
        let name = "shared-server"
        let hostServer = MCPServer(
            name: name,
            command: "npx",
            args: ["-y", "fetch-mcp"],
            env: ["KEY": "host-value"],
            url: nil,
            headers: nil
        )
        let projectServer = MCPServer(
            name: name,
            command: "npx",
            args: ["-y", "fetch-mcp"],
            env: ["KEY": "project-value"],
            url: nil,
            headers: nil
        )

        let merged = MergedMCPServer.merge(
            projectServers: [projectServer],
            hostServers: [hostServer]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.server.name, name)
        // Project entry wins; the row is tagged as an override of the host entry.
        XCTAssertEqual(merged.first?.source, .projectOverride)
        XCTAssertEqual(merged.first?.server.env, ["KEY": "project-value"])
    }

    func testMerge_DistinctHostAndProjectNames_AllPresentAndSorted() {
        let hostServers = [
            MCPServer(name: "zeta", command: "a", args: nil, env: nil, url: nil, headers: nil),
            MCPServer(name: "alpha", command: "b", args: nil, env: nil, url: nil, headers: nil),
        ]
        let projectServers = [
            MCPServer(name: "mid", command: "c", args: nil, env: nil, url: nil, headers: nil),
            MCPServer(name: "beta", command: "d", args: nil, env: nil, url: nil, headers: nil),
        ]

        let merged = MergedMCPServer.merge(projectServers: projectServers, hostServers: hostServers)

        XCTAssertEqual(merged.map(\.server.name), ["alpha", "beta", "mid", "zeta"])
        let sourcesByName = Dictionary(uniqueKeysWithValues: merged.map { ($0.server.name, $0.source) })
        XCTAssertEqual(sourcesByName["alpha"], .host)
        XCTAssertEqual(sourcesByName["zeta"], .host)
        XCTAssertEqual(sourcesByName["beta"], .project)
        XCTAssertEqual(sourcesByName["mid"], .project)
    }

    func testMerge_ProjectOverrideTakesPrecedenceOverHost_OnlyOneRow() {
        // Same name in both — exactly one merged row, sourced from the project entry.
        let hostServer = MCPServer(name: "sentry", command: "npx", args: ["sentry-mcp"], env: nil, url: nil, headers: nil)
        let projectServer = MCPServer(name: "sentry", command: "npx", args: ["sentry-mcp"], env: ["DISABLED": "1"], url: nil, headers: nil)

        let merged = MergedMCPServer.merge(projectServers: [projectServer], hostServers: [hostServer])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .projectOverride)
        XCTAssertEqual(merged.first?.server.env, ["DISABLED": "1"])
    }

    func testBadgeText_DistinguishesSources() {
        XCTAssertEqual(MergedMCPServer.Source.host.badgeText, "Host")
        XCTAssertEqual(MergedMCPServer.Source.project.badgeText, "Project")
        XCTAssertEqual(MergedMCPServer.Source.projectOverride.badgeText, "Project (override)")
    }

    func testSelectionLoadRequestRejectsStaleAndCancelledResults() {
        let hostA = UUID()
        let hostB = UUID()
        let requestA = MCPSelectionLoadRequest(selectionID: hostA)
        let requestB = MCPSelectionLoadRequest(selectionID: hostB)

        XCTAssertFalse(
            requestA.canApply(activeRequest: requestB, selectedID: hostB, isCancelled: false)
        )
        XCTAssertTrue(
            requestB.canApply(activeRequest: requestB, selectedID: hostB, isCancelled: false)
        )
        XCTAssertFalse(
            requestB.canApply(activeRequest: requestB, selectedID: hostB, isCancelled: true)
        )
        XCTAssertFalse(
            requestB.canApply(activeRequest: nil, selectedID: nil, isCancelled: false)
        )
        XCTAssertFalse(
            MCPSelectionLoadRequest.canPresent(loadedSelectionID: hostA, selectedID: hostB)
        )
        XCTAssertTrue(
            MCPSelectionLoadRequest.canPresent(loadedSelectionID: hostB, selectedID: hostB)
        )
        XCTAssertFalse(
            MCPSelectionLoadRequest.canPresent(loadedSelectionID: nil, selectedID: nil)
        )
    }

    func testProjectOverrideEditModeUsesSuppliedDetailsAndProjectScope() {
        let mode = MCPServerEditMode.createProjectOverride

        XCTAssertFalse(mode.shouldLoadDetails)
        XCTAssertEqual(mode.scopeHint, .project)
    }

    func testExistingEditModeLoadsRequestedScope() {
        let mode = MCPServerEditMode.existing(scopeHint: .global)

        XCTAssertTrue(mode.shouldLoadDetails)
        XCTAssertEqual(mode.scopeHint, .global)
    }

    func testManagedProvisioningAssessmentUsesOnlyProjectServers() {
        let hostOnlyManagedServers = [
            MCPServer(
                name: MCPServer.managedSchedulerServerName,
                command: nil,
                args: nil,
                env: nil,
                url: "http://host.invalid/mcp",
                headers: nil
            ),
            MCPServer(
                name: MCPServer.managedAvatarServerName,
                command: "python3",
                args: ["host-avatar.py"],
                env: nil,
                url: nil,
                headers: nil
            )
        ]

        // Host entries are deliberately not input: only project-scope entries
        // can satisfy project-specific managed definitions.
        XCTAssertEqual(hostOnlyManagedServers.count, 2)
        let assessment = ManagedMCPProvisioningAssessment(projectServers: [])
        XCTAssertFalse(assessment.hasScheduler)
        XCTAssertFalse(assessment.hasAvatar)
        XCTAssertFalse(assessment.avatarNeedsRepair)
    }

    func testManagedProvisioningAssessmentRepairsDisconnectedProjectAvatar() {
        var avatar = MCPServer(
            name: MCPServer.managedAvatarServerName,
            command: "python3",
            args: ["project-avatar.py"],
            env: nil,
            url: nil,
            headers: nil
        )
        avatar.status = .disconnected

        let assessment = ManagedMCPProvisioningAssessment(projectServers: [avatar])

        XCTAssertTrue(assessment.hasAvatar)
        XCTAssertTrue(assessment.avatarNeedsRepair)
    }
}

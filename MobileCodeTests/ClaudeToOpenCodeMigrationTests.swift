import XCTest
@testable import CodeAgentsMobile

final class ClaudeToOpenCodeMigrationTests: XCTestCase {
    // MARK: - Project migration fields / detection

    func testNewProjectDefaultsMigrationVersionAndOpenCodeRuntime() {
        let project = makeProject()

        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.openCodeMigrationVersion, ClaudeToOpenCodeMigration.currentVersion)
        XCTAssertFalse(project.needsOpenCodeMigration)
        XCTAssertNil(project.openCodeMigrationLastError)
    }

    func testLegacyNilRuntimeNeedsMigrationAndFallsBackToOpenCode() {
        let project = makeProject()
        project.agentRuntimeRawValue = nil
        project.openCodeMigrationVersion = nil

        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertTrue(project.needsOpenCodeMigration)
    }

    func testClaudeProxyRuntimeNeedsMigration() {
        let project = makeProject()
        project.selectedAgentRuntime = .claudeProxy
        project.openCodeMigrationVersion = nil

        XCTAssertTrue(project.needsOpenCodeMigration)
        XCTAssertEqual(project.selectedAgentRuntime, .claudeProxy)
    }

    func testMigratedClaudeProxyDoesNotNeedMigrationAgain() {
        let project = makeProject()
        project.selectedAgentRuntime = .claudeProxy
        project.openCodeMigrationVersion = ClaudeToOpenCodeMigration.currentVersion

        XCTAssertFalse(project.needsOpenCodeMigration)
    }

    func testUnknownRuntimeNeedsMigrationAndResolvesToOpenCode() {
        let project = makeProject()
        project.agentRuntimeRawValue = "futureRuntime"
        project.openCodeMigrationVersion = nil

        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertTrue(project.needsOpenCodeMigration)
        XCTAssertEqual(
            CodingAgentRuntimeResolver.runtimeKind(for: project),
            .openCode
        )
    }

    func testClearClaudeProxyTransportStatePreservesAgentIdentity() {
        let project = makeProject()
        let streamingId = UUID()
        project.claudeSessionId = "claude_session"
        project.proxyConversationId = "conv"
        project.proxyConversationGroupId = "group"
        project.proxyLastEventId = 9
        project.proxyAgentId = "agent-keep"
        project.activeStreamingMessageId = streamingId
        project.hasActiveClaudeStream = true

        project.clearClaudeProxyTransportState(clearActiveStreamingMessage: true)

        XCTAssertNil(project.claudeSessionId)
        XCTAssertNil(project.proxyConversationId)
        XCTAssertNil(project.proxyConversationGroupId)
        XCTAssertNil(project.proxyLastEventId)
        XCTAssertNil(project.activeStreamingMessageId)
        XCTAssertFalse(project.hasActiveClaudeStream)
        XCTAssertEqual(project.proxyAgentId, "agent-keep")
    }

    func testClearClaudeProxyTransportStateCanPreserveStreamingMessageId() {
        let project = makeProject()
        let streamingId = UUID()
        project.activeStreamingMessageId = streamingId
        project.proxyConversationId = "conv"

        project.clearClaudeProxyTransportState(clearActiveStreamingMessage: false)

        XCTAssertNil(project.proxyConversationId)
        XCTAssertEqual(project.activeStreamingMessageId, streamingId)
    }

    // MARK: - Path D pure merge

    func testServersFromClaudeMCPJSONParsesLocalAndRemote() throws {
        let json = try loadFixture("claude-mcp.json")
        let servers = try MCPClaudeToOpenCodeMigrator.servers(fromClaudeMCPJSON: json)
        let byName = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0) })

        XCTAssertEqual(byName["filesystem"]?.command, "npx")
        XCTAssertEqual(byName["filesystem"]?.args?.first, "-y")
        XCTAssertEqual(byName["filesystem"]?.env?["ROOT"], "/workspace")
        XCTAssertEqual(byName["remote-api"]?.url, "https://example.com/mcp")
        XCTAssertEqual(byName["remote-api"]?.headers?["Authorization"], "Bearer token")
        XCTAssertTrue(byName.keys.contains("codeagents-scheduled-tasks"))
    }

    func testMergeImportsImportableSkipsManagedExistingAndUnconvertible() throws {
        let claudeJSON = try loadFixture("claude-mcp.json")
        let openCodeJSONC = try loadFixture("opencode-with-mcp.jsonc")
        let claudeServers = try MCPClaudeToOpenCodeMigrator.servers(fromClaudeMCPJSON: claudeJSON)
        var document = try OpenCodeMCPConfigDocument(jsonString: openCodeJSONC)

        // Pretend filesystem already exists under a different path — use existing-local only.
        let result = MCPClaudeToOpenCodeMigrator.merge(servers: claudeServers, into: document)
        document = result.document
        let report = result.report

        XCTAssertTrue(report.imported.contains("filesystem"))
        XCTAssertTrue(report.imported.contains("remote-api"))
        XCTAssertTrue(report.skippedManaged.contains(MCPServer.managedSchedulerServerName))
        XCTAssertTrue(report.failedNames.contains("broken"))
        XCTAssertFalse(report.imported.contains(MCPServer.managedSchedulerServerName))

        // Non-MCP keys preserved
        XCTAssertEqual(document.root["formatter"] as? Bool, false)
        XCTAssertEqual(document.selectedModelID, "anthropic/claude-sonnet-4")
        XCTAssertEqual(document.server(named: "existing-local")?.command, "echo")
        XCTAssertEqual(document.server(named: "filesystem")?.command, "npx")
        XCTAssertEqual(document.server(named: "remote-api")?.url, "https://example.com/mcp")
    }

    func testMergeIsIdempotentOnSecondRun() throws {
        let claudeJSON = try loadFixture("claude-mcp.json")
        let claudeServers = try MCPClaudeToOpenCodeMigrator.servers(fromClaudeMCPJSON: claudeJSON)
        var document = OpenCodeMCPConfigDocument()

        let first = MCPClaudeToOpenCodeMigrator.merge(servers: claudeServers, into: document)
        document = first.document
        let second = MCPClaudeToOpenCodeMigrator.merge(servers: claudeServers, into: document)

        XCTAssertFalse(first.report.imported.isEmpty)
        XCTAssertTrue(second.report.imported.isEmpty)
        XCTAssertEqual(
            Set(second.report.skippedExisting),
            Set(first.report.imported)
        )
    }

    func testNormalizedForOpenCodeImportConvertsHttpCommandToRemoteURL() {
        let server = MCPServer(
            name: "remote-cli",
            command: "http",
            args: ["https://mcp.example.com"],
            env: nil,
            url: nil,
            headers: ["X-Key": "1"]
        )
        let normalized = server.normalizedForOpenCodeImport()

        XCTAssertEqual(normalized.url, "https://mcp.example.com")
        XCTAssertNil(normalized.command)
        XCTAssertTrue(MCPClaudeToOpenCodeMigrator.isImportable(server))
    }

    func testIsImportableRejectsManagedAndEmptyServers() {
        let managed = MCPServer.managedSchedulerServer
        let empty = MCPServer(name: "empty", command: nil, args: nil, env: nil, url: nil, headers: nil)

        XCTAssertFalse(MCPClaudeToOpenCodeMigrator.isImportable(managed))
        XCTAssertFalse(MCPClaudeToOpenCodeMigrator.isImportable(empty))
    }

    func testRulesAutoCopyPolicyMatchesLayoutHelper() {
        XCTAssertTrue(
            AgentProjectFileLayout.shouldAutoCopyLegacyRulesToAgents(
                hasAgents: false,
                hasLegacyClaudeDirectory: true,
                hasLegacyClaudeRoot: false
            )
        )
        XCTAssertEqual(
            AgentProjectFileLayout.preferredLegacyRulesRelativePath(
                hasLegacyClaudeDirectory: true,
                hasLegacyClaudeRoot: true
            ),
            AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath
        )
    }

    @MainActor
    func testMigrateIfNeededNoOpsWhenAlreadyMigrated() async {
        let project = makeProject()
        project.selectedAgentRuntime = .openCode
        project.openCodeMigrationVersion = ClaudeToOpenCodeMigration.currentVersion

        let service = ClaudeToOpenCodeMigrationService()
        let report = await service.migrateIfNeeded(project: project, modelContext: nil)

        XCTAssertFalse(report.didMigrate)
        XCTAssertTrue(report.alreadyMigrated)
        XCTAssertEqual(project.openCodeMigrationVersion, ClaudeToOpenCodeMigration.currentVersion)
    }

    @MainActor
    func testMigrateIfNeededPromotesRuntimeAndClearsProxyTransportWithoutNetworkWhenMCPFailsSoft() async {
        // Without SSH, MCP/session/scheduler steps soft-fail but version still stamps.
        let project = makeProject()
        project.agentRuntimeRawValue = CodingAgentRuntimeKind.claudeProxy.rawValue
        project.openCodeMigrationVersion = nil
        project.claudeSessionId = "ses_claude"
        project.proxyConversationId = "conv"
        project.proxyConversationGroupId = "group"
        project.proxyLastEventId = 12
        project.proxyAgentId = "agent-keep"
        project.activeStreamingMessageId = UUID()

        let service = ClaudeToOpenCodeMigrationService()
        let report = await service.migrateIfNeeded(project: project, modelContext: nil)

        XCTAssertTrue(report.didMigrate)
        XCTAssertTrue(report.promotedRuntime)
        XCTAssertTrue(report.clearedProxyTransport)
        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.openCodeMigrationVersion, ClaudeToOpenCodeMigration.currentVersion)
        XCTAssertNil(project.claudeSessionId)
        XCTAssertNil(project.proxyConversationId)
        XCTAssertNil(project.proxyLastEventId)
        XCTAssertNil(project.activeStreamingMessageId)
        XCTAssertEqual(project.proxyAgentId, "agent-keep")
        // Second call is a no-op
        let second = await service.migrateIfNeeded(project: project, modelContext: nil)
        XCTAssertFalse(second.didMigrate)
        XCTAssertTrue(second.alreadyMigrated)
    }

    // MARK: - Helpers

    private func makeProject() -> RemoteProject {
        RemoteProject(name: "Test", serverId: UUID())
    }

    private func loadFixture(_ name: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testsDir.appendingPathComponent("Fixtures/MCP/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

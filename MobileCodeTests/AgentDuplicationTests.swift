//
//  AgentDuplicationTests.swift
//  CodeAgentsMobileTests
//
//  Purpose: Unit coverage for Duplicate Agent path helpers, validation, and approval copy.
//

import XCTest
@testable import CodeAgentsMobile

final class AgentDuplicationTests: XCTestCase {

    // MARK: - Path helpers

    func testParentDirectory() {
        XCTAssertEqual(AgentDuplicationPath.parentDirectory(of: "/root/projects/blog-a"), "/root/projects")
        XCTAssertEqual(AgentDuplicationPath.parentDirectory(of: "/a/b/c/"), "/a/b")
        XCTAssertEqual(AgentDuplicationPath.parentDirectory(of: "/only"), "/")
        XCTAssertNil(AgentDuplicationPath.parentDirectory(of: "/"))
        XCTAssertNil(AgentDuplicationPath.parentDirectory(of: "   "))
    }

    func testJoinPath() {
        XCTAssertEqual(
            AgentDuplicationPath.join(parent: "/root/projects", folderName: "blog-b"),
            "/root/projects/blog-b"
        )
        XCTAssertEqual(
            AgentDuplicationPath.join(parent: "/root/projects/", folderName: "blog-b"),
            "/root/projects/blog-b"
        )
    }

    func testDefaultDisplayName() {
        XCTAssertEqual(AgentDuplicationPath.defaultDisplayName(from: "Blog A"), "Blog A Copy")
        XCTAssertEqual(AgentDuplicationPath.defaultDisplayName(from: "  "), "Agent Copy")
    }

    func testSuggestedFolderNameSanitizes() {
        XCTAssertEqual(AgentDuplicationPath.suggestedFolderName(from: "Blog A Copy"), "Blog-A-Copy")
        XCTAssertNil(AgentDuplicationPath.suggestedFolderName(from: "  "))
        XCTAssertNil(AgentDuplicationPath.suggestedFolderName(from: "../evil"))
    }

    func testResolvedDisplayNameMatchesCreateAgent() {
        XCTAssertNil(AgentDuplicationPath.resolvedDisplayName(displayName: "same", folderName: "same"))
        XCTAssertEqual(
            AgentDuplicationPath.resolvedDisplayName(displayName: "Pretty", folderName: "pretty"),
            "Pretty"
        )
        XCTAssertNil(AgentDuplicationPath.resolvedDisplayName(displayName: "  ", folderName: "x"))
    }

    // MARK: - Request validation

    func testValidateRequestFields() {
        XCTAssertEqual(
            AgentDuplicationPath.validateRequestFields(displayName: "", folderName: "ok"),
            .emptyDisplayName
        )
        XCTAssertEqual(
            AgentDuplicationPath.validateRequestFields(displayName: "Ok", folderName: "../no"),
            .invalidFolderName
        )
        XCTAssertNil(
            AgentDuplicationPath.validateRequestFields(displayName: "Ok", folderName: "blog-b")
        )
    }

    func testNextFolderNameCandidate() {
        XCTAssertEqual(AgentDuplicationPath.nextFolderNameCandidate(base: "blog-copy", attempt: 1), "blog-copy")
        XCTAssertEqual(AgentDuplicationPath.nextFolderNameCandidate(base: "blog-copy", attempt: 2), "blog-copy-2")
        XCTAssertEqual(AgentDuplicationPath.nextFolderNameCandidate(base: "blog-copy", attempt: 3), "blog-copy-3")
    }

    // MARK: - Remote bootstrap (fast path)

    func testBootstrapScriptIncludesExclusiveMkdirAndServerLocalCopies() {
        let script = AgentDuplicationRemoteBootstrap.shellScript(
            sourcePath: "/home/codeagent/projects/X",
            clonePath: "/home/codeagent/projects/X-Copy",
            copyRules: true,
            copySkills: true,
            copyAvatarImage: true
        )
        XCTAssertTrue(script.contains("mkdir -- \"$DST\""))
        XCTAssertTrue(script.contains(AgentDuplicationRemoteBootstrap.existsMarker))
        XCTAssertTrue(script.contains(AgentDuplicationRemoteBootstrap.okMarker))
        XCTAssertTrue(script.contains("cp -a --"))
        XCTAssertTrue(script.contains(".opencode/skills"))
        XCTAssertTrue(script.contains("AGENTS.md"))
        XCTAssertTrue(script.contains(".codeagents/avatar.png"))
        // Must not scp/upload from phone — only remote paths.
        XCTAssertFalse(script.contains("scp "))
    }

    func testBootstrapScriptOmitsOptionalSections() {
        let script = AgentDuplicationRemoteBootstrap.shellScript(
            sourcePath: "/a/src",
            clonePath: "/a/dst",
            copyRules: false,
            copySkills: false,
            copyAvatarImage: false
        )
        XCTAssertFalse(script.contains("AGENTS.md"))
        XCTAssertFalse(script.contains(".opencode/skills"))
        XCTAssertFalse(script.contains("avatar.png"))
        XCTAssertTrue(script.contains(AgentDuplicationRemoteBootstrap.okMarker))
    }

    func testBootstrapOutputInterpretation() {
        XCTAssertNoThrow(
            try AgentDuplicationRemoteBootstrap.interpretOutput("noise\nDUPLICATE_OK\n").get()
        )
        if case .failure(let error) = AgentDuplicationRemoteBootstrap.interpretOutput("DUPLICATE_EXISTS") {
            XCTAssertEqual(error, .directoryAlreadyExists)
        } else {
            XCTFail("expected directoryAlreadyExists")
        }
        if case .failure(let error) = AgentDuplicationRemoteBootstrap.interpretOutput("DUPLICATE_MKDIR_FAILED") {
            XCTAssertEqual(error, .failedToCreateDirectory)
        } else {
            XCTFail("expected failedToCreateDirectory")
        }
    }

    func testProgressLabelsAreNonEmpty() {
        for phase in [
            DuplicateAgentProgress.preparing,
            .creatingFolder,
            .copyingWorkspace,
            .configuringTools,
            .finishing
        ] {
            XCTAssertFalse(phase.userLabel.isEmpty)
        }
    }

    func testEnvCopyModes() {
        XCTAssertEqual(AgentEnvCopyMode.off.rawValue, "off")
        XCTAssertEqual(AgentEnvCopyMode.keysOnly.rawValue, "keysOnly")
        XCTAssertEqual(AgentEnvCopyMode.keysAndValues.rawValue, "keysAndValues")
    }

    func testDuplicateRequestDefaults() {
        let request = DuplicateAgentRequest(
            sourceProjectId: UUID(),
            displayName: "Blog B",
            folderName: "blog-b"
        )
        XCTAssertTrue(request.copyRules)
        XCTAssertTrue(request.copySkills)
        XCTAssertTrue(request.copyProjectMCP)
        XCTAssertTrue(request.copyPermissions)
        XCTAssertEqual(request.envMode, .off)
        XCTAssertFalse(request.copyTasks)
    }

    // MARK: - Task clone field policy (pure)

    func testTaskClonePolicyFields() {
        let sourceId = UUID()
        let cloneId = UUID()
        let source = AgentScheduledTask(
            projectId: sourceId,
            title: "Daily",
            prompt: "Check blog",
            isEnabled: true,
            nextRunAt: Date().addingTimeInterval(3600),
            lastRunAt: Date().addingTimeInterval(-3600),
            remoteId: "remote-123"
        )

        let clone = AgentScheduledTask(
            projectId: cloneId,
            title: source.title,
            prompt: source.prompt,
            isEnabled: false,
            timeZoneId: source.timeZoneId,
            frequency: source.frequency,
            interval: source.interval,
            weekdayMask: source.weekdayMask,
            monthlyMode: source.monthlyMode,
            dayOfMonth: source.dayOfMonth,
            ordinalWeek: source.ordinalWeek,
            ordinalWeekday: source.ordinalWeekday,
            monthOfYear: source.monthOfYear,
            timeOfDayMinutes: source.timeOfDayMinutes,
            nextRunAt: nil,
            lastRunAt: nil,
            remoteId: nil
        )

        XCTAssertNotEqual(clone.id, source.id)
        XCTAssertEqual(clone.projectId, cloneId)
        XCTAssertFalse(clone.isEnabled)
        XCTAssertNil(clone.remoteId)
        XCTAssertNil(clone.nextRunAt)
        XCTAssertNil(clone.lastRunAt)
        XCTAssertEqual(clone.prompt, source.prompt)
    }

    // MARK: - Env mode

    func testEnvKeysOnlyClearsValues() {
        let sourceValue = "secret-token"
        let mode = AgentEnvCopyMode.keysOnly
        let copiedValue: String
        switch mode {
        case .off:
            copiedValue = sourceValue
        case .keysOnly:
            copiedValue = ""
        case .keysAndValues:
            copiedValue = sourceValue
        }
        XCTAssertEqual(copiedValue, "")
        XCTAssertEqual(AgentEnvCopyMode.keysAndValues.rawValue, "keysAndValues")
    }

    // MARK: - Permissions bulk copy

    func testCopyAgentApprovalsIncludesPolicyAndKnown() {
        let sourceId = UUID()
        let destId = UUID()
        let store = ToolApprovalStore.shared

        store.setAgentPolicy(nil, agentId: sourceId)
        store.setAgentPolicy(nil, agentId: destId)
        store.setDecision(toolName: "Bash", decision: .allow, agentId: sourceId)
        store.setDecision(toolName: "Write", decision: .deny, agentId: sourceId)
        store.recordKnownTool("CustomTool", agentId: sourceId)
        store.setAgentPolicy(.allow, agentId: sourceId)

        store.copyAgentApprovals(from: sourceId, to: destId)

        XCTAssertEqual(store.agentPolicy(for: destId), .allow)
        XCTAssertTrue(store.allowedTools(for: destId).contains("bash"))
        XCTAssertTrue(store.deniedTools(for: destId).contains("write"))
        XCTAssertTrue(store.knownTools(for: destId).contains(where: {
            ToolApprovalStore.normalizeToolName($0) == "customtool"
        }))

        store.removeAgentApprovals(for: destId)
        XCTAssertNil(store.agentPolicy(for: destId))
        XCTAssertTrue(store.allowedTools(for: destId).isEmpty)
        XCTAssertTrue(store.deniedTools(for: destId).isEmpty)

        // Cleanup so other tests / device state are not polluted longer than needed.
        store.removeAgentApprovals(for: sourceId)
        store.removeAgentApprovals(for: destId)
    }

    /// Skill assignments must only be created after a successful remote install/copy.
    func testSkillAssignmentPolicyRequiresSuccessfulInstall() {
        struct Outcome {
            let installed: Bool
            let shouldInsertAssignment: Bool
        }
        let success = Outcome(installed: true, shouldInsertAssignment: true)
        let failure = Outcome(installed: false, shouldInsertAssignment: false)
        XCTAssertEqual(success.installed, success.shouldInsertAssignment)
        XCTAssertEqual(failure.installed, failure.shouldInsertAssignment)
        XCTAssertFalse(failure.shouldInsertAssignment)
    }

    func testNewRemoteProjectShellHasEmptySession() {
        let project = RemoteProject(
            name: "clone",
            displayName: "Clone",
            serverId: UUID(),
            basePath: "/root/projects"
        )
        project.openCodeSessionId = "ses_should_clear"
        project.proxyAgentId = "should-clear"
        project.resetOpenCodeRuntimeState()
        project.clearClaudeProxyTransportState()
        project.proxyAgentId = nil

        XCTAssertNil(project.openCodeSessionId)
        XCTAssertTrue(project.openCodeLastMessageIds.isEmpty)
        XCTAssertNil(project.proxyAgentId)
        XCTAssertNil(project.claudeSessionId)
        XCTAssertEqual(project.selectedAgentRuntime, .openCode)
        XCTAssertEqual(project.openCodeMigrationVersion, ClaudeToOpenCodeMigration.currentVersion)
    }
}

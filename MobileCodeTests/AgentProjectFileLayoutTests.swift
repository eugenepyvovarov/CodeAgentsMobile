import XCTest
@testable import CodeAgentsMobile

final class AgentProjectFileLayoutTests: XCTestCase {
    func testRulesSelectionPrefersAgentsFile() {
        let selection = AgentProjectFileLayout.selectRulesFile(
            hasAgents: true,
            hasLegacyClaudeDirectory: true,
            hasLegacyClaudeRoot: true
        )

        XCTAssertEqual(selection.kind, .agents)
        XCTAssertEqual(selection.readRelativePath, "AGENTS.md")
        XCTAssertEqual(selection.writeRelativePath, "AGENTS.md")
        XCTAssertFalse(selection.shouldOfferMigration)
    }

    func testRulesSelectionOffersMigrationFromClaudeDirectoryRules() {
        let selection = AgentProjectFileLayout.selectRulesFile(
            hasAgents: false,
            hasLegacyClaudeDirectory: true,
            hasLegacyClaudeRoot: false
        )

        XCTAssertEqual(selection.kind, .legacyClaudeDirectory)
        XCTAssertEqual(selection.readRelativePath, ".claude/CLAUDE.md")
        XCTAssertEqual(selection.writeRelativePath, "AGENTS.md")
        XCTAssertTrue(selection.shouldOfferMigration)
    }

    func testRulesSelectionSupportsRootClaudeRulesFallback() {
        let selection = AgentProjectFileLayout.selectRulesFile(
            hasAgents: false,
            hasLegacyClaudeDirectory: false,
            hasLegacyClaudeRoot: true
        )

        XCTAssertEqual(selection.kind, .legacyClaudeRoot)
        XCTAssertEqual(selection.readRelativePath, "CLAUDE.md")
        XCTAssertEqual(selection.writeRelativePath, "AGENTS.md")
        XCTAssertTrue(selection.shouldOfferMigration)
    }

    func testRulesSelectionCreatesAgentsWhenNoRulesExist() {
        let selection = AgentProjectFileLayout.selectRulesFile(
            hasAgents: false,
            hasLegacyClaudeDirectory: false,
            hasLegacyClaudeRoot: false
        )

        XCTAssertEqual(selection.kind, .missing)
        XCTAssertEqual(selection.readRelativePath, "AGENTS.md")
        XCTAssertEqual(selection.writeRelativePath, "AGENTS.md")
        XCTAssertFalse(selection.shouldOfferMigration)
    }

    func testSkillLookupKeepsOpenCodeFirstWithLegacyFallbacks() {
        XCTAssertEqual(
            AgentProjectFileLayout.skillLookupRelativePaths,
            [".opencode/skills", ".claude/skills", ".agents/skills"]
        )
    }

    func testAttachmentReferencesUseCodeAgentsDirectoryAndDisplayLegacyNames() {
        XCTAssertEqual(
            AgentProjectFileLayout.attachmentReference(fileName: "12345678-report.pdf"),
            ".codeagents/attachments/12345678-report.pdf"
        )
        XCTAssertEqual(
            AgentProjectFileLayout.attachmentDisplayName(for: ".codeagents/attachments/12345678-report.pdf"),
            "report.pdf"
        )
        XCTAssertEqual(
            AgentProjectFileLayout.attachmentDisplayName(for: ".claude/attachments/abcdef12-legacy.png"),
            "legacy.png"
        )
    }

    func testIdentityPathsUseCodeAgentsPrimaryAndClaudeFallback() {
        XCTAssertEqual(AgentProjectFileLayout.identityRelativePath, ".codeagents/codeagents.json")
        XCTAssertEqual(AgentProjectFileLayout.legacyIdentityRelativePath, ".claude/codeagents.json")
        XCTAssertEqual(
            AgentProjectFileLayout.remotePath(projectPath: "/workspace/app", relativePath: AgentProjectFileLayout.identityRelativePath),
            "/workspace/app/.codeagents/codeagents.json"
        )
    }
}

import XCTest
@testable import CodeAgentsMobile

final class AgentRulesAssemblyTests: XCTestCase {
    func testAspectPathsLiveUnderCodeAgentsRules() {
        XCTAssertEqual(AgentRulesAspect.personality.relativePath, ".codeagents/rules/personality.md")
        XCTAssertEqual(AgentRulesAspect.codeAgentsUI.relativePath, ".codeagents/rules/codeagents-ui.md")
        XCTAssertEqual(AgentProjectFileLayout.rulesDirectoryRelativePath, ".codeagents/rules")
        XCTAssertEqual(AgentProjectFileLayout.rulesPersonalityRelativePath, ".codeagents/rules/personality.md")
        XCTAssertEqual(AgentProjectFileLayout.rulesUIRelativePath, ".codeagents/rules/codeagents-ui.md")
    }

    func testAssembleWrapsAspectsWithMarkers() {
        let assembled = AgentRulesAssembly.assemble(
            personality: "Be concise and warm.",
            uiRules: "FORCE-WIDGETS:\n- tables"
        )

        XCTAssertTrue(assembled.contains("# Agent Rules"))
        XCTAssertTrue(assembled.contains(AgentRulesAspect.personality.startMarker))
        XCTAssertTrue(assembled.contains(AgentRulesAspect.personality.endMarker))
        XCTAssertTrue(assembled.contains(AgentRulesAspect.codeAgentsUI.startMarker))
        XCTAssertTrue(assembled.contains("Be concise and warm."))
        XCTAssertTrue(assembled.contains("FORCE-WIDGETS:"))
        XCTAssertTrue(assembled.contains(".codeagents/rules/"))
    }

    func testExtractAspectsFromManagedEnvelope() {
        let assembled = AgentRulesAssembly.assemble(
            personality: "Domain expert in finance.",
            uiRules: "Use tables for statements."
        )
        let extracted = AgentRulesAssembly.extractAspects(from: assembled)

        XCTAssertEqual(extracted.personality, "Domain expert in finance.")
        XCTAssertEqual(extracted.uiRules, "Use tables for statements.")
    }

    func testExtractAspectsFromLegacyMonolithStripsStockUI() {
        let monolith = """
        You are a helpful research partner.

        \(CodeAgentsUIRules.rulesMarkdown)
        """
        let extracted = AgentRulesAssembly.extractAspects(from: monolith)

        XCTAssertEqual(extracted.personality, "You are a helpful research partner.")
        XCTAssertNil(extracted.uiRules)
    }

    func testStripKnownUIContentRemovesToolCallGuard() {
        let content = """
        Prefer short answers.

        \(CodeAgentsUIRules.toolCallGuardMarkdown)
        """
        let stripped = AgentRulesAssembly.stripKnownUIContent(from: content)
        XCTAssertEqual(stripped, "Prefer short answers.")
        XCTAssertFalse(stripped.contains("codeagents-ui is NOT a tool"))
    }

    func testContainsManagedMarkers() {
        let assembled = AgentRulesAssembly.assemble(personality: "x", uiRules: "y")
        XCTAssertTrue(AgentRulesAssembly.containsManagedMarkers(assembled))
        XCTAssertFalse(AgentRulesAssembly.containsManagedMarkers("plain rules"))
    }
}

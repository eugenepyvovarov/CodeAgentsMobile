import XCTest
@testable import CodeAgentsMobile

@MainActor
final class AgentSkillRemoteScanTests: XCTestCase {
    func testParseRemoteSkillScanOutput() {
        let output = """
        ___SKILL_BEGIN___
        super-imagine
        .opencode/skills/super-imagine
        ---
        name: super-imagine
        description: Image gen skill
        ---

        # Super
        ___SKILL_END___
        ___SKILL_BEGIN___
        site-domain-monitoring
        .opencode/skills/site-domain-monitoring
        ---
        name: Site Domain Monitoring
        description: Watch domains
        ---
        ___SKILL_END___
        """

        let skills = AgentSkillSyncService.shared.parseRemoteSkillScanOutput(output)
        XCTAssertEqual(skills.count, 2)
        XCTAssertEqual(skills[0].slug, "super-imagine")
        XCTAssertEqual(skills[0].relativePath, ".opencode/skills/super-imagine")
        XCTAssertEqual(skills[0].summary, "Image gen skill")
        XCTAssertEqual(skills[1].slug, "site-domain-monitoring")
        XCTAssertTrue(skills[1].name.localizedCaseInsensitiveContains("domain"))
    }

    func testParseRemoteSkillScanOutputDedupesSlug() {
        let output = """
        ___SKILL_BEGIN___
        demo
        .opencode/skills/demo
        ---
        name: Demo A
        ---
        ___SKILL_END___
        ___SKILL_BEGIN___
        demo
        .claude/skills/demo
        ---
        name: Demo B
        ---
        ___SKILL_END___
        """
        let skills = AgentSkillSyncService.shared.parseRemoteSkillScanOutput(output)
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "Demo A")
    }
}

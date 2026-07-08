import XCTest
@testable import CodeAgentsMobile

final class OpenCodePromptBuilderTests: XCTestCase {
    func testBuildAddsSystemRulesAndTextPart() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: "msg_fixture",
            composedPrompt: "  Hello OpenCode  ",
            projectPath: "/workspace/app",
            model: OpenCodePromptModel(providerID: "minimax", modelID: "MiniMax-M2.7"),
            systemRules: "CodeAgents rules"
        )

        XCTAssertEqual(result.payload.messageID, "msg_fixture")
        XCTAssertEqual(result.payload.model?.fullID, "minimax/MiniMax-M2.7")
        XCTAssertEqual(result.payload.system, "CodeAgents rules")
        XCTAssertNil(result.payload.tools)
        XCTAssertEqual(result.payload.parts.count, 1)
        XCTAssertEqual(result.payload.parts[0].type, "text")
        XCTAssertEqual(result.payload.parts[0].text, "Hello OpenCode")
    }

    func testBuildInjectsCodeAgentsUIRulesByDefault() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: nil,
            composedPrompt: "Show a chart of the last three runs.",
            projectPath: "/workspace/app"
        )

        let system = try XCTUnwrap(result.payload.system)
        XCTAssertTrue(system.contains("FORCE-WIDGETS"))
        XCTAssertTrue(system.contains("codeagents-ui is NOT a tool"))
        XCTAssertTrue(system.contains("fenced code blocks"))
    }

    func testBuildOmitsAppUUIDMessageIDBecauseOpenCodeRequiresNativeIDs() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: UUID().uuidString,
            composedPrompt: "Hello OpenCode",
            projectPath: "/workspace/app",
            systemRules: "CodeAgents rules"
        )

        XCTAssertNil(result.payload.messageID)
        let body = try OpenCodeSessionJSON.encode(result.payload)
        XCTAssertFalse(body.contains("messageID"))
    }

    func testBuildConvertsFileReferencesToFileParts() throws {
        let prompt = """
        @README.txt
        @docs/My File.pdf

        Summarize these files.
        """

        let result = try OpenCodePromptBuilder.build(
            messageID: nil,
            composedPrompt: prompt,
            projectPath: "/workspace/app",
            systemRules: "rules"
        )

        XCTAssertEqual(result.fileReferences.map(\.absolutePath), [
            "/workspace/app/README.txt",
            "/workspace/app/docs/My File.pdf"
        ])
        XCTAssertEqual(result.payload.parts.map(\.type), ["text", "file", "file"])
        XCTAssertEqual(result.payload.parts[0].text, "Summarize these files.")
        XCTAssertEqual(result.payload.parts[1].filename, "README.txt")
        XCTAssertEqual(result.payload.parts[1].mime, "text/plain")
        XCTAssertEqual(result.payload.parts[1].url, "file:///workspace/app/README.txt")
        XCTAssertEqual(result.payload.parts[2].filename, "My File.pdf")
        XCTAssertEqual(result.payload.parts[2].mime, "application/pdf")
        XCTAssertEqual(result.payload.parts[2].url, "file:///workspace/app/docs/My%20File.pdf")
    }

    func testBuildAddsSkillInstructionAndSkillTool() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: nil,
            composedPrompt: "/agent-browser Inspect localhost",
            projectPath: "/workspace/app",
            systemRules: "rules"
        )

        XCTAssertEqual(result.skillReference?.slug, "agent-browser")
        XCTAssertEqual(result.skillReference?.skillFilePaths, [
            "/workspace/app/.opencode/skills/agent-browser/SKILL.md",
            "/workspace/app/.claude/skills/agent-browser/SKILL.md",
            "/workspace/app/.agents/skills/agent-browser/SKILL.md"
        ])
        XCTAssertEqual(result.payload.tools?["skill"], true)
        XCTAssertTrue(result.payload.system?.contains("OpenCode skill request") == true)
        XCTAssertTrue(result.payload.system?.contains("agent-browser") == true)
        XCTAssertEqual(result.payload.parts.first?.text, "Inspect localhost")
    }

    func testBuildUsesFallbackTextForAttachmentOnlyPrompt() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: nil,
            composedPrompt: "@screenshot.png",
            projectPath: "/workspace/app",
            systemRules: ""
        )

        XCTAssertNil(result.payload.system)
        XCTAssertEqual(result.payload.parts.map(\.type), ["text", "file"])
        XCTAssertEqual(result.payload.parts[0].text, "Use the attached file(s) for this request.")
    }

    func testBuildIncludesThinkingVariantWhenProvided() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: "msg_fixture",
            composedPrompt: "Think carefully",
            projectPath: "/workspace/app",
            model: OpenCodePromptModel(providerID: "openai", modelID: "gpt-5.5"),
            variant: "high",
            systemRules: "rules"
        )

        XCTAssertEqual(result.payload.variant, "high")
        let body = try OpenCodeSessionJSON.encode(result.payload)
        XCTAssertTrue(body.contains("\"variant\":\"high\""))
    }

    func testBuildOmitsEmptyThinkingVariant() throws {
        let result = try OpenCodePromptBuilder.build(
            messageID: nil,
            composedPrompt: "Hello",
            projectPath: "/workspace/app",
            variant: "   ",
            systemRules: "rules"
        )

        let body = try OpenCodeSessionJSON.encode(result.payload)
        XCTAssertFalse(body.contains("variant"))
    }

}

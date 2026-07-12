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

    // MARK: - Active session pin reconcile

    func testActiveSessionPinReconcileKeepsMatchingWrite() {
        XCTAssertEqual(
            OpenCodeActiveSessionPinReconcile.action(
                writtenSessionId: "ses_aaa",
                currentSessionId: "ses_aaa"
            ),
            .none
        )
    }

    func testActiveSessionPinReconcileRepinsWhenSessionChanged() {
        XCTAssertEqual(
            OpenCodeActiveSessionPinReconcile.action(
                writtenSessionId: "ses_old",
                currentSessionId: "ses_new"
            ),
            .pin("ses_new")
        )
    }

    func testActiveSessionPinReconcileClearsWhenSessionRemoved() {
        XCTAssertEqual(
            OpenCodeActiveSessionPinReconcile.action(
                writtenSessionId: "ses_old",
                currentSessionId: nil
            ),
            .clear
        )
    }

    // MARK: - Batched reference validation

    func testReferenceValidatorShellUsesSkillORAndFileAND() {
        let command = OpenCodePromptReferenceValidator.shellCommand(
            skillPaths: ["/a/SKILL.md", "/b/SKILL.md"],
            filePaths: ["/proj/.codeagents/attachments/1.png", "/proj/doc.txt"],
            escape: SSHShellQuoting.quote
        )

        // Must run under bash so fish login shells do not parse POSIX if/fi.
        XCTAssertTrue(command.hasPrefix("bash -c "), command)
        XCTAssertTrue(command.contains("/a/SKILL.md"), command)
        XCTAssertTrue(command.contains("/b/SKILL.md"), command)
        XCTAssertTrue(command.contains("||"), command)
        XCTAssertTrue(command.contains("MISSING_SKILL"), command)
        XCTAssertTrue(command.contains("MISSING_FILE:0"), command)
        XCTAssertTrue(command.contains("MISSING_FILE:1"), command)
        XCTAssertTrue(command.contains("echo OK"), command)
    }

    func testReferenceValidatorShellQuotesScriptForNestedLoginShell() {
        let command = OpenCodePromptReferenceValidator.shellCommand(
            skillPaths: [],
            filePaths: ["/tmp/it's-a-file.png"],
            escape: SSHShellQuoting.quote
        )
        XCTAssertTrue(command.hasPrefix("bash -c "), command)
        // Path body survives quoting (apostrophe may be split as '\'' inside the bash -c payload).
        XCTAssertTrue(command.contains("s-a-file.png"), command)
        XCTAssertTrue(command.contains("MISSING_FILE:0"), command)
        // Outer payload is a single-quoted bash -c argument (SSHShellQuoting.quote).
        XCTAssertTrue(command.contains("bash -c '"), command)
    }

    func testReferenceValidatorParseOK() {
        let error = OpenCodePromptReferenceValidator.parseFailure(
            output: "OK\n",
            skillSlug: "demo",
            skillPaths: ["/a"],
            filePaths: ["/b"]
        )
        XCTAssertNil(error)
    }

    func testReferenceValidatorParseMissingSkill() {
        let error = OpenCodePromptReferenceValidator.parseFailure(
            output: "MISSING_SKILL\n",
            skillSlug: "demo-skill",
            skillPaths: ["/a/SKILL.md"],
            filePaths: []
        )
        XCTAssertEqual(
            error,
            .missingSkill(slug: "demo-skill", checkedPaths: ["/a/SKILL.md"])
        )
    }

    func testReferenceValidatorParseMissingFileByIndex() {
        let error = OpenCodePromptReferenceValidator.parseFailure(
            output: "MISSING_FILE:1\n",
            skillSlug: nil,
            skillPaths: [],
            filePaths: ["/first.png", "/second.png"]
        )
        XCTAssertEqual(error, .missingAttachment("/second.png"))
    }

}

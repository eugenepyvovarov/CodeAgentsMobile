import XCTest
@testable import CodeAgentsMobile

final class ChatSkillPromptBuilderTests: XCTestCase {
    func testBuildWithoutSkillReturnsTrimmedMessage() {
        let result = ChatSkillPromptBuilder.build(message: "  Hello  ")
        XCTAssertEqual(result, "Hello")
    }

    func testBuildWithSkillAddsSkillHeaderAndMessage() {
        let result = ChatSkillPromptBuilder.build(
            message: "Do the thing",
            skillName: "Agent Browser",
            skillSlug: "agent-browser"
        )
        XCTAssertEqual(result, "/agent-browser Do the thing")
    }

    func testBuildWithLeadingSlashInSlugGetsNormalized() {
        let result = ChatSkillPromptBuilder.build(message: "Hi", skillSlug: "/brainstorming")
        XCTAssertEqual(result, "/brainstorming Hi")
    }

    func testBuildWithWhitespaceOnlyMessageSendsOnlySkillHeader() {
        let result = ChatSkillPromptBuilder.build(message: "   \n  ", skillName: "Commit")
        XCTAssertEqual(result, "/commit")
    }

    func testBuildWithFileReferencesPrefixesAtAndPlacesBeforeMessage() {
        let result = ChatSkillPromptBuilder.build(
            message: "Summarize these files",
            fileReferences: ["README.md", "@Package.swift"]
        )
        XCTAssertEqual(result, "@README.md\n@Package.swift\n\nSummarize these files")
    }

    func testBuildWithSkillAndFileReferencesWhenMessageEmpty() {
        let result = ChatSkillPromptBuilder.build(
            message: "   ",
            skillName: "Agent Browser",
            skillSlug: "agent-browser",
            fileReferences: ["docs/README.md"]
        )
        XCTAssertEqual(result, "/agent-browser\n\n@docs/README.md")
    }
}

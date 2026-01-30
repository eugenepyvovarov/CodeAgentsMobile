import XCTest
@testable import CodeAgentsMobile

final class ComposedPromptParserTests: XCTestCase {
    func testParseEmptyPromptReturnsEmptyComponents() {
        let parsed = ComposedPromptParser.parse("")
        XCTAssertEqual(parsed, ComposedPromptComponents(message: "", skillName: nil, skillSlug: nil, fileReferences: []))
    }

    func testParseSlashCommandWithInlineMessage() {
        let prompt = "/agent-browser Do the thing"
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertNil(parsed.skillName)
        XCTAssertEqual(parsed.skillSlug, "agent-browser")
        XCTAssertEqual(parsed.fileReferences, [])
        XCTAssertEqual(parsed.message, "Do the thing")
    }

    func testParseSlashCommandWithFilesAndMessage() {
        let prompt = """
        /agent-browser Do the thing

        @README.md
        @docs/guide.md
        """
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertNil(parsed.skillName)
        XCTAssertEqual(parsed.skillSlug, "agent-browser")
        XCTAssertEqual(parsed.fileReferences, ["README.md", "docs/guide.md"])
        XCTAssertEqual(parsed.message, "Do the thing")
    }

    func testParseSkillNameHeaderAndMessage() {
        let prompt = "Use the “Agent Browser” skill.\n\nDo the thing"
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertEqual(parsed.skillName, "Agent Browser")
        XCTAssertNil(parsed.skillSlug)
        XCTAssertEqual(parsed.fileReferences, [])
        XCTAssertEqual(parsed.message, "Do the thing")
    }

    func testParseSkillNameAndSlugHeaderWithFilesAndMessage() {
        let prompt = """
        Use the “Agent Browser” skill (slug: agent-browser).

        @README.md
        @docs/guide.md

        Summarize these files.
        """
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertEqual(parsed.skillName, "Agent Browser")
        XCTAssertEqual(parsed.skillSlug, "agent-browser")
        XCTAssertEqual(parsed.fileReferences, ["README.md", "docs/guide.md"])
        XCTAssertEqual(parsed.message, "Summarize these files.")
    }

    func testParseSlugOnlyHeader() {
        let prompt = "Use the skill with slug “agent-browser”.\n\nHello"
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertNil(parsed.skillName)
        XCTAssertEqual(parsed.skillSlug, "agent-browser")
        XCTAssertEqual(parsed.fileReferences, [])
        XCTAssertEqual(parsed.message, "Hello")
    }

    func testParseFileReferencesOnly() {
        let prompt = "@README.md\n@docs/guide.md\n\nDo it"
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertNil(parsed.skillName)
        XCTAssertNil(parsed.skillSlug)
        XCTAssertEqual(parsed.fileReferences, ["README.md", "docs/guide.md"])
        XCTAssertEqual(parsed.message, "Do it")
    }

    func testParseDoesNotTreatMixedSectionAsFileReferences() {
        let prompt = "@README.md\nDo it"
        let parsed = ComposedPromptParser.parse(prompt)

        XCTAssertEqual(parsed.fileReferences, [])
        XCTAssertEqual(parsed.message, "@README.md\nDo it")
    }
}

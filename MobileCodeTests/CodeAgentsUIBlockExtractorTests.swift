import XCTest
@testable import CodeAgentsMobile

final class CodeAgentsUIBlockExtractorTests: XCTestCase {
    func testSegmentsPreservesOrderWithUIBlock() {
        let text = """
        Intro text
        ```codeagents-ui
        { "type": "codeagents_ui", "version": 1, "elements": [
          { "type": "markdown", "id": "m1", "text": "Widget text" }
        ] }
        ```
        Outro text
        """

        let segments = CodeAgentsUIBlockExtractor.segments(from: text)
        XCTAssertEqual(segments.count, 3)

        if case .markdown(let intro) = segments[0] {
            XCTAssertTrue(intro.contains("Intro text"))
        } else {
            XCTFail("Expected markdown segment")
        }

        if case .ui(let block) = segments[1] {
            XCTAssertEqual(block.elements.count, 1)
        } else {
            XCTFail("Expected UI segment")
        }

        if case .markdown(let outro) = segments[2] {
            XCTAssertTrue(outro.contains("Outro text"))
        } else {
            XCTFail("Expected markdown segment")
        }
    }

    func testSegmentsLeavesUnclosedFenceAsMarkdown() {
        let text = """
        Intro text
        ```codeagents-ui
        { "type": "codeagents_ui", "version": 1, "elements": [
          { "type": "markdown", "id": "m1", "text": "Widget text" }
        ] }
        """

        let segments = CodeAgentsUIBlockExtractor.segments(from: text)
        XCTAssertEqual(segments.count, 1)

        if case .markdown(let intro) = segments[0] {
            XCTAssertTrue(intro.contains("Intro text"))
        } else {
            XCTFail("Expected markdown segment")
        }
    }

    func testSegmentsTreatsInvalidJSONAsMarkdown() {
        let text = """
        ```codeagents-ui
        { "type": "codeagents_ui", "version": 1, "elements": [ }
        ```
        """

        let segments = CodeAgentsUIBlockExtractor.segments(from: text)
        XCTAssertTrue(segments.isEmpty)
    }

    func testSegmentsAcceptsUnderscoreFenceLabel() {
        let text = """
        ```codeagents_ui
        { "type": "codeagents_ui", "version": 1, "elements": [
          { "type": "markdown", "id": "m1", "text": "Widget text" }
        ] }
        ```
        """

        let segments = CodeAgentsUIBlockExtractor.segments(from: text)
        XCTAssertEqual(segments.count, 1)
        if case .ui = segments[0] {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected UI segment")
        }
    }
}

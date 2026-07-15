import SwiftUI
import XCTest
@testable import CodeAgentsMobile

final class MarkdownAttributedStringBuilderTests: XCTestCase {
    func testMarkdownLinkPreservesDestinationAndHasVisibleStyling() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.com/docs"))
        let attributed = MarkdownAttributedStringBuilder.make(
            from: "Read the [documentation](https://example.com/docs)."
        )

        let linkRun = try XCTUnwrap(attributed.runs.first { $0.link == destination })

        XCTAssertEqual(linkRun.foregroundColor, .accentColor)
        XCTAssertNotNil(linkRun.underlineStyle)
    }

    func testBareWebURLBecomesLink() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.com/status"))
        let attributed = MarkdownAttributedStringBuilder.make(
            from: "Check https://example.com/status for updates."
        )

        XCTAssertTrue(attributed.runs.contains { $0.link == destination })
    }

    func testBareWebURLInsideInlineCodeStaysUnlinked() {
        let attributed = MarkdownAttributedStringBuilder.make(
            from: "Run `curl https://example.com/status` in the terminal."
        )

        XCTAssertFalse(attributed.runs.contains { $0.link != nil })
    }

    func testOrdinaryTextStaysUnlinked() {
        let attributed = MarkdownAttributedStringBuilder.make(from: "No links here.")

        XCTAssertFalse(attributed.runs.contains { $0.link != nil })
    }
}

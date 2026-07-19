import XCTest
@testable import CodeAgentsMobile

final class NotificationPreviewTextTests: XCTestCase {
    func testKeepsProseAndRemovesCodeAgentsUIJSON() {
        let raw = """
        Fresh check complete. **1 alert.**
        ```codeagents-ui
        {
          "type": "codeagents_ui",
          "version": 1,
          "title": "Domain / SSL / HTTP status",
          "elements": [
            { "type": "markdown", "id": "status", "text": "One domain needs attention." }
          ]
        }
        ```
        """

        let preview = NotificationPreviewText.normalize(raw)

        XCTAssertEqual(preview, "Fresh check complete. **1 alert.**")
        XCTAssertFalse(preview?.contains("codeagents_ui") == true)
    }

    func testUsesWidgetTitleWhenReplyContainsOnlyWidget() {
        let raw = """
        ```codeagents_ui
        {
          "type": "codeagents_ui",
          "version": 1,
          "title": "Domain / SSL / HTTP status",
          "elements": [
            { "type": "markdown", "id": "status", "text": "One domain needs attention." }
          ]
        }
        ```
        """

        XCTAssertEqual(
            NotificationPreviewText.normalize(raw),
            "Domain / SSL / HTTP status"
        )
    }

    func testUsesWidgetElementWhenBlockHasNoTitle() {
        let raw = """
        ```codeagents-ui
        {
          "type": "codeagents_ui",
          "version": 1,
          "elements": [
            { "type": "markdown", "id": "status", "text": "One domain needs attention." }
          ]
        }
        ```
        """

        XCTAssertEqual(
            NotificationPreviewText.normalize(raw),
            "One domain needs attention."
        )
    }

    func testDropsUnclosedWidgetFenceAfterProse() {
        let raw = """
        Human-readable summary.
        ```codeagents-ui
        { "type": "codeagents_ui", "version": 1
        """

        XCTAssertEqual(NotificationPreviewText.normalize(raw), "Human-readable summary.")
    }

    func testTruncatesAfterRemovingWidgetPayload() {
        let raw = """
        Alpha beta gamma.
        ```codeagents-ui
        {
          "type": "codeagents_ui",
          "version": 1,
          "title": "A very long hidden widget title",
          "elements": [
            { "type": "markdown", "id": "status", "text": "Hidden widget content." }
          ]
        }
        ```
        Delta epsilon zeta.
        """

        XCTAssertEqual(
            NotificationPreviewText.normalize(raw, maxLength: 24),
            "Alpha beta gamma. Delta…"
        )
    }
}
